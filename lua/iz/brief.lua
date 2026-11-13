-- The Brief: the only input the agent gets from iz. Every token counts, so it
-- carries only Comments waiting for the agent, grouped by file, one line each.
local comments = require("iz.session.comments")
local session_mod = require("iz.session")
local storage = require("iz.storage")
local util = require("iz.util")

local M = {}

M.FILE = "brief.md"
M.EMPTY = "No pending comments."

---@param root string
function M.path(root)
  return storage.dir(root) .. "/" .. M.FILE
end

--- Continuation lines of a multi-line body are indented under their first line.
---@param text string
---@param prefix string
local function indent(text, prefix)
  return (text:gsub("\n", "\n" .. prefix))
end

---@param c iz.Comment
local function location(c)
  if c.scope == "session" then
    return nil
  elseif c.scope == "file" or not c.line then
    return "file"
  end
  local loc = "L" .. c.line
  if c.end_line and c.end_line ~= c.line then
    loc = loc .. "-" .. c.end_line
  end
  if c.side == "old" then
    loc = loc .. " (deleted lines, as in the base)"
  elseif c.anchor and c.anchor.state == "lost" then
    loc = loc .. " (code moved or changed; last seen here)"
  end
  return loc
end

---@param c iz.Comment
---@return string[]
local function entry(c)
  local loc = location(c)
  local head = c.id .. (loc and (" " .. loc) or "") .. ": "
  local out = { head .. indent(c.thread[1].body, "  ") }
  -- Snippets cost tokens; send them only when the line number alone can't find the code.
  local needs_snippet = c.anchor and (c.side == "old" or c.anchor.state == "lost")
  if needs_snippet and c.anchor.snippet ~= "" then
    for _, line in ipairs(vim.split(c.anchor.snippet, "\n", { plain = true })) do
      out[#out + 1] = "  > " .. line
    end
  end
  if #c.thread > 1 then
    local last_agent
    for i = #c.thread, 2, -1 do
      if c.thread[i].author == "agent" then
        last_agent = c.thread[i]
        break
      end
    end
    if last_agent then
      out[#out + 1] = "  agent: " .. indent(last_agent.body, "    ")
    end
    -- The latest reviewer message, when it is not the root itself. An empty
    -- one only sent a Suggestion on as it is: nothing to add.
    local last = comments.last(c)
    if last.body ~= "" then
      out[#out + 1] = "  reviewer: " .. indent(last.body, "    ")
    end
  end
  for _, path in ipairs(c.attachments or {}) do
    out[#out + 1] = "  image: " .. path
  end
  return out
end

---@param session iz.Session
---@return string? body everything except the header line, nil when nothing is pending
---@return integer count
local function render_body(session)
  local pending = vim.tbl_filter(comments.awaiting_agent, session.data.comments)
  if #pending == 0 then
    return nil, 0
  end
  local by_file, files, session_level = {}, {}, {}
  for _, c in ipairs(pending) do
    if c.scope == "session" then
      table.insert(session_level, c)
    else
      if not by_file[c.file] then
        by_file[c.file] = {}
        table.insert(files, c.file)
      end
      table.insert(by_file[c.file], c)
    end
  end
  table.sort(files)

  local lines = {}
  local function section(title, list)
    table.sort(list, function(a, b)
      return (a.line or 0) < (b.line or 0)
    end)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## " .. title
    for _, c in ipairs(list) do
      vim.list_extend(lines, entry(c))
    end
  end
  if #session_level > 0 then
    section("Session", session_level)
  end
  for _, file in ipairs(files) do
    section(file, by_file[file])
  end
  return table.concat(lines, "\n"), #pending
end

---@param id string
---@param count integer
---@param text string
local function assemble(id, count, text)
  return table.concat({
    ("# iz brief %s · %s"):format(id, util.plural(count, "comment")),
    text,
    "",
    ("When done, write your replies to %s/inbox/%s.jsonl in a single Write,"):format(
      storage.DIR,
      id
    ),
    "one JSON line per comment: "
      .. '{"id": "c_…", "claim": "addressed" | "declined" | "question", "note": "…"}',
  }, "\n") .. "\n"
end

local function new_id()
  return "b_" .. util.random_hex(2)
end

--- Renders the Brief; keeps the previous id while the content is unchanged.
---@param session iz.Session
---@return string content
---@return { id: string, hash: string }? meta nil when nothing is pending
function M.render(session)
  local text, count = render_body(session)
  if not text then
    return M.EMPTY .. "\n", nil
  end
  local hash = vim.fn.sha256(text)
  local prev = session.data.brief
  local id = (prev and prev.hash == hash) and prev.id or new_id()
  return assemble(id, count, text), { id = id, hash = hash }
end

--- Writes `.iz/brief.md` when its content changed. Returns the Brief id.
---@param session iz.Session
---@return string? id
function M.update(session)
  local content, meta = M.render(session)
  if not vim.deep_equal(meta, session.data.brief) then
    session.data.brief = meta
    session_mod.save(session)
  end
  local path = M.path(session.root)
  if storage.read_file(path) ~= content then
    storage.mkdirp(storage.dir(session.root))
    storage.write_atomic(path, content)
  end
  return meta and meta.id
end

return M
