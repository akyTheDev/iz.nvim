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

local WHO = { user = "you", agent = "agent", coreviewer = "co-reviewer" }

--- `path` as it fits in a title: whole, else with directories cut to their
--- first letter, else just the file name.
---@param path string
---@param max? integer defaults to 48
---@return string
function M.short_path(path, max)
  max = max or 48
  if #path <= max then
    return path
  end
  local short = vim.fn.pathshorten(path)
  return #short <= max and short or vim.fs.basename(path)
end

---@param m iz.Message
---@return string
function M.who(m)
  return WHO[m.author] or "you"
end

--- What a message says, in the words shown to the user: an empty message
--- from the user sent a Suggestion on as it is.
---@param m iz.Message
---@return string
function M.body(m)
  if m.author == "user" and m.body == "" then
    return "sent to the agent"
  end
  return m.body
end

---@param text string
---@return string
function M.one_line(text)
  return (text:gsub("%s*\n%s*", " ⏎ "))
end

return M
