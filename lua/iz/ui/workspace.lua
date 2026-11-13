-- The review workspace: a tab with the file list, the two diff windows and the
-- comment panel. One workspace per Neovim instance.
local anchor = require("iz.session.anchor")
local async = require("iz.async")
local backend = require("iz.diff.backend")
local brief = require("iz.brief")
local comments = require("iz.session.comments")
local config = require("iz.config")
local coreview = require("iz.coreview")
local editor = require("iz.ui.editor")
local files_ui = require("iz.ui.files")
local format = require("iz.ui.format")
local git = require("iz.git")
local help = require("iz.ui.help")
local hl = require("iz.ui.highlights")
local hunks = require("iz.git.hunks")
local inbox = require("iz.inbox")
local inline = require("iz.ui.inline")
local lock = require("iz.storage.lock")
local ops = require("iz.git.ops")
local panel = require("iz.ui.panel")
local session_mod = require("iz.session")
local storage = require("iz.storage")
local summary_mod = require("iz.summary")
local thread = require("iz.ui.thread")
local util = require("iz.util")

local api = vim.api
local M = {}

---@class iz.Workspace
---@field root string
---@field session iz.Session
---@field view iz.View
---@field readonly boolean
---@field tab integer
---@field wins { files: integer, left: integer, right: integer }
---@field files_buf integer
---@field line_paths table<integer, string>
---@field path? string File shown in the diff.
---@field filter boolean Show only Unstaged hunks.
---@field panel { buf: integer, win?: integer, ids: table<integer, string>, manual?: boolean }
---@field summary { buf: integer, win?: integer } The strip above the diff.
---@field mapped table<integer, boolean> Buffers that carry our diff keymaps.
---@field bufs { left?: integer, right?: integer } What `show()` put in the diff windows.
---@field showing boolean `show()` is placing buffers; the diff windows are in flux.
---@field reading? integer The tab where code opened from the diff windows goes.
---@field reading_hint? boolean The reading tab was explained once.
---@field watchers uv.uv_fs_event_t[]
---@field augroup integer
---@field suggested? boolean The "looks done" hint was shown for the current state.

-- nil while the workspace is closed; every entry point checks `M.get()` or
-- runs from a key that only exists while it is open.
---@type iz.Workspace
local W

local pending = 0

---@param msg string
---@param level? integer
local function notify(msg, level)
  vim.notify("iz: " .. msg, level or vim.log.levels.INFO)
end

--- Runs an async job tracked by `M.idle()`; errors are shown, not thrown.
---@param fn fun()
local function job(fn)
  pending = pending + 1
  async.run(fn, function(err)
    pending = pending - 1
    if err then
      vim.schedule(function()
        -- Drop the traceback for errors raised on purpose.
        notify(tostring(err):match("^([^\n]*)"), vim.log.levels.ERROR)
      end)
    end
  end)
end

--- True when no workspace job is running; tests wait on this.
function M.idle()
  return pending == 0
end

---@return iz.Workspace?
function M.get()
  if W and api.nvim_tabpage_is_valid(W.tab) then
    return W
  end
  return nil
end

---@return iz.DiffContext?
local function diff_ctx()
  if not W or not W.path or not W.view.by_path[W.path] then
    return nil
  end
  return {
    root = W.root,
    session = W.session,
    file = W.view.by_path[W.path],
    left_rev = W.filter and "index" or "base",
    left_win = W.wins.left,
    right_win = W.wins.right,
  }
end

local function writable()
  if W.readonly then
    notify("read-only: another Neovim owns this session", vim.log.levels.WARN)
    return false
  end
  return true
end

