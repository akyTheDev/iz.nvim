local M = {}

---@param opts? table
function M.setup(opts)
  if vim.fn.has("nvim-0.10") == 0 then
    vim.notify("iz.nvim requires Neovim 0.10 or newer", vim.log.levels.ERROR)
    return
  end
  require("iz.config").setup(opts)
end

return M
