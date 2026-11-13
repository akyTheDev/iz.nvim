-- Turns the agent's inbox files into Replies. The agent only ever creates new
-- files here; Neovim reads them, moves their content into session.json and
-- deletes them, so each file has exactly one writer.
local comments = require("iz.session.comments")
local session_mod = require("iz.session")
local storage = require("iz.storage")
local util = require("iz.util")

local M = {}

---@class iz.IngestResult
---@field replies integer
---@field questions integer
---@field unknown string[] Comment ids the agent answered that do not exist.
---@field failed string[] Files moved to inbox/failed/ because of invalid lines.
---@field waiting string[] Files whose last line is still being written.

-- A file this old with a broken last line is not being written any more.
M.STALE_AFTER = 10

--- Decodes a JSONL file an agent wrote; `check` turns each object into an
--- entry or says what is wrong with it.
---@param content string
---@param final? boolean treat an unfinished last line as an error instead of waiting
---@param check fun(value: table, source?: string): any?, string?
---@param source? string path of the file being decoded, passed on to `check`
---@return any[]? entries, string[] errors; entries nil when the file is still being written
function M.decode(content, final, check, source)
  local lines = vim.split(content, "\n", { plain = true })
  local complete = final or content:sub(-1) == "\n"
  if content:sub(-1) == "\n" then
    table.remove(lines)
  end
  local entries, errors = {}, {}
  for i, line in ipairs(lines) do
    if vim.trim(line) ~= "" then
      local ok, value = pcall(vim.json.decode, line)
      if not ok or type(value) ~= "table" then
        -- A broken last line without a newline may simply be unfinished.
        if i == #lines and not complete then
          return nil, {}
        end
        errors[#errors + 1] = ("line %d: not valid JSON"):format(i)
      else
        local entry, err = check(value, source)
        if entry then
          entries[#entries + 1] = entry
        else
          errors[#errors + 1] = ("line %d: %s"):format(i, err)
        end
      end
    end
  end
  return entries, errors
end

---@param value table
local function reply(value)
  if type(value.id) ~= "string" or not comments.CLAIMS[value.claim] then
    return nil, "needs an id and a claim of addressed, declined or question"
  end
  return {
    id = value.id,
    claim = value.claim,
    note = type(value.note) == "string" and value.note or "",
  }
end

---@param content string
---@param final? boolean treat an unfinished last line as an error instead of waiting
---@return table[]? entries, string[] errors; entries nil when the file is still being written
function M.parse(content, final)
  return M.decode(content, final, reply)
end

---@class iz.DrainedFile
---@field name string
---@field entries any[]
---@field errors string[]

--- Reads every `*.jsonl` file in `dir`, oldest name first. Files still being
--- written are left for later; the rest are deleted, or moved to `failed/`
--- when a line was invalid. The valid lines of a failed file still count.
---@param dir string
---@param check fun(value: table, source?: string): any?, string? `source` is the file's path
---@return iz.DrainedFile[] done, string[] waiting
function M.drain(dir, check)
  local names = {}
  for name, kind in vim.fs.dir(dir) do
    if kind == "file" and name:match("%.jsonl$") then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  local done, waiting = {}, {}
  for _, name in ipairs(names) do
    local path = dir .. "/" .. name
    local stat = vim.uv.fs_stat(path)
    local stale = stat and os.time() - stat.mtime.sec > M.STALE_AFTER
    local entries, errors = M.decode(storage.read_file(path) or "", stale, check, path)
    if not entries then
      waiting[#waiting + 1] = name
    else
      if #errors > 0 then
        storage.mkdirp(dir .. "/failed")
        vim.uv.fs_rename(path, dir .. "/failed/" .. name)
      else
        os.remove(path)
      end
      done[#done + 1] = { name = name, entries = entries, errors = errors }
    end
  end
  return done, waiting
end

--- Reads every inbox file into the Session. Saves once when anything changed.
---@param session iz.Session
---@return iz.IngestResult
function M.ingest(session)
  local done, waiting = M.drain(storage.inbox_dir(session.root), reply)
  local result = { replies = 0, questions = 0, unknown = {}, failed = {}, waiting = waiting }
  local ts = util.now()
  for _, file in ipairs(done) do
    for _, e in ipairs(file.entries) do
      local c = comments.find(session, e.id)
      if c then
        comments.agent_reply(session, c, e.claim, e.note, ts)
        result.replies = result.replies + 1
        if e.claim == "question" then
          result.questions = result.questions + 1
        end
      else
        table.insert(result.unknown, e.id)
      end
    end
    if #file.errors > 0 then
      table.insert(result.failed, file.name .. " (" .. table.concat(file.errors, "; ") .. ")")
    end
  end
  if result.replies > 0 then
    session_mod.save(session)
  end
  return result
end

---@param result iz.IngestResult
---@return string? message nil when there is nothing to say
function M.summary(result)
  local parts = {}
  if result.replies > 0 then
    local msg = "agent replied to " .. util.plural(result.replies, "comment")
    if result.questions > 0 then
      msg = msg .. " · " .. util.plural(result.questions, "question")
    end
    parts[#parts + 1] = msg
  end
  if #result.unknown > 0 then
    parts[#parts + 1] = "unknown comment ids: " .. table.concat(result.unknown, ", ")
  end
  if #result.failed > 0 then
    parts[#parts + 1] = "moved to inbox/failed: " .. table.concat(result.failed, ", ")
  end
  return #parts > 0 and table.concat(parts, "\n") or nil
end

return M
