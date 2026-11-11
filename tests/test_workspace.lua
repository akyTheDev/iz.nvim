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
  H.eq(files_lines(ws), { "M a.txt  +2 -2  ◐ partial" })

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
    "  a.txt:3  " .. c.id,
    "    you: use a constant",
  })
  H.eq(files_lines(ws), { "M a.txt  +1 -1  ● new  1 open" })

  local inline = require("iz.ui.inline")
  local right = api.nvim_win_get_buf(ws.wins.right)
  local marks = api.nvim_buf_get_extmarks(right, inline.ns, 0, -1, { details = true })
  H.eq(#marks, 1)
  H.eq(marks[1][2], 2)
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
  H.eq(panel_lines(ws)[2], "  a.txt:4 (lost)  " .. c.id)
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
