local H = require("tests.helpers")
local brief = require("iz.brief")
local comments = require("iz.session.comments")
local inbox = require("iz.inbox")
local session = require("iz.session")
local storage = require("iz.storage")

local T = MiniTest.new_set()

local function new_session()
  local root = H.repo()
  return H.run(function()
    return session.create(root)
  end)
end

local function line_comment(s, file, line, body, extra)
  return comments.add(s, vim.tbl_extend("force", {
    scope = "line",
    file = file,
    side = "new",
    line = line,
    end_line = line,
    anchor = { snippet = "code at " .. line, context_before = {}, state = "found" },
    body = body,
  }, extra or {}))
end

T["brief"] = MiniTest.new_set()

T["brief"]["groups pending comments by file, session first, one line each"] = function()
  local s = new_session()
  line_comment(s, "src/b.lua", 9, "second file")
  line_comment(s, "src/a.lua", 42, "use NotFoundError")
  line_comment(s, "src/a.lua", 7, "rename")
  comments.add(s, {
    scope = "session",
    body = "login overflows on mobile",
    attachments = { ".iz/x.png" },
  })
  local done = line_comment(s, "src/a.lua", 1, "already resolved")
  comments.set_status(s, done, "resolved")

  local content, meta = brief.render(s)
  local ids = vim.tbl_map(function(c)
    return c.id
  end, s.data.comments)
  H.eq(content, table.concat({
    ("# iz brief %s · 4 comments"):format(meta.id),
    "",
    "## Session",
    ids[4] .. ": login overflows on mobile",
    "  image: .iz/x.png",
    "",
    "## src/a.lua",
    ids[3] .. " L7: rename",
    ids[2] .. " L42: use NotFoundError",
    "",
    "## src/b.lua",
    ids[1] .. " L9: second file",
    "",
    ("When done, write your replies to .iz/inbox/%s.jsonl in a single Write,"):format(meta.id),
    "one JSON line per comment: "
      .. '{"id": "c_…", "claim": "addressed" | "declined" | "question", "note": "…"}',
    "",
  }, "\n"))
end

T["brief"]["sends a snippet only for lost anchors and deleted lines"] = function()
  local s = new_session()
  local lost = line_comment(s, "a.lua", 3, "lost one")
  lost.anchor.state = "lost"
  line_comment(s, "a.lua", 5, "deleted one", { side = "old" })
  line_comment(s, "a.lua", 8, "plain one")
  local content = brief.render(s)
  local function has(text)
    return content:find(text, 1, true) ~= nil
  end
  H.eq(has("L3 (code moved or changed; last seen here): lost one\n  > code at 3"), true)
  H.eq(has("L5 (deleted lines, as in the base): deleted one\n  > code at 5"), true)
  H.eq(content:find("code at 8", 1, true), nil)
end

T["brief"]["sends only the agent's last note and the reviewer's latest reply"] = function()
  local s = new_session()
  local c = line_comment(s, "a.lua", 1, "root")
  comments.agent_reply(s, c, "addressed", "first try")
  comments.reply(s, c, "not yet")
  comments.agent_reply(s, c, "addressed", "second try")
  comments.reply(s, c, "still no")
  local content = brief.render(s)
  H.eq(content:find(": root\n  agent: second try\n  reviewer: still no\n", 1, true) ~= nil, true)
  H.eq(content:find("first try", 1, true), nil)
end

T["brief"]["keeps its id while the content is unchanged and is one line when empty"] = function()
  local s = new_session()
  H.eq(brief.update(s), nil)
  H.eq(storage.read_file(brief.path(s.root)), brief.EMPTY .. "\n")

  local c = line_comment(s, "a.lua", 1, "x")
  local id = brief.update(s)
  H.eq(brief.update(s), id)
  comments.reply(s, c, "more")
  H.neq(brief.update(s), id)
end

T["inbox"] = MiniTest.new_set()

local function drop(s, name, content)
  local dir = require("iz.storage").inbox_dir(s.root)
  vim.fn.mkdir(dir, "p")
  H.write(s.root, ".iz/inbox/" .. name, content)
  return dir .. "/" .. name
end

T["inbox"]["ingests replies, stamps them and deletes the file"] = function()
  local s = new_session()
  local a = line_comment(s, "a.lua", 1, "a")
  local b = line_comment(s, "a.lua", 2, "b")
  -- The Write tool may omit the trailing newline.
  local path = drop(s, "b_0001.jsonl", table.concat({
    vim.json.encode({ id = a.id, claim = "addressed", note = "done" }),
    vim.json.encode({ id = b.id, claim = "question", note = "which error?" }),
  }, "\n"))

  local result = inbox.ingest(s)
  H.eq({ result.replies, result.questions }, { 2, 1 })
  H.eq(vim.uv.fs_stat(path), nil)
  H.eq(comments.claim(a), "addressed")
  H.eq(a.thread[2].ts ~= nil, true)
  H.eq(a.status, "open")
  H.eq(#session.load(s.root, s.id).data.comments[2].thread, 2)
  H.eq(inbox.summary(result), "agent replied to 2 comments · 1 question")
end

T["inbox"]["reports unknown ids and moves files with invalid lines to failed/"] = function()
  local s = new_session()
  local a = line_comment(s, "a.lua", 1, "a")
  drop(s, "b_0002.jsonl", table.concat({
    vim.json.encode({ id = a.id, claim = "addressed", note = "ok" }),
    vim.json.encode({ id = "c_nope", claim = "addressed", note = "?" }),
    vim.json.encode({ id = a.id, claim = "done", note = "bad claim" }),
  }, "\n") .. "\n")

  local result = inbox.ingest(s)
  H.eq(result.replies, 1)
  H.eq(result.unknown, { "c_nope" })
  H.eq(#result.failed, 1)
  local failed = require("iz.storage").inbox_dir(s.root) .. "/failed/b_0002.jsonl"
  H.eq(vim.uv.fs_stat(failed) ~= nil, true)
end

T["inbox"]["waits for a file whose last line is unfinished"] = function()
  local s = new_session()
  local a = line_comment(s, "a.lua", 1, "a")
  local line = vim.json.encode({ id = a.id, claim = "addressed", note = "x" })
  local path = drop(s, "b_0003.jsonl", line .. '\n{"id": "c_')
  local result = inbox.ingest(s)
  H.eq({ result.replies, #result.waiting }, { 0, 1 })
  H.eq(vim.uv.fs_stat(path) ~= nil, true)
end

T["inbox"]["a reply to a closed comment is kept without reopening it"] = function()
  local s = new_session()
  local a = line_comment(s, "a.lua", 1, "a")
  comments.set_status(s, a, "resolved")
  local line = vim.json.encode({ id = a.id, claim = "addressed", note = "late" })
  drop(s, "b_0004.jsonl", line .. "\n")
  inbox.ingest(s)
  H.eq({ #a.thread, a.status }, { 2, "resolved" })
end

return T
