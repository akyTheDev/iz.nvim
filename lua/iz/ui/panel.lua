-- The comment panel: every Comment of the Session with its thread, grouped by
-- who has to act next.
local comments = require("iz.session.comments")
local hl = require("iz.ui.highlights")

local api = vim.api
local M = {}

---@param text string
local function one_line(text)
  return (text:gsub("\n", " ⏎ "))
end

---@param c iz.Comment
local function location(c)
  if c.scope == "session" then
    return "session"
  elseif c.scope == "file" or not c.line then
    return c.file
  end
  local loc = ("%s:%d"):format(c.file, c.line)
  if c.end_line and c.end_line ~= c.line then
    loc = loc .. "-" .. c.end_line
  end
  if c.side == "old" then
    loc = loc .. " (deleted)"
  end
  if c.anchor and c.anchor.state == "lost" then
    loc = loc .. " (lost)"
  end
  return loc
end

---@param session iz.Session
---@return string[] lines, table<integer, string> ids, table[] marks
function M.render(session)
  local for_you = { title = "Waiting for you", items = {} }
  local for_agent = { title = "Waiting for the agent", items = {} }
  local closed = { title = "Closed", items = {}, collapsed = true }
  for _, c in ipairs(session.data.comments) do
    local g = closed
    if comments.awaiting_user(c) then
      g = for_you
    elseif comments.awaiting_agent(c) then
      g = for_agent
    end
    table.insert(g.items, c)
  end
  local groups = { for_you, for_agent, closed }
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
  local function add(line, id, group)
    lines[#lines + 1] = line
    ids[#lines] = id
    if group then
      marks[#marks + 1] = { #lines, group }
    end
  end

  for _, g in ipairs(groups) do
    if #g.items > 0 then
      if #lines > 0 then
        add("")
      end
      add(("%s (%d)"):format(g.title, #g.items), nil, "IzDirectory")
      for _, c in ipairs(g.items) do
        if g.collapsed then
          local mark = c.status == "resolved" and "✓" or "–"
          local root_body = one_line(c.thread[1].body)
          local text = ("  %s %s  %s  %s"):format(mark, c.status, location(c), root_body)
          add(text, c.id, "IzMuted")
        else
          local claim = comments.claim(c)
          local badge = claim and ("  [" .. claim .. "]") or ""
          add(("  %s  %s%s"):format(location(c), c.id, badge), c.id, "IzComment")
          for _, m in ipairs(c.thread) do
            local who = m.author == "agent" and "agent" or "you"
            add(("    %s: %s"):format(who, one_line(m.body)), c.id)
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
    api.nvim_buf_set_extmark(buf, hl.ns, m[1] - 1, 0, { line_hl_group = m[2] })
  end
  return ids
end

return M
