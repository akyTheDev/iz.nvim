local H = require("tests.helpers")
local diff = require("iz.git.diff")
local hunks = require("iz.git.hunks")

local T = MiniTest.new_set()

T["git diff output becomes files, hunks and blob ids"] = function()
  local text = table.concat({
    "diff --git a/src/a b.lua b/src/a b.lua",
    "index " .. string.rep("1", 40) .. ".." .. string.rep("2", 40) .. " 100644",
    "--- a/src/a b.lua",
    "+++ b/src/a b.lua",
    "@@ -3 +3,2 @@",
    "-old",
    "+new",
    "+more",
    "@@ -10,0 +11 @@ fn()",
    "+inserted",
    "diff --git a/img.png b/img.png",
    "new file mode 100644",
    "index " .. string.rep("0", 40) .. ".." .. string.rep("3", 40),
    "Binary files /dev/null and b/img.png differ",
    "",
  }, "\n")
  local files = diff.parse(text)
  H.eq(#files, 2)
  H.eq(files[1].path, "src/a b.lua")
  H.eq(files[1].old_blob, string.rep("1", 40))
  H.eq(#files[1].hunks, 2)
  H.eq(files[1].hunks[1].old_start, 3)
  H.eq(files[1].hunks[1].old_count, 1)
  H.eq(files[1].hunks[1].new_count, 2)
  H.eq(files[1].hunks[2].old_count, 0)
  H.eq(files[1].hunks[2].lines, { "+inserted" })
  H.eq(files[2].status, "added")
  H.eq(files[2].binary, true)
  H.eq(files[2].old_blob, nil)
end

T["a patch from a subset of hunks keeps the file header"] = function()
  local file = diff.parse(table.concat({
    "diff --git a/x b/x",
    "--- a/x",
    "+++ b/x",
    "@@ -1 +1 @@",
    "-a",
    "+b",
    "@@ -5 +5 @@",
    "-c",
    "+d",
  }, "\n"))[1]
  local expected = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -5 +5 @@\n-c\n+d\n"
  H.eq(diff.patch(file, { file.hunks[2] }), expected)
end

T["hunk sides overlap when they share or touch lines"] = function()
  -- replace lines 10-12 vs. an insertion right after line 12
  H.eq(hunks.overlaps(10, 3, 12, 0), true)
  -- disjoint ranges
  H.eq(hunks.overlaps(10, 3, 14, 2), false)
  -- adjacent non-empty ranges are separate hunks
  H.eq(hunks.overlaps(10, 3, 13, 1), false)
  -- two insertions at the same gap
  H.eq(hunks.overlaps(4, 0, 4, 0), true)
  H.eq(hunks.overlaps(4, 0, 5, 0), false)
end

return T
