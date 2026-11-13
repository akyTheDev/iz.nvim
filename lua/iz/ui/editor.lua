-- Floating editor for writing a Comment or a Reply: a read-only context on
-- top (the code being commented on, or the thread being answered) and the
-- markdown input under it, drawn as one card.
local clipboard = require("iz.clipboard")
local config = require("iz.config")
local hl = require("iz.ui.highlights")
local storage = require("iz.storage")

local api = vim.api
local M = {}

M.FILETYPE = "iz-comment"
M.PLACEHOLDER = "Write your comment… markdown; <C-v> pastes a screenshot"

local count = 0
local ns = api.nvim_create_namespace("iz.editor")

---@class iz.EditorContext
---@field lines string[]
---@field filetype? string Highlights the lines like that kind of file.
---@field first_line? integer Line number of `lines[1]`; no numbers without it.
---@field marks? table[] `{ line, group, first_col, last_col }`, 1-based line.

---@class iz.EditorOpts
---@field title string
---@field session iz.Session
---@field context? iz.EditorContext
---@field on_save fun(body: string, attachments: string[])

local WINHIGHLIGHT = table.concat({
  "NormalFloat:IzFloat",
  "FloatBorder:IzFloatBorder",
  "FloatTitle:IzFloatTitle",
  "FloatFooter:IzFloatFooter",
}, ",")

--- Highlights `buf` as `filetype` without setting 'filetype': that would
--- start language servers and filetype plugins on a scratch buffer.
---@param buf integer
---@param filetype string
local function highlight_as(buf, filetype)
  local lang = vim.treesitter.language.get_lang(filetype) or filetype
  if not pcall(vim.treesitter.start, buf, lang) then
    vim.bo[buf].syntax = filetype
  end
end

--- Turns completion and suggestions off in the comment buffer only: a
--- review comment is prose, and popups over it get in the way.
---@param buf integer
local function no_completion(buf)
  vim.b[buf].completion = false -- blink.cmp
  vim.b[buf].minicompletion_disable = true -- mini.completion
  vim.b[buf].copilot_enabled = false -- copilot.vim
  vim.b[buf].copilot_suggestion_hidden = true -- copilot.lua
  pcall(function()
    vim.bo[buf].autocomplete = false -- built-in, Neovim 0.12+
  end)
  -- Servers that attach to every filetype get detached again.
  api.nvim_create_autocmd("LspAttach", {
    buffer = buf,
    callback = function(ev)
      vim.schedule(function()
        if api.nvim_buf_is_valid(buf) then
          pcall(vim.lsp.buf_detach_client, buf, ev.data.client_id)
        end
      end)
    end,
  })
end

---@param buf integer
local function placeholder(buf)
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines == 1 and lines[1] == "" then
    api.nvim_buf_set_extmark(buf, ns, 0, 0, {
      virt_text = { { M.PLACEHOLDER, "IzMuted" } },
      virt_text_pos = "overlay",
    })
  end
end

---@param context iz.EditorContext
---@param width integer
---@return integer buf
local function context_buf(context, width)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  api.nvim_buf_set_lines(buf, 0, -1, false, context.lines)
  vim.bo[buf].modifiable = false
  if context.filetype and context.filetype ~= "" then
    highlight_as(buf, context.filetype)
  end
  if context.first_line then
    local last = context.first_line + #context.lines - 1
    local digits = math.min(#tostring(last), width)
    for i = 1, #context.lines do
      api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
        virt_text = { { ("%" .. digits .. "d  "):format(context.first_line + i - 1), "LineNr" } },
        virt_text_pos = "inline",
      })
    end
  end
  for _, m in ipairs(context.marks or {}) do
    api.nvim_buf_set_extmark(buf, hl.ns, m[1] - 1, m[3], { end_col = m[4], hl_group = m[2] })
  end
  return buf
end

