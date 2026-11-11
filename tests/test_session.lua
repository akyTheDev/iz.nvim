local H = require("tests.helpers")
local hunks = require("iz.git.hunks")
local lock = require("iz.storage.lock")
local session = require("iz.session")
local storage = require("iz.storage")

local T = MiniTest.new_set()

local function view_of(s)
  return H.run(function()
    return hunks.compute(s)
  end)
end

local function create(root)
  return H.run(function()
    return session.create(root)
  end)
end

T["create"] = MiniTest.new_set()

T["create"]["writes session.json, current and the exclude entry"] = function()
  local root = H.repo()
  local s = create(root)
  H.eq(session.current(root).id, s.id)
  H.eq(s.data.state, "active")
  H.eq(H.git(root, { "rev-parse", "refs/iz/sessions/" .. s.id }), s.data.base)
  local exclude = H.read(root, ".git/info/exclude")
  H.eq(exclude:find("/.iz/", 1, true) ~= nil, true)
  H.eq(H.git(root, { "status", "--porcelain" }), "")
end

T["create"]["does not touch .gitignore and adds the exclude line once"] = function()
  local root = H.repo()
  create(root)
  H.run(function()
    storage.ensure(root)
  end)
  local _, count = H.read(root, ".git/info/exclude"):gsub("/%.iz/", "")
  H.eq(count, 1)
  H.eq(H.read(root, ".gitignore"), nil)
end

T["create"]["works in a repository without commits"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local root = vim.uv.fs_realpath(dir)
  H.git(root, { "init", "-q" })
  local s = create(root)
  H.write(root, "new.txt", "x\n")
  local view = view_of(s)
  H.eq(#view.files, 1)
  H.eq(view.files[1].kind, "?")
end

T["create"]["refuses an index with conflicts"] = function()
  local root = H.repo({ ["f"] = "base\n" })
  H.git(root, { "checkout", "-q", "-b", "other" })
  H.write(root, "f", "other\n")
  H.git(root, { "commit", "-qam", "other" })
  H.git(root, { "checkout", "-q", "main" })
  H.write(root, "f", "main\n")
  H.git(root, { "commit", "-qam", "main" })
  vim.system({ "git", "merge", "-q", "other" }, { cwd = root }):wait()
  local ok, err = pcall(create, root)
  H.eq(ok, false)
  H.eq(tostring(err):find("conflicts") ~= nil, true)
end

T["base"] = MiniTest.new_set()

T["base"]["staged but uncommitted work from an earlier task stays out of the diff"] = function()
  local root = H.repo({ ["a.txt"] = "one\n" })
  H.write(root, "a.txt", "one\ntwo\n")
  H.git(root, { "add", "a.txt" })
  local s = create(root)
  H.eq(#view_of(s).files, 0)
  H.write(root, "a.txt", "one\ntwo\nthree\n")
  local view = view_of(s)
  H.eq(#view.files, 1)
  H.eq(view.files[1].hunks[1].lines, { "+three" })
end

T["base"]["files the agent created before the session opened are listed as new"] = function()
  -- The usual flow: the agent works first, then the user runs :Iz.
  local root = H.repo()
  H.write(root, "src/errors.lua", "return {}\n")
  local s = create(root)
  local file = view_of(s).files[1]
  H.eq({ file.path, file.kind }, { "src/errors.lua", "?" })
end

T["base"]["survives garbage collection"] = function()
  local root = H.repo()
  local s = create(root)
  H.git(root, { "gc", "-q", "--prune=now" })
  H.eq(H.git(root, { "cat-file", "-t", s.data.base }), "commit")
end

T["view"] = MiniTest.new_set()

T["view"]["lists added, modified and deleted files with counts"] = function()
  local root = H.repo({ ["keep.txt"] = "a\nb\n", ["gone.txt"] = "x\n" })
  local s = create(root)
  H.write(root, "keep.txt", "a\nB\nc\n")
  os.remove(root .. "/gone.txt")
  H.write(root, "dir/new.txt", "n\n")
  local view = view_of(s)
  local kinds = vim.tbl_map(function(f)
    return f.path .. ":" .. f.kind
  end, view.files)
  H.eq(kinds, { "dir/new.txt:?", "gone.txt:D", "keep.txt:M" })
  H.eq(view.by_path["keep.txt"].added, 2)
  H.eq(view.by_path["keep.txt"].removed, 1)
end

T["view"]["sees a same-size edit made in the same second as the last index write"] = function()
  -- Racy git: only the index file's own mtime tells git to distrust stat data.
  local root = H.repo({ ["a.txt"] = "a\n" })
  local s = create(root)
  H.write(root, "a.txt", "b\n")
  vim.wait(1100, function()
    return false
  end)
  H.eq(#view_of(s).files, 1)
end

T["view"]["never lists .iz/"] = function()
  local root = H.repo()
  local s = create(root)
  H.write(root, ".iz/extra.txt", "x\n")
  H.eq(#view_of(s).files, 0)
end

T["session"] = MiniTest.new_set()

T["session"]["open reuses the active session and complete clears current"] = function()
  local root = H.repo()
  local first = create(root)
  local again = H.run(function()
    return session.open(root)
  end)
  H.eq(again.id, first.id)
  session.complete(first)
  H.eq(session.current(root), nil)
  H.eq(session.load(root, first.id).data.state, "completed")
  local next_session = H.run(function()
    return session.open(root)
  end)
  H.neq(next_session.id, first.id)
end

T["session"]["rejects an unknown schema version"] = function()
  local root = H.repo()
  local s = create(root)
  s.data.schema_version = 99
  session.save(s)
  local ok, err = pcall(session.load, root, s.id)
  H.eq(ok, false)
  H.eq(tostring(err):find("schema version") ~= nil, true)
end

T["one writer: the lock is kept from other live Neovims and taken from dead ones"] = function()
  local root = H.repo()
  H.eq(lock.acquire(root), true)
  H.eq(lock.acquire(root), true)
  -- A live process that is not us holds the lock.
  storage.write_json(storage.dir(root) .. "/lock", { pid = 1 })
  local acquired, owner = lock.acquire(root)
  H.eq(acquired, false)
  H.eq(owner.pid, 1)
  -- A dead holder is replaced.
  storage.write_json(storage.dir(root) .. "/lock", { pid = 999999 })
  H.eq(lock.acquire(root), true)
  lock.release(root)
  H.eq(vim.uv.fs_stat(storage.dir(root) .. "/lock"), nil)
end

return T