local function set_winbars()
  local mode = W.filter and "index · unstaged only" or "base"
  local staged, total, open = 0, 0, 0
  for _, f in ipairs(W.view.files) do
    staged, total = staged + f.staged, total + f.staged + f.unstaged
  end
  for _, c in ipairs(W.session.data.comments) do
    open = open + (c.status == "open" and 1 or 0)
  end
  local parts = { "iz", ("%d/%d staged"):format(staged, total) }
  if open > 0 then
    parts[#parts + 1] = open .. " open"
  end
  if W.readonly then
    parts[#parts + 1] = "read-only"
  end
  local hint = config.options.keymaps.files.help
  hint = (hint and hint ~= "") and ("%=" .. hint:gsub("%%", "%%%%") .. " keys ") or ""
  vim.wo[W.wins.files].winbar = " " .. table.concat(parts, " · ") .. hint
  vim.wo[W.wins.left].winbar = " " .. mode
  vim.wo[W.wins.right].winbar = " " .. (W.path or "") .. " · working tree"
end

local function draw_files()
  set_winbars()
  W.line_paths = files_ui.draw(W.files_buf, W.view.files, {
    filter = W.filter,
    width = config.options.files_width,
    extra = function(file)
      local n = comments.open_count(W.session, file.path)
      return n > 0 and ("  %d open"):format(n) or nil
    end,
  })
end

local fit_summary

--- The two diff sides share their width evenly.
local function equalize()
  local left, right = W.wins.left, W.wins.right
  if api.nvim_win_is_valid(left) and api.nvim_win_is_valid(right) then
    local total = api.nvim_win_get_width(left) + api.nvim_win_get_width(right)
    api.nvim_win_set_width(left, math.floor(total / 2))
  end
end

local function sync_panel()
  local want = W.panel.manual
  if want == nil then
    want = #W.session.data.comments > 0
  end
  local open = W.panel.win ~= nil and api.nvim_win_is_valid(W.panel.win)
  if want and not open then
    -- Full height at the far right, beside the Summary strip as well.
    W.panel.win = api.nvim_open_win(W.panel.buf, false, {
      split = "right",
      win = -1,
      width = config.options.panel_width,
    })
    vim.wo[W.panel.win].number = false
    vim.wo[W.panel.win].relativenumber = false
    vim.wo[W.panel.win].signcolumn = "no"
    vim.wo[W.panel.win].winfixwidth = true
    vim.wo[W.panel.win].cursorline = true
    -- Messages wrap under their text, past the "    agent  " label.
    vim.wo[W.panel.win].wrap = true
    vim.wo[W.panel.win].linebreak = true
    vim.wo[W.panel.win].breakindent = true
    vim.wo[W.panel.win].breakindentopt = "shift:7"
    vim.wo[W.panel.win].winbar = " comments"
  elseif not want and open then
    api.nvim_win_close(W.panel.win, true)
    W.panel.win = nil
  end
  if want ~= open then
    equalize()
    fit_summary()
  end
  if want then
    W.panel.ids = panel.draw(W.panel.buf, W.session)
  end
end

local function draw_comments()
  local ctx = diff_ctx()
  if ctx then
    inline.draw(ctx)
  end
  draw_files()
  sync_panel()
  if not W.readonly then
    brief.update(W.session)
  end
end

--- Moves agent replies from `.iz/inbox/` and Co-reviewer Suggestions from
--- `.iz/coreview/` into the Session.
---@param quiet? boolean leave reporting the replies to the caller
---@return iz.IngestResult?
local function ingest(quiet)
  if W.readonly then
    return nil
  end
  for _, source in ipairs({ coreview, summary_mod }) do
    local res = source.ingest(W.session)
    local msg = source.summary(res)
    if msg then
      notify(msg, #res.failed > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
    end
  end
  local result = inbox.ingest(W.session)
  local msg = inbox.summary(result)
  if msg and not quiet then
    local problem = #result.failed > 0 or #result.unknown > 0
    notify(msg, problem and vim.log.levels.WARN or vim.log.levels.INFO)
  end
  return result
end

---@return string? first path with something to review, else the first path
local function first_path()
  local files = files_ui.sort(W.view.files)
  for _, f in ipairs(files) do
    if f.unstaged > 0 then
      return f.path
    end
  end
  return files[1] and files[1].path
end

--- Whether `path` is in the file list as currently filtered.
---@param path? string
local function visible(path)
  local file = path and W.view.by_path[path]
  return file ~= nil and not (W.filter and file.unstaged == 0)
end

local map_diff_keys
local suggest_done

--- Sizes the Summary strip to its wrapped text, up to `summary_height` rows.
--- Runs again whenever its width changes: the panel opening narrows it.
function fit_summary()
  local win = W.summary.win
  if not (win and api.nvim_win_is_valid(win)) then
    return
  end
  local width = math.max(api.nvim_win_get_width(win) - 2, 1) -- minus the sign column
  local rows = 0
  for _, l in ipairs(api.nvim_buf_get_lines(W.summary.buf, 0, -1, false)) do
    rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / width))
  end
  local height = math.min(rows, config.options.summary_height)
  if api.nvim_win_get_height(win) ~= height then
    api.nvim_win_set_height(win, height)
  end
end

--- Shows the agent's Summary of the file in a strip above both diff sides,
--- and removes the strip for a file without one. The strip is a window of
--- its own: virtual lines above line 1 hide inside folds and push one diff
--- side out of line with the other.
local function draw_summary()
  local max = config.options.summary_height
  local s = max > 0 and W.path and summary_mod.get(W.session, W.path) or nil
  local open = W.summary.win ~= nil and api.nvim_win_is_valid(W.summary.win)
  if not s then
    if open then
      api.nvim_win_close(W.summary.win, true)
      W.summary.win = nil
      equalize()
    end
    return
  end
  local buf = W.summary.buf
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(s.body, "\n"))
  vim.bo[buf].modifiable = false
  if not open then
    W.summary.win = api.nvim_open_win(buf, false, {
      split = "above",
      win = W.wins.right,
      height = 1,
    })
    -- Moving (not recreating) the left side under the strip keeps its diff state.
    vim.fn.win_splitmove(W.wins.left, W.wins.right, { vertical = true })
    local wo = vim.wo[W.summary.win]
    -- The sign column pads the text, as in the thread view.
    wo.number, wo.relativenumber, wo.signcolumn = false, false, "yes:1"
    wo.wrap, wo.linebreak, wo.cursorline = true, true, false
    wo.winfixheight = true
    equalize()
  end
  local win = W.summary.win --[[@as integer]]
  fit_summary()
  api.nvim_buf_clear_namespace(buf, hl.ns, 0, -1)
  api.nvim_buf_set_extmark(buf, hl.ns, 0, 0, {
    end_row = api.nvim_buf_line_count(buf),
    hl_group = s.outdated and "IzSummaryOutdated" or "IzSummary",
    strict = false,
  })
  local label = s.outdated and "agent says · outdated: the file changed since" or "agent says"
  local path = W.path:gsub("%%", "%%%%")
  vim.wo[win].statusline = " " .. path .. " · " .. label
end

--- Async. Shows `path` in the diff windows.
---@param path? string
local function show(path)
  W.path = path
  local ctx = diff_ctx()
  W.showing = true
  local ok, err = pcall(function()
    if ctx then
      backend.open(ctx)
      inline.draw(ctx)
      map_diff_keys(api.nvim_win_get_buf(W.wins.left))
      map_diff_keys(api.nvim_win_get_buf(W.wins.right))
    end
  end)
  W.bufs = {
    left = api.nvim_win_get_buf(W.wins.left),
    right = api.nvim_win_get_buf(W.wins.right),
  }
  W.showing = false
  if not ok then
    error(err, 0)
  end
  draw_summary()
  set_winbars()
end

