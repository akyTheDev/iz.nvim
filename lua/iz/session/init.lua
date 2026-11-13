local git = require("iz.git")
local storage = require("iz.storage")
local trees = require("iz.git.trees")
local util = require("iz.util")

local M = {}

-- 2: messages can come from the Co-reviewer (`author = "coreviewer"`), a user
-- message with an empty body means "sent as it is", and `summaries` holds the
-- agent's per-file Summaries.
M.SCHEMA_VERSION = 2

---@class iz.SessionData
---@field schema_version integer
---@field id string
---@field created_at string
---@field completed_at? string
---@field state "active"|"completed"
---@field base string Commit wrapping the index snapshot.
---@field comments table[]
---@field trash table[] Discard stack, newest last.
---@field brief? { id: string, hash: string } The Brief last written to `.iz/brief.md`.
---@field summaries table<string, iz.Summary> By repository-relative path.

---@class iz.Session
---@field root string
---@field id string
---@field data iz.SessionData

---@param root string
local function current_path(root)
  return storage.dir(root) .. "/current"
end

--- Reserves a new session id by creating its directory; mkdir fails when the
--- directory exists, so two Neovims can't end up with the same id.
---@param root string
local function new_id(root)
  storage.mkdirp(storage.dir(root) .. "/sessions")
  local base = os.date("%Y-%m-%d-%H%M%S") --[[@as string]]
  local id, n = base, 1
  while not vim.uv.fs_mkdir(storage.session_dir(root, id), 493) do
    n = n + 1
    id = base .. "-" .. n
  end
  return id
end

---@param root string
---@param id string
---@return iz.Session?
function M.load(root, id)
  local data = storage.read_json(storage.session_dir(root, id) .. "/session.json")
  if not data then
    return nil
  end
  -- Version 1 is a subset of version 2; it is written back as 2 on the next save.
  if data.schema_version == 1 then
    data.schema_version = M.SCHEMA_VERSION
  end
  if data.schema_version ~= M.SCHEMA_VERSION then
    error(("session %s has schema version %s; this iz understands %d"):format(
      id,
      tostring(data.schema_version),
      M.SCHEMA_VERSION
    ), 0)
  end
  -- JSON turns empty tables into arrays; restore the shapes the code expects.
  data.comments = data.comments or {}
  data.trash = data.trash or {}
  data.summaries = data.summaries or {}
  return { root = root, id = id, data = data }
end

---@param root string
---@return iz.Session?
function M.current(root)
  local id = storage.read_file(current_path(root))
  id = id and vim.trim(id)
  if not id or id == "" then
    return nil
  end
  return M.load(root, id)
end

---@param session iz.Session
function M.save(session)
  storage.write_json(storage.session_dir(session.root, session.id) .. "/session.json", session.data)
end

--- Async: call inside `async.run`.
---@param root string
---@return iz.Session
function M.create(root)
  storage.ensure(root)
  local id = new_id(root)
  local base = trees.create_base(root, id)
  storage.mkdirp(storage.session_dir(root, id))
  local session = {
    root = root,
    id = id,
    data = {
      schema_version = M.SCHEMA_VERSION,
      id = id,
      created_at = util.now(),
      state = "active",
      base = base,
      comments = {},
      trash = {},
      summaries = {},
    },
  }
  M.save(session)
  storage.write_atomic(current_path(root), id .. "\n")
  return session
end

--- Returns the active Session, creating one when there is none. Async.
---@param root string
---@return iz.Session
function M.open(root)
  local current = M.current(root)
  if current and current.data.state == "active" then
    return current
  end
  return M.create(root)
end

---@param session iz.Session
function M.complete(session)
  session.data.state = "completed"
  session.data.completed_at = util.now()
  M.save(session)
  os.remove(current_path(session.root))
end

--- Resolves the repository root for `cwd`. Async.
---@param cwd? string
---@return string? root
function M.root(cwd)
  return git.toplevel(cwd or vim.fn.getcwd())
end

return M
