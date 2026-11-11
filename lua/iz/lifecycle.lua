-- Closing a Session. There is no carry-over: open Comments are either closed
-- as ignored or the close is cancelled, so nothing disappears silently.
local brief = require("iz.brief")
local comments = require("iz.session.comments")
local panel = require("iz.ui.panel")
local session_mod = require("iz.session")
local storage = require("iz.storage")
local util = require("iz.util")

local M = {}

---@param session iz.Session
local function finish(session)
  session_mod.complete(session)
  -- Every comment is closed now, so this writes the empty Brief.
  brief.update(session)
  vim.notify(
    "iz: session closed. Consider /clear in Claude Code before the next task.",
    vim.log.levels.INFO
  )
end

--- Asks about open Comments when there are any, then completes the Session.
---@param session iz.Session
---@param on_done? fun() called only when the Session was closed
---@param on_cancel? fun() called when the user kept the Session open
function M.done(session, on_done, on_cancel)
  local open = vim.tbl_filter(function(c)
    return c.status == "open"
  end, session.data.comments)

  if #open == 0 then
    finish(session)
    return on_done and on_done()
  end

  local close = ("Close %s as ignored and finish"):format(util.plural(#open, "open comment"))
  local prompt = { prompt = "iz: this session still has open comments" }
  vim.ui.select({ close, "Cancel" }, prompt, function(choice)
    if choice ~= close then
      if on_cancel then
        on_cancel()
      end
      return
    end
    for _, c in ipairs(open) do
      comments.set_status(session, c, "ignored")
    end
    finish(session)
    if on_done then
      on_done()
    end
  end)
end

---@param root string
---@param filter? { state?: "active"|"completed" }
---@return iz.Session[] newest first
function M.list(root, filter)
  local out = {}
  local dir = storage.dir(root) .. "/sessions"
  if not vim.uv.fs_stat(dir) then
    return out
  end
  for name, kind in vim.fs.dir(dir) do
    if kind == "directory" then
      local ok, s = pcall(session_mod.load, root, name)
      if ok and s and not (filter and filter.state and s.data.state ~= filter.state) then
        out[#out + 1] = s
      end
    end
  end
  table.sort(out, function(a, b)
    return a.data.created_at > b.data.created_at
  end)
  return out
end

--- Shows a past Session's Comments and threads in a read-only tab.
---@param session iz.Session
function M.show(session)
  local lines = panel.render(session)
  vim.cmd("tabnew")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.wo.winbar = (" iz · %s · %s"):format(session.id, session.data.state)
end

return M
