local H = require("tests.helpers")
local lifecycle = require("iz.lifecycle")
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

--- Answers the next vim.ui.select with the item at `index` (nil cancels).
local function answer_select(index)
  local original = vim.ui.select
  vim.ui.select = function(items, _, on_choice)
    vim.ui.select = original
    on_choice(index and items[index] or nil)
  end
end

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      workspace.close()
      wait()
    end,
  },
})

T["done without open comments closes the session, the brief and the workspace"] = function()
  local root = H.repo({ ["a.txt"] = "a\n" })
  H.write(root, "a.txt", "b\n")
  local ws = open(root)
  local id = ws.session.id
  workspace.actions.done()
  H.eq(workspace.get(), nil)
  H.eq(session.current(root), nil)
  H.eq(session.load(root, id).data.state, "completed")
  H.eq(H.read(root, ".iz/brief.md"), "No pending comments.\n")
end

T["done with open comments asks, and cancelling changes nothing"] = function()
  local root = H.repo({ ["a.txt"] = "a\n" })
  H.write(root, "a.txt", "b\n")
  local s = H.run(function()
    return session.create(root)
  end)
  require("iz.session.comments").add(s, { scope = "session", body = "x" })

  answer_select(2)
  lifecycle.done(s)
  H.eq(session.current(root).data.state, "active")
  H.eq(s.data.comments[1].status, "open")

  answer_select(1)
  lifecycle.done(s)
  H.eq(session.load(root, s.id).data.state, "completed")
  H.eq(session.load(root, s.id).data.comments[1].status, "ignored")
end

T["the next session starts from the previous task's uncommitted, staged work"] = function()
  local root = H.repo({ ["a.txt"] = "a\n" })
  local first = open(root)
  H.write(root, "a.txt", "first task\n")
  H.git(root, { "add", "a.txt" })
  workspace.actions.done()
  H.eq(first.session.data.state, "completed")

  local second = open(root)
  H.neq(second.session.id, first.session.id)
  H.eq(#second.view.files, 0)
  H.eq(#lifecycle.list(root), 2)
end

T["a second Neovim gets a read-only workspace"] = function()
  local root = H.repo({ ["a.txt"] = "a\n" })
  H.write(root, "a.txt", "b\n")
  H.run(function()
    return session.create(root)
  end)
  -- PID 1 is always alive and never us.
  storage.write_json(storage.dir(root) .. "/lock", { pid = 1 })
  local ws = open(root)
  H.eq(ws.readonly, true)
  H.eq(vim.wo[ws.wins.files].winbar:find("read-only", 1, true) ~= nil, true)

  local before = H.read(root, ".iz/sessions/" .. ws.session.id .. "/session.json")
  api.nvim_set_current_win(ws.wins.right)
  workspace.actions.stage()
  workspace.actions.comment_session()
  wait()
  H.eq(H.git(root, { "diff", "--cached", "--name-only" }), "")
  H.eq(H.read(root, ".iz/sessions/" .. ws.session.id .. "/session.json"), before)
  H.eq(lock.owner(root).pid, 1)
  os.remove(storage.dir(root) .. "/lock")
end

T["says once when the session looks done"] = function()
  local root = H.repo({ ["a.txt"] = "a\n" })
  H.write(root, "a.txt", "b\n")
  local ws = open(root)
  H.eq(ws.suggested, false)
  workspace.actions.stage_file()
  wait()
  H.eq(ws.suggested, true)
end

return T
