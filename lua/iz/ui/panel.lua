-- The comment panel: every Comment of the Session, grouped by who has to act
-- next. Open ones show the first and the last message; the panel window wraps
-- them, and the thread view (`<CR>`) shows everything.
local comments = require("iz.session.comments")
local format = require("iz.ui.format")
local hl = require("iz.ui.highlights")

local api = vim.api
local M = {}

local WHO_HL = { agent = "IzClaim", coreviewer = "IzSuggestion" }

---@param session iz.Session
---@return string[] lines, table<integer, string> ids, table[] marks
function M.render(session)
  local for_you = { title = "Waiting for you", items = {} }
  local suggested = { title = "Suggested by the co-reviewer", items = {} }
  local for_agent = { title = "Waiting for the agent", items = {} }
  local closed = { title = "Closed", items = {}, collapsed = true }
  for _, c in ipairs(session.data.comments) do
    local g = closed
    if comments.awaiting_user(c) then
      g = for_you
    elseif comments.suggested(c) then
      g = suggested
    elseif comments.awaiting_agent(c) then
      g = for_agent
    end
    table.insert(g.items, c)
  end
  local groups = { for_you, suggested, for_agent, closed }
  -- Session comments first, then by file and line.
  for _, g in ipairs(groups) do
    table.sort(g.items, function(a, b)
      local fa, fb = a.file or "", b.file or ""
      if fa ~= fb then
        return fa < fb
      end
      return (a.line or 0) < (b.line or 0)
    end)
  end

  local lines, ids, marks = {}, {}, {}
  ---@param span? integer[] start and end column of `group`; the whole line without it
  local function add(line, id, group, span)
    lines[#lines + 1] = line
    ids[#lines] = id
    if group then
      marks[#marks + 1] = { #lines, group, span and span[1], span and span[2] }
    end
  end
  ---@param m iz.Message
  local function message(c, m)
    local who = format.who(m)
    local group = WHO_HL[m.author] or "IzMuted"
    add(("    %-5s  %s"):format(who, format.one_line(format.body(m))), c.id, group,
      { 4, 4 + math.max(#who, 5) })
  end

  for _, g in ipairs(groups) do
    if #g.items > 0 then
      if #lines > 0 then
        add("")
      end
      add(("%s (%d)"):format(g.title, #g.items), nil, "IzDirectory")
      for i, c in ipairs(g.items) do
        if g.collapsed then
          local mark = c.status == "resolved" and "✓" or "–"
          local root_body = format.one_line(c.thread[1].body)
          local text = ("  %s %s  %s  %s"):format(mark, c.status, format.location(c), root_body)
          add(text, c.id, "IzMuted")
        else
          if i > 1 then
            add("")
          end
          add("  " .. format.headline(c), c.id, "IzComment")
          local n = #c.thread
          message(c, c.thread[1])
          if n > 2 then
            add(("    … %d more"):format(n - 2), c.id, "IzMuted")
          end
          if n > 1 then
            message(c, c.thread[n])
          end
        end
      end
    end
  end
  if #lines == 0 then
    add("No comments yet.", nil, "IzMuted")
  end
  return lines, ids, marks
end

---@param buf integer
---@param session iz.Session
---@return table<integer, string> ids line -> comment id
function M.draw(buf, session)
  local lines, ids, marks = M.render(session)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  api.nvim_buf_clear_namespace(buf, hl.ns, 0, -1)
  for _, m in ipairs(marks) do
    if m[3] then
      api.nvim_buf_set_extmark(buf, hl.ns, m[1] - 1, m[3], { end_col = m[4], hl_group = m[2] })
    else
      api.nvim_buf_set_extmark(buf, hl.ns, m[1] - 1, 0, { line_hl_group = m[2] })
    end
  end
  return ids
end

return M
