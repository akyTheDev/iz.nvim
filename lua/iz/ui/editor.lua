-- Floating markdown buffer for writing a Comment or a Reply.
local clipboard = require("iz.clipboard")
local config = require("iz.config")
local storage = require("iz.storage")

local api = vim.api
local M = {}

local count = 0

---@class iz.EditorOpts
---@field title string
---@field session iz.Session
---@field on_save fun(body: string, attachments: string[])

---@param opts iz.EditorOpts
---@return integer buf
function M.open(opts)
  count = count + 1
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  api.nvim_buf_set_name(buf, "iz://comment/" .. count)

  local width = math.min(80, vim.o.columns - 4)
  local height = 10
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    border = "rounded",
    style = "minimal",
    title = " " .. opts.title .. " ",
    title_pos = "center",
    footer = " <C-s> save · q cancel ",
    footer_pos = "right",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  local attachments = {}

  local function close()
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
  end

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
