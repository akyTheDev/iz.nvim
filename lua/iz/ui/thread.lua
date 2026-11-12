-- A Comment's whole thread in a float: where long messages are read and
-- answered. The panel and the inline comments only summarise.
local config = require("iz.config")
local format = require("iz.ui.format")

local api = vim.api
local M = {}

---@param c iz.Comment
---@return string[]
function M.render(c)
  local lines = {}
  if c.anchor and c.anchor.state == "lost" then
    lines[#lines + 1] = "Originally on:"
    lines[#lines + 1] = "```"
    vim.list_extend(lines, vim.split(c.anchor.snippet, "\n"))
    lines[#lines + 1] = "```"
  end
  for _, m in ipairs(c.thread) do
    if #lines > 0 then
      lines[#lines + 1] = ""
    end
    local head = "**" .. format.who(m) .. "**"
    if m.claim then
      head = head .. " · " .. m.claim
    end
    lines[#lines + 1] = head
    vim.list_extend(lines, vim.split(m.body, "\n"))
  end
  return lines
end

---@class iz.ThreadActions
---@field reply fun(c: iz.Comment)
---@field resolve fun(c: iz.Comment)
---@field ignore fun(c: iz.Comment)
---@field reopen fun(c: iz.Comment)

---@param c iz.Comment
---@param actions iz.ThreadActions
---@return integer win
function M.open(c, actions)
  local lines = M.render(c)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"

  local width = math.min(90, vim.o.columns - 8)
  local rows = 0
  for _, l in ipairs(lines) do
    rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / width))
  end
  local height = math.max(1, math.min(rows, vim.o.lines - 8))

  local k = config.options.keymaps.panel
  local hints = {}
  for _, h in ipairs({
    { k.reply, "reply" },
    { k.resolve, "resolve" },
    { k.ignore, "ignore" },
    { k.reopen, "reopen" },
    { "q", "close" },
  }) do
    if h[1] and h[1] ~= "" then
      hints[#hints + 1] = h[1] .. " " .. h[2]
    end
  end

  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    border = "rounded",
    style = "minimal",
    title = " " .. format.headline(c) .. " · " .. c.status .. " ",
    title_pos = "center",
    footer = " " .. table.concat(hints, " · ") .. " ",
    footer_pos = "right",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].conceallevel = 2

  local function close()
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
  end
  local o = { buffer = buf, nowait = true, silent = true }
  local function map(lhs, fn)
    if lhs and lhs ~= "" then
      vim.keymap.set("n", lhs, function()
        close()
        fn(c)
      end, o)
    end
  end
  map(k.reply, actions.reply)
  map(k.resolve, actions.resolve)
  map(k.ignore, actions.ignore)
  map(k.reopen, actions.reopen)
  vim.keymap.set("n", "q", close, o)
  vim.keymap.set("n", "<Esc>", close, o)
  return win
end

return M
