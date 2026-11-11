-- Stage, unstage, discard and undo. Every hunk operation recomputes the file
-- first and refuses to act when the hunk the caller saw no longer exists.
local diff = require("iz.git.diff")
local git = require("iz.git")
local hunks = require("iz.git.hunks")
local session_mod = require("iz.session")
local storage = require("iz.storage")

local M = {}

M.STALE = "the diff changed since it was shown; refresh and try again"

---@class iz.HunkRef
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer

---@param session iz.Session
---@param path string
---@param ref iz.HunkRef
---@return iz.FileView file
---@return iz.Hunk hunk
---@return iz.View view
local function locate(session, path, ref)
  local view = hunks.compute(session, { path })
  local file = view.by_path[path]
  for _, h in ipairs(file and file.hunks or {}) do
    if
      h.old_start == ref.old_start
      and h.old_count == ref.old_count
      and h.new_start == ref.new_start
      and h.new_count == ref.new_count
    then
      return file, h, view
    end
  end
  error(M.STALE, 0)
end

---@param root string
---@param patch string
---@param flags string[]
local function apply(root, patch, flags)
  local args = { "apply", "--unidiff-zero" }
  vim.list_extend(args, flags)
  table.insert(args, "-")
  local _, res = git.run(args, { cwd = root, stdin = patch, allow_fail = true })
  if res.code ~= 0 then
    -- `git apply` is all-or-nothing, so a failure leaves files untouched.
    error(M.STALE, 0)
  end
end

---@param session iz.Session
---@param entry table
---@param content string
---@param ext string
local function push_trash(session, entry, content, ext)
  local dir = storage.session_dir(session.root, session.id) .. "/trash"
  storage.mkdirp(dir)
  local name = ("%s-%d.%s"):format(os.date("%Y%m%d-%H%M%S"), #session.data.trash + 1, ext)
  storage.write_atomic(dir .. "/" .. name, content)
  entry.file = "trash/" .. name
  table.insert(session.data.trash, entry)
  session_mod.save(session)
end

--- Async. Approves the Hunk by applying its unapproved parts to the index.
---@param session iz.Session
---@param path string
---@param ref iz.HunkRef
function M.stage_hunk(session, path, ref)
  local file, hunk = locate(session, path, ref)
  if hunk.state == "staged" then
    return
  end
  local parts = hunks.overlapping(hunk, file.unstaged_diff.hunks, "new")
  apply(session.root, diff.patch(file.unstaged_diff, parts), { "--cached" })
end

--- Async. Takes the Hunk's approved parts back out of the index.
---@param session iz.Session
---@param path string
---@param ref iz.HunkRef
function M.unstage_hunk(session, path, ref)
  local _, hunk, view = locate(session, path, ref)
  local staged = hunks.diff_trees(session.root, session.data.base, view.trees.index, { path })[path]
  if not staged then
    return
  end
  -- Base -> index and Base -> working tree share the old side, so match on it.
  local parts = hunks.overlapping(hunk, staged.hunks, "old")
  if #parts > 0 then
    apply(session.root, diff.patch(staged, parts), { "--cached", "-R" })
  end
end

--- Async. Reverts the Hunk's unapproved parts in the working tree; approved code stays.
---@param session iz.Session
---@param path string
---@param ref iz.HunkRef
function M.discard_hunk(session, path, ref)
  local file, hunk = locate(session, path, ref)
  if hunk.state == "staged" then
    return
  end
  -- An unstaged hunk always has an index -> working tree diff.
  local u = assert(file.unstaged_diff)
  local patch = diff.patch(u, hunks.overlapping(hunk, u.hunks, "new"))
  apply(session.root, patch, { "-R" })
  push_trash(session, { kind = "patch", path = path }, patch, "patch")
end

--- Async.
---@param session iz.Session
---@param path string
function M.stage_file(session, path)
  git.run({ "add", "-A", "--", path }, { cwd = session.root })
end

--- Async. Puts the file's index entry back to how it was at Base.
---@param session iz.Session
---@param path string
function M.unstage_file(session, path)
  local root, base = session.root, session.data.base
  if git.exists(root, base, path) then
    git.run({ "restore", "--staged", "--source=" .. base, "--", path }, { cwd = root })
  else
    git.run({ "rm", "--cached", "--quiet", "--ignore-unmatch", "--", path }, { cwd = root })
  end
end

--- Async. Reverts every unapproved change in the file.
---@param session iz.Session
---@param path string
function M.discard_file(session, path)
  local root = session.root
  local view = hunks.compute(session, { path })
  local u = view.by_path[path] and view.by_path[path].unstaged_diff
  if not u then
    return
  end
  if not u.binary and #u.hunks > 0 then
    local patch = diff.patch(u, u.hunks)
    apply(root, patch, { "-R" })
    push_trash(session, { kind = "patch", path = path }, patch, "patch")
    return
  end
  -- Binary or mode-only: keep a full copy, then restore the index version.
  local abs = root .. "/" .. path
  local content = storage.read_file(abs)
  if git.exists(root, ":0", path) then
    git.run({ "checkout", "--", path }, { cwd = root })
  else
    os.remove(abs)
  end
  if content then
    push_trash(session, { kind = "copy", path = path }, content, "bin")
  end
end

--- Async. Re-applies the most recent discard.
---@param session iz.Session
---@return table? entry the restored trash entry, nil when the stack is empty
function M.undo_discard(session)
  local entry = session.data.trash[#session.data.trash]
  if not entry then
    return nil
  end
  local stored = storage.session_dir(session.root, session.id) .. "/" .. entry.file
  local content = assert(storage.read_file(stored), "trash entry missing: " .. stored)
  if entry.kind == "patch" then
    local ok = pcall(apply, session.root, content, {})
    if not ok then
      error("cannot re-apply the discarded change; it is kept at " .. stored, 0)
    end
  else
    local abs = session.root .. "/" .. entry.path
    storage.mkdirp(vim.fs.dirname(abs))
    storage.write_atomic(abs, content)
  end
  table.remove(session.data.trash)
  session_mod.save(session)
  return entry
end

return M
