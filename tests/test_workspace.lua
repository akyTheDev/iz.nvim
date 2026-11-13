local H = require("tests.helpers")
local hl = require("iz.ui.highlights")
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

local function files_lines(ws)
  return api.nvim_buf_get_lines(ws.files_buf, 0, -1, false)
end

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      workspace.close()
      wait()
    end,
  },
})

T["opens a tab with the file list and a diff of the first file"] = function()
  local root = H.repo({ ["a.txt"] = H.lines(5), ["src/b.txt"] = "b\n" })
  H.write(root, "a.txt", H.lines(5, { [2] = "two" }))
  H.write(root, "src/b.txt", "b\nB\n")
  local ws = open(root)

  H.eq(files_lines(ws), {
    "M a.txt  +1 -1  ● new",
    "src/",
    "  M b.txt  +1 -0  ● new",
  })
  H.eq(ws.path, "a.txt")
  H.eq(api.nvim_buf_get_name(api.nvim_win_get_buf(ws.wins.right)), root .. "/a.txt")
  H.eq(vim.wo[ws.wins.left].diff, true)
  H.eq(vim.wo[ws.wins.right].diff, true)
  H.eq(api.nvim_buf_get_lines(api.nvim_win_get_buf(ws.wins.left), 1, 2, false), { "line 2" })
  -- Named, so tab lines and status lines don't say [Scratch].
  H.eq(api.nvim_buf_get_name(ws.files_buf), "iz://files")
end

T["? lists the keys of the window, as configured"] = function()
  local help = require("iz.ui.help")
  local config = require("iz.config")
  config.setup({ keymaps = { panel = { ignore = "" } } })
  local lines = help.lines("panel")
  config.setup()
  H.eq(lines[1], " <CR>  open the thread and show its code")
  H.eq(vim.tbl_contains(lines, " i     ignore"), false)

  local root = H.repo({ ["a.txt"] = "a\n" })
  H.write(root, "a.txt", "A\n")
  local ws = open(root)
  api.nvim_set_current_win(ws.wins.files)
  api.nvim_feedkeys("?", "x", false)
  H.eq(api.nvim_win_get_config(0).title[1][1], " iz · files ")
  vim.cmd("close")
end

T["opening a file from the list puts the cursor on its first hunk"] = function()
  local root = H.repo({ ["a.txt"] = "a\n", ["b.txt"] = H.lines(9) })
  H.write(root, "a.txt", "A\n")
  H.write(root, "b.txt", H.lines(9, { [6] = "six" }))
  local ws = open(root)
  api.nvim_set_current_win(ws.wins.files)
  api.nvim_win_set_cursor(ws.wins.files, { 2, 0 })
  workspace.actions.open_under_cursor()
  wait()
  H.eq(ws.path, "b.txt")
  H.eq(api.nvim_get_current_win(), ws.wins.right)
  H.eq(api.nvim_win_get_cursor(ws.wins.right)[1], 6)

  workspace.actions.focus_files()
  H.eq(api.nvim_get_current_win(), ws.wins.files)
  H.eq(api.nvim_win_get_cursor(ws.wins.files)[1], 2)
end

T["moving through the file list shows the file under the cursor, focus stays"] = function()
  local root = H.repo({ ["a.txt"] = "a\n", ["b.txt"] = H.lines(30) })
  H.write(root, "a.txt", "A\n")
  H.write(root, "b.txt", H.lines(30, { [20] = "twenty" }))
  local ws = open(root)
  H.eq(ws.path, "a.txt")
  api.nvim_set_current_win(ws.wins.files)
  api.nvim_win_set_cursor(ws.wins.files, { 2, 0 })
  -- Headless Neovim fires CursorMoved only from its main loop, not for feedkeys.
  api.nvim_exec_autocmds("CursorMoved", { buffer = ws.files_buf })
  -- The preview is debounced.
  H.eq(vim.wait(3000, function()
    return ws.path == "b.txt"
  end, 10), true)
  wait()
  H.eq(api.nvim_get_current_win(), ws.wins.files)
  H.eq(api.nvim_buf_get_name(api.nvim_win_get_buf(ws.wins.right)), root .. "/b.txt")
  H.eq(api.nvim_win_get_cursor(ws.wins.right)[1], 20)

  -- <CR> moves into the file already shown.
  workspace.actions.open_under_cursor()
  wait()
  H.eq(api.nvim_get_current_win(), ws.wins.right)
  H.eq(api.nvim_win_get_cursor(ws.wins.right)[1], 20)
