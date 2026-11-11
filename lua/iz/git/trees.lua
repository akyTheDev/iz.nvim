-- Tree snapshots built on a throwaway index so the user's real index is never touched.
local git = require("iz.git")
local storage = require("iz.storage")

local M = {}

local counter = 0

---@generic T
---@param root string
---@param fn fun(env: table<string, string>): T
---@return T
local function with_temp_index(root, fn)
  counter = counter + 1
  local tmp = ("%s/tmp-index-%d-%d"):format(storage.dir(root), vim.uv.os_getpid(), counter)
  local index = git.git_path(root, "index")
  local stat = vim.uv.fs_stat(index)
  if stat then
    assert(vim.uv.fs_copyfile(index, tmp))
    -- Git re-checks "racily clean" entries by comparing them with the index
    -- file's mtime. A fresh copy would look newer and hide same-size edits
    -- made right after the last index write, so keep the original times.
    local function t(ts)
      return ts.sec + ts.nsec / 1e9
    end
    assert(vim.uv.fs_utime(tmp, t(stat.atime), t(stat.mtime)))
  end
  local ok, result = pcall(fn, { GIT_INDEX_FILE = tmp })
  os.remove(tmp)
  os.remove(tmp .. ".lock")
  if not ok then
    error(result, 0)
  end
  return result
end

---@class iz.Trees
---@field index string Tree of the current index.
---@field work string Tree of the working tree, untracked files included.

--- Async: call inside `async.run`.
---@param root string
---@return iz.Trees
function M.snapshot(root)
  return with_temp_index(root, function(env)
    local index = vim.trim(git.run({ "write-tree" }, { cwd = root, env = env }))
    git.run({ "add", "-A" }, { cwd = root, env = env })
    local work = vim.trim(git.run({ "write-tree" }, { cwd = root, env = env }))
    return { index = index, work = work }
  end)
end

--- Snapshots the index as a commit under `refs/iz/sessions/<id>` so `git gc` keeps it.
--- Untracked files are not part of it: the agent usually creates them before
--- the user opens the Session, so they must show up as new.
--- Async: call inside `async.run`.
---@param root string
---@param id string
---@return string base commit hash
function M.create_base(root, id)
  local unmerged = git.run({ "ls-files", "-u" }, { cwd = root })
  if unmerged ~= "" then
    error("the index has unresolved conflicts; resolve them before starting a session", 0)
  end

  local tree = with_temp_index(root, function(env)
    return vim.trim(git.run({ "write-tree" }, { cwd = root, env = env }))
  end)

  local identity = {
    GIT_AUTHOR_NAME = "iz",
    GIT_AUTHOR_EMAIL = "iz@localhost",
    GIT_COMMITTER_NAME = "iz",
    GIT_COMMITTER_EMAIL = "iz@localhost",
  }
  local commit = vim.trim(git.run({ "commit-tree", tree, "-m", "iz base " .. id }, {
    cwd = root,
    env = identity,
  }))
  git.run({ "update-ref", "refs/iz/sessions/" .. id, commit }, { cwd = root })
  return commit
end

return M
