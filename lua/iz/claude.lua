-- Installs the Claude Code side: the /iz skill and a Stop hook that drops a
-- signal file into `.iz/` when the agent finishes a turn.
local storage = require("iz.storage")

local M = {}

M.SKILL_VERSION = 1
local SKILL_MARKER = "iz.nvim skill v"
local HOOK_MARKER = "# iz.nvim"

M.HOOK_COMMAND = '[ -d "$CLAUDE_PROJECT_DIR/.iz" ] && date +%s > "$CLAUDE_PROJECT_DIR/.iz/stop"; '
  .. "exit 0 "
  .. HOOK_MARKER

function M.skill_content()
  return table.concat({
    "---",
    "name: iz",
    "description: Address the open review comments from iz.nvim",
    "allowed-tools: Bash(cat *) Read Edit Write",
    "---",
    "",
    ("<!-- %s%d: managed by :IzInstallClaude -->"):format(SKILL_MARKER, M.SKILL_VERSION),
    "",
    "Current code review:",
    "",
    "!`cat .iz/brief.md`",
    "",
    "Rules:",
    "- Address each comment at its file:line; leave unrelated code alone.",
    "- If an image path is given, open and look at the image first.",
    "- When done, write the inbox file named at the end of the brief in a single Write,",
    '  one JSON line per comment: {"id", "claim", "note"}',
    "  (claim: addressed | declined | question).",
    "- Do not edit any other file under .iz/.",
    "",
    "$ARGUMENTS",
    "",
  }, "\n")
end

-- sha256 of every skill text iz has shipped; add the old one when the template changes.
local SHIPPED = {}

--- Whether `content` is a skill iz wrote itself, so replacing it loses nothing.
---@param content string
function M.is_template(content)
  local hash = vim.fn.sha256(content)
  return hash == vim.fn.sha256(M.skill_content()) or SHIPPED[hash] == true
end

---@param dir? string
local function claude_dir(dir)
  return dir or vim.env.CLAUDE_CONFIG_DIR or vim.fs.joinpath(vim.uv.os_homedir(), ".claude")
end

---@param path string
local function backup(path)
  if vim.uv.fs_stat(path) then
    assert(vim.uv.fs_copyfile(path, path .. ".bak"))
  end
end

---@param settings table
---@return boolean
local function has_hook(settings)
  local stop = type(settings.hooks) == "table" and settings.hooks.Stop
  if type(stop) ~= "table" then
    return false
  end
  for _, entry in ipairs(stop) do
    for _, h in ipairs(type(entry) == "table" and entry.hooks or {}) do
      if type(h.command) == "string" and h.command:find(HOOK_MARKER, 1, true) then
        return true
      end
    end
  end
  return false
end

---@param path string
---@return table
local function read_settings(path)
  local content = storage.read_file(path)
  if not content or vim.trim(content) == "" then
    return vim.empty_dict()
  end
  local ok, value = pcall(vim.json.decode, content)
  if not ok or type(value) ~= "table" then
    error(path .. " is not valid JSON; fix it or add the hook by hand", 0)
  end
  return value
end

---@class iz.InstallOpts
---@field dir? string Claude config dir, defaults to $CLAUDE_CONFIG_DIR or ~/.claude.
---@field confirm? fun(msg: string): boolean Asked before overwriting a hand-edited skill.

--- Installs or updates the skill and the Stop hook. Idempotent.
---@param opts? iz.InstallOpts
---@return string[] report one line per file
function M.install(opts)
  opts = opts or {}
  local dir = claude_dir(opts.dir)
  local report = {}

  local skill_path = vim.fs.joinpath(dir, "skills", "iz", "SKILL.md")
  local existing = storage.read_file(skill_path)
  local content = M.skill_content()
  if existing == content then
    report[#report + 1] = "skill unchanged: " .. skill_path
  else
    local hand_edited = existing and not M.is_template(existing)
    local replace = not hand_edited
      or (opts.confirm and opts.confirm(skill_path .. " was edited by hand. Replace it?"))
    if not replace then
      report[#report + 1] = "skill left as is: " .. skill_path
    else
      storage.mkdirp(vim.fs.dirname(skill_path))
      if hand_edited then
        backup(skill_path)
      end
      storage.write_atomic(skill_path, content)
      report[#report + 1] = (existing and "skill updated: " or "skill installed: ") .. skill_path
    end
  end

  local settings_path = vim.fs.joinpath(dir, "settings.json")
  local settings = read_settings(settings_path)
  if has_hook(settings) then
    report[#report + 1] = "Stop hook unchanged: " .. settings_path
  else
    if type(settings.hooks) ~= "table" then
      settings.hooks = vim.empty_dict()
    end
    if type(settings.hooks.Stop) ~= "table" then
      settings.hooks.Stop = {}
    end
    local entry = { hooks = { { type = "command", command = M.HOOK_COMMAND } } }
    table.insert(settings.hooks.Stop, entry)
    storage.mkdirp(dir)
    backup(settings_path)
    storage.write_json(settings_path, settings)
    report[#report + 1] = "Stop hook added: " .. settings_path
  end
  return report
end

--- Removes the skill and our Stop hook entry; leaves every other setting alone.
---@param opts? { dir?: string }
---@return string[] report
function M.uninstall(opts)
  local dir = claude_dir(opts and opts.dir)
  local report = {}
  local skill_dir = vim.fs.joinpath(dir, "skills", "iz")
  if vim.uv.fs_stat(skill_dir) then
    vim.fn.delete(skill_dir, "rf")
    report[#report + 1] = "skill removed: " .. skill_dir
  end

  local settings_path = vim.fs.joinpath(dir, "settings.json")
  local settings = read_settings(settings_path)
  if has_hook(settings) then
    local kept = {}
    for _, entry in ipairs(settings.hooks.Stop) do
      local hooks = vim.tbl_filter(function(h)
        return not (type(h.command) == "string" and h.command:find(HOOK_MARKER, 1, true))
      end, entry.hooks or {})
      if #hooks > 0 then
        entry.hooks = hooks
        kept[#kept + 1] = entry
      end
    end
    settings.hooks.Stop = #kept > 0 and kept or nil
    if vim.tbl_isempty(settings.hooks) then
      settings.hooks = nil
    end
    backup(settings_path)
    storage.write_json(settings_path, settings)
    report[#report + 1] = "Stop hook removed: " .. settings_path
  end
  if #report == 0 then
    report[#report + 1] = "nothing to remove"
  end
  return report
end

--- Which parts are installed, for :checkhealth.
---@param dir? string
function M.status(dir)
  dir = claude_dir(dir)
  local skill = storage.read_file(vim.fs.joinpath(dir, "skills", "iz", "SKILL.md"))
  local version = skill and tonumber(skill:match(SKILL_MARKER .. "(%d+)"))
  local ok, settings = pcall(read_settings, vim.fs.joinpath(dir, "settings.json"))
  return {
    skill = skill ~= nil,
    skill_current = version == M.SKILL_VERSION,
    hook = ok and has_hook(settings),
  }
end

return M