end

T["staging from the diff marks the hunk and updates the list"] = function()
  local root = H.repo({ ["a.txt"] = H.lines(20) })
  H.write(root, "a.txt", H.lines(20, { [2] = "two", [15] = "fifteen" }))
  local ws = open(root)

  api.nvim_set_current_win(ws.wins.right)
  api.nvim_win_set_cursor(ws.wins.right, { 2, 0 })
  workspace.actions.stage()
  wait()

  local file = ws.view.by_path["a.txt"]
  H.eq({ file.hunks[1].state, file.hunks[2].state }, { "staged", "unstaged" })
  H.eq(files_lines(ws), { "M a.txt  +2 -2  ◐ 1/2" })
  H.eq(vim.wo[ws.wins.files].winbar, " iz · 1/2 staged%=? keys ")

  local right = api.nvim_win_get_buf(ws.wins.right)
  local marks = api.nvim_buf_get_extmarks(right, hl.ns, 0, -1, { details = true })
  local staged = vim.tbl_filter(function(m)
    return m[4].hl_group == "IzStaged"
  end, marks)
  H.eq(#staged, 1)
  H.eq(staged[1][2], 1) -- 0-based row of line 2
end

T["next hunk jumps within the file and then to the next file"] = function()
  local root = H.repo({ ["a.txt"] = H.lines(20), ["b.txt"] = H.lines(5) })
  H.write(root, "a.txt", H.lines(20, { [2] = "two", [15] = "fifteen" }))
  H.write(root, "b.txt", H.lines(5, { [4] = "four" }))
  local ws = open(root)

  api.nvim_set_current_win(ws.wins.right)
  api.nvim_win_set_cursor(ws.wins.right, { 1, 0 })
  workspace.actions.next_hunk()
  H.eq(api.nvim_win_get_cursor(ws.wins.right)[1], 2)
  workspace.actions.next_hunk()
  H.eq(api.nvim_win_get_cursor(ws.wins.right)[1], 15)
  workspace.actions.next_hunk()
  wait()
  H.eq(ws.path, "b.txt")
  H.eq(api.nvim_win_get_cursor(ws.wins.right)[1], 4)
end

T["the filter hides fully staged files and diffs against the index"] = function()
  local root = H.repo({ ["a.txt"] = "a\n", ["b.txt"] = "b\n" })
  H.write(root, "a.txt", "a\nA\n")
  H.write(root, "b.txt", "b\nB\n")
  local ws = open(root)
  -- Staged after the session opened, so it is an approval rather than part of Base.
  H.git(root, { "add", "a.txt" })
  workspace.refresh()
  wait()
  H.eq(#files_lines(ws), 2)

  workspace.actions.toggle_filter()
  wait()
  H.eq(files_lines(ws), { "M b.txt  +1 -0  ● new" })
  local left_name = api.nvim_buf_get_name(api.nvim_win_get_buf(ws.wins.left))
  H.eq(left_name:find("/index/", 1, true) ~= nil, true)
end

T["edits made in the workspace show up as unstaged"] = function()
  local root = H.repo({ ["a.txt"] = "a\n" })
  H.write(root, "a.txt", "a\nagent\n")
  local ws = open(root)
  H.git(root, { "add", "a.txt" })
  workspace.refresh()
  wait()
  H.eq(files_lines(ws), { "M a.txt  +1 -0  ✓ staged" })

  api.nvim_set_current_win(ws.wins.right)
  api.nvim_buf_set_lines(0, -1, -1, false, { "mine" })
  vim.cmd("silent write")
  -- The save triggers a debounced refresh.
  vim.wait(3000, function()
    return files_lines(ws)[1] == "M a.txt  +2 -0  ● new"
  end, 20)
  wait()
  H.eq(files_lines(ws), { "M a.txt  +2 -0  ● new" })
end

--- Types `body` into the open comment editor and saves it.
local function type_and_save(body)
  local buf = api.nvim_get_current_buf()
  H.eq(vim.bo[buf].filetype, "markdown")
  vim.cmd("stopinsert")
  api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(body, "\n"))
  vim.cmd("write")
end

local function panel_lines(ws)
  return api.nvim_buf_get_lines(ws.panel.buf, 0, -1, false)
end

T["comments"] = MiniTest.new_set()

T["comments"]["the workspace keys work in the panel without running its plain keys"] = function()
  local root = H.repo({ ["a.txt"] = "a\n" })
  H.write(root, "a.txt", "A\n")
  local ws = open(root)
  require("iz.session.comments").add(ws.session, { scope = "session", body = "x" })
  workspace.refresh()
  wait()
  api.nvim_set_current_win(ws.panel.win)
  api.nvim_win_set_cursor(ws.panel.win, { 2, 0 })
  -- Real keys (the default leader is `\`): `<leader>if` must not fall through
  -- to the panel's `i` (ignore).
  api.nvim_feedkeys("\\if", "x", false)
  wait()
  H.eq(ws.filter, true)
  H.eq(ws.session.data.comments[1].status, "open")
end

T["comments"]["the panel key opens the panel, moves into it, then closes it"] = function()
  local root = H.repo({ ["a.txt"] = "a\n" })
  H.write(root, "a.txt", "A\n")
  local ws = open(root)
  api.nvim_set_current_win(ws.wins.right)

  workspace.actions.toggle_panel()
  H.eq(api.nvim_get_current_win(), ws.panel.win)

  api.nvim_set_current_win(ws.wins.right)
  workspace.actions.toggle_panel()
  H.eq(api.nvim_get_current_win(), ws.panel.win)

  workspace.actions.toggle_panel()
  H.eq(ws.panel.win, nil)
  H.eq(api.nvim_get_current_win(), ws.wins.right)
end

T["comments"]["a line comment opens the panel, shows inline and counts in the list"] = function()
  local root = H.repo({ ["a.txt"] = H.lines(5) })
  H.write(root, "a.txt", H.lines(5, { [3] = "three" }))
  local ws = open(root)
  H.eq(ws.panel.win, nil)

  api.nvim_set_current_win(ws.wins.right)
  api.nvim_win_set_cursor(ws.wins.right, { 3, 0 })
  workspace.actions.comment_line()
  type_and_save("use a constant")

  local c = ws.session.data.comments[1]
  local got = { c.scope, c.file, c.side, c.line, c.anchor.snippet }
  H.eq(got, { "line", "a.txt", "new", 3, "three" })
  H.eq(api.nvim_win_is_valid(ws.panel.win), true)
  H.eq(panel_lines(ws), {
    "Waiting for the agent (1)",
    "  a.txt:3",
    "    you    use a constant",
  })
  H.eq(files_lines(ws), { "M a.txt  +1 -1  ● new  1 open" })

  local inline = require("iz.ui.inline")
  local right = api.nvim_win_get_buf(ws.wins.right)
  local marks = api.nvim_buf_get_extmarks(right, inline.ns, 0, -1, { details = true })
  H.eq(#marks, 1)
  H.eq(marks[1][2], 2)
  H.eq(marks[1][4].virt_lines[1][2][1], "you: ")
  H.eq(marks[1][4].virt_lines[1][3][1], "use a constant")
end

T["comments"]["a comment on an unchanged base line lands on the working tree line"] = function()
  local root = H.repo({ ["a.txt"] = H.lines(6) })
  H.write(root, "a.txt", "new top\n" .. H.lines(6, { [2] = "two" }))
  local ws = open(root)

  api.nvim_set_current_win(ws.wins.left)
  api.nvim_win_set_cursor(ws.wins.left, { 5, 0 })
  workspace.actions.comment_line()
  type_and_save("unchanged line")
  local c = ws.session.data.comments[1]
  H.eq({ c.side, c.line, c.anchor.snippet }, { "new", 6, "line 5" })

  -- A changed line on the base side is a real old-side comment.
  api.nvim_set_current_win(ws.wins.left)
  api.nvim_win_set_cursor(ws.wins.left, { 2, 0 })
  workspace.actions.comment_line()
  type_and_save("why change this")
  c = ws.session.data.comments[2]
  H.eq({ c.side, c.line, c.anchor.snippet }, { "old", 2, "line 2" })
end

T["comments"]["panel actions resolve, reply and move"] = function()
  local root = H.repo({ ["a.txt"] = H.lines(5) })
  H.write(root, "a.txt", H.lines(5, { [3] = "three" }))
  local ws = open(root)
  workspace.actions.comment_session()
  type_and_save("check the login page")
  local c = ws.session.data.comments[1]

  api.nvim_set_current_win(ws.panel.win)
  api.nvim_win_set_cursor(ws.panel.win, { 2, 0 })
  workspace.actions.panel_reply()
  type_and_save("and the signup page")
  H.eq(#c.thread, 2)

  api.nvim_set_current_win(ws.panel.win)
  api.nvim_win_set_cursor(ws.panel.win, { 2, 0 })
  workspace.actions.panel_resolve()
  H.eq(c.status, "resolved")
  H.eq(panel_lines(ws), { "Closed (1)", "  ✓ resolved  session  check the login page" })
  H.eq(require("iz.session").load(root, ws.session.id).data.comments[1].status, "resolved")
end

T["comments"]["the panel shows first and last messages; lost reads as line changed"] = function()
  local c = {
    id = "c_1", scope = "line", file = "a.txt", side = "new", line = 4, end_line = 4,
    status = "open", attachments = {},
    anchor = { snippet = "x", context_before = {}, state = "lost" },
    thread = {
      { author = "user", body = "first\nsecond line", ts = "" },
      { author = "agent", claim = "question", body = "which one?", ts = "" },
      { author = "user", body = "the first", ts = "" },
      { author = "agent", claim = "addressed", body = "done", ts = "" },
    },
  }
  local other = vim.deepcopy(c)
  other.line, other.end_line, other.thread = 9, 9, { c.thread[2] }
  local lines = require("iz.ui.panel").render({ data = { comments = { c, other } } })
  H.eq(lines, {
    "Waiting for you (2)",
    "  a.txt:4 · line changed · addressed",
    "    you    first ⏎ second line",
    "    … 2 more",
    "    agent  done",
    "",
    "  a.txt:9 · lost · question",
    "    agent  which one?",
  })
end

T["comments"]["an inline comment fits its window, label included"] = function()
  local c = {
    id = "c_1", scope = "line", file = "a.txt", side = "new", line = 1, end_line = 1,
    status = "open", attachments = {},
    anchor = { snippet = "x", context_before = {}, state = "lost" },
    thread = {
      { author = "user", body = "x", ts = "" },
      { author = "agent", claim = "addressed", body = string.rep("long ", 20), ts = "" },
    },
  }
  local chunks = require("iz.ui.inline").virt_lines(c, 40)[1]
  H.eq(chunks[2][1], "addressed · line changed: ")
  local text = table.concat(vim.tbl_map(function(ch)
    return ch[1]
  end, chunks))
  H.eq(vim.fn.strchars(text), 40)
  H.eq(vim.fn.strcharpart(text, 39), "…")
end

T["comments"]["opening the panel keeps the two diff sides the same width"] = function()
  local root = H.repo({ ["a.txt"] = "a\n" })
  H.write(root, "a.txt", "A\n")
  local ws = open(root)
  workspace.actions.toggle_panel()
  local l, r = api.nvim_win_get_width(ws.wins.left), api.nvim_win_get_width(ws.wins.right)
  H.eq(math.abs(l - r) <= 1, true)
end

T["comments"]["<CR> in the panel opens the whole thread, where r resolves it"] = function()
  local root = H.repo({ ["a.txt"] = H.lines(5) })
  H.write(root, "a.txt", H.lines(5, { [3] = "three" }))
  local ws = open(root)
  local long = string.rep("word ", 60) .. "END"
  local c = require("iz.session.comments").add(ws.session, {
    scope = "line", file = "a.txt", side = "new", line = 3, end_line = 3,
    anchor = { snippet = "three", context_before = {}, state = "found" }, body = long,
  })
  workspace.refresh()
  wait()
  api.nvim_set_current_win(ws.panel.win)
  api.nvim_win_set_cursor(ws.panel.win, { 2, 0 })
  workspace.actions.panel_jump()
  wait()

  local float = api.nvim_get_current_win()
  H.eq(api.nvim_win_get_config(float).relative, "editor")
  local text = table.concat(api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  H.eq(text:find("END", 1, true) ~= nil, true)
  -- The diff behind it is on the Comment's code.
  H.eq(api.nvim_win_get_cursor(ws.wins.right)[1], 3)

  api.nvim_feedkeys("r", "x", false)
  H.eq(c.status, "resolved")
  H.eq(api.nvim_win_is_valid(float), false)
end

T["comments"]["going to the panel from a commented line lands on that comment"] = function()
  local root = H.repo({ ["a.txt"] = H.lines(9) })
  H.write(root, "a.txt", H.lines(9, { [2] = "two", [8] = "eight" }))
  local ws = open(root)
  local comments = require("iz.session.comments")
  for line, text in pairs({ [2] = "two", [8] = "eight" }) do
    comments.add(ws.session, {
      scope = "line", file = "a.txt", side = "new", line = line, end_line = line,
      anchor = { snippet = text, context_before = {}, state = "found" }, body = "on " .. line,
    })
  end
  workspace.refresh()
  wait()
  api.nvim_set_current_win(ws.wins.right)
  api.nvim_win_set_cursor(ws.wins.right, { 8, 0 })
  workspace.actions.toggle_panel()
  H.eq(api.nvim_get_current_win(), ws.panel.win)
  H.eq(api.nvim_get_current_line(), "  a.txt:8")
end

T["comments"]["the thread opens from the commented line in the diff"] = function()
  local root = H.repo({ ["a.txt"] = H.lines(5) })
  H.write(root, "a.txt", H.lines(5, { [3] = "three" }))
  local ws = open(root)
  api.nvim_set_current_win(ws.wins.right)
  api.nvim_win_set_cursor(ws.wins.right, { 3, 0 })
  workspace.actions.comment_line()
  type_and_save("use a constant")

  api.nvim_set_current_win(ws.wins.right)
  api.nvim_win_set_cursor(ws.wins.right, { 3, 0 })
  workspace.actions.open_thread()
  H.eq(api.nvim_buf_get_lines(0, 0, -1, false), { "you", "use a constant" })
  vim.cmd("close")
end

T["comments"]["the thread shows who wrote each message without markdown marks"] = function()
  local thread = require("iz.ui.thread")
  local lines, marks = thread.render({
    id = "c_1", scope = "line", file = "a.txt", line = 3, status = "open", attachments = {},
    thread = {
      { author = "user", body = "why?", ts = "" },
      { author = "agent", claim = "question", body = "revert it?\nor keep it", ts = "" },
    },
  })
  H.eq(lines, { "you", "why?", "", "agent · question", "revert it?", "or keep it" })
  H.eq(marks, {
    { 1, "IzThreadUser", 0, 3 },
    { 4, "IzThreadAgent", 0, 5 },
    { 4, "IzClaim", 5, #"agent · question" },
  })
end

T["comments"]["the thread float is roomy and keeps markdown rendered under the cursor"] = function()
  local root = H.repo({ ["a.txt"] = H.lines(5) })
  H.write(root, "a.txt", H.lines(5, { [3] = "three" }))
  local ws = open(root)
  api.nvim_set_current_win(ws.wins.right)
  api.nvim_win_set_cursor(ws.wins.right, { 3, 0 })
  workspace.actions.comment_line()
  type_and_save("short")
  api.nvim_set_current_win(ws.wins.right)
  api.nvim_win_set_cursor(ws.wins.right, { 3, 0 })
  workspace.actions.open_thread()
  local float = api.nvim_get_current_win()
  H.eq(api.nvim_win_get_height(float), math.floor(vim.o.lines * 0.6))
  H.eq(api.nvim_win_get_width(float) >= math.min(72, vim.o.columns - 6), true)
  H.eq(vim.wo[float].concealcursor, "nc")
  vim.cmd("close")
end

T["summary"] = MiniTest.new_set()

--- Real order: the agent ran /iz-summary before :Iz.
local function repo_with_summary()
  local root = H.repo({ ["a.txt"] = H.lines(5), ["b.txt"] = H.lines(5) })
  H.write(root, "a.txt", H.lines(5, { [3] = "three" }))
  H.write(root, "b.txt", H.lines(5, { [4] = "four" }))
  H.write(root, ".iz/summaries/20261113-120000.jsonl", vim.json.encode({
    file = "a.txt",
    summary = "Line three now names the constant the parser expects.",
  }) .. "\n")
  return root
end

--- The leaves of `layout` (from winlayout()), depth first.
local function leaves(layout)
  if layout[1] == "leaf" then
    return { layout[2] }
  end
  local out = {}
  for _, child in ipairs(layout[2]) do
    vim.list_extend(out, leaves(child))
  end
  return out
end

T["summary"]["a strip above both diff sides shows it, only for a file that has one"] = function()
  local root = repo_with_summary()
  local ws = open(root)
  H.eq(ws.path, "a.txt")
  local strip = assert(ws.summary.win)
  H.eq(api.nvim_buf_get_lines(api.nvim_win_get_buf(strip), 0, -1, false), {
    "Line three now names the constant the parser expects.",
  })
  H.eq(vim.wo[strip].statusline, " a.txt · agent says")
  -- One column: the strip on top, the two diff sides side by side under it.
  local col = vim.tbl_filter(function(node)
    return node[1] == "col"
  end, vim.fn.winlayout()[2])[1]
  H.eq(leaves(col), { strip, ws.wins.left, ws.wins.right })
  H.eq(col[2][2][1], "row")
  H.eq({ vim.wo[ws.wins.left].diff, vim.wo[ws.wins.right].diff }, { true, true })

  -- The panel stays full height beside it, and the narrower strip grows to fit.
  local strip_buf = api.nvim_win_get_buf(strip)
  vim.bo[strip_buf].modifiable = true
  api.nvim_buf_set_lines(strip_buf, 0, -1, false, { string.rep("word ", 30) })
  vim.bo[strip_buf].modifiable = false
  local before = api.nvim_win_get_height(strip)
  workspace.actions.toggle_panel()
  H.eq(api.nvim_win_get_height(strip) > before, true)
  local top = vim.tbl_map(function(node)
    return node[1] == "leaf" and node[2] or node[1]
  end, vim.fn.winlayout()[2])
  H.eq(top, { ws.wins.files, "col", ws.panel.win })
  workspace.actions.toggle_panel()

  api.nvim_set_current_win(ws.wins.files)
  api.nvim_win_set_cursor(ws.wins.files, { 2, 0 })
  workspace.actions.open_under_cursor()
  wait()
  H.eq(ws.path, "b.txt")
  H.eq(api.nvim_win_is_valid(strip), false)
  H.eq({ vim.wo[ws.wins.left].diff, vim.wo[ws.wins.right].diff }, { true, true })
  local l, r = api.nvim_win_get_width(ws.wins.left), api.nvim_win_get_width(ws.wins.right)
  H.eq(math.abs(l - r) <= 1, true)
end

T["summary"]["the strip says when the file changed after the summary"] = function()
  local root = repo_with_summary()
  local ws = open(root)
  H.write(root, "a.txt", H.lines(5, { [3] = "three", [5] = "five" }))
  workspace.refresh()
  wait()
  local label = vim.wo[ws.summary.win].statusline
  H.eq(label, " a.txt · agent says · outdated: the file changed since")
end

T["co-reviewer"] = MiniTest.new_set()

--- Real order: the co-reviewer ran before :Iz, maybe before `.iz/` existed.
local function repo_with_suggestions()
  local root = H.repo({ ["a.txt"] = H.lines(5) })
  H.write(root, "a.txt", H.lines(5, { [3] = "three" }))
  H.write(root, ".iz/coreview/20261113-120000.jsonl", table.concat({
    vim.json.encode({ file = "a.txt", line = 3, body = "three is a magic number" }),
    vim.json.encode({ file = "a.txt", body = "no test covers this" }),
  }, "\n") .. "\n")
  return root
end

T["co-reviewer"]["suggestions written before :Iz show up in their own group"] = function()
  local root = repo_with_suggestions()
  local ws = open(root)
  H.eq(panel_lines(ws), {
    "Suggested by the co-reviewer (2)",
    "  a.txt",
    "    co-reviewer  no test covers this",
    "",
    "  a.txt:3",
    "    co-reviewer  three is a magic number",
  })
  -- `.iz/` stays out of git even though the co-reviewer created it.
  H.eq(H.git(root, { "status", "--porcelain" }), "M a.txt")
  H.eq(vim.uv.fs_stat(root .. "/.iz/coreview/20261113-120000.jsonl"), nil)
end

T["co-reviewer"]["s sends a suggestion as it is and I ignores the rest"] = function()
  local root = repo_with_suggestions()
  local ws = open(root)
  api.nvim_set_current_win(ws.panel.win)
  api.nvim_win_set_cursor(ws.panel.win, { 5, 0 })
  api.nvim_feedkeys("s", "x", false)
  local sent = ws.session.data.comments[1]
  H.eq(sent.thread[2], { author = "user", body = "", ts = sent.thread[2].ts })
  H.eq(panel_lines(ws)[1], "Suggested by the co-reviewer (1)")
  H.eq(vim.tbl_contains(panel_lines(ws), "    you    sent to the agent"), true)
  local text = H.read(root, ".iz/brief.md")
  H.eq(text:find(sent.id .. " L3: three is a magic number", 1, true) ~= nil, true)
  -- Inline, the diff still says what was sent.
  local chunks = vim.tbl_map(function(chunk)
    return chunk[1]
  end, require("iz.ui.inline").virt_lines(sent, 80)[1])
  H.eq(table.concat(chunks), "  ┃ sent: three is a magic number")

  api.nvim_feedkeys("I", "x", false)
  H.eq(ws.session.data.comments[2].status, "ignored")
  H.eq(sent.status, "open")
end

T["co-reviewer"]["the thread names the co-reviewer and sends with s"] = function()
  local root = repo_with_suggestions()
  local ws = open(root)
  api.nvim_set_current_win(ws.wins.right)
  api.nvim_win_set_cursor(ws.wins.right, { 3, 0 })
  workspace.actions.open_thread()
  local float = api.nvim_get_current_win()
  H.eq(api.nvim_buf_get_lines(0, 0, -1, false), { "co-reviewer", "three is a magic number" })
  H.eq(api.nvim_win_get_config(float).footer[1][1]:find("^ s send") ~= nil, true)
  api.nvim_feedkeys("s", "x", false)
  H.eq(api.nvim_win_is_valid(float), false)
  H.eq(require("iz.session.comments").awaiting_agent(ws.session.data.comments[1]), true)
end

T["comments"]["the thread float scales with a wide screen"] = function()
  local root = H.repo({ ["a.txt"] = H.lines(5) })
  H.write(root, "a.txt", H.lines(5, { [3] = "three" }))
  local ws = open(root)
  api.nvim_set_current_win(ws.wins.right)
  api.nvim_win_set_cursor(ws.wins.right, { 3, 0 })
  workspace.actions.comment_line()
  type_and_save("short")
  local columns, lines = vim.o.columns, vim.o.lines
  vim.o.columns, vim.o.lines = 250, 80
  api.nvim_set_current_win(ws.wins.right)
  api.nvim_win_set_cursor(ws.wins.right, { 3, 0 })
  workspace.actions.open_thread()
  local float = api.nvim_get_current_win()
  local size = { api.nvim_win_get_width(float), api.nvim_win_get_height(float) }
  vim.cmd("close")
  vim.o.columns, vim.o.lines = columns, lines
  H.eq(size, { 150, 48 })
end

T["comments"]["anchors follow the code on refresh and get lost when it disappears"] = function()
  local root = H.repo({ ["a.txt"] = H.lines(5) })
  H.write(root, "a.txt", H.lines(5, { [3] = "three" }))
  local ws = open(root)
  api.nvim_set_current_win(ws.wins.right)
  api.nvim_win_set_cursor(ws.wins.right, { 3, 0 })
  workspace.actions.comment_line()
  type_and_save("x")
  local c = ws.session.data.comments[1]

  H.write(root, "a.txt", "new\n" .. H.lines(5, { [3] = "three" }))
  workspace.refresh()
  wait()
  H.eq({ c.line, c.anchor.state }, { 4, "found" })

  H.write(root, "a.txt", H.lines(5))
  workspace.refresh()
  wait()
  H.eq({ c.anchor.state, c.status }, { "lost", "open" })
  H.eq(panel_lines(ws)[2], "  a.txt:4 · lost")
end

T["comments"]["writes the Brief and picks up agent replies from the inbox"] = function()
  local root = H.repo({ ["a.txt"] = H.lines(5) })
  H.write(root, "a.txt", H.lines(5, { [3] = "three" }))
  local ws = open(root)
  api.nvim_set_current_win(ws.wins.right)
  api.nvim_win_set_cursor(ws.wins.right, { 3, 0 })
  workspace.actions.comment_line()
  type_and_save("use a constant")
  local c = ws.session.data.comments[1]

  local text = H.read(root, ".iz/brief.md")
  local id = text:match("^# iz brief (b_%x+)")
  H.eq(text:find(c.id .. " L3: use a constant", 1, true) ~= nil, true)

  local reply = vim.json.encode({ id = c.id, claim = "addressed", note = "extracted" })
  H.write(root, (".iz/inbox/%s.jsonl"):format(id), reply)
  H.eq(vim.wait(3000, function()
    return #c.thread == 2
  end, 20), true)
  wait()
  H.eq(H.read(root, ".iz/brief.md"), "No pending comments.\n")
  H.eq(panel_lines(ws)[1], "Waiting for you (1)")
end

T["a stop signal refreshes the open workspace and is consumed"] = function()
  local root = H.repo({ ["a.txt"] = "a\n" })
  H.write(root, "a.txt", "b\n")
  -- `.iz/` does not exist yet: opening the workspace must start the listener.
  local ws = open(root)
  local right = api.nvim_win_get_buf(ws.wins.right)
  -- The stop listener starts asynchronously; let it come up before the hook fires.
  vim.wait(500, function()
    return false
  end)

  -- The agent edits the open file and adds another, then its Stop hook fires.
  H.write(root, "a.txt", "agent\n")
  H.write(root, "new.txt", "n\n")
  H.write(root, ".iz/stop", "1\n")
  H.eq(vim.wait(3000, function()
    return #ws.view.files == 2
  end, 20), true)
  wait()
  H.eq(vim.uv.fs_stat(root .. "/.iz/stop"), nil)
  H.eq(api.nvim_buf_get_lines(right, 0, -1, false), { "agent" })
  require("iz.signal").stop()
end

T["comments"]["the comment editor discards an empty body"] = function()
  local root = H.repo({ ["a.txt"] = "a\n" })
  H.write(root, "a.txt", "b\n")
  local ws = open(root)
  workspace.actions.comment_session()
  type_and_save("   ")
  H.eq(#ws.session.data.comments, 0)
end

T["close removes the tab, scratch buffers and the lock"] = function()
  local root = H.repo({ ["a.txt"] = "a\n" })
  H.write(root, "a.txt", "b\n")
  local tabs = #api.nvim_list_tabpages()
  local ws = open(root)
  local files_buf = ws.files_buf
  H.eq(#api.nvim_list_tabpages(), tabs + 1)
  workspace.close()
  H.eq(#api.nvim_list_tabpages(), tabs)
  H.eq(api.nvim_buf_is_valid(files_buf), false)
  H.eq(vim.uv.fs_stat(storage.dir(root) .. "/lock"), nil)
end

return T
