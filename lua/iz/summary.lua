-- Summaries: the agent's own account of what it changed in a file and why,
-- written on request with /iz-summary. They arrive in `.iz/summaries/` (the
-- agent only creates files there) and are shown above the diff. A Summary
-- remembers the file it describes; once the file changes it reads as outdated.
local inbox = require("iz.inbox")
local session_mod = require("iz.session")
local storage = require("iz.storage")
local util = require("iz.util")

local M = {}

M.DIR = "summaries"
-- A Summary is a few sentences; anything longer belongs in the code or a Comment.
M.MAX_LENGTH = 1200

---@class iz.Summary
---@field body string
---@field hash? string sha256 of the file it describes; nil when it already changed on arrival
---@field ts string

---@param root string
function M.dir(root)
  return storage.dir(root) .. "/" .. M.DIR
end

---@class iz.SummaryResult
---@field summaries integer
---@field failed string[] Files moved to summaries/failed/ because of invalid lines.
---@field waiting string[] Files whose last line is still being written.

---@param stat? uv.fs_stat.result
local function mtime(stat)
  return stat and (stat.mtime.sec + stat.mtime.nsec / 1e9) or 0
end

---@param root string
local function checker(root)
  ---@param value table
  ---@param source? string
  return function(value, source)
    if type(value.file) ~= "string" or not storage.is_repo_path(value.file) then
      return nil, "file must be a path inside the repository"
    end
    if type(value.summary) ~= "string" or vim.trim(value.summary) == "" then
      return nil, "needs a summary"
    end
    if #value.summary > M.MAX_LENGTH then
      return nil, ("summary longer than %d characters"):format(M.MAX_LENGTH)
    end
    local path = root .. "/" .. value.file
    local content = storage.read_file(path)
    if not content then
      return nil, "no such file: " .. value.file
    end
    local hash = vim.fn.sha256(content) ---@type string?
    -- Read later than it was written: if the file changed in between, the
    -- Summary may describe code that is gone.
    if source and mtime(vim.uv.fs_stat(path)) > mtime(vim.uv.fs_stat(source)) then
      hash = nil
    end
    return { file = value.file, body = vim.trim(value.summary), hash = hash }
  end
end

--- Reads every Summary file into the Session; a newer Summary of a file
--- replaces the older one. Saves once when anything changed.
---@param session iz.Session
---@return iz.SummaryResult
function M.ingest(session)
  local result = { summaries = 0, failed = {}, waiting = {} }
  local dir = M.dir(session.root)
  if not vim.uv.fs_stat(dir) then
    return result
  end
  local done, waiting = inbox.drain(dir, checker(session.root))
  result.waiting = waiting
  local ts = util.now()
  for _, file in ipairs(done) do
    for _, e in ipairs(file.entries) do
      session.data.summaries[e.file] = { body = e.body, hash = e.hash, ts = ts }
      result.summaries = result.summaries + 1
    end
    if #file.errors > 0 then
      table.insert(result.failed, file.name .. " (" .. table.concat(file.errors, "; ") .. ")")
    end
  end
  if result.summaries > 0 then
    session_mod.save(session)
  end
  return result
end

---@param result iz.SummaryResult
---@return string? message nil when there is nothing to say
function M.summary(result)
  local parts = {}
  if result.summaries > 0 then
    parts[#parts + 1] = "agent summarised " .. util.plural(result.summaries, "file")
  end
  if #result.failed > 0 then
    parts[#parts + 1] = "moved to summaries/failed: " .. table.concat(result.failed, ", ")
  end
  return #parts > 0 and table.concat(parts, "\n") or nil
end

--- The Summary of `path`, and whether the file changed since it was written.
---@param session iz.Session
---@param path string
---@return { body: string, outdated: boolean }?
function M.get(session, path)
  local s = session.data.summaries[path]
  if not s then
    return nil
  end
  local content = storage.read_file(session.root .. "/" .. path)
  local current = s.hash ~= nil and content ~= nil and vim.fn.sha256(content) == s.hash
  return { body = s.body, outdated = not current }
end

return M
