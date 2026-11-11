local M = {}

M.defaults = {
  files_width = 42,
  panel_width = 56,
  keymaps = {
    -- Insert-mode key in the comment editor; falls back to a literal <C-v>
    -- when the clipboard holds no image.
    paste_image = "<C-v>",
    -- File list: a read-only buffer, so plain keys are safe.
    files = {
      open = "<CR>",
      stage = "s",
      unstage = "u",
      discard = "x",
      undo_discard = "U",
      toggle_filter = "f",
      comment = "c",
      toggle_panel = "p",
      refresh = "R",
      close = "q",
    },
    -- Diff windows: the right side is the real, editable file, so these must
    -- not shadow editing keys.
    diff = {
      stage = "<leader>is",
      unstage = "<leader>iu",
      discard = "<leader>ix",
      undo_discard = "<leader>iU",
      toggle_filter = "<leader>if",
      comment = "<leader>ic",
      comment_hunk = "<leader>iC",
      toggle_panel = "<leader>ip",
      next_hunk = "]h",
      prev_hunk = "[h",
      close = "<leader>iq",
    },
    panel = {
      jump = "<CR>",
      reply = "a",
      resolve = "r",
      ignore = "i",
      reopen = "o",
      move = "m",
      close = "q",
    },
  },
}

M.options = vim.deepcopy(M.defaults)

---@param opts? table
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
