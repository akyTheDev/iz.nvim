local H = require("tests.helpers")
local anchor = require("iz.session.anchor")
local comments = require("iz.session.comments")
local session = require("iz.session")

local T = MiniTest.new_set()

local function new_session()
  local root = H.repo()
  return H.run(function()
    return session.create(root)
  end)
end

T["model"] = MiniTest.new_set()

T["model"]["a reply clears the claim and sends the comment back to the agent"] = function()
  local s = new_session()
  local c = comments.add(s, { scope = "session", body = "check the login page" })
  H.eq(comments.awaiting_agent(c), true)
  H.eq(comments.claim(c), nil)

  comments.agent_reply(s, c, "addressed", "fixed")
  H.eq(comments.claim(c), "addressed")
  H.eq(comments.awaiting_user(c), true)
  H.eq(comments.awaiting_agent(c), false)

  comments.reply(s, c, "still broken on mobile")
  H.eq(comments.claim(c), nil)
  H.eq(comments.awaiting_agent(c), true)
  H.eq(#c.thread, 3)
end

T["model"]["status is set only through set_status and persists"] = function()
  local s = new_session()
  local c = comments.add(s, { scope = "file", file = "a.txt", body = "x" })
  comments.agent_reply(s, c, "declined", "out of scope")
  H.eq(c.status, "open")
  comments.set_status(s, c, "ignored")
  H.eq(session.load(s.root, s.id).data.comments[1].status, "ignored")
  H.eq(comments.awaiting_user(c), false)
  comments.set_status(s, c, "open")
  H.eq(comments.awaiting_user(c), true)
end

T["model"]["rejects empty bodies and unknown claims"] = function()
  local s = new_session()
  H.eq(pcall(comments.add, s, { scope = "session", body = "  " }), false)
  local c = comments.add(s, { scope = "session", body = "x" })
  H.eq(pcall(comments.agent_reply, s, c, "done", "x"), false)
end

T["anchor"] = MiniTest.new_set()

local function lines(text)
  return vim.split(text, "\n", { plain = true })
end

T["anchor"]["follows its line when code is inserted above"] = function()
  local before = lines("a\nb\nthrow x\nc")
  local a = anchor.capture(before, 3, 3)
  H.eq(a.context_before, { "a", "b" })
  H.eq(anchor.locate(a, lines("new\nnew\na\nb\nthrow x\nc"), 3, 1), 5)
end

T["anchor"]["picks the duplicate whose context matches"] = function()
  local a = anchor.capture(lines("if ok then\nreturn 1\nend"), 2, 2)
  local after = lines("if bad then\nreturn 1\nend\nx\nif ok then\nreturn 1\nend")
  H.eq(anchor.locate(a, after, 2, 1), 6)
end

T["anchor"]["stays in place when only the line above changed"] = function()
  local a = anchor.capture(lines("local x = 1\nreturn x"), 2, 2)
  H.eq(anchor.locate(a, lines("local x = 2\nreturn x"), 2, 1), 2)
end

T["anchor"]["is lost when the line is gone, and never fuzzy-matched"] = function()
  local a = anchor.capture(lines("x\nthrow new Error()\ny"), 2, 2)
  H.eq(anchor.locate(a, lines("x\nthrow new NotFoundError()\ny"), 2, 1), nil)
end

T["anchor"]["relocate_all updates lines, marks lost and keeps status"] = function()
  local s = new_session()
  local file = "line 1\nline 2\ntarget\nline 4\n"
  local function add(line)
    local l = lines(file)
    return comments.add(s, {
      scope = "line",
      file = "f.txt",
      side = "new",
      line = line,
      end_line = line,
      anchor = anchor.capture(l, line, line),
      body = "c",
    })
  end
  local moved, gone = add(3), add(4)
  local old = comments.add(s, {
    scope = "line", file = "f.txt", side = "old", line = 1, end_line = 1,
    anchor = anchor.capture(lines(file), 1, 1), body = "old side",
  })
  local changed = anchor.relocate_all(s, function()
    return "inserted\nline 1\nline 2\ntarget\n"
  end)
  H.eq(changed, true)
  H.eq({ moved.line, moved.anchor.state }, { 4, "found" })
  H.eq({ gone.line, gone.anchor.state, gone.status }, { 4, "lost", "open" })
  H.eq(old.line, 1)
end

return T