--- Whether the diff windows still show what `show()` put there; `gd` or
--- `:edit` in them may have replaced it.
local function intact()
  return W.bufs.left == api.nvim_win_get_buf(W.wins.left)
    and W.bufs.right == api.nvim_win_get_buf(W.wins.right)
end

--- Moves a buffer that was opened in a diff window (`gd`, `:edit`, a picker)
--- to the reading tab, cursor and all, and puts the diff back. Reviewing and
--- reading code don't fight over the same window.
---@param win integer a diff window
---@param expected integer the buffer `show()` put there
local function to_reading_tab(win, expected)
  local foreign = api.nvim_win_get_buf(win)
  local cursor = api.nvim_win_get_cursor(win)
  -- Back first: the diff window is whole again whatever happens next.
  api.nvim_win_set_buf(win, expected)
  local tab = W.reading
  if tab and api.nvim_tabpage_is_valid(tab) then
    api.nvim_set_current_tabpage(tab)
  else
    vim.cmd("tabnew")
    W.reading = api.nvim_get_current_tabpage()
  end
  local target = api.nvim_get_current_win()
  local scratch = api.nvim_win_get_buf(target)
  api.nvim_win_set_buf(target, foreign)
  pcall(api.nvim_win_set_cursor, target, cursor)
  api.nvim_win_call(target, function()
    vim.cmd("normal! zv")
  end)
  local unnamed = api.nvim_buf_get_name(scratch) == "" and not vim.bo[scratch].modified
  if scratch ~= foreign and unnamed and #vim.fn.win_findbuf(scratch) == 0 then
    pcall(api.nvim_buf_delete, scratch, {})
  end
  if not W.reading_hint then
    W.reading_hint = true
    notify("opened in the reading tab; gT or :Iz goes back to the review")
  end
end

--- Runs after something put a buffer in a window. Scheduled: a jump such as
--- `gd` places the buffer first and moves the cursor after.
local function guard_diff_windows()
  vim.schedule(function()
    if not M.get() or W.showing then
      return
    end
    for _, side in ipairs({ "left", "right" }) do
      local win, expected = W.wins[side], W.bufs[side]
      if
        api.nvim_win_is_valid(win)
        and expected
        and api.nvim_buf_is_valid(expected)
        and api.nvim_win_get_buf(win) ~= expected
      then
        to_reading_tab(win, expected)
        return
      end
    end
  end)
end

--- Says once when nothing is left to look at; says it again only after the
--- state stopped and then started looking done.
function suggest_done()
  local unstaged = 0
  for _, f in ipairs(W.view.files) do
    unstaged = unstaged + f.unstaged
  end
  local waiting = vim.iter(W.session.data.comments):any(function(c)
    return comments.awaiting_user(c) or comments.suggested(c)
  end)
  local looks_done = #W.view.files > 0 and unstaged == 0 and not waiting
  if looks_done and not W.suggested then
    notify("session looks done: everything is staged and nothing waits for you. Run :IzDone")
  end
  W.suggested = looks_done
end

local busy = false

--- Async. Runs `fn` alone: jobs that await and then replace shared state (the
--- view, the file shown) would otherwise finish out of order and leave the
--- screen and `W` disagreeing. Not re-entrant: `fn` must not call it again.
---@param fn fun()
local function exclusive(fn)
  while busy do
    async.await(function(resume)
      vim.defer_fn(resume, 10)
    end)
  end
  busy = true
  local ok, err = pcall(fn)
  busy = false
  if not ok then
    error(err, 0)
  end
end

local function refresh_inner()
  if not M.get() then
    return
  end
  if W.readonly then
    -- Another Neovim writes the session; show what it saved.
    W.session = session_mod.current(W.root) or W.session
  end
  -- The agent edits files behind Neovim's back; pick that up before diffing.
  local right = api.nvim_win_get_buf(W.wins.right)
  if vim.bo[right].buftype == "" then
    pcall(vim.cmd.checktime, right)
  end
  ingest()
  if anchor.relocate_all(W.session) and not W.readonly then
    session_mod.save(W.session)
  end
  W.view = hunks.compute(W.session)
  local keep = W.path
  if not visible(keep) then
    keep = first_path()
  end
  local ctx = diff_ctx()
  -- With something else in a diff window, redraw rather than mark that buffer.
  if keep == W.path and ctx and not W.filter and intact() then
    backend.mark(ctx)
    for _, win in ipairs({ W.wins.left, W.wins.right }) do
      api.nvim_win_call(win, function()
        vim.cmd("diffupdate")
      end)
    end
    set_winbars()
  else
    -- Against the index the left side changes with every stage; reload it.
    show(keep)
  end
  draw_summary()
  draw_comments()
  suggest_done()
end

--- Async. Re-anchors comments, recomputes the view and redraws everything.
local function refresh()
  exclusive(refresh_inner)
end

local refresh_timer
--- Coalesces bursts of events (saves, index writes) into one refresh.
function M.schedule_refresh()
  if not M.get() then
    return
  end
  refresh_timer = refresh_timer or assert(vim.uv.new_timer())
  refresh_timer:stop()
  refresh_timer:start(150, 0, function()
    vim.schedule(function()
      job(refresh)
    end)
  end)
end

function M.refresh()
  job(refresh)
end

