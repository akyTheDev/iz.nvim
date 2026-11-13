-- Turns the Co-reviewer's files in `.iz/coreview/` into Suggestions. Same
-- contract as the inbox: the Co-reviewer only creates files there; Neovim
-- reads them into session.json and deletes them, so each file has one writer.
local anchor = require("iz.session.anchor")
local comments = require("iz.session.comments")
local inbox = require("iz.inbox")
local session_mod = require("iz.session")
local storage = require("iz.storage")
local util = require("iz.util")

local M = {}

M.DIR = "coreview"
-- Per ingest: a Co-reviewer that writes more than this is not being selective.
M.MAX = 30

---@param root string
function M.dir(root)
  return storage.dir(root) .. "/" .. M.DIR
end

---@class iz.CoreviewResult
---@field suggestions integer
---@field failed string[] Files moved to coreview/failed/ because of invalid lines.
---@field waiting string[] Files whose last line is still being written.

---@param n any
local function positive_int(n)
  return type(n) == "number" and n >= 1 and math.floor(n) == n
end

--- One line of a Co-reviewer file as a new Suggestion, or what is wrong with it.
---@param root string
---@return fun(value: table): iz.NewComment?, string?
local function checker(root)
  local accepted = 0
  local function check(value)
    if type(value.body) ~= "string" or vim.trim(value.body) == "" then
      return nil, "needs a body"
    end
    if value.file == nil then
      return { scope = "session", body = value.body }
    end
    if type(value.file) ~= "string" or not storage.is_repo_path(value.file) then
      return nil, "file must be a path inside the repository"
    end
    local content = storage.read_file(root .. "/" .. value.file)
    if not content then
      return nil, "no such file: " .. value.file
    end
    if value.line == nil then
      return { scope = "file", file = value.file, body = value.body }
    end
    local first, last = value.line, value.end_line or value.line
    local lines = vim.split(content, "\n", { plain = true })
    if lines[#lines] == "" then
      table.remove(lines)
    end
    if not (positive_int(first) and positive_int(last) and first <= last and last <= #lines) then
      return nil, ("lines must be within 1..%d of %s"):format(#lines, value.file)
    end
    return {
      scope = "line",
      file = value.file,
      side = "new",
      line = first,
      end_line = last,
      anchor = anchor.capture(lines, first, last),
      body = value.body,
    }
  end
  return function(value)
    local spec, err = check(value)
    if spec then
      if accepted >= M.MAX then
        return nil, ("more than %d suggestions"):format(M.MAX)
      end
      accepted = accepted + 1
    end
    return spec, err
  end
end

--- Reads every Co-reviewer file into the Session as Suggestions. Saves once
--- when anything changed.
---@param session iz.Session
---@return iz.CoreviewResult
function M.ingest(session)
  local result = { suggestions = 0, failed = {}, waiting = {} }
  local dir = M.dir(session.root)
  if not vim.uv.fs_stat(dir) then
    return result
  end
  local done, waiting = inbox.drain(dir, checker(session.root))
  result.waiting = waiting
  for _, file in ipairs(done) do
    for _, spec in ipairs(file.entries) do
      comments.add_suggestion(session, spec)
      result.suggestions = result.suggestions + 1
    end
    if #file.errors > 0 then
      table.insert(result.failed, file.name .. " (" .. table.concat(file.errors, "; ") .. ")")
    end
  end
  if result.suggestions > 0 then
    session_mod.save(session)
  end
  return result
end

---@param result iz.CoreviewResult
---@return string? message nil when there is nothing to say
function M.summary(result)
  local parts = {}
  if result.suggestions > 0 then
    parts[#parts + 1] = "co-reviewer left " .. util.plural(result.suggestions, "suggestion")
  end
  if #result.failed > 0 then
    parts[#parts + 1] = "moved to coreview/failed: " .. table.concat(result.failed, ", ")
  end
  return #parts > 0 and table.concat(parts, "\n") or nil
end

return M
