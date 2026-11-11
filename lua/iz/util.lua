local M = {}

--- UTC timestamp in ISO 8601, the format of every stored time.
---@return string
function M.now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ") --[[@as string]]
end

---@param n integer
---@param one string
---@param many? string defaults to `one .. "s"`
function M.plural(n, one, many)
  return ("%d %s"):format(n, n == 1 and one or (many or one .. "s"))
end

--- Random hex from the OS, so ids differ across Neovim restarts
--- (`math.random` starts from the same seed every time).
---@param bytes integer
---@return string
function M.random_hex(bytes)
  local raw = assert(vim.uv.random(bytes))
  return (raw:gsub(".", function(c)
    return ("%02x"):format(c:byte())
  end))
end

return M
