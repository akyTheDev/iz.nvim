-- A Comment's whole thread in a float: where long messages are read and
-- answered. The panel and the inline comments only summarise.
local comments = require("iz.session.comments")
local config = require("iz.config")
local format = require("iz.ui.format")
local hl = require("iz.ui.highlights")

local api = vim.api
local M = {}

local AUTHOR_HL = {
  user = "IzThreadUser",
  agent = "IzThreadAgent",
  coreviewer = "IzThreadCoreviewer",
}

---@param c iz.Comment
---@return string[] lines, table[] marks `{ line, group, first_col, last_col }`, 1-based line
function M.render(c)
  local lines, marks = {}, {}
  if c.anchor and c.anchor.state == "lost" then
    lines[#lines + 1] = "Originally on:"
    marks[#marks + 1] = { #lines, "IzMuted", 0, #lines[#lines] }
    lines[#lines + 1] = "```"
    vim.list_extend(lines, vim.split(c.anchor.snippet, "\n"))
    lines[#lines + 1] = "```"
  end
  for _, m in ipairs(c.thread) do
    if #lines > 0 then
      lines[#lines + 1] = ""
    end
    -- Plain text with a highlight, not markdown bold: conceal would show the
    -- `**` again whenever the cursor is on the line.
    local who = format.who(m)
    local head = who
    if m.claim then
      head = head .. " · " .. m.claim
    end
    lines[#lines + 1] = head
    marks[#marks + 1] = { #lines, AUTHOR_HL[m.author] or "IzThreadUser", 0, #who }
    if #head > #who then
      marks[#marks + 1] = { #lines, "IzClaim", #who, #head }
    end
    local body = format.body(m)
    vim.list_extend(lines, vim.split(body, "\n"))
    if body ~= m.body then
      marks[#marks + 1] = { #lines, "IzMuted", 0, #body }
    end
  end
  return lines, marks
end

---@class iz.ThreadActions
---@field reply fun(c: iz.Comment)
---@field resolve fun(c: iz.Comment)
---@field ignore fun(c: iz.Comment)
---@field reopen fun(c: iz.Comment)
---@field send fun(c: iz.Comment)

---@param c iz.Comment
---@param actions iz.ThreadActions
---@return integer win
function M.open(c, actions)
  local lines, marks = M.render(c)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for _, m in ipairs(marks) do
    api.nvim_buf_set_extmark(buf, hl.ns, m[1] - 1, m[3], { end_col = m[4], hl_group = m[2] })
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"

  -- Wide enough to read prose, with room to grow for long threads.
  local max_width = math.max(1, vim.o.columns - 6)
  local width = math.min(max_width, math.max(72, math.floor(vim.o.columns * 0.6)), 110)
  local text_width = width - 2 -- the sign column pads the text
  local rows = 0
  for _, l in ipairs(lines) do
    rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / text_width))
  end
  local max_height = math.max(1, vim.o.lines - 8)
  local height = math.min(max_height, math.max(rows + 1, 12))

  local k = config.options.keymaps.panel
  local hints = {}
  local send = comments.suggested(c) and k.send or nil
  for _, h in ipairs({
    { send, "send" },
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
  vim.wo[win].breakindent = true
  vim.wo[win].conceallevel = 2
  -- Read-only text: keep markdown rendered on the cursor line too.
  vim.wo[win].concealcursor = "nc"
  vim.wo[win].signcolumn = "yes:1"
  vim.wo[win].cursorline = false

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
  map(send, actions.send)
  map(k.reply, actions.reply)
  map(k.resolve, actions.resolve)
  map(k.ignore, actions.ignore)
  map(k.reopen, actions.reopen)
  vim.keymap.set("n", "q", close, o)
  vim.keymap.set("n", "<Esc>", close, o)
  return win
end

return M
