local async = require("iz.async")

local M = {}

---@class iz.GitOpts
---@field cwd string
---@field stdin? string
---@field env? table<string, string>
---@field allow_fail? boolean Return the result instead of raising on a non-zero exit.

--- Runs git without blocking. Must be called inside `async.run`.
---@param args string[]
---@param opts iz.GitOpts
---@return string stdout
---@return vim.SystemCompleted result
function M.run(args, opts)
  local cmd = { "git", "-c", "core.quotepath=false" }
  vim.list_extend(cmd, args)
  local result = async.await(function(resume)
    vim.system(cmd, { cwd = opts.cwd, stdin = opts.stdin, env = opts.env }, function(obj)
      vim.schedule(function()
        resume(obj)
      end)
    end)
  end)
  result.stdout = result.stdout or ""
  result.stderr = result.stderr or ""
  if result.code ~= 0 and not opts.allow_fail then
    error(("git %s failed: %s"):format(args[1], vim.trim(result.stderr)), 0)
  end
  return result.stdout, result
end

---@param cwd string
---@return string? root
function M.toplevel(cwd)
  local out, res = M.run({ "rev-parse", "--show-toplevel" }, { cwd = cwd, allow_fail = true })
  if res.code ~= 0 then
    return nil
  end
  return vim.trim(out)
end

--- Absolute path of a file inside the git dir; worktree aware (`info/exclude`, `index`).
---@param root string
---@param name string
function M.git_path(root, name)
  local path = vim.trim(M.run({ "rev-parse", "--git-path", name }, { cwd = root }))
  if path:sub(1, 1) ~= "/" then
    path = root .. "/" .. path
  end
  return path
end

---@param root string
---@param rev string
---@param path string
---@return string? content nil when the path does not exist at `rev`
function M.show(root, rev, path)
  local out, res = M.run({ "show", rev .. ":" .. path }, { cwd = root, allow_fail = true })
  if res.code ~= 0 then
    return nil
  end
  return out
end

---@param root string
---@param rev string
---@param path string
function M.exists(root, rev, path)
  local _, res = M.run({ "cat-file", "-e", rev .. ":" .. path }, { cwd = root, allow_fail = true })
  return res.code == 0
end

return M
