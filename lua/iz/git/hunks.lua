-- The Session's view of the code: Hunks between Base and the working tree, each
-- classified Staged or Unstaged by comparing against index -> working tree.
local diff = require("iz.git.diff")
local git = require("iz.git")
local trees = require("iz.git.trees")

local M = {}

---@class iz.Hunk : iz.DiffHunk
---@field state "staged"|"unstaged"
---@field new_vs_index {[1]: integer, [2]: integer}[] Working-tree line ranges not yet in the index.

---@class iz.FileView
---@field path string
---@field kind "A"|"M"|"D"|"?" `?` = not in the index at all.
---@field binary boolean
---@field added integer
---@field removed integer
---@field hunks iz.Hunk[]
---@field staged integer
---@field unstaged integer
---@field diff iz.DiffFile Base -> working tree.
---@field unstaged_diff? iz.DiffFile Index -> working tree, nil when fully staged.

---@class iz.View
---@field trees iz.Trees
---@field files iz.FileView[]
---@field by_path table<string, iz.FileView>

--- Half-open line interval of a hunk side. An empty side (count 0) is the gap
--- after line `start`, represented as the point `start + 1`.
local function interval(start, count)
  if count == 0 then
    return start + 1, start + 1
  end
  return start, start + count
end

--- Whether two hunk sides touch. Empty sides count when they sit on or inside the other.
function M.overlaps(s1, c1, s2, c2)
  local a1, b1 = interval(s1, c1)
  local a2, b2 = interval(s2, c2)
  if c1 == 0 and c2 == 0 then
    return a1 == a2
  elseif c1 == 0 then
    return a2 <= a1 and a1 <= b2
  elseif c2 == 0 then
    return a1 <= a2 and a2 <= b1
  end
  return a1 < b2 and a2 < b1
end

---@param hunk iz.DiffHunk
---@param candidates iz.DiffHunk[]
---@param side "old"|"new"
---@return iz.DiffHunk[]
function M.overlapping(hunk, candidates, side)
  local start, count = hunk[side .. "_start"], hunk[side .. "_count"]
  return vim.tbl_filter(function(c)
    return M.overlaps(start, count, c[side .. "_start"], c[side .. "_count"])
  end, candidates)
end

---@param root string
---@param a string
---@param b string
---@param paths? string[]
---@return table<string, iz.DiffFile>, iz.DiffFile[]
function M.diff_trees(root, a, b, paths)
  local args = {
    "diff-tree", "-r", "-p", "-U0", "--no-renames", "--no-color", "--full-index", a, b,
  }
  if paths then
    table.insert(args, "--")
    vim.list_extend(args, paths)
  end
  local list = diff.parse(git.run(args, { cwd = root }))
  local by_path = {}
  for _, f in ipairs(list) do
    by_path[f.path] = f
  end
  return by_path, list
end

---@param file iz.DiffFile
---@param unstaged? iz.DiffFile Index -> working tree.
---@param staged? iz.DiffFile Base -> index.
---@param kind string
---@return iz.FileView
local function build_file(file, unstaged, staged, kind)
  local view = {
    path = file.path,
    kind = kind,
    binary = file.binary,
    added = 0,
    removed = 0,
    hunks = {},
    staged = 0,
    unstaged = 0,
    diff = file,
    unstaged_diff = unstaged,
  }
  for _, h in ipairs(file.hunks) do
    local hunk = vim.deepcopy(h) --[[@as iz.Hunk]]
    hunk.new_vs_index = {}
    local touching = unstaged and M.overlapping(h, unstaged.hunks, "new") or {}
    hunk.state = #touching == 0 and "staged" or "unstaged"
    -- Marking "new since approval" only makes sense where something was approved.
    local approved_before = staged and #M.overlapping(h, staged.hunks, "old") > 0
    for _, u in ipairs(approved_before and touching or {}) do
      if u.new_count > 0 then
        hunk.new_vs_index[#hunk.new_vs_index + 1] = { u.new_start, u.new_start + u.new_count - 1 }
      end
    end
    view[hunk.state] = view[hunk.state] + 1
    for _, line in ipairs(h.lines) do
      local c = line:sub(1, 1)
      if c == "+" then
        view.added = view.added + 1
      elseif c == "-" then
        view.removed = view.removed + 1
      end
    end
    view.hunks[#view.hunks + 1] = hunk
  end
  -- Binary and mode-only changes have no hunks; the file as a whole is the unit.
  if #file.hunks == 0 then
    local state = unstaged and "unstaged" or "staged"
    view[state] = 1
  end
  return view
end

--- Async: call inside `async.run`.
---@param session iz.Session
---@param paths? string[] Limit to these paths.
---@return iz.View
function M.compute(session, paths)
  local root, data = session.root, session.data
  local t = trees.snapshot(root)
  local _, session_files = M.diff_trees(root, data.base, t.work, paths)
  local unstaged = M.diff_trees(root, t.index, t.work, paths)
  local staged = M.diff_trees(root, data.base, t.index, paths)

  local view = { trees = t, files = {}, by_path = {} }
  for _, f in ipairs(session_files) do
    local u = unstaged[f.path]
    local kind = ({ added = "A", deleted = "D", modified = "M" })[f.status]
    if f.status == "added" and u and u.status == "added" then
      kind = "?"
    end
    local file = build_file(f, u, staged[f.path], kind)
    view.files[#view.files + 1] = file
    view.by_path[f.path] = file
  end
  table.sort(view.files, function(a, b)
    return a.path < b.path
  end)
  return view
end

return M
