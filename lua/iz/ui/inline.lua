-- Open Comments drawn as one virtual line under the code they are anchored to:
-- who spoke last and the start of what they said. The thread view has the rest.
local comments = require("iz.session.comments")
local format = require("iz.ui.format")

local api = vim.api
local M = {}

M.ns = api.nvim_create_namespace("iz.comments")

---@param c iz.Comment
---@param width integer columns available for the line
---@return table[] virt_lines
function M.virt_lines(c, width)
  local last = comments.last(c)
  -- A Claim already says the agent spoke.
  local label = { comments.claim(c) or format.who(last) }
  local text = last.body
  if last.author == "user" and last.body == "" and #c.thread > 1 then
    -- Sent as it is: what was sent says more than who sent it.
    label[1], text = "sent", c.thread[#c.thread - 1].body
  end
  label[#label + 1] = format.anchor_state(c)
  local chunks = {
    { "  ┃ ", "IzComment" },
    { table.concat(label, " · ") .. ": ", "IzMuted" },
    { format.one_line(text), "IzComment" },
  }
  -- Virtual lines don't wrap: cut to the window, label included.
  local room = width
  for _, chunk in ipairs(chunks) do
    local n = vim.fn.strchars(chunk[1])
    if n > room then
      chunk[1] = room > 1 and vim.fn.strcharpart(chunk[1], 0, room - 1) .. "…" or ""
    end
    room = math.max(room - n, 0)
  end
  return { chunks }
end

--- The line of the other diff side under which a filler goes, so a virtual
--- line under `line` of `side` doesn't push the two sides out of line: diff
--- mode doesn't count virtual lines. Inside a Hunk the filler goes on the
--- paired line, or under the other side's last line of the Hunk when it is
--- shorter; either way the two sides line up again after the Hunk.
---@param hunks iz.DiffHunk[] between the left side and the working tree
---@param side "old"|"new" the side the virtual line is on
---@param line integer
---@return integer other may be 0: the filler goes above the first line
function M.mirror_line(hunks, side, line)
  local this, other = side, side == "old" and "new" or "old"
  local offset = 0
  for _, h in ipairs(hunks) do
    local start, count = h[this .. "_start"], h[this .. "_count"]
    local o_start, o_count = h[other .. "_start"], h[other .. "_count"]
    if count > 0 and start <= line and line < start + count then
      local k = line - start + 1
      if k <= o_count then
        return o_start + k - 1
      end
      -- For an empty block `o_start` is the line before it.
      return o_count > 0 and o_start + o_count - 1 or o_start
    end
    local before = (count > 0 and start + count - 1 < line) or (count == 0 and start < line)
    if before then
      offset = offset + o_count - count
    end
  end
  return line + offset
end

---@param buf integer
---@param line integer may be 0: above the first line
local function filler(buf, line)
  local opts = { virt_lines = { { { "", "" } } } }
  if line < 1 then
    line, opts.virt_lines_above = 1, true
  end
  line = math.min(line, api.nvim_buf_line_count(buf))
  pcall(api.nvim_buf_set_extmark, buf, M.ns, line - 1, 0, opts)
end

---@param ctx iz.DiffContext
function M.draw(ctx)
  local left = api.nvim_win_get_buf(ctx.left_win)
  local right = api.nvim_win_get_buf(ctx.right_win)
  api.nvim_buf_clear_namespace(left, M.ns, 0, -1)
  api.nvim_buf_clear_namespace(right, M.ns, 0, -1)
  local u = ctx.file.unstaged_diff
  local hunks = ctx.left_rev == "index" and (u and u.hunks or {}) or ctx.file.hunks

  for _, c in ipairs(comments.for_file(ctx.session, ctx.file.path)) do
    if c.status == "open" and c.line then
      local old = c.side == "old"
      local buf = old and left or right
      -- Base line numbers mean nothing against the index.
      if not (old and ctx.left_rev == "index") then
        local win = old and ctx.left_win or ctx.right_win
        local info = vim.fn.getwininfo(win)[1]
        local width = api.nvim_win_get_width(win) - (info and info.textoff or 0)
        -- A lost comment stays at its last known line: the fix is usually right there.
        local row = math.min((c.end_line or c.line) - 1, api.nvim_buf_line_count(buf) - 1)
        row = math.max(row, 0)
        local ok = pcall(api.nvim_buf_set_extmark, buf, M.ns, row, 0, {
          virt_lines = M.virt_lines(c, width),
        })
        if ok then
          filler(old and right or left, M.mirror_line(hunks, old and "old" or "new", row + 1))
        end
      end
    end
  end
end

return M
