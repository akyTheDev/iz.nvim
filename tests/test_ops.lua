local H = require("tests.helpers")
local hunks = require("iz.git.hunks")
local ops = require("iz.git.ops")
local session = require("iz.session")

local T = MiniTest.new_set()

local function setup(files)
  local root = H.repo(files)
  local s = H.run(function()
    return session.create(root)
  end)
  return root, s
end

local function file_view(s, path)
  return H.run(function()
    return hunks.compute(s).by_path[path]
  end)
end

local function call(fn, ...)
  local args = { ... }
  return H.run(function()
    return fn(unpack(args))
  end)
end

T["stage and unstage a single hunk out of two"] = function()
  local root, s = setup({ ["f.txt"] = H.lines(20) })
  H.write(root, "f.txt", H.lines(20, { [2] = "two", [15] = "fifteen" }))
  local file = file_view(s, "f.txt")
  H.eq(#file.hunks, 2)

  call(ops.stage_hunk, s, "f.txt", file.hunks[1])
  file = file_view(s, "f.txt")
  H.eq({ file.hunks[1].state, file.hunks[2].state }, { "staged", "unstaged" })
  H.eq(H.git(root, { "diff", "--cached", "--name-only" }), "f.txt")

  call(ops.unstage_hunk, s, "f.txt", file.hunks[1])
  file = file_view(s, "f.txt")
  H.eq({ file.hunks[1].state, file.hunks[2].state }, { "unstaged", "unstaged" })
  H.eq(H.git(root, { "diff", "--cached", "--name-only" }), "")
end

T["a staged hunk that changes again becomes unstaged and marks the new lines"] = function()
  local root, s = setup({ ["f.txt"] = H.lines(10) })
  H.write(root, "f.txt", H.lines(10, { [3] = "three", [4] = "four" }))
  call(ops.stage_hunk, s, "f.txt", file_view(s, "f.txt").hunks[1])
  H.write(root, "f.txt", H.lines(10, { [3] = "three", [4] = "FOUR" }))

  local file = file_view(s, "f.txt")
  H.eq(#file.hunks, 1)
  H.eq(file.hunks[1].state, "unstaged")
  H.eq(file.hunks[1].new_vs_index, { { 4, 4 } })

  -- A hunk that was never approved marks nothing: all of it is new anyway.
  H.write(root, "f.txt", H.lines(10, { [3] = "three", [4] = "FOUR", [9] = "nine" }))
  H.eq(file_view(s, "f.txt").hunks[2].new_vs_index, {})

  -- Staging again approves the whole block.
  call(ops.stage_hunk, s, "f.txt", file.hunks[1])
  H.eq(file_view(s, "f.txt").hunks[1].state, "staged")
end

T["discard keeps the approved part and undo brings the rest back"] = function()
  local root, s = setup({ ["f.txt"] = H.lines(10) })
  H.write(root, "f.txt", H.lines(10, { [3] = "three" }))
  call(ops.stage_hunk, s, "f.txt", file_view(s, "f.txt").hunks[1])
  H.write(root, "f.txt", H.lines(10, { [3] = "three", [4] = "four" }))

  call(ops.discard_hunk, s, "f.txt", file_view(s, "f.txt").hunks[1])
  H.eq(H.read(root, "f.txt"), H.lines(10, { [3] = "three" }))
  H.eq(#s.data.trash, 1)

  call(ops.undo_discard, s)
  H.eq(H.read(root, "f.txt"), H.lines(10, { [3] = "three", [4] = "four" }))
  H.eq(#s.data.trash, 0)
end

T["new, deleted and binary files"] = function()
  local root, s = setup({ ["old.txt"] = "bye\n", ["img.bin"] = "\0\1\2" })
  H.write(root, "new.txt", "hi\n")
  os.remove(root .. "/old.txt")
  H.write(root, "img.bin", "\0\3\4")

  -- A new untracked file stages through its single hunk.
  call(ops.stage_hunk, s, "new.txt", file_view(s, "new.txt").hunks[1])
  H.eq(file_view(s, "new.txt").kind, "A")
  H.eq(file_view(s, "new.txt").hunks[1].state, "staged")

  call(ops.stage_hunk, s, "old.txt", file_view(s, "old.txt").hunks[1])
  H.eq(file_view(s, "old.txt").staged, 1)

  local bin = file_view(s, "img.bin")
  H.eq(bin.binary, true)
  H.eq(bin.unstaged, 1)
  call(ops.discard_file, s, "img.bin")
  H.eq(H.read(root, "img.bin"), "\0\1\2")
  call(ops.undo_discard, s)
  H.eq(H.read(root, "img.bin"), "\0\3\4")
end

T["discarding a new untracked file removes it and undo restores it"] = function()
  local root, s = setup()
  H.write(root, "tmp.txt", "a\nb\n")
  call(ops.discard_hunk, s, "tmp.txt", file_view(s, "tmp.txt").hunks[1])
  H.eq(H.read(root, "tmp.txt"), nil)
  call(ops.undo_discard, s)
  H.eq(H.read(root, "tmp.txt"), "a\nb\n")
end

T["file level stage and unstage"] = function()
  local root, s = setup({ ["f.txt"] = H.lines(20) })
  H.write(root, "f.txt", H.lines(20, { [2] = "two", [15] = "fifteen" }))
  H.write(root, "n.txt", "n\n")
  call(ops.stage_file, s, "f.txt")
  call(ops.stage_file, s, "n.txt")
  H.eq(file_view(s, "f.txt").unstaged, 0)
  call(ops.unstage_file, s, "f.txt")
  call(ops.unstage_file, s, "n.txt")
  H.eq(file_view(s, "f.txt").staged, 0)
  H.eq(file_view(s, "n.txt").kind, "?")
end

T["a stale hunk is refused"] = function()
  local root, s = setup({ ["f.txt"] = H.lines(10) })
  H.write(root, "f.txt", H.lines(10, { [3] = "three" }))
  local seen = file_view(s, "f.txt").hunks[1]
  H.write(root, "f.txt", H.lines(10, { [3] = "three", [4] = "four" }))
  local ok, err = pcall(call, ops.stage_hunk, s, "f.txt", seen)
  H.eq(ok, false)
  H.eq(tostring(err):find(ops.STALE, 1, true) ~= nil, true)
  H.eq(H.git(root, { "diff", "--cached", "--name-only" }), "")
end

return T
