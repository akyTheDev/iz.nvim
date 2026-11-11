-- Open Comments drawn as virtual lines under the code they are anchored to.
local comments = require("iz.session.comments")

local api = vim.api
local M = {}

M.ns = api.nvim_create_namespace("iz.comments")

local MAX = 100

---@param text string
local function first_line(text)
  local line = text:match("^[^\n]*")
  if vim.fn.strchars(line) > MAX then
    line = vim.fn.strcharpart(line, 0, MAX - 1) .. "…"
  end
  return line
end

---@param c iz.Comment
---@return table[] virt_lines
function M.virt_lines(c)
  local head = { { "  ┃ ", "IzComment" }, { c.id .. " ", "IzMuted" } }
  local claim = comments.claim(c)
  if claim then
    head[#head + 1] = { "[" .. claim .. "] ", "IzClaim" }
  end
  if c.anchor and c.anchor.state == "lost" then
    head[#head + 1] = { ("(lost, was line %d) "):format(c.line), "IzPartial" }
  end
  head[#head + 1] = { first_line(c.thread[1].body), "IzComment" }
  local out = { head }
  if #c.thread > 1 then
    local last = comments.last(c)
    local who = last.author == "agent" and "agent" or "you"
    out[#out + 1] = {
      { "  ┃   ↳ " .. who .. ": ", "IzMuted" },
      { first_line(last.body), "IzComment" },
    }
  end
  return out
end

---@param ctx iz.DiffContext
function M.draw(ctx)
  local left = api.nvim_win_get_buf(ctx.left_win)
  local right = api.nvim_win_get_buf(ctx.right_win)
  api.nvim_buf_clear_namespace(left, M.ns, 0, -1)
  api.nvim_buf_clear_namespace(right, M.ns, 0, -1)

  for _, c in ipairs(comments.for_file(ctx.session, ctx.file.path)) do
    if c.status == "open" and c.line then
      local buf = c.side == "old" and left or right
      -- Base line numbers mean nothing against the index.
      if not (c.side == "old" and ctx.left_rev == "index") then
        -- A lost comment stays at its last known line: the fix is usually right there.
        local row = math.min((c.end_line or c.line) - 1, api.nvim_buf_line_count(buf) - 1)
        pcall(api.nvim_buf_set_extmark, buf, M.ns, math.max(row, 0), 0, {
          virt_lines = M.virt_lines(c),
        })
      end
    end
  end
end

return M