---@param opts iz.EditorOpts
---@return integer buf
function M.open(opts)
  count = count + 1
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  api.nvim_buf_set_name(buf, "iz://comment/" .. count)
  no_completion(buf)
  vim.treesitter.language.register("markdown", M.FILETYPE)
  vim.bo[buf].filetype = M.FILETYPE
  highlight_as(buf, "markdown")

  local size = config.options.editor
  local max_width = math.max(1, vim.o.columns - 6)
  local width = math.min(max_width, math.max(72, math.floor(vim.o.columns * size.width)))
  local room = math.max(4, vim.o.lines - 6)
  local height = math.min(math.max(6, math.floor(vim.o.lines * size.height)), room)
  local context = opts.context and #opts.context.lines > 0 and opts.context or nil
  -- The context gets at most a third of the card; the input keeps the rest.
  local ctx_height = context and math.min(#context.lines, math.max(1, math.floor(room / 3))) or 0
  height = math.min(height, room - (context and ctx_height + 2 or 0))
  local total = (context and ctx_height + 2 or 1) + height + 1
  local row = math.max(0, math.floor((vim.o.lines - total) / 2) - 1)
  local col = math.floor((vim.o.columns - width) / 2)
  local title = " " .. opts.title .. " "
  local footer = " <C-s> save · <C-v> image · q cancel "

  local ctx_win
  if context then
    -- One card: the context's bottom border is the line between the two parts.
    ctx_win = api.nvim_open_win(context_buf(context, width), false, {
      relative = "editor",
      row = row,
      col = col,
      width = width,
      height = ctx_height,
      border = { "╭", "─", "╮", "│", "┤", "─", "├", "│" },
      style = "minimal",
      focusable = false,
      title = title,
      title_pos = "left",
    })
    vim.wo[ctx_win].winhighlight = WINHIGHLIGHT
    vim.wo[ctx_win].wrap = false
    if not context.first_line then
      -- A thread: its latest messages matter most.
      vim.wo[ctx_win].wrap = true
      vim.wo[ctx_win].conceallevel = 2
      api.nvim_win_call(ctx_win, function()
        vim.cmd("normal! G")
      end)
    end
  end

  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = context and row + ctx_height + 2 or row,
    col = col,
    width = width,
    height = height,
    border = context and { "", "", "", "│", "╯", "─", "╰", "│" } or "rounded",
    style = "minimal",
    title = not context and title or nil,
    title_pos = not context and "left" or nil,
    footer = footer,
    footer_pos = "right",
  })
  vim.wo[win].winhighlight = WINHIGHLIGHT
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].signcolumn = "yes:1" -- pads the text from the border
  if ctx_win then
    vim.wo[ctx_win].signcolumn = "yes:1"
  end
  -- nvim-cmp only takes per-buffer settings for the current buffer.
  if package.loaded.cmp then
    pcall(function()
      require("cmp").setup.buffer({ enabled = false })
    end)
  end

  local attachments = {}

  local function close()
    for _, w in ipairs({ win, ctx_win }) do
      if w and api.nvim_win_is_valid(w) then
        api.nvim_win_close(w, true)
      end
    end
  end
  -- `:q` or any other way out of the input takes the context with it.
  api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      vim.schedule(close)
    end,
  })

  local function save()
    vim.cmd("stopinsert")
    local body = vim.trim(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
    vim.bo[buf].modified = false
    close()
    if body == "" then
      vim.notify("iz: empty comment discarded", vim.log.levels.WARN)
      return
    end
    -- Keep only images whose link survived editing.
    local used = vim.tbl_filter(function(path)
      return body:find(path, 1, true) ~= nil
    end, attachments)
    opts.on_save(body, used)
  end

  local function paste_image()
    local rel = ("%s/sessions/%s/assets/%s-%d.png"):format(
      storage.DIR,
      opts.session.id,
      os.date("%Y%m%d-%H%M%S"),
      #attachments + 1
    )
    if clipboard.save_image(opts.session.root .. "/" .. rel) then
      table.insert(attachments, rel)
      api.nvim_put({ ("![](%s)"):format(rel) }, "c", false, true)
    else
      -- No image: behave like the built-in <C-v> (insert the next key literally).
      api.nvim_feedkeys(api.nvim_replace_termcodes("<C-v>", true, false, true), "n", false)
    end
  end

  placeholder(buf)
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    callback = function()
      placeholder(buf)
    end,
  })
  api.nvim_create_autocmd("BufWriteCmd", { buffer = buf, callback = save })
  local o = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set({ "n", "i" }, "<C-s>", save, o)
  vim.keymap.set("n", "q", close, o)
  vim.keymap.set("n", "<Esc><Esc>", close, o)
  local paste = config.options.keymaps.paste_image
  if paste and paste ~= "" then
    vim.keymap.set("i", paste, paste_image, o)
  end
  vim.cmd("startinsert")
  return buf
end

return M
