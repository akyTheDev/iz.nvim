-- Minimal coroutine runner: code inside `run` reads sequentially while every
-- external call (git, timers) yields instead of blocking the event loop.
local M = {}

---@param fn fun(): any
---@param done? fun(err: any, result: any)
function M.run(fn, done)
  local co = coroutine.create(fn)

  local function finish(err, result)
    if done then
      done(err, result)
    elseif err then
      vim.schedule(function()
        vim.notify("iz: " .. tostring(err), vim.log.levels.ERROR)
      end)
    end
  end

  local function step(...)
    local ok, ret = coroutine.resume(co, ...)
    if not ok then
      local err = type(ret) == "string" and debug.traceback(co, ret) or ret
      return finish(err)
    end
    if coroutine.status(co) == "dead" then
      return finish(nil, ret)
    end
    local registered, reg_err = pcall(ret, step)
    if not registered then
      finish(reg_err)
    end
  end

  step()
end

--- Suspends the current coroutine until `register` calls the resume callback.
---@param register fun(resume: fun(...))
function M.await(register)
  assert(coroutine.running(), "iz.async.await called outside of async.run")
  return coroutine.yield(register)
end

--- Lets queued events run before continuing.
function M.yield_to_loop()
  M.await(function(resume)
    vim.schedule(resume)
  end)
end

--- Runs `fn` to completion and returns its result. Blocks; meant for tests.
---@param fn fun(): any
---@param timeout? integer
function M.block_on(fn, timeout)
  local finished, err, result = false, nil, nil
  M.run(fn, function(e, r)
    finished, err, result = true, e, r
  end)
  if not vim.wait(timeout or 10000, function()
    return finished
  end, 5) then
    error("iz.async.block_on timed out", 2)
  end
  if err then
    error(err, 0)
  end
  return result
end

return M