--- The agent finished a turn: pull in its replies and changes, then report once.
function M.on_stop()
  job(function()
    local result = ingest(true)
    refresh()
    local unstaged = 0
    for _, f in ipairs(W.view.files) do
      unstaged = unstaged + f.unstaged
    end
    local parts = { "agent finished", util.plural(unstaged, "unstaged hunk") }
    if result and result.replies > 0 then
      parts[#parts + 1] = util.plural(result.replies, "reply", "replies")
    end
    notify(table.concat(parts, " · "))
    local extra = result and (#result.unknown > 0 or #result.failed > 0) and inbox.summary(result)
    if extra then
      notify(extra, vim.log.levels.WARN)
    end
  end)
end

---@param bufnr integer
local function reload(bufnr)
  local real = api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].buftype == ""
  if real and not vim.bo[bufnr].modified then
    api.nvim_buf_call(bufnr, function()
      vim.cmd("silent! edit")
    end)
  end
end

--- The diff window the cursor is in, or the right one.
local function diff_win()
  local win = api.nvim_get_current_win()
  if win ~= W.wins.left and win ~= W.wins.right then
    win = W.wins.right
  end
  return win
end

--- Line range under the cursor or the visual selection; leaves visual mode.
---@param win integer
---@return integer first, integer last
local function cursor_range(win)
  local first, last = vim.fn.line("v", win), vim.fn.line(".", win)
  if vim.fn.mode():find("^[vV\22]") == nil then
    first = last
  else
    api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  end
  if first > last then
    first, last = last, first
  end
  return first, last
end

---@return iz.Hunk[]
local function hunks_under_cursor()
  local ctx = diff_ctx()
  if not ctx then
    return {}
  end
  local win = diff_win()
  local found = backend.hunks_at(ctx, win, cursor_range(win))
  if #found == 0 and win == W.wins.left then
    -- Against the index, positions map through the right window.
    local cursor = vim.fn.line(".", W.wins.right)
    found = backend.hunks_at(ctx, W.wins.right, cursor, cursor)
  end
  return found
end

---@param fn fun(session: iz.Session, path: string, hunk: iz.Hunk)
local function hunk_action(fn)
  return function()
    if not writable() then
      return
    end
    local targets, path = hunks_under_cursor(), W.path --[[@as string]]
    if #targets == 0 then
      notify("no hunk under the cursor", vim.log.levels.WARN)
      return
    end
    local right = api.nvim_win_get_buf(W.wins.right)
    if vim.bo[right].modified then
      notify("save the file first", vim.log.levels.WARN)
      return
    end
    job(function()
      -- Bottom-up keeps earlier hunk positions valid while later ones change.
      for i = #targets, 1, -1 do
        fn(W.session, path, targets[i])
      end
      reload(right)
      refresh()
    end)
  end
end

local function path_under_cursor()
  if api.nvim_get_current_win() == W.wins.files then
    return W.line_paths[vim.fn.line(".")]
  end
  return W.path
end

---@param fn fun(session: iz.Session, path: string)
local function file_action(fn)
  return function()
    local path = path_under_cursor()
    if not path or not writable() then
      return
    end
    -- Git works on the file on disk; unsaved edits would be lost or come back.
    local buf = vim.fn.bufnr(W.root .. "/" .. path)
    if buf ~= -1 and vim.bo[buf].modified then
      notify("save " .. path .. " first", vim.log.levels.WARN)
      return
    end
    job(function()
      fn(W.session, path)
      reload(vim.fn.bufnr(W.root .. "/" .. path))
      refresh()
    end)
  end
end

M.actions = {}

M.actions.stage = hunk_action(ops.stage_hunk)
M.actions.unstage = hunk_action(ops.unstage_hunk)
M.actions.discard = hunk_action(ops.discard_hunk)
M.actions.stage_file = file_action(ops.stage_file)
M.actions.unstage_file = file_action(ops.unstage_file)
M.actions.discard_file = file_action(ops.discard_file)

function M.actions.undo_discard()
  if not writable() then
    return
  end
  job(function()
    local entry = ops.undo_discard(W.session)
    if not entry then
      notify("nothing to undo")
      return
    end
    reload(vim.fn.bufnr(W.root .. "/" .. entry.path))
    refresh()
  end)
end

function M.actions.toggle_filter()
  W.filter = not W.filter
  notify(W.filter and "showing unstaged changes only" or "showing every change since the Base")
  job(function()
    exclusive(function()
      draw_files()
      show(visible(W.path) and W.path or first_path())
    end)
  end)
end

--- Puts the right diff window's cursor on the file's first or last Hunk,
--- without moving into it.
---@param first boolean
local function reveal_hunk(first)
  local ctx = diff_ctx()
  if not ctx then
    return
  end
  local targets = backend.targets(ctx, W.wins.right)
  local line = first and targets[1] or targets[#targets]
  local max = api.nvim_buf_line_count(api.nvim_win_get_buf(W.wins.right))
  api.nvim_win_set_cursor(W.wins.right, { math.min(math.max(line or 1, 1), max), 0 })
  api.nvim_win_call(W.wins.right, function()
    vim.cmd("normal! zz")
  end)
end

--- Moves the cursor into the real file, on its first or last Hunk.
---@param first boolean
local function focus_hunk(first)
  if not diff_ctx() then
    return
  end
  reveal_hunk(first)
  api.nvim_set_current_win(W.wins.right)
end

--- Back to the file list, on the file being shown.
function M.actions.focus_files()
  api.nvim_set_current_win(W.wins.files)
  for line, path in pairs(W.line_paths) do
    if path == W.path then
      api.nvim_win_set_cursor(W.wins.files, { line, 0 })
      return
    end
  end
end

function M.actions.open_under_cursor()
  local path = W.line_paths[vim.fn.line(".")]
  if path then
    job(function()
      exclusive(function()
        -- Already previewed while moving through the list, unless the diff
        -- windows show something else by now.
        if path ~= W.path or not intact() then
          show(path)
        end
        focus_hunk(true)
      end)
    end)
  end
end

local preview_timer
--- Shows the file under the cursor of the file list in the diff, on its first
--- Hunk, while the cursor stays in the list. Debounced: holding `j` shows only
--- where it stops.
local function preview_under_cursor()
  preview_timer = preview_timer or assert(vim.uv.new_timer())
  preview_timer:stop()
  preview_timer:start(80, 0, function()
    vim.schedule(function()
      if not M.get() or api.nvim_get_current_win() ~= W.wins.files then
        return
      end
      local path = W.line_paths[vim.fn.line(".", W.wins.files)]
      if not path or path == W.path then
        return
      end
      job(function()
        exclusive(function()
          if M.get() and path ~= W.path then
            show(path)
            reveal_hunk(true)
          end
        end)
      end)
    end)
  end)
end

---@param dir 1|-1
local function jump(dir)
  return function()
    local ctx = diff_ctx()
    local win = api.nvim_get_current_win()
    if not ctx or (win ~= W.wins.left and win ~= W.wins.right) then
      return
    end
    local cursor = vim.fn.line(".")
    local lines = backend.targets(ctx, win)
    if dir < 0 then
      lines = vim.fn.reverse(lines)
    end
    for _, l in ipairs(lines) do
      if (dir > 0 and l > cursor) or (dir < 0 and l < cursor) then
        api.nvim_win_set_cursor(win, { l, 0 })
        return
      end
    end
    -- Past the last hunk: continue in the next (or previous) file, in list order.
    local listed = vim.tbl_filter(function(f)
      return visible(f.path)
    end, files_ui.sort(W.view.files))
    for i, f in ipairs(listed) do
      if f.path == W.path then
        local next_file = listed[i + dir]
        if next_file then
          job(function()
            exclusive(function()
              show(next_file.path)
              focus_hunk(dir > 0)
            end)
          end)
        end
        return
      end
    end
  end
end

M.actions.next_hunk = jump(1)
M.actions.prev_hunk = jump(-1)

---@param title string
---@param on_save fun(body: string, attachments: string[])
---@param context? iz.EditorContext what the editor shows above the input
local function write(title, on_save, context)
  editor.open({
    title = title,
    session = W.session,
    context = context,
    on_save = function(body, attachments)
      on_save(body, attachments)
      draw_comments()
    end,
  })
end

--- Maps left-side lines to the working tree when they sit outside every hunk:
--- an unchanged line is the same code on both sides, so it belongs to the new side.
---@param list iz.DiffHunk[] hunks between the left side and the working tree
---@param first integer
---@param last integer
---@return integer? first, integer? last nil when the range touches changed lines
local function to_new_side(list, first, last)
  local offset = 0
  for _, h in ipairs(list) do
    if h.old_count == 0 then
      if first <= h.old_start and h.old_start < last then
        return nil
      elseif h.old_start < first then
        offset = offset + h.new_count
      end
    else
      local h_last = h.old_start + h.old_count - 1
      if h.old_start <= last and first <= h_last then
        return nil
      elseif h_last < first then
        offset = offset + h.new_count - h.old_count
      end
    end
  end
  return first + offset, last + offset
end

---@param scope "line"|"hunk"
local function diff_comment(scope)
  return function()
    local ctx = diff_ctx()
    if not ctx or not writable() then
      return
    end
    local win = diff_win()
    local side = win == W.wins.left and "old" or "new"
    local first, last
    if scope == "hunk" then
      local h = hunks_under_cursor()[1]
      if not h then
        notify("no hunk under the cursor", vim.log.levels.WARN)
        return
      end
      if h.new_count > 0 then
        side, first, last = "new", h.new_start, h.new_start + h.new_count - 1
      else
        side, first, last = "old", h.old_start, h.old_start + h.old_count - 1
      end
    else
      first, last = cursor_range(win)
      if side == "old" then
        local u = ctx.file.unstaged_diff
        local list = W.filter and (u and u.hunks or {}) or ctx.file.hunks
        local f, l = to_new_side(list, first, last)
        if f then
          side, first, last = "new", f, l --[[@as integer]]
        end
      end
    end
    if side == "old" and W.filter then
      notify("turn off the filter to comment on deleted lines", vim.log.levels.WARN)
      return
    end
    local buf = api.nvim_win_get_buf(side == "old" and W.wins.left or W.wins.right)
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    local captured = anchor.capture(lines, first, last)
    local path = W.path --[[@as string]] -- diff_ctx() above means a file is shown
    local range = last ~= first and ("-" .. last) or ""
    local title = ("comment · %s:%d%s"):format(format.short_path(path), first, range)
    local context = {
      lines = vim.list_slice(lines, first, last),
      filetype = vim.bo[buf].filetype,
      first_line = first,
    }
    write(title, function(body, attachments)
      comments.add(W.session, {
        scope = scope,
        file = path,
        side = side,
        line = first,
        end_line = last,
        anchor = captured,
        body = body,
        attachments = attachments,
      })
    end, context)
  end
end

M.actions.comment_line = diff_comment("line")
M.actions.comment_hunk = diff_comment("hunk")

function M.actions.comment_file()
  local path = path_under_cursor()
  if not path or not writable() then
    return
  end
  write("comment · " .. format.short_path(path), function(body, attachments)
    comments.add(W.session, { scope = "file", file = path, body = body, attachments = attachments })
  end)
end

function M.actions.comment_session()
  if not writable() then
    return
  end
  write("comment · session", function(body, attachments)
    comments.add(W.session, { scope = "session", body = body, attachments = attachments })
  end)
end

--- The Comment on the cursor line of a diff window, an open one first.
---@param win integer
---@return iz.Comment?
local function comment_on_line(win)
  local side = win == W.wins.left and "old" or "new"
  local line = vim.fn.line(".", win)
  local found
  -- With the filter on, the left side is the index: Base line numbers don't apply.
  local list = (side == "old" and W.filter) and {} or comments.for_file(W.session, W.path or "")
  for _, c in ipairs(list) do
    local covers = c.line and c.line <= line and line <= (c.end_line or c.line)
    if covers and (c.side or "new") == side then
      if c.status == "open" then
        return c
      end
      found = found or c
    end
  end
  return found
end

--- Opens the panel and moves into it, on the Comment of the diff line the
--- cursor was on. From inside the panel, closes it and goes back to the file.
function M.actions.toggle_panel()
  local from = api.nvim_get_current_win()
  local c = (from == W.wins.left or from == W.wins.right) and comment_on_line(from) or nil
  local open = W.panel.win ~= nil and api.nvim_win_is_valid(W.panel.win)
  if open and from ~= W.panel.win then
    api.nvim_set_current_win(W.panel.win)
  else
    W.panel.manual = not open
    sync_panel()
    api.nvim_set_current_win(W.panel.manual and W.panel.win or W.wins.right)
  end
  if c and api.nvim_get_current_win() == W.panel.win then
    local first
    for line, id in pairs(W.panel.ids) do
      if id == c.id and (not first or line < first) then
        first = line
      end
    end
    if first then
      api.nvim_win_set_cursor(W.panel.win, { first, 0 })
    end
  end
end

---@return iz.Comment?
local function comment_under_cursor()
  local id = W.panel.ids[vim.fn.line(".")]
  return id and comments.find(W.session, id) or nil
end

---@param c iz.Comment
local function reply(c)
  if not writable() then
    return
  end
  -- Answering means seeing what is being answered.
  local lines, marks = thread.render(c)
  local title = "reply · " .. format.short_path(format.location(c))
  write(title, function(body, attachments)
    comments.reply(W.session, c, body, attachments)
  end, { lines = lines, marks = marks, filetype = "markdown" })
end

---@param status "open"|"resolved"|"ignored"
---@return fun(c: iz.Comment)
local function set_status(status)
  return function(c)
    if not writable() then
      return
    end
    comments.set_status(W.session, c, status)
    draw_comments()
  end
end

---@param c iz.Comment
local function send(c)
  if not writable() then
    return
  end
  if not comments.suggested(c) then
    notify("only an unsent co-reviewer suggestion can be sent", vim.log.levels.WARN)
    return
  end
  comments.send(W.session, c)
  draw_comments()
end

---@param c iz.Comment
local function open_thread(c)
  thread.open(c, {
    send = send,
    reply = reply,
    resolve = set_status("resolved"),
    ignore = set_status("ignored"),
    reopen = set_status("open"),
  })
end

--- Opens the thread, with the diff behind it moved to the Comment's code.
function M.actions.panel_jump()
  local c = comment_under_cursor()
  if not c then
    return
  end
  if not c.file then
    open_thread(c)
    return
  end
  job(function()
    exclusive(function()
      if W.path ~= c.file and W.view.by_path[c.file] then
        show(c.file)
      end
      if W.path == c.file then
        local win = c.side == "old" and W.wins.left or W.wins.right
        api.nvim_set_current_win(win)
        if c.line then
          local max = api.nvim_buf_line_count(api.nvim_win_get_buf(win))
          api.nvim_win_set_cursor(win, { math.min(c.line, max), 0 })
        end
      end
      open_thread(c)
    end)
  end)
end

--- Opens the thread of the Comment on the cursor line of a diff window.
function M.actions.open_thread()
  local found = comment_on_line(diff_win())
  if found then
    open_thread(found)
  else
    notify("no comment on this line")
  end
end

---@param fn fun(c: iz.Comment)
local function on_panel_comment(fn)
  return function()
    local c = comment_under_cursor()
    if c then
      fn(c)
    end
  end
end

M.actions.panel_reply = on_panel_comment(reply)
M.actions.panel_resolve = on_panel_comment(set_status("resolved"))
M.actions.panel_ignore = on_panel_comment(set_status("ignored"))
M.actions.panel_reopen = on_panel_comment(set_status("open"))
M.actions.panel_send = on_panel_comment(send)

--- Ignores every Suggestion the user has not sent, in one go.
function M.actions.ignore_suggestions()
  if not writable() then
    return
  end
  local n = 0
  for _, c in ipairs(W.session.data.comments) do
    if comments.suggested(c) then
      comments.set_status(W.session, c, "ignored")
      n = n + 1
    end
  end
  if n == 0 then
    notify("no unsent suggestions")
    return
  end
  notify("ignored " .. util.plural(n, "suggestion"))
  draw_comments()
end

function M.actions.done()
  if not writable() then
    return
  end
  require("iz.lifecycle").done(W.session, M.close)
end

--- Re-anchors the Comment to the line under the cursor in the right diff window.
function M.actions.panel_move()
  local c = comment_under_cursor()
  if not c or not c.file or not writable() then
    return
  end
  if c.file ~= W.path then
    notify("open " .. c.file .. " in the diff first", vim.log.levels.WARN)
    return
  end
  local line = vim.fn.line(".", W.wins.right)
  local height = c.line and c.end_line and (c.end_line - c.line + 1) or 1
  local lines = api.nvim_buf_get_lines(api.nvim_win_get_buf(W.wins.right), 0, -1, false)
  comments.move(W.session, c, lines, line, line + height - 1)
  draw_comments()
end

---@param buf integer
---@param lhs string
---@param rhs function
---@param desc string
---@param modes? string|string[]
local function bufmap(buf, lhs, rhs, desc, modes)
  if lhs and lhs ~= "" then
    local opts = { buffer = buf, nowait = true, silent = true, desc = "iz: " .. desc }
    vim.keymap.set(modes or "n", lhs, rhs, opts)
  end
end

---@param buf integer
function map_diff_keys(buf)
  if W.mapped[buf] then
    return
  end
  W.mapped[buf] = true
  local k = config.options.keymaps.diff
  bufmap(buf, k.stage, M.actions.stage, "stage hunk", { "n", "x" })
  bufmap(buf, k.unstage, M.actions.unstage, "unstage hunk", { "n", "x" })
  bufmap(buf, k.discard, M.actions.discard, "discard hunk", { "n", "x" })
  bufmap(buf, k.undo_discard, M.actions.undo_discard, "undo last discard")
  bufmap(buf, k.toggle_filter, M.actions.toggle_filter, "toggle unstaged-only filter")
  bufmap(buf, k.comment, M.actions.comment_line, "comment on line(s)", { "n", "x" })
  bufmap(buf, k.comment_hunk, M.actions.comment_hunk, "comment on hunk")
  bufmap(buf, k.open_thread, M.actions.open_thread, "open the comment thread on this line")
  bufmap(buf, k.toggle_panel, M.actions.toggle_panel, "toggle comment panel")
  bufmap(buf, k.focus_files, M.actions.focus_files, "go to the file list")
  bufmap(buf, k.next_hunk, M.actions.next_hunk, "next hunk")
  bufmap(buf, k.prev_hunk, M.actions.prev_hunk, "previous hunk")
  bufmap(buf, k.close, M.close, "close workspace")
  bufmap(buf, k.help, function()
    help.open("diff")
  end, "show keys")
end

local function unmap_diff_keys()
  local k = config.options.keymaps.diff
  for buf in pairs(W.mapped) do
    if api.nvim_buf_is_valid(buf) then
      for _, lhs in pairs(k) do
        for _, mode in ipairs({ "n", "x" }) do
          pcall(vim.keymap.del, mode, lhs, { buffer = buf })
        end
      end
    end
  end
  W.mapped = {}
end

--- The `<leader>i` keys that aren't about a Hunk work in every iz window, so
--- they do the same thing wherever the cursor is. Without them, `<leader>if`
--- in the panel would run its plain `i` (ignore) key.
---@param buf integer
local function map_workspace_keys(buf)
  local k = config.options.keymaps.diff
  bufmap(buf, k.toggle_filter, M.actions.toggle_filter, "toggle unstaged-only filter")
  bufmap(buf, k.toggle_panel, M.actions.toggle_panel, "toggle comment panel")
  bufmap(buf, k.focus_files, M.actions.focus_files, "go to the file list")
  bufmap(buf, k.close, M.close, "close workspace")
end

local function map_files_keys()
  local buf, k = W.files_buf, config.options.keymaps.files
  map_workspace_keys(buf)
  bufmap(buf, k.open, M.actions.open_under_cursor, "open file")
  bufmap(buf, k.stage, M.actions.stage_file, "stage file")
  bufmap(buf, k.unstage, M.actions.unstage_file, "unstage file")
  bufmap(buf, k.discard, M.actions.discard_file, "discard file")
  bufmap(buf, k.undo_discard, M.actions.undo_discard, "undo last discard")
  bufmap(buf, k.toggle_filter, M.actions.toggle_filter, "toggle unstaged-only filter")
  bufmap(buf, k.comment, M.actions.comment_file, "comment on file")
  bufmap(buf, k.toggle_panel, M.actions.toggle_panel, "toggle comment panel")
  bufmap(buf, k.refresh, M.refresh, "refresh")
  bufmap(buf, k.close, M.close, "close workspace")
  bufmap(buf, k.help, function()
    help.open("files")
  end, "show keys")
  if config.options.preview_on_move then
    api.nvim_create_autocmd("CursorMoved", {
      group = W.augroup,
      buffer = buf,
      callback = preview_under_cursor,
    })
  end
end

local function map_panel_keys()
  local buf, k = W.panel.buf, config.options.keymaps.panel
  map_workspace_keys(buf)
  bufmap(buf, k.jump, M.actions.panel_jump, "open the thread and go to its code")
  bufmap(buf, k.reply, M.actions.panel_reply, "reply")
  bufmap(buf, k.resolve, M.actions.panel_resolve, "resolve")
  bufmap(buf, k.ignore, M.actions.panel_ignore, "ignore")
  bufmap(buf, k.reopen, M.actions.panel_reopen, "reopen")
  bufmap(buf, k.send, M.actions.panel_send, "send the suggestion to the agent")
  bufmap(buf, k.ignore_suggestions, M.actions.ignore_suggestions, "ignore every unsent suggestion")
  bufmap(buf, k.move, M.actions.panel_move, "move to cursor line")
  bufmap(buf, k.close, M.actions.toggle_panel, "close panel")
  bufmap(buf, k.help, function()
    help.open("panel")
  end, "show keys")
end

---@param filetype string
---@param name string shown instead of [Scratch]; a URL-like name is never taken
---for a file path, so it can't clash with a real file
local function scratch(filetype, name)
  local buf = api.nvim_create_buf(false, true)
  pcall(api.nvim_buf_set_name, buf, name)
  vim.bo[buf].filetype = filetype
  vim.bo[buf].modifiable = false
  return buf
end

local function create_layout()
  vim.cmd("tabnew")
  local tab = api.nvim_get_current_tabpage()
  local right = api.nvim_get_current_win()
  local left = api.nvim_open_win(0, false, { split = "left", win = right })
  local files_buf = scratch("iz-files", "iz://files")
  local files = api.nvim_open_win(files_buf, true, {
    split = "left",
    win = -1,
    width = config.options.files_width,
  })
  vim.wo[files].number = false
  vim.wo[files].relativenumber = false
  vim.wo[files].signcolumn = "no"
  vim.wo[files].winfixwidth = true
  vim.wo[files].cursorline = true
  vim.wo[files].wrap = false
  return tab, { files = files, left = left, right = right }, files_buf
end

---@param dir string
---@param on_change fun(filename: string)
---@return uv.uv_fs_event_t?
local function watch_dir(dir, on_change)
  local handle = vim.uv.new_fs_event()
  if not handle then
    return nil
  end
  handle:start(dir, {}, function(_, filename)
    if filename then
      vim.schedule(function()
        on_change(filename)
      end)
    end
  end)
  return handle
end

--- Watches `.iz/inbox/` for agent replies, `.iz/coreview/` for Suggestions
--- and `.iz/summaries/` for Summaries; only the session's writer does this.
local function watch_inbox()
  local dirs = { storage.inbox_dir(W.root), coreview.dir(W.root), summary_mod.dir(W.root) }
  for _, dir in ipairs(dirs) do
    vim.fn.mkdir(dir, "p")
    table.insert(W.watchers, watch_dir(dir, function(name)
      if name:match("%.jsonl$") then
        M.schedule_refresh()
      end
    end))
  end
end

local opening = false

--- Opens the workspace for the repository at the cwd, creating a Session if needed.
function M.open()
  if M.get() then
    api.nvim_set_current_tabpage(W.tab)
    return
  end
  -- A second :Iz while the first is still setting up must not build another tab.
  if opening then
    return
  end
  opening = true
  hl.setup()
  job(function()
    local ok, err = pcall(M._open)
    opening = false
    if not ok then
      error(err, 0)
    end
  end)
end

--- Async body of `M.open`.
function M._open()
  local root = session_mod.root()
  if not root then
    error("not inside a git repository", 0)
  end
  local can_write = lock.acquire(root)
  local session
  if can_write then
    session = session_mod.open(root)
  else
    session = session_mod.current(root)
    if not session then
      error("another Neovim owns iz in this repository and no session is active", 0)
    end
  end
  if anchor.relocate_all(session) and can_write then
    session_mod.save(session)
  end
  local view = hunks.compute(session)
  local tab, wins, files_buf = create_layout()
  W = {
    root = root,
    session = session,
    view = view,
    readonly = not can_write,
    tab = tab,
    wins = wins,
    files_buf = files_buf,
    line_paths = {},
    filter = false,
    panel = { buf = scratch("iz-panel", "iz://comments"), ids = {} },
    summary = { buf = scratch("iz-summary", "iz://summary") },
    mapped = {},
    bufs = {},
    showing = false,
    watchers = {},
    augroup = api.nvim_create_augroup("iz.workspace", { clear = true }),
  }
  -- Git replaces the index through a rename, so watch its directory.
  local index = git.git_path(root, "index")
  table.insert(W.watchers, watch_dir(vim.fs.dirname(index), function(name)
    if name == "index" then
      M.schedule_refresh()
    end
  end))
  if not W.readonly then
    watch_inbox()
  end
  -- `.iz/` may have just been created; make sure Stop signals are heard.
  require("iz.signal").start()
  ingest()
  map_files_keys()
  map_panel_keys()
  show(first_path())
  draw_comments()
  suggest_done()

  api.nvim_create_autocmd("BufWinEnter", {
    group = W.augroup,
    callback = guard_diff_windows,
  })
  api.nvim_create_autocmd("BufWritePost", {
    group = W.augroup,
    callback = function(ev)
      if vim.startswith(api.nvim_buf_get_name(ev.buf), root .. "/") then
        M.schedule_refresh()
      end
    end,
  })
  api.nvim_create_autocmd("FocusGained", {
    group = W.augroup,
    callback = function()
      -- The other Neovim may have let go of the session meanwhile.
      if W.readonly and lock.acquire(root) then
        W.readonly = false
        -- Continue from what the previous owner saved, not from our stale copy.
        W.session = session_mod.current(root) or W.session
        watch_inbox()
        notify("this Neovim now owns the session")
        set_winbars()
      end
      M.schedule_refresh()
    end,
  })
  api.nvim_create_autocmd("WinResized", {
    group = W.augroup,
    callback = function()
      -- Inline comments are cut to their window's width.
      local resized = vim.v.event.windows or {}
      if W and W.summary.win and vim.tbl_contains(resized, W.summary.win) then
        fit_summary()
      end
      local ctx = W and diff_ctx()
      if
        ctx
        and (vim.tbl_contains(resized, W.wins.left) or vim.tbl_contains(resized, W.wins.right))
      then
        inline.draw(ctx)
      end
    end,
  })
  api.nvim_create_autocmd("TabClosed", {
    group = W.augroup,
    callback = function()
      if W and not api.nvim_tabpage_is_valid(W.tab) then
        M.close()
      end
    end,
  })
end

--- Closes the workspace; real file buffers stay loaded, our scratch buffers go.
function M.close()
  if not W then
    return
  end
  local ws = W
  local ctx = diff_ctx()
  if ctx and api.nvim_win_is_valid(ctx.left_win) then
    backend.close(ctx)
  end
  -- The windows may already be gone (:tabclose), so clear by buffer: real
  -- files must not keep iz marks after the workspace closes.
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) then
      api.nvim_buf_clear_namespace(buf, hl.ns, 0, -1)
      api.nvim_buf_clear_namespace(buf, inline.ns, 0, -1)
    end
  end
  unmap_diff_keys()
  for _, w in ipairs(ws.watchers) do
    w:stop()
    w:close()
  end
  pcall(api.nvim_del_augroup_by_id, ws.augroup)
  if not ws.readonly then
    lock.release(ws.root)
  end
  W = nil ---@diagnostic disable-line: cast-local-type
  if api.nvim_tabpage_is_valid(ws.tab) then
    if #api.nvim_list_tabpages() > 1 then
      api.nvim_set_current_tabpage(ws.tab)
      vim.cmd("tabclose")
    else
      api.nvim_set_current_win(ws.wins.right)
      vim.cmd("only")
    end
  end
  for _, buf in ipairs({ ws.files_buf, ws.panel.buf, ws.summary.buf }) do
    if api.nvim_buf_is_valid(buf) then
      api.nvim_buf_delete(buf, { force = true })
    end
  end
end

return M
