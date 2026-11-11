-- Keeps Comments attached to their code. Exact matches only: a lost Anchor is
-- easy to spot and fix, a Comment silently moved to the wrong line is not.
local storage = require("iz.storage")

local M = {}

local CONTEXT_LINES = 2

---@param lines string[]
---@param before integer the context ends right above this line
---@param count integer
---@return string[]
local function context(lines, before, count)
  local out = {}
  local i = before - 1
  while i >= 1 and #out < count do
    local t = vim.trim(lines[i])
    if t ~= "" then
      table.insert(out, 1, t)
    end
    i = i - 1
  end
  return out
end

---@param lines string[]
---@param first integer
---@param last integer
local function snippet(lines, first, last)
  local out = {}
  for i = first, last do
    if lines[i] == nil then
      return nil
    end
    out[#out + 1] = vim.trim(lines[i])
  end
  return table.concat(out, "\n")
end

---@param lines string[]
---@param first integer
---@param last integer
---@return iz.Anchor
function M.capture(lines, first, last)
  return {
    snippet = snippet(lines, first, last) or "",
    context_before = context(lines, first, CONTEXT_LINES),
    state = "found",
  }
end

---@param anchor iz.Anchor
---@param lines string[]
---@param line integer last known first line
---@param height integer number of anchored lines
---@return integer? line new first line, nil when lost
function M.locate(anchor, lines, line, height)
  local function context_matches(i)
    return vim.deep_equal(context(lines, i, #anchor.context_before), anchor.context_before)
  end

  local in_place = snippet(lines, line, line + height - 1) == anchor.snippet
  if in_place and context_matches(line) then
    return line
  end

  local best
  for i = 1, #lines - height + 1 do
    if snippet(lines, i, i + height - 1) == anchor.snippet and context_matches(i) then
      if not best or math.abs(i - line) < math.abs(best - line) then
        best = i
      end
    end
  end
  -- Same text still in place but only its surroundings changed: stay put.
  if not best and in_place then
    return line
  end
  return best
end

---@param comment iz.Comment
local function relocatable(comment)
  return comment.anchor ~= nil and comment.side == "new" and comment.line ~= nil
end

--- Re-finds every new-side Anchor in the files as they are on disk.
---@param session iz.Session
---@param read? fun(path: string): string? defaults to reading the working tree
---@return boolean changed
function M.relocate_all(session, read)
  read = read or function(path)
    return storage.read_file(session.root .. "/" .. path)
  end
  local cache, changed = {}, false
  for _, c in ipairs(session.data.comments) do
    if relocatable(c) and c.status == "open" then
      if cache[c.file] == nil then
        local content = read(c.file)
        cache[c.file] = content and vim.split(content, "\n", { plain = true }) or false
      end
      local lines = cache[c.file]
      local height = (c.end_line or c.line) - c.line + 1
      local found = lines and M.locate(c.anchor, lines, c.line, height)
      local state = found and "found" or "lost"
      if found and found ~= c.line then
        c.end_line = found + height - 1
        c.line = found
        changed = true
      end
      if state ~= c.anchor.state then
        c.anchor.state = state
        changed = true
      end
    end
  end
  return changed
end

return M
