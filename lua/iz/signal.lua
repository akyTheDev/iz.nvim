-- Listens for `.iz/stop`, written by the Claude Code Stop hook, so iz can react
-- when the agent finishes even while the workspace is closed.
local async = require("iz.async")
local git = require("iz.git")
local storage = require("iz.storage")

local M = {}

---@type { root: string, handle: uv.uv_fs_event_t }?
local active

M.FILE = "stop"

---@param root string
local function handle_stop(root)
  local path = storage.dir(root) .. "/" .. M.FILE
  if not vim.uv.fs_stat(path) then
    return
  end
  local workspace = require("iz.ui.workspace")
  local ws = workspace.get()
  if ws and ws.root == root then
    if not ws.readonly then
      os.remove(path)
      workspace.on_stop()
    end
  else
    -- Another live Neovim owns the session; the signal is for it.
    local owner = require("iz.storage.lock").owner(root)
    if owner and owner.pid ~= vim.uv.os_getpid() then
      return
    end
    os.remove(path)
    vim.notify("iz: agent finished · run :Iz to review", vim.log.levels.INFO)
  end
end

function M.stop()
  if active then
    active.handle:stop()
    active.handle:close()
    active = nil
  end
end

--- Watches `.iz/` of the repository at the cwd, if it has one.
function M.start()
  async.run(function()
    local root = git.toplevel(vim.fn.getcwd())
    if active and active.root == root then
      return
    end
    M.stop()
    if not root or not vim.uv.fs_stat(storage.dir(root)) then
      return
    end
    local handle = assert(vim.uv.new_fs_event())
    handle:start(storage.dir(root), {}, function(_, filename)
      if filename == M.FILE then
        vim.schedule(function()
          handle_stop(root)
        end)
      end
    end)
    active = { root = root, handle = handle }
    -- A signal written while Neovim was closed.
    handle_stop(root)
  end)
end

return M
