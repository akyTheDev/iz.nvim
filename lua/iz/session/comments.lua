-- Comments and their threads. Status belongs to the user; a Claim is derived
-- from the agent's latest Reply and is never stored on its own.
local session_mod = require("iz.session")
local util = require("iz.util")

local M = {}

---@class iz.Message
---@field author "user"|"agent"|"coreviewer"
---@field body string
---@field claim? "addressed"|"declined"|"question"
---@field ts string

---@class iz.Anchor
---@field snippet string Trimmed anchored lines, joined by "\n".
---@field context_before string[] Up to two preceding non-blank lines, trimmed.
---@field state "found"|"lost"

---@class iz.Comment
---@field id string
---@field scope "line"|"hunk"|"file"|"session"
---@field file? string
---@field side? "new"|"old" `old` lines are Base lines.
---@field line? integer
---@field end_line? integer
---@field anchor? iz.Anchor
---@field status "open"|"resolved"|"ignored"
---@field attachments string[] Repository-relative paths.
---@field thread iz.Message[]

M.CLAIMS = { addressed = true, declined = true, question = true }
M.STATUSES = { open = true, resolved = true, ignored = true }

---@param session iz.Session
local function new_id(session)
  local taken = {}
  for _, c in ipairs(session.data.comments) do
    taken[c.id] = true
  end
  local id
  repeat
    id = "c_" .. util.random_hex(2)
  until not taken[id]
  return id
end

---@param comment iz.Comment
---@return iz.Message
function M.last(comment)
  return comment.thread[#comment.thread]
end

---@param comment iz.Comment
---@return string? claim present only while the agent wrote the latest message
function M.claim(comment)
  local last = M.last(comment)
  return last.author == "agent" and last.claim or nil
end

--- A Suggestion: written by the Co-reviewer and not sent by the user yet.
--- It stays out of the Brief until the user sends it.
---@param comment iz.Comment
function M.suggested(comment)
  return comment.status == "open" and M.last(comment).author == "coreviewer"
end

--- Open and waiting for the agent: the user had the last word.
---@param comment iz.Comment
function M.awaiting_agent(comment)
  return comment.status == "open" and M.last(comment).author == "user"
end

--- Open and waiting for the user: the agent had the last word.
---@param comment iz.Comment
function M.awaiting_user(comment)
  return comment.status == "open" and M.last(comment).author == "agent"
end

---@param session iz.Session
---@param id string
---@return iz.Comment?
function M.find(session, id)
  for _, c in ipairs(session.data.comments) do
    if c.id == id then
      return c
    end
  end
end

---@param session iz.Session
---@param path string
---@return iz.Comment[]
function M.for_file(session, path)
  return vim.tbl_filter(function(c)
    return c.file == path
  end, session.data.comments)
end

---@param session iz.Session
---@param path string
function M.open_count(session, path)
  local n = 0
  for _, c in ipairs(M.for_file(session, path)) do
    if c.status == "open" then
      n = n + 1
    end
  end
  return n
end

---@class iz.NewComment
---@field scope "line"|"hunk"|"file"|"session"
---@field body string
---@field file? string
---@field side? "new"|"old"
---@field line? integer
---@field end_line? integer
---@field anchor? iz.Anchor
---@field attachments? string[]

---@param session iz.Session
---@param spec iz.NewComment
---@param author "user"|"coreviewer"
---@return iz.Comment
local function new_comment(session, spec, author)
  assert(vim.trim(spec.body) ~= "", "empty comment")
  return {
    id = new_id(session),
    scope = spec.scope,
    file = spec.file,
    side = spec.side,
    line = spec.line,
    end_line = spec.end_line,
    anchor = spec.anchor,
    status = "open",
    attachments = spec.attachments or {},
    thread = { { author = author, body = spec.body, ts = util.now() } },
  }
end

---@param session iz.Session
---@param spec iz.NewComment
---@return iz.Comment
function M.add(session, spec)
  local comment = new_comment(session, spec, "user")
  table.insert(session.data.comments, comment)
  session_mod.save(session)
  return comment
end

--- A Suggestion from the Co-reviewer. The caller saves, so a batch lands in one write.
---@param session iz.Session
---@param spec iz.NewComment
---@return iz.Comment
function M.add_suggestion(session, spec)
  local comment = new_comment(session, spec, "coreviewer")
  table.insert(session.data.comments, comment)
  return comment
end

--- Sends a Suggestion to the agent as it is: an empty Reply from the user,
--- so the thread records who sent it and when.
---@param session iz.Session
---@param comment iz.Comment
function M.send(session, comment)
  assert(M.suggested(comment), "only an unsent Suggestion can be sent")
  table.insert(comment.thread, { author = "user", body = "", ts = util.now() })
  session_mod.save(session)
end

--- A Reply from the user; it clears any Claim and sends the Comment back to the agent.
---@param session iz.Session
---@param comment iz.Comment
---@param body string
---@param attachments? string[]
function M.reply(session, comment, body, attachments)
  assert(vim.trim(body) ~= "", "empty reply")
  table.insert(comment.thread, { author = "user", body = body, ts = util.now() })
  vim.list_extend(comment.attachments, attachments or {})
  session_mod.save(session)
end

--- A Reply from the agent. Never changes Status. The caller saves, so a batch
--- of replies lands in one write.
---@param session iz.Session
---@param comment iz.Comment
---@param claim "addressed"|"declined"|"question"
---@param note string
---@param ts? string
function M.agent_reply(session, comment, claim, note, ts)
  assert(M.CLAIMS[claim], "unknown claim " .. tostring(claim))
  local message = { author = "agent", claim = claim, body = note, ts = ts or util.now() }
  table.insert(comment.thread, message)
end

--- Re-anchors a Comment to new-side lines `first..last` of `lines`.
---@param session iz.Session
---@param comment iz.Comment
---@param lines string[] the working-tree file
---@param first integer
---@param last integer
function M.move(session, comment, lines, first, last)
  comment.side, comment.line, comment.end_line = "new", first, last
  if comment.scope == "file" then
    comment.scope = "line"
  end
  comment.anchor = require("iz.session.anchor").capture(lines, first, last)
  session_mod.save(session)
end

--- The only way Status changes; the agent has no path here.
---@param session iz.Session
---@param comment iz.Comment
---@param status "open"|"resolved"|"ignored"
function M.set_status(session, comment, status)
  assert(M.STATUSES[status], "unknown status " .. tostring(status))
  comment.status = status
  session_mod.save(session)
end

return M
