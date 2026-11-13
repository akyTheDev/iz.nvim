-- Installs the Claude Code side: the /iz, /iz-coreview and /iz-summary skills,
-- and a Stop hook that drops a signal file into `.iz/` when the agent finishes
-- a turn.
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

--- The Co-reviewer: a second agent, in a fresh context, that reviews the
--- changes before the user and leaves Suggestions. It never edits code and
--- never talks to the agent; the user decides what gets sent.
function M.coreview_content()
  return table.concat({
    "---",
    "name: iz-coreview",
    "description: Review the uncommitted changes as iz.nvim's co-reviewer and leave"
      .. " suggestions for the user",
    "argument-hint: [review skill or what to focus on]",
    "context: fork",
    "agent: general-purpose",
    "background: false",
    "disable-model-invocation: true",
    "allowed-tools: Bash(git diff *) Bash(git status *) Bash(git ls-files *) Bash(date *)"
      .. " Bash(mkdir -p .iz/coreview) Read Grep Glob Write Skill",
    "---",
    "",
    ("<!-- %s%d: managed by :IzInstallClaude -->"):format(SKILL_MARKER, M.SKILL_VERSION),
    "",
    "You are the co-reviewer. Another agent wrote the uncommitted changes in this",
    "repository; the user reviews them in iz.nvim right after you. You do not edit",
    "code and you do not fix anything: you only leave suggestions. The user reads",
    "each one and decides whether to send it to the agent.",
    "",
    "1. See what changed: `git status --short`, `git diff` for tracked files, and",
    "   read untracked files in full. Read surrounding code when a change needs it.",
    "2. Review. If the user named a review skill below, use it (through the Skill",
    "   tool) and follow its criteria. Otherwise look for bugs, missing cases,",
    "   broken contracts and risks; leave style alone. Be selective: every",
    "   suggestion costs the user a decision.",
    "3. `mkdir -p .iz/coreview`, then write all suggestions in a single Write to",
    "   `.iz/coreview/<stamp>.jsonl`, where <stamp> is !`date +%Y%m%d-%H%M%S`",
    "   One JSON object per line:",
    '   {"file": "src/a.lua", "line": 12, "end_line": 14, "body": "…"}',
    "   - `file` is relative to the repository root; `line` and `end_line` are",
    "     1-based lines of the file as it is now. `end_line` is optional.",
    "   - Leave out `line` for a note on a whole file, and `file` too for a note",
    "     on the whole change.",
    "   - `body` says what is wrong and why, in a sentence or two, so the agent",
    "     can act on it if the user sends it.",
    "4. Do not touch any other file under .iz/. Answer with one line: how many",
    "   suggestions you left, and that the user can review them with :Iz.",
    "",
    "$ARGUMENTS",
    "",
  }, "\n")
end

--- Summaries come from the agent that wrote the code, in the same
--- conversation: only it knows why. Run on request, for larger changes.
function M.summary_content()
  return table.concat({
    "---",
    "name: iz-summary",
    "description: Summarize, for the iz.nvim reviewer, what you changed in each larger file"
      .. " and why",
    "argument-hint: [minimum changed lines, default 20]",
    "disable-model-invocation: true",
    "allowed-tools: Bash(git diff *) Bash(git ls-files *) Bash(date *)"
      .. " Bash(mkdir -p .iz/summaries) Write",
    "---",
    "",
    ("<!-- %s%d: managed by :IzInstallClaude -->"):format(SKILL_MARKER, M.SKILL_VERSION),
    "",
    "Lines added and removed per tracked file:",
    "",
    "!`git diff --numstat`",
    "",
    "New, untracked files:",
    "",
    "!`git ls-files --others --exclude-standard`",
    "",
    "Minimum changed lines (20 when empty): $ARGUMENTS",
    "",
    "For each file you changed in this task whose added plus removed lines reach",
    "the minimum (a new file counts all its lines), write a short summary for the",
    "user who reviews it next in iz.nvim:",
    "- 1 to 3 sentences, from what you know of this task: why the file changed",
    "  and what to look at first. Don't restate the diff; the user sees it.",
    "- Skip files you didn't change and files below the minimum.",
    "",
    "`mkdir -p .iz/summaries`, then write them in a single Write to",
    "`.iz/summaries/<stamp>.jsonl`, where <stamp> is !`date +%Y%m%d-%H%M%S`",
    "One JSON object per line, `file` relative to the repository root:",
    '{"file": "src/a.lua", "summary": "…"}',
    "",
    "Do not edit any other file under .iz/. Answer with one line: which files you",
    "summarised.",
    "",
  }, "\n")
