-- Regressions found by review: multiple Neovims, interrupted agents, closing in
-- unusual ways, and UI state that drifted from what is on screen.
local H = require("tests.helpers")
local comments = require("iz.session.comments")
local hl = require("iz.ui.highlights")
local inbox = require("iz.inbox")
local inline = require("iz.ui.inline")
local lock = require("iz.storage.lock")
local session = require("iz.session")
local storage = require("iz.storage")
local workspace = require("iz.ui.workspace")

local api = vim.api

local function wait()
  H.eq(vim.wait(10000, workspace.idle, 10), true)
end

local function open(root)
  vim.fn.chdir(root)
  workspace.open()
  wait()
  return assert(workspace.get())
end

local function create(root)
  return H.run(function()
    return session.create(root)
  end)
end

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      workspace.close()
      wait()
    end,
  },
})

T["multiple Neovims"] = MiniTest.new_set()

T["multiple Neovims"]["taking over the lock keeps what the other instance saved"] = function()
  local root = H.repo({ ["a.txt"] = "a\n" })
  H.write(root, "a.txt", "b\n")
  local s = create(root)
  -- PID 1 is always alive and never us.
  storage.write_json(storage.dir(root) .. "/lock", { pid = 1 })
  local ws = open(root)
  H.eq(ws.readonly, true)

  -- The owner adds a comment, then quits.
  comments.add(session.current(root), { scope = "session", body = "from the owner" })
  os.remove(storage.dir(root) .. "/lock")
  api.nvim_exec_autocmds("FocusGained", {})
  H.eq(vim.wait(2000, function()
    return not ws.readonly and #ws.session.data.comments == 1
  end, 20), true)
  wait()

  comments.add(ws.session, { scope = "session", body = "from the new owner" })
  H.eq(#session.load(root, s.id).data.comments, 2)
end

T["multiple Neovims"]["a Neovim that doesn't own the session leaves the stop signal"] = function()
  local root = H.repo()
  create(root)
  storage.write_json(storage.dir(root) .. "/lock", { pid = 1 })
  vim.fn.chdir(root)
  local signal = require("iz.signal")
  signal.start()
  -- Starting the watcher is async; give it a moment before the hook fires.
  vim.wait(300, function()
    return false
  end)
  H.write(root, ".iz/stop", "1\n")
  -- Nothing should happen, so there is no condition to wait on: give a wrong
  -- consumer time to act.
  vim.wait(500, function()
    return false
  end)
  H.eq(vim.uv.fs_stat(root .. "/.iz/stop") ~= nil, true)
  signal.stop()
  os.remove(storage.dir(root) .. "/lock")
end

T["multiple Neovims"][":IzDone cancelled without a workspace releases the lock"] = function()
  local root = H.repo()
  local s = create(root)
  comments.add(s, { scope = "session", body = "x" })
  vim.fn.chdir(root)
  local original, asked = vim.ui.select, false
  vim.ui.select = function(_, _, on_choice)
    vim.ui.select = original
    asked = true
    on_choice(nil)
  end
  require("iz.commands").done()
  H.eq(vim.wait(2000, function()
    return asked
  end, 20), true)
  H.eq(vim.uv.fs_stat(root .. "/.iz/lock"), nil)
  H.eq(session.current(root).data.state, "active")
end

T["multiple Neovims"]["running :Iz twice quickly opens one workspace"] = function()
  local root = H.repo({ ["a.txt"] = "a\n" })
  H.write(root, "a.txt", "b\n")
  vim.fn.chdir(root)
  local tabs = #api.nvim_list_tabpages()
  workspace.open()
  workspace.open()
  wait()
  H.eq(#api.nvim_list_tabpages(), tabs + 1)
  local n = 0
  for _ in vim.fs.dir(root .. "/.iz/sessions") do
    n = n + 1
  end
  H.eq(n, 1)
end

T["ids differ across restarts even with the same Lua random seed"] = function()
  local a, b = create(H.repo()), create(H.repo())
  math.randomseed(1)
  local first = comments.add(a, { scope = "session", body = "x" }).id
  math.randomseed(1)
  local second = comments.add(b, { scope = "session", body = "x" }).id
  H.neq(first, second)
end

T["an inbox file left unfinished is not retried forever"] = function()
  local root = H.repo()
  local s = create(root)
  local c = comments.add(s, { scope = "session", body = "x" })
  local name = ".iz/inbox/b_0001.jsonl"
  local content = '{"id":"%s","claim":"addressed","note":"ok"}\n{"id": "c_x", "claim": addr'
  H.write(root, name, content:format(c.id))

  -- Fresh: maybe still being written, so wait.
  local result = inbox.ingest(s)
  H.eq({ result.replies, #result.waiting }, { 0, 1 })

  -- Old: the agent is not coming back; keep the valid line and report the rest.
  local old = os.time() - 60
  vim.uv.fs_utime(root .. "/" .. name, old, old)
  result = inbox.ingest(s)
  H.eq(result.replies, 1)
  H.eq(#result.failed, 1)
  H.eq(inbox.summary(result) ~= nil, true)
end

T["a skill edited by hand is not replaced without asking, even with the marker kept"] = function()
  local claude = require("iz.claude")
  local dir = vim.fn.tempname()
  claude.install({ dir = dir })
  local skill = dir .. "/skills/iz/SKILL.md"
  H.write(dir, "skills/iz/SKILL.md", H.read(dir, "skills/iz/SKILL.md") .. "\nMY OWN RULE\n")
  local asked = false
  claude.install({
    dir = dir,
    confirm = function()
      asked = true
      return false
    end,
  })
  H.eq(asked, true)
  H.eq(H.read(dir, "skills/iz/SKILL.md"):find("MY OWN RULE", 1, true) ~= nil, true)
  H.eq(vim.uv.fs_stat(skill .. ".bak"), nil)
end

T["workspace"] = MiniTest.new_set()

T["workspace"][":tabclose leaves no iz marks on the real file"] = function()
  local root = H.repo({ ["a.txt"] = "a\nb\n" })
  H.write(root, "a.txt", "a\nB\n")
  local ws = open(root)
  local right = api.nvim_win_get_buf(ws.wins.right)
  comments.add(ws.session, {
    scope = "line", file = "a.txt", side = "new", line = 2, end_line = 2,
    anchor = { snippet = "B", context_before = { "a" }, state = "found" }, body = "x",
  })
  workspace.actions.stage_file()
  wait()
  H.eq(#api.nvim_buf_get_extmarks(right, hl.ns, 0, -1, {}) > 0, true)

  api.nvim_set_current_tabpage(ws.tab)
  vim.cmd("tabclose")
  wait()
  H.eq(workspace.get(), nil)
  H.eq(#api.nvim_buf_get_extmarks(right, hl.ns, 0, -1, {}), 0)
  H.eq(#api.nvim_buf_get_extmarks(right, inline.ns, 0, -1, {}), 0)
end

T["workspace"]["turning on the filter moves away from a file it hides"] = function()
  local root = H.repo({ ["a.txt"] = "a\n", ["b.txt"] = "b\n" })
  H.write(root, "a.txt", "A\n")
  H.write(root, "b.txt", "B\n")
  local ws = open(root)
  H.eq(ws.path, "a.txt")
  workspace.actions.stage_file()
  wait()
  workspace.actions.toggle_filter()
  wait()
  H.eq(ws.path, "b.txt")
end

T["workspace"]["a refresh with the filter on keeps both diff windows"] = function()
  local root = H.repo({ ["a.txt"] = H.lines(20) })
  H.write(root, "a.txt", H.lines(20, { [2] = "two", [15] = "fifteen" }))
  local ws = open(root)
  workspace.actions.toggle_filter()
  wait()
  api.nvim_set_current_win(ws.wins.right)
  api.nvim_win_set_cursor(ws.wins.right, { 2, 0 })
  workspace.actions.stage()
  wait()
  H.eq(api.nvim_win_is_valid(ws.wins.left), true)
  H.eq(vim.wo[ws.wins.left].diff, true)
end

T["workspace"]["file actions are refused while the file has unsaved changes"] = function()
  local root = H.repo({ ["a.txt"] = "a\n" })
  H.write(root, "a.txt", "agent\n")
  local ws = open(root)
  local right = api.nvim_win_get_buf(ws.wins.right)
  api.nvim_buf_set_lines(right, 0, -1, false, { "mine, unsaved" })
  api.nvim_set_current_win(ws.wins.files)
  workspace.actions.discard_file()
  wait()
  H.eq(H.read(root, "a.txt"), "agent\n")
  vim.bo[right].modified = false
end

T["workspace"]["the panel lists comments by file and line"] = function()
  local root = H.repo({ ["a.txt"] = H.lines(9), ["b.txt"] = "b\n" })
  H.write(root, "a.txt", H.lines(9, { [5] = "five" }))
  local ws = open(root)
  local function add(file, line)
    comments.add(ws.session, {
      scope = "line", file = file, side = "new", line = line, end_line = line,
      anchor = { snippet = "line " .. line, context_before = {}, state = "found" },
      body = file .. line,
    })
  end
  add("b.txt", 1)
  add("a.txt", 7)
  add("a.txt", 2)
  workspace.refresh()
  wait()
  local headers = vim.tbl_filter(function(l)
    return l:match("^  %S+:%d")
  end, api.nvim_buf_get_lines(ws.panel.buf, 0, -1, false))
  H.eq(vim.tbl_map(function(l)
    return l:match("^  (%S+:%d+)")
  end, headers), { "a.txt:2", "a.txt:7", "b.txt:1" })
end

T["workspace"]["a lost comment stays near where it was"] = function()
  local root = H.repo({ ["a.txt"] = H.lines(9) })
  H.write(root, "a.txt", H.lines(9, { [6] = "six" }))
  local ws = open(root)
  comments.add(ws.session, {
    scope = "line", file = "a.txt", side = "new", line = 6, end_line = 6,
    anchor = { snippet = "gone", context_before = {}, state = "lost" }, body = "x",
  })
  workspace.refresh()
  wait()
  local marks = api.nvim_buf_get_extmarks(api.nvim_win_get_buf(ws.wins.right), inline.ns, 0, -1, {})
  H.eq(marks[1][2], 5)
end

T["the file list shows each directory once"] = function()
  local files = require("iz.ui.files")
  local view = function(path)
    return {
      path = path,
      kind = "M",
      binary = false,
      added = 1,
      removed = 0,
      staged = 0,
      unstaged = 1,
      hunks = {},
    }
  end
  local list = { view("a/b.txt"), view("a/c/d.txt"), view("a/e.txt") }
  local rendered = files.render(list, { filter = false })
  H.eq(rendered.lines, {
    "a/",
    "  M b.txt  +1 -0  ● new",
    "  M e.txt  +1 -0  ● new",
    "a/c/",
    "  M d.txt  +1 -0  ● new",
  })
end

T[":Iz history lists only closed sessions"] = function()
  local root = H.repo()
  local first = create(root)
  session.complete(first)
  create(root)
  local lifecycle = require("iz.lifecycle")
  local closed = lifecycle.list(root, { state = "completed" })
  H.eq(vim.tbl_map(function(s)
    return s.id
  end, closed), { first.id })
end

return T
