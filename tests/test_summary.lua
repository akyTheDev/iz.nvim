local H = require("tests.helpers")
local session = require("iz.session")
local summary = require("iz.summary")

local T = MiniTest.new_set()

local function new_session(files)
  local root = H.repo(files)
  return H.run(function()
    return session.create(root)
  end)
end

---@param s iz.Session
---@param name string
---@param objects (table|string)[]
local function write_summaries(s, name, objects)
  local lines = vim.tbl_map(function(o)
    return type(o) == "string" and o or vim.json.encode(o)
  end, objects)
  H.write(s.root, ".iz/summaries/" .. name, table.concat(lines, "\n") .. "\n")
end

T["a summary is stored per file and the newest one wins"] = function()
  local s = new_session({ ["a.txt"] = "a\n", ["b.txt"] = "b\n" })
  write_summaries(s, "1.jsonl", {
    { file = "a.txt", summary = "first take" },
    { file = "b.txt", summary = "  why b changed  " },
  })
  write_summaries(s, "2.jsonl", { { file = "a.txt", summary = "second take" } })
  local result = summary.ingest(s)
  H.eq(result.summaries, 3)
  H.eq(summary.get(s, "a.txt"), { body = "second take", outdated = false })
  H.eq(summary.get(s, "b.txt"), { body = "why b changed", outdated = false })
  H.eq(summary.get(s, "c.txt"), nil)
  H.eq(vim.uv.fs_stat(s.root .. "/.iz/summaries/1.jsonl"), nil)
  -- Saved, so a restart keeps them.
  H.eq(session.load(s.root, s.id).data.summaries["a.txt"].body, "second take")
end

T["a summary reads as outdated once its file changes"] = function()
  local s = new_session({ ["a.txt"] = "a\n" })
  write_summaries(s, "1.jsonl", { { file = "a.txt", summary = "added a" } })
  summary.ingest(s)
  H.write(s.root, "a.txt", "a changed\n")
  H.eq(summary.get(s, "a.txt").outdated, true)
end

T["a file changed after its summary was written reads as outdated on arrival"] = function()
  local s = new_session({ ["a.txt"] = "a\n" })
  write_summaries(s, "1.jsonl", { { file = "a.txt", summary = "added a" } })
  -- Neovim reads the summary later, after the agent edited the file again.
  local source = s.root .. "/.iz/summaries/1.jsonl"
  local now = os.time()
  vim.uv.fs_utime(source, now - 60, now - 60)
  H.write(s.root, "a.txt", "a, edited after the summary\n")
  summary.ingest(s)
  H.eq(summary.get(s, "a.txt").outdated, true)
end

T["invalid summaries are refused and their file kept aside"] = function()
  local s = new_session({ ["a.txt"] = "a\n" })
  write_summaries(s, "1.jsonl", {
    { file = "a.txt", summary = "fine" },
    { file = "../x", summary = "outside" },
    { file = ".iz/brief.md", summary = "iz itself" },
    { file = "missing.txt", summary = "no such file" },
    { file = "a.txt", summary = " " },
    { file = "a.txt", summary = string.rep("x", summary.MAX_LENGTH + 1) },
  })
  local result = summary.ingest(s)
  H.eq(result.summaries, 1)
  for n = 2, 6 do
    H.eq(result.failed[1]:find(("line %d:"):format(n), 1, true) ~= nil, true)
  end
  H.eq(vim.uv.fs_stat(s.root .. "/.iz/summaries/failed/1.jsonl") ~= nil, true)
end

return T
