-- Side-by-side diff on Neovim's built-in diff mode: left is a read-only scratch
-- buffer with the Base (or index) content, right is the real file.
local git = require("iz.git")
local hl = require("iz.ui.highlights")

local api = vim.api
local M = {}

---@param name string
---@return integer? buf the buffer with exactly this name (`bufnr()` would also match partially)
local function find_named(name)
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_get_name(buf) == name then
      return buf
    end
  end
end

--- Shows a read-only scratch buffer in `win`. The new buffer goes into the
--- window before an old one with the same name is removed: wiping a buffer
--- that a window still shows would close that window.
---@param win integer
---@param name string
---@param lines string[]
---@param path string used for filetype detection
local function place_scratch(win, name, lines, path)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  api.nvim_win_set_buf(win, buf)
  local old = find_named(name)
  if old and old ~= buf then
    api.nvim_buf_delete(old, { force = true })
  end
  api.nvim_buf_set_name(buf, name)
  local ft = vim.filetype.match({ filename = path, buf = buf })
  if ft then
    vim.bo[buf].filetype = ft
  end
  return buf
end

---@param content string?
local function to_lines(content)
  if not content or content == "" then
    return {}
  end
  local lines = vim.split(content, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

---@param win integer
local function diffoff(win)
  if api.nvim_win_is_valid(win) then
    api.nvim_win_call(win, function()
      vim.cmd("diffoff")
    end)
  end
end

--- Async: reads the left side from git.
---@param ctx iz.DiffContext
function M.open(ctx)
  local file, root = ctx.file, ctx.root
  local rev = ctx.left_rev == "index" and ":0" or ctx.session.data.base
  diffoff(ctx.left_win)
  diffoff(ctx.right_win)

  local id = ctx.session.id
  local left_name = ("iz://%s/%s/%s"):format(id, ctx.left_rev, file.path)
  if file.binary then
    local msg = { "(binary file: no text diff)" }
    place_scratch(ctx.left_win, left_name, msg, file.path)
    local right_name = ("iz://%s/binary/%s"):format(id, file.path)
    place_scratch(ctx.right_win, right_name, msg, "")
    return
  end

  local left = to_lines(git.show(root, rev, file.path))
  place_scratch(ctx.left_win, left_name, left, file.path)

  if file.kind == "D" then
    place_scratch(ctx.right_win, ("iz://%s/deleted/%s"):format(id, file.path), {}, file.path)
  else
    local right = vim.fn.bufadd(root .. "/" .. file.path)
    vim.fn.bufload(right)
    vim.bo[right].buflisted = true
    api.nvim_win_set_buf(ctx.right_win, right)
  end

  for _, win in ipairs({ ctx.left_win, ctx.right_win }) do
    api.nvim_win_call(win, function()
      vim.cmd("diffthis")
    end)
  end
  M.mark(ctx)
end

---@param buf integer
---@param first integer 1-based
---@param count integer
---@param opts table
local function mark_range(buf, first, count, opts)
  if count == 0 then
    return
  end
  api.nvim_buf_set_extmark(buf, hl.ns, first - 1, 0, vim.tbl_extend("force", {
    end_row = first - 1 + count,
    strict = false,
  }, opts))
end

---@param ctx iz.DiffContext
function M.mark(ctx)
  local left = api.nvim_win_get_buf(ctx.left_win)
  local right = api.nvim_win_get_buf(ctx.right_win)
  api.nvim_buf_clear_namespace(left, hl.ns, 0, -1)
  api.nvim_buf_clear_namespace(right, hl.ns, 0, -1)
  if ctx.file.binary then
    return
  end

  local badge = { { " staged", "IzStagedMark" } }
  for _, h in ipairs(ctx.file.hunks) do
    if h.state == "staged" then
      mark_range(right, h.new_start, h.new_count, { hl_group = "IzStaged", priority = 200 })
      -- Against the index a staged hunk shows no difference, so only mark it against Base.
      if ctx.left_rev == "base" then
        mark_range(left, h.old_start, h.old_count, { hl_group = "IzStaged", priority = 200 })
      end
      local buf, line = right, h.new_start
      if h.new_count == 0 then
        buf, line = left, h.old_start
      end
      pcall(api.nvim_buf_set_extmark, buf, hl.ns, math.max(line, 1) - 1, 0, {
        sign_text = "✓",
        sign_hl_group = "IzStagedMark",
        virt_text = badge,
        virt_text_pos = "eol",
      })
    else
      for _, r in ipairs(h.new_vs_index) do
        mark_range(right, r[1], r[2] - r[1] + 1, {
          sign_text = "●",
          sign_hl_group = "IzNewSinceApproval",
        })
      end
    end
  end
end

---@param h iz.Hunk
---@param side "old"|"new"
local function span(h, side)
  local start, count = h[side .. "_start"], h[side .. "_count"]
  if count == 0 then
    -- A pure deletion or insertion sits between `start` and `start + 1`.
    return math.max(start, 1), start + 1
  end
  return start, start + count - 1
end

---@param ctx iz.DiffContext
---@param win integer
local function side_of(ctx, win)
  return win == ctx.left_win and "old" or "new"
end

---@param ctx iz.DiffContext
---@param win integer
---@param first integer
---@param last integer
---@return iz.Hunk[]
function M.hunks_at(ctx, win, first, last)
  local side = side_of(ctx, win)
  if side == "old" and ctx.left_rev == "index" then
    -- Index line numbers do not match Base hunks; use the right side position instead.
    return {}
  end
  return vim.tbl_filter(function(h)
    local a, b = span(h, side)
    return a <= last and first <= b
  end, ctx.file.hunks)
end

---@param ctx iz.DiffContext
---@param win integer
---@return integer[]
function M.targets(ctx, win)
  local side = side_of(ctx, win)
  return vim.tbl_map(function(h)
    return (span(h, side))
  end, ctx.file.hunks)
end

---@param ctx iz.DiffContext
function M.close(ctx)
  diffoff(ctx.left_win)
  diffoff(ctx.right_win)
  for _, win in ipairs({ ctx.left_win, ctx.right_win }) do
    if api.nvim_win_is_valid(win) then
      api.nvim_buf_clear_namespace(api.nvim_win_get_buf(win), hl.ns, 0, -1)
    end
  end
end

return M
