-- Labels shared by the panel, the inline comments and the thread view.
local comments = require("iz.session.comments")

local M = {}

--- How a lost Anchor reads to the user. When the agent says it addressed the
--- Comment, the code was most likely changed on purpose; otherwise the Comment
--- may need moving with `m`.
---@param c iz.Comment
---@return string?
function M.anchor_state(c)
  if not (c.anchor and c.anchor.state == "lost") then
    return nil
  end
  return comments.claim(c) == "addressed" and "line changed" or "lost"
end

---@param c iz.Comment
---@return string
function M.location(c)
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
  return loc
end

--- "a.txt:3 · line changed · addressed"
---@param c iz.Comment
---@return string
function M.headline(c)
  local parts = { M.location(c) }
  parts[#parts + 1] = M.anchor_state(c)
  parts[#parts + 1] = comments.claim(c)
  return table.concat(parts, " · ")
end

---@param m iz.Message
---@return string
function M.who(m)
  return m.author == "agent" and "agent" or "you"
end

---@param text string
---@return string
function M.one_line(text)
  return (text:gsub("%s*\n%s*", " ⏎ "))
end

return M
