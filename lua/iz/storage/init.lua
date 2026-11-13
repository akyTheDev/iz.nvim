local git = require("iz.git")

local M = {}

M.DIR = ".iz"

---@param root string
function M.dir(root)
  return root .. "/" .. M.DIR
end

---@param root string
---@param id string
function M.session_dir(root, id)
  return M.dir(root) .. "/sessions/" .. id
end

---@param root string
function M.inbox_dir(root)
  return M.dir(root) .. "/inbox"
end

--- Whether an agent-supplied `path` names a file inside the repository and
--- outside `.iz/`: relative, without `..`.
---@param path string
---@return boolean
function M.is_repo_path(path)
  if path == "" or path:sub(1, 1) == "/" then
    return false
  end
  for part in path:gmatch("[^/]+") do
    if part == ".." then
      return false
    end
  end
  return not (path == M.DIR or vim.startswith(path, M.DIR .. "/"))
end

---@param path string
---@return string?
function M.read_file(path)
  local fd = vim.uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local stat = assert(vim.uv.fs_fstat(fd))
  local data = assert(vim.uv.fs_read(fd, stat.size, 0))
  vim.uv.fs_close(fd)
  return data
end

--- Writes through a temp file and a rename so readers never see a partial file.
---@param path string
---@param content string
function M.write_atomic(path, content)
  local tmp = path .. ".tmp"
  local fd = assert(vim.uv.fs_open(tmp, "w", 420))
  assert(vim.uv.fs_write(fd, content, 0))
  vim.uv.fs_fsync(fd)
  vim.uv.fs_close(fd)
  assert(vim.uv.fs_rename(tmp, path))
end

---@param path string
---@return table?
function M.read_json(path)
  local content = M.read_file(path)
  if not content or content == "" then
    return nil
  end
  return vim.json.decode(content, { luanil = { object = true, array = true } })
end

---@param path string
---@param value table
function M.write_json(path, value)
  -- `indent` exists on Neovim 0.12+; fall back to compact output on older versions.
  local ok, encoded = pcall(vim.json.encode, value, { indent = "  " })
  if not ok then
    encoded = vim.json.encode(value)
  end
  M.write_atomic(path, encoded .. "\n")
end

---@param path string
function M.mkdirp(path)
  vim.fn.mkdir(path, "p")
end

--- Creates `.iz/` and hides it from git through `info/exclude`, never `.gitignore`.
--- Async: call inside `async.run`.
---@param root string
function M.ensure(root)
  M.mkdirp(M.dir(root) .. "/inbox")
  local exclude = git.git_path(root, "info/exclude")
  local content = M.read_file(exclude) or ""
  for line in vim.gsplit(content, "\n", { plain = true }) do
    if vim.trim(line) == "/" .. M.DIR .. "/" then
      return
    end
  end
  M.mkdirp(vim.fs.dirname(exclude))
  local sep = (content == "" or content:sub(-1) == "\n") and "" or "\n"
  M.write_atomic(exclude, content .. sep .. "/" .. M.DIR .. "/\n")
end

return M