end

---@class iz.SkillSpec
---@field name string
---@field content fun(): string

---@type iz.SkillSpec[]
M.SKILLS = {
  { name = "iz", content = M.skill_content },
  { name = "iz-coreview", content = M.coreview_content },
  { name = "iz-summary", content = M.summary_content },
}

-- sha256 of every skill text iz has shipped; add the old one when the template changes.
local SHIPPED = {}

--- Whether `content` is a skill iz wrote itself, so replacing it loses nothing.
---@param content string
function M.is_template(content)
  local hash = vim.fn.sha256(content)
  for _, skill in ipairs(M.SKILLS) do
    if hash == vim.fn.sha256(skill.content()) then
      return true
    end
  end
  return SHIPPED[hash] == true
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

---@param dir string
---@param skill iz.SkillSpec
---@param opts iz.InstallOpts
---@return string report
local function install_skill(dir, skill, opts)
  local skill_path = vim.fs.joinpath(dir, "skills", skill.name, "SKILL.md")
  local existing = storage.read_file(skill_path)
  local content = skill.content()
  if existing == content then
    return "skill unchanged: " .. skill_path
  end
  local hand_edited = existing and not M.is_template(existing)
  local replace = not hand_edited
    or (opts.confirm and opts.confirm(skill_path .. " was edited by hand. Replace it?"))
  if not replace then
    return "skill left as is: " .. skill_path
  end
  storage.mkdirp(vim.fs.dirname(skill_path))
  if hand_edited then
    backup(skill_path)
  end
  storage.write_atomic(skill_path, content)
  return (existing and "skill updated: " or "skill installed: ") .. skill_path
end

--- Installs or updates the skills and the Stop hook. Idempotent.
---@param opts? iz.InstallOpts
---@return string[] report one line per file
function M.install(opts)
  opts = opts or {}
  local dir = claude_dir(opts.dir)
  local report = {}
  for _, skill in ipairs(M.SKILLS) do
    report[#report + 1] = install_skill(dir, skill, opts)
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

--- Removes the skills and our Stop hook entry; leaves every other setting alone.
---@param opts? { dir?: string }
---@return string[] report
function M.uninstall(opts)
  local dir = claude_dir(opts and opts.dir)
  local report = {}
  for _, skill in ipairs(M.SKILLS) do
    local skill_dir = vim.fs.joinpath(dir, "skills", skill.name)
    if vim.uv.fs_stat(skill_dir) then
      vim.fn.delete(skill_dir, "rf")
      report[#report + 1] = "skill removed: " .. skill_dir
    end
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

--- Which parts are installed, for :checkhealth. `skill` and `skill_current`
--- hold only when every skill is installed and current.
---@param dir? string
function M.status(dir)
  dir = claude_dir(dir)
  local installed, current = true, true
  for _, skill in ipairs(M.SKILLS) do
    local text = storage.read_file(vim.fs.joinpath(dir, "skills", skill.name, "SKILL.md"))
    local version = text and tonumber(text:match(SKILL_MARKER .. "(%d+)"))
    installed = installed and text ~= nil
    current = current and version == M.SKILL_VERSION
  end
  local ok, settings = pcall(read_settings, vim.fs.joinpath(dir, "settings.json"))
  return {
    skill = installed,
    skill_current = current,
    hook = ok and has_hook(settings),
  }
end

return M
