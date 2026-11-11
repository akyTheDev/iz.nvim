-- One writer per worktree: the first Neovim to take `.iz/lock` writes, others read.
local storage = require("iz.storage")

local M = {}

---@param root string
local function lock_path(root)
  return storage.dir(root) .. "/lock"
end

---@param pid integer
local function alive(pid)
  local ok, err = vim.uv.kill(pid, 0)
  -- EPERM means the process exists but belongs to someone else.
  return ok == 0 or (err ~= nil and err:find("EPERM") ~= nil)
end

---@param root string
---@return table? owner pid and start time of the live holder, if any
function M.owner(root)
  local info = storage.read_json(lock_path(root))
  if info and info.pid and alive(info.pid) then
    return info
  end
  return nil
end

---@param root string
---@return boolean acquired
---@return table? owner the other live holder when not acquired
function M.acquire(root)
  local pid = vim.uv.os_getpid()
  local owner = M.owner(root)
  if owner and owner.pid ~= pid then
    return false, owner
  end
  storage.mkdirp(storage.dir(root))
  storage.write_json(lock_path(root), { pid = pid, started_at = require("iz.util").now() })
  return true
end

---@param root string
function M.release(root)
  local info = storage.read_json(lock_path(root))
  if info and info.pid == vim.uv.os_getpid() then
    os.remove(lock_path(root))
  end
end

return M
