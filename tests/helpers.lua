local async = require("iz.async")

local H = {}

H.eq = MiniTest.expect.equality
H.neq = MiniTest.expect.no_equality

--- Runs git synchronously; tests only.
---@param root string
---@param args string[]
function H.git(root, args)
  local cmd = { "git" }
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, { cwd = root, text = true }):wait()
  if res.code ~= 0 then
    error(("git %s: %s"):format(table.concat(args, " "), res.stderr), 2)
  end
  return vim.trim(res.stdout)
end

---@param root string
---@param path string
---@param content string
function H.write(root, path, content)
  local abs = root .. "/" .. path
  vim.fn.mkdir(vim.fs.dirname(abs), "p")
  local f = assert(io.open(abs, "wb"))
  f:write(content)
  f:close()
end

---@param root string
---@param path string
function H.read(root, path)
  local f = io.open(root .. "/" .. path, "rb")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  return content
end

--- Fresh repository with one commit holding `files`.
---@param files? table<string, string>
---@return string root
function H.repo(files)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local root = assert(vim.uv.fs_realpath(dir))
  H.git(root, { "init", "-q", "-b", "main" })
  H.git(root, { "config", "user.name", "test" })
  H.git(root, { "config", "user.email", "test@example.com" })
  H.git(root, { "config", "commit.gpgsign", "false" })
  for path, content in pairs(files or { ["README.md"] = "hello\n" }) do
    H.write(root, path, content)
  end
  H.git(root, { "add", "-A" })
  H.git(root, { "commit", "-q", "-m", "init" })
  return root
end

--- Lines `1..n` joined, handy for multi-hunk files.
---@param n integer
---@param edit? table<integer, string>
function H.lines(n, edit)
  local out = {}
  for i = 1, n do
    out[#out + 1] = (edit and edit[i]) or ("line " .. i)
  end
  return table.concat(out, "\n") .. "\n"
end

H.run = async.block_on

return H
