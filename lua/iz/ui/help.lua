-- `?`: the keys of the window the cursor is in, read from the user's config.
local config = require("iz.config")

local api = vim.api
local M = {}

---@type table<string, {[1]: string, [2]: string}[]>
local SECTIONS = {
  files = {
    { "open", "open the file, cursor on its first hunk" },
    { "stage", "stage the file" },
    { "unstage", "unstage the file" },
    { "discard", "discard the file's unstaged changes" },
    { "undo_discard", "undo the last discard" },
    { "comment", "comment on the file" },
    { "toggle_filter", "show unstaged changes only" },
    { "toggle_panel", "go to the comment panel" },
    { "refresh", "refresh" },
    { "close", "close the workspace" },
  },
  diff = {
    { "next_hunk", "next hunk, then the next file" },
    { "prev_hunk", "previous hunk" },
    { "stage", "stage the hunk (visual: every hunk in range)" },
    { "unstage", "unstage the hunk" },
    { "discard", "discard the hunk" },
    { "undo_discard", "undo the last discard" },
    { "comment", "comment on the line (visual: the range)" },
    { "comment_hunk", "comment on the hunk" },
    { "open_thread", "read the comment thread on this line" },
    { "focus_files", "go to the file list" },
    { "toggle_filter", "show unstaged changes only" },
    { "toggle_panel", "go to the comment panel" },
    { "close", "close the workspace" },
  },
  panel = {
    { "jump", "open the thread and show its code" },
    { "reply", "reply" },
    { "resolve", "resolve" },
    { "ignore", "ignore" },
    { "reopen", "reopen" },
    { "move", "move the comment to the diff's cursor line" },
    { "close", "close the panel" },
  },
}

---@param section "files"|"diff"|"panel"
---@return string[]
function M.lines(section)
  local keys = config.options.keymaps[section]
  local rows = {}
  for _, entry in ipairs(SECTIONS[section]) do
    local lhs = keys[entry[1]]
    if lhs and lhs ~= "" then
      rows[#rows + 1] = { lhs, entry[2] }
    end
  end
  local width = 0
  for _, r in ipairs(rows) do
    width = math.max(width, vim.fn.strdisplaywidth(r[1]))
  end
  return vim.tbl_map(function(r)
    return (" %s%s  %s"):format(r[1], string.rep(" ", width - vim.fn.strdisplaywidth(r[1])), r[2])
  end, rows)
end

---@param section "files"|"diff"|"panel"
function M.open(section)
  local lines = M.lines(section)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l) + 1)
  end
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - #lines) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = #lines,
    border = "rounded",
    style = "minimal",
    title = " iz · " .. section .. " ",
    title_pos = "center",
  })
  for _, lhs in ipairs({ "q", "<Esc>", "?" }) do
    vim.keymap.set("n", lhs, function()
      api.nvim_win_close(win, true)
    end, { buffer = buf, nowait = true, silent = true })
  end
end

return M
