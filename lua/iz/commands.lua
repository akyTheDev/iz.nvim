local M = {}

---@type table<string, fun(args: string[])>
local subcommands = {}

---@param fargs string[]
function M.iz(fargs)
  local name = fargs[1]
  if not name then
    return require("iz.ui.workspace").open()
  end
  local fn = subcommands[name]
  if not fn then
    vim.notify("iz: unknown subcommand " .. name, vim.log.levels.ERROR)
    return
  end
  fn(vim.list_slice(fargs, 2))
end

function M.subcommands()
  return vim.tbl_keys(subcommands)
end

---@param name string
---@param fn fun(args: string[])
function M.register(name, fn)
  subcommands[name] = fn
end

--- Runs `fn` with the open workspace, or tells the user to open one.
---@param fn fun(ws: table)
local function with_workspace(fn)
  return function()
    local workspace = require("iz.ui.workspace")
    if not workspace.get() then
      vim.notify("iz: open the workspace with :Iz first", vim.log.levels.WARN)
      return
    end
    fn(workspace)
  end
end

M.register("comment", with_workspace(function(ws)
  ws.actions.comment_session()
end))

M.register("history", function()
  require("iz.async").run(function()
    local root = require("iz.git").toplevel(vim.fn.getcwd())
    local sessions = root and require("iz.lifecycle").list(root, { state = "completed" }) or {}
    if #sessions == 0 then
      vim.notify("iz: no closed sessions yet", vim.log.levels.INFO)
      return
    end
    vim.ui.select(sessions, {
      prompt = "iz sessions",
      format_item = function(s)
        return ("%s  %s"):format(s.id, require("iz.util").plural(#s.data.comments, "comment"))
      end,
    }, function(choice)
      if choice then
        require("iz.lifecycle").show(choice)
      end
    end)
  end)
end)

--- Closes the active Session, through the workspace when it is open.
function M.done()
  local workspace = require("iz.ui.workspace")
  if workspace.get() then
    return workspace.actions.done()
  end
  require("iz.async").run(function()
    local root = require("iz.git").toplevel(vim.fn.getcwd())
    if not root then
      error("not inside a git repository", 0)
    end
    local lock = require("iz.storage.lock")
    if not lock.acquire(root) then
      error("another Neovim owns this session; close it there", 0)
    end
    local session = require("iz.session").current(root)
    if not session then
      lock.release(root)
      vim.notify("iz: no active session", vim.log.levels.INFO)
      return
    end
    local function release()
      lock.release(root)
    end
    require("iz.lifecycle").done(session, release, release)
  end)
end

--- Copies `.iz/brief.md`, inbox instruction included, so any agent can answer.
function M.export()
  require("iz.async").run(function()
    local brief = require("iz.brief")
    local root = require("iz.git").toplevel(vim.fn.getcwd())
    local content = root and require("iz.storage").read_file(brief.path(root))
    if not content or vim.trim(content) == brief.EMPTY then
      vim.notify("iz: no pending comments to export", vim.log.levels.INFO)
      return
    end
    local ok = pcall(vim.fn.setreg, "+", content)
    if ok and vim.fn.getreg("+") == content then
      vim.notify("iz: Brief copied to the clipboard", vim.log.levels.INFO)
    else
      vim.fn.setreg('"', content)
      vim.notify('iz: no system clipboard; Brief copied to the " register', vim.log.levels.INFO)
    end
  end)
end

---@param remove boolean
function M.install_claude(remove)
  local claude = require("iz.claude")
  local ok, report = pcall(function()
    if remove then
      return claude.uninstall()
    end
    return claude.install({
      confirm = function(msg)
        return vim.fn.confirm(msg, "&Yes\n&No", 2) == 1
      end,
    })
  end)
  if not ok then
    vim.notify("iz: " .. tostring(report), vim.log.levels.ERROR)
    return
  end
  vim.notify("iz:\n" .. table.concat(report, "\n"), vim.log.levels.INFO)
end

return M
