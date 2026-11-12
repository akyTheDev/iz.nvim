-- The file list: grouped by directory, one line per file with its review status.
local hl = require("iz.ui.highlights")

local api = vim.api
local M = {}

local KIND_HL = {
  A = "IzKindAdded",
  ["?"] = "IzKindAdded",
  M = "IzKindChanged",
  D = "IzKindRemoved",
}

---@param file iz.FileView
---@return string word, string group
local function status_of(file)
  if file.unstaged == 0 then
    return "✓ staged", "IzStaged"
  elseif file.staged > 0 then
    return ("◐ %d/%d"):format(file.staged, file.staged + file.unstaged), "IzPartial"
  end
  return "● new", "IzUnstaged"
end

---@class iz.FilesRender
---@field lines string[]
---@field paths table<integer, string> line number -> file path

---@param path string
local function dir_of(path)
  local dir = vim.fs.dirname(path)
  return dir == "." and "" or dir .. "/"
end

--- Keeps the end of a long directory, where the distinguishing part usually is.
---@param dir string
---@param width integer
local function shorten(dir, width)
  if vim.fn.strchars(dir) <= width then
    return dir
  end
  return "…" .. vim.fn.strcharpart(dir, vim.fn.strchars(dir) - width + 1)
end

--- Display order: by directory first, so each directory gets exactly one header.
--- Navigation uses the same order so "next file" means the next line.
---@param files iz.FileView[]
---@return iz.FileView[]
function M.sort(files)
  local sorted = { unpack(files) }
  table.sort(sorted, function(a, b)
    local da, db = dir_of(a.path), dir_of(b.path)
    if da ~= db then
      return da < db
    end
    return a.path < b.path
  end)
  return sorted
end

---@param files iz.FileView[]
---@param opts { filter: boolean, width?: integer, extra?: fun(file: iz.FileView): string? }
---@return iz.FilesRender, table[] highlights
function M.render(files, opts)
  local lines, paths, marks = {}, {}, {}
  local last_dir
  for _, file in ipairs(M.sort(files)) do
    if not (opts.filter and file.unstaged == 0) then
      local dir = dir_of(file.path)
      if dir ~= last_dir and dir ~= "" then
        local header = shorten(dir, (opts.width or 1000) - 1)
        lines[#lines + 1] = header
        marks[#marks + 1] = { #lines, 0, #header, "IzDirectory" }
      end
      last_dir = dir

      local word, group = status_of(file)
      local name = vim.fs.basename(file.path)
      local indent = dir == "" and "" or "  "
      local counts = file.binary and "bin" or ("+%d -%d"):format(file.added, file.removed)
      local extra = opts.extra and opts.extra(file)
      local line = ("%s%s %s  %s  %s%s"):format(indent, file.kind, name, counts, word, extra or "")
      lines[#lines + 1] = line
      paths[#lines] = file.path

      local kind_col = #indent
      marks[#marks + 1] = { #lines, kind_col, kind_col + 1, KIND_HL[file.kind] }
      local word_col = line:find(word, 1, true) - 1
      marks[#marks + 1] = { #lines, word_col, word_col + #word, group }
      if file.unstaged == 0 then
        marks[#marks + 1] = { #lines, kind_col + 2, kind_col + 2 + #name, "IzMuted" }
      end
    end
  end
  if #lines == 0 then
    lines = { opts.filter and "Nothing left to review." or "No changes since Base." }
    marks = { { 1, 0, #lines[1], "IzMuted" } }
  end
  return { lines = lines, paths = paths }, marks
end

---@param buf integer
---@param files iz.FileView[]
---@param opts { filter: boolean, width?: integer, extra?: fun(file: iz.FileView): string? }
---@return table<integer, string> paths line -> path
function M.draw(buf, files, opts)
  local rendered, marks = M.render(files, opts)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, rendered.lines)
  vim.bo[buf].modifiable = false
  api.nvim_buf_clear_namespace(buf, hl.ns, 0, -1)
  for _, m in ipairs(marks) do
    api.nvim_buf_set_extmark(buf, hl.ns, m[1] - 1, m[2], { end_col = m[3], hl_group = m[4] })
  end
  return rendered.paths
end

return M
