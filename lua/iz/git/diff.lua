-- Parser for `git diff-tree -p -U0 --no-renames --full-index` output.
local M = {}

---@class iz.DiffHunk
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer
---@field header string The `@@ ... @@` line.
---@field lines string[] Body lines, prefixed with `+`, `-` or `\`.

---@class iz.DiffFile
---@field path string
---@field status "added"|"deleted"|"modified"
---@field binary boolean
---@field old_blob? string
---@field new_blob? string
---@field header string[] Lines from `diff --git` up to the first hunk; reused to build patches.
---@field hunks iz.DiffHunk[]

local NULL_BLOB = string.rep("0", 40)

---@param line string `diff --git a/<p> b/<p>`; without renames both sides are equal.
local function path_from_git_line(line)
  local rest = line:sub(#"diff --git a/" + 1)
  return rest:sub(1, (#rest - #" b/") / 2)
end

---@param text string
---@return iz.DiffFile[]
function M.parse(text)
  local files = {}
  local file, hunk

  for line in vim.gsplit(text, "\n", { plain = true }) do
    if vim.startswith(line, "diff --git ") then
      file = {
        path = path_from_git_line(line),
        status = "modified",
        binary = false,
        header = { line },
        hunks = {},
      }
      hunk = nil
      files[#files + 1] = file
    elseif file and not hunk and not vim.startswith(line, "@@") then
      if line ~= "" then
        file.header[#file.header + 1] = line
      end
      if vim.startswith(line, "new file mode") then
        file.status = "added"
      elseif vim.startswith(line, "deleted file mode") then
        file.status = "deleted"
      elseif vim.startswith(line, "Binary files") then
        file.binary = true
      else
        local old, new = line:match("^index (%x+)%.%.(%x+)")
        if old then
          file.old_blob = old ~= NULL_BLOB and old or nil
          file.new_blob = new ~= NULL_BLOB and new or nil
        end
      end
    elseif file and vim.startswith(line, "@@") then
      local os_, oc, ns, nc = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
      hunk = {
        old_start = tonumber(os_),
        old_count = oc == "" and 1 or tonumber(oc),
        new_start = tonumber(ns),
        new_count = nc == "" and 1 or tonumber(nc),
        header = line,
        lines = {},
      }
      file.hunks[#file.hunks + 1] = hunk
    elseif hunk and line ~= "" then
      hunk.lines[#hunk.lines + 1] = line
    end
  end

  return files
end

--- Builds a patch that `git apply --unidiff-zero` accepts from a subset of hunks.
---@param file iz.DiffFile
---@param hunks iz.DiffHunk[]
---@return string
function M.patch(file, hunks)
  local out = vim.deepcopy(file.header)
  for _, h in ipairs(hunks) do
    out[#out + 1] = h.header
    vim.list_extend(out, h.lines)
  end
  return table.concat(out, "\n") .. "\n"
end

return M
