local H = require("tests.helpers")
local brief = require("iz.brief")
local comments = require("iz.session.comments")
local coreview = require("iz.coreview")
local session = require("iz.session")
local storage = require("iz.storage")

local T = MiniTest.new_set()

local function new_session(files)
  local root = H.repo(files)
  return H.run(function()
    return session.create(root)
  end)
end

---@param s iz.Session
---@param name string
---@param objects (table|string)[] a string is written as it is
local function write_coreview(s, name, objects)
  local lines = vim.tbl_map(function(o)
    return type(o) == "string" and o or vim.json.encode(o)
  end, objects)
  H.write(s.root, ".iz/coreview/" .. name, table.concat(lines, "\n") .. "\n")
end

T["suggestions land as open comments the agent has not seen, anchored to their code"] = function()
  local s = new_session({ ["a.txt"] = H.lines(5) })
  write_coreview(s, "1.jsonl", {
    { file = "a.txt", line = 2, end_line = 3, body = "off by one" },
    { file = "a.txt", body = "no tests for this file" },
    { body = "the change misses the docs" },
  })
  local result = coreview.ingest(s)
  H.eq(result.suggestions, 3)
  H.eq(result.failed, {})
  H.eq(vim.uv.fs_stat(s.root .. "/.iz/coreview/1.jsonl"), nil)

  local line, file, whole = unpack(s.data.comments)
  H.eq({ line.scope, line.line, line.end_line, line.side }, { "line", 2, 3, "new" })
  H.eq(line.anchor.snippet, "line 2\nline 3")
  H.eq({ file.scope, file.file }, { "file", "a.txt" })
  H.eq(whole.scope, "session")
  for _, c in ipairs(s.data.comments) do
    H.eq(c.status, "open")
    H.eq(c.thread[1].author, "coreviewer")
    H.eq(comments.suggested(c), true)
    H.eq(comments.awaiting_agent(c), false)
    H.eq(comments.awaiting_user(c), false)
  end
  -- Saved, so a restart keeps them.
  H.eq(#session.load(s.root, s.id).data.comments, 3)
end

T["invalid lines are refused and their file kept aside; valid ones still count"] = function()
  local s = new_session({ ["a.txt"] = H.lines(5) })
  write_coreview(s, "1.jsonl", {
    { file = "a.txt", line = 1, body = "fine" },
    { file = "../outside.txt", body = "escapes the repository" },
    { file = ".iz/brief.md", body = "touches iz itself" },
    { file = "/etc/passwd", body = "absolute" },
    { file = "missing.txt", body = "no such file" },
    { file = "a.txt", line = 6, body = "past the end" },
    { file = "a.txt", line = 3, end_line = 2, body = "backwards" },
    { file = "a.txt", line = 1.5, body = "not a line" },
    { file = "a.txt", line = 1, body = "  " },
    "not json",
  })
  local result = coreview.ingest(s)
  H.eq(result.suggestions, 1)
  H.eq(#result.failed, 1)
  local reasons = result.failed[1]
  for _, n in ipairs({ 2, 3, 4, 5, 6, 7, 8, 9, 10 }) do
    H.eq(reasons:find(("line %d:"):format(n), 1, true) ~= nil, true)
  end
  H.eq(vim.uv.fs_stat(s.root .. "/.iz/coreview/failed/1.jsonl") ~= nil, true)
end

T["a file still being written waits for its last line"] = function()
  local s = new_session({ ["a.txt"] = "a\n" })
  H.write(s.root, ".iz/coreview/1.jsonl", '{"file": "a.txt", "body": "x"}\n{"file": "a.t')
  local result = coreview.ingest(s)
  H.eq(result.suggestions, 0)
  H.eq(result.waiting, { "1.jsonl" })
  H.eq(#s.data.comments, 0)
end

T["more suggestions than the cap are refused"] = function()
  local s = new_session({ ["a.txt"] = "a\n" })
  local many = {}
  for i = 1, coreview.MAX + 2 do
    many[i] = { file = "a.txt", body = "note " .. i }
  end
  write_coreview(s, "1.jsonl", many)
  local result = coreview.ingest(s)
  H.eq(result.suggestions, coreview.MAX)
  H.eq(result.failed[1]:find("more than " .. coreview.MAX, 1, true) ~= nil, true)
end

T["the Brief leaves suggestions out until the user sends them"] = function()
  local s = new_session({ ["a.txt"] = H.lines(5) })
  write_coreview(s, "1.jsonl", {
    { file = "a.txt", line = 2, body = "off by one" },
    { file = "a.txt", line = 4, body = "unchecked nil" },
    { file = "a.txt", line = 5, body = "not worth it" },
  })
  coreview.ingest(s)
  local as_is, with_note = s.data.comments[1], s.data.comments[2]
  H.eq(brief.render(s), brief.EMPTY .. "\n")

  comments.send(s, as_is)
  comments.reply(s, with_note, "and add a test")
  H.eq(comments.suggested(as_is), false)
  H.eq(comments.awaiting_agent(as_is), true)

  local content, meta = brief.render(s)
  H.eq(content, table.concat({
    ("# iz brief %s · 2 comments"):format(meta.id),
    "",
    "## a.txt",
    as_is.id .. " L2: off by one",
    with_note.id .. " L4: unchecked nil",
    "  reviewer: and add a test",
    "",
    "When done, write your replies to .iz/inbox/" .. meta.id .. ".jsonl in a single Write,",
    "one JSON line per comment: "
      .. '{"id": "c_…", "claim": "addressed" | "declined" | "question", "note": "…"}',
  }, "\n") .. "\n")

  -- Only an unsent Suggestion can be sent.
  H.eq(pcall(comments.send, s, as_is), false)
end

T["a version 1 session loads and is saved as version 2"] = function()
  local s = new_session()
  s.data.schema_version = 1
  session.save(s)
  local loaded = assert(session.load(s.root, s.id))
  H.eq(loaded.data.schema_version, session.SCHEMA_VERSION)
  session.save(loaded)
  H.eq(storage.read_json(storage.session_dir(s.root, s.id) .. "/session.json").schema_version, 2)
end

return T
