local M = {}

M.defaults = {
  files_width = 42,
  panel_width = 56,
  -- Rows of the strip above the diff that shows the agent's Summary of the
  -- file (/iz-summary); 0 never shows it.
  summary_height = 5,
  -- Moving through the file list shows the file under the cursor in the diff;
  -- `<CR>` still moves into it.
  preview_on_move = true,
  -- The thread float, as a share of the screen; it grows past the height for
  -- long threads.
  thread = { width = 0.6, height = 0.6 },
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
      help = "?",
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
      open_thread = "<leader>ik",
      toggle_panel = "<leader>ip",
      focus_files = "<leader>il",
      next_hunk = "]h",
      prev_hunk = "[h",
      close = "<leader>iq",
      help = "<leader>i?",
    },
    panel = {
      jump = "<CR>",
      reply = "a",
      resolve = "r",
      ignore = "i",
      reopen = "o",
      send = "s",
      ignore_suggestions = "I",
      move = "m",
      close = "q",
      help = "?",
    },
  },
}

M.options = vim.deepcopy(M.defaults)

---@param opts? table
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
