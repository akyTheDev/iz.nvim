-- Saves an image from the system clipboard to a file. Clipboard tools answer in
-- milliseconds, so this runs synchronously from the insert-mode key.
local M = {}

local TIMEOUT = 3000

---@param cmd string[]
local function run(cmd)
  local ok, obj = pcall(vim.system, cmd, { text = false })
  if not ok then
    return { code = -1, stdout = "" }
  end
  return obj:wait(TIMEOUT)
end

---@param path string
---@param data string
local function write(path, data)
  local f = assert(io.open(path, "wb"))
  f:write(data)
  f:close()
end

---@param dest string
local function macos(dest)
  if vim.fn.executable("pngpaste") == 1 then
    return run({ "pngpaste", dest }).code == 0
  end
  -- No pngpaste: AppleScript can read PNG data straight from the clipboard.
  local quoted = dest:gsub('"', '\\"')
  return run({
    "osascript",
    "-e", "set png to (the clipboard as «class PNGf»)",
    "-e", ('set f to open for access (POSIX file "%s") with write permission'):format(quoted),
    "-e", "write png to f",
    "-e", "close access f",
  }).code == 0
end

---@param list_cmd string[]
---@param read_cmd string[]
---@param dest string
local function via(list_cmd, read_cmd, dest)
  local types = run(list_cmd)
  if types.code ~= 0 or not (types.stdout or ""):find("image/png", 1, true) then
    return false
  end
  local img = run(read_cmd)
  if img.code ~= 0 or not img.stdout or img.stdout == "" then
    return false
  end
  write(dest, img.stdout)
  return true
end

local warned = false

---@param dest string absolute path of the PNG to create
---@return boolean saved false when the clipboard holds no image
function M.save_image(dest)
  vim.fn.mkdir(vim.fs.dirname(dest), "p")
  local saved
  if vim.fn.has("mac") == 1 then
    saved = macos(dest)
  elseif vim.env.WAYLAND_DISPLAY and vim.fn.executable("wl-paste") == 1 then
    saved = via({ "wl-paste", "--list-types" }, { "wl-paste", "--type", "image/png" }, dest)
  elseif vim.fn.executable("xclip") == 1 then
    local base = { "xclip", "-selection", "clipboard", "-o", "-t" }
    local targets = vim.list_extend(vim.deepcopy(base), { "TARGETS" })
    saved = via(targets, vim.list_extend(vim.deepcopy(base), { "image/png" }), dest)
  else
    if not warned then
      warned = true
      vim.notify("iz: install wl-paste or xclip to paste images", vim.log.levels.INFO)
    end
    return false
  end
  return saved and vim.uv.fs_stat(dest) ~= nil
end

return M
