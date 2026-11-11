-- The seam between the workspace and whatever draws the diff (ADR 0001).
-- Only the native `:diffthis` backend exists; an inline one can implement the
-- same functions later.

---@class iz.DiffContext
---@field root string
---@field session iz.Session
---@field file iz.FileView
---@field left_rev "base"|"index"
---@field left_win integer
---@field right_win integer

---@class iz.DiffBackend
---@field open fun(ctx: iz.DiffContext) Shows the file in both windows. Async.
---@field mark fun(ctx: iz.DiffContext) Redraws Staged / new-since-approval marks.
---@field hunks_at fun(ctx: iz.DiffContext, win: integer, first: integer, last: integer): iz.Hunk[]
---@field targets fun(ctx: iz.DiffContext, win: integer): integer[] Line of each hunk, in order.
---@field close fun(ctx: iz.DiffContext)

return require("iz.diff.native")
