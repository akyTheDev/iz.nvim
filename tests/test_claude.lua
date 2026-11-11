local H = require("tests.helpers")
local claude = require("iz.claude")
local storage = require("iz.storage")

local T = MiniTest.new_set()

local function temp_dir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return dir
end

T["installs the skill and the hook, and is idempotent"] = function()
  local dir = temp_dir()
  local report = claude.install({ dir = dir })
  H.eq(report[1]:match("^skill installed"), "skill installed")
  H.eq(report[2]:match("^Stop hook added"), "Stop hook added")

  local skill = storage.read_file(dir .. "/skills/iz/SKILL.md")
  H.eq(skill:find("!`cat .iz/brief.md`", 1, true) ~= nil, true)
  local settings = storage.read_json(dir .. "/settings.json")
  H.eq(settings.hooks.Stop[1].hooks[1].type, "command")

  local again = claude.install({ dir = dir })
  H.eq(again[1]:match("^skill unchanged"), "skill unchanged")
  H.eq(again[2]:match("^Stop hook unchanged"), "Stop hook unchanged")
  H.eq(#storage.read_json(dir .. "/settings.json").hooks.Stop, 1)
  H.eq(claude.status(dir), { skill = true, skill_current = true, hook = true })
end

T["keeps every other setting and hook"] = function()
  local dir = temp_dir()
  storage.write_json(dir .. "/settings.json", {
    model = "opus",
    permissions = { allow = { "Bash(make test)" } },
    hooks = {
      Stop = { { hooks = { { type = "command", command = "say done" } } } },
      PreToolUse = { { matcher = "Bash", hooks = { { type = "command", command = "audit" } } } },
    },
  })
  claude.install({ dir = dir })
  local s = storage.read_json(dir .. "/settings.json")
  H.eq(s.model, "opus")
  H.eq(s.permissions.allow, { "Bash(make test)" })
  H.eq(s.hooks.PreToolUse[1].hooks[1].command, "audit")
  H.eq(#s.hooks.Stop, 2)
  H.eq(vim.uv.fs_stat(dir .. "/settings.json.bak") ~= nil, true)

  claude.uninstall({ dir = dir })
  s = storage.read_json(dir .. "/settings.json")
  H.eq(s.hooks.Stop, { { hooks = { { type = "command", command = "say done" } } } })
  H.eq(s.hooks.PreToolUse[1].hooks[1].command, "audit")
  H.eq(vim.uv.fs_stat(dir .. "/skills/iz"), nil)
end

T["asks before replacing a hand-edited skill"] = function()
  local dir = temp_dir()
  H.write(dir, "skills/iz/SKILL.md", "my own skill\n")
  local report = claude.install({
    dir = dir,
    confirm = function()
      return false
    end,
  })
  H.eq(report[1]:match("^skill left as is"), "skill left as is")
  H.eq(storage.read_file(dir .. "/skills/iz/SKILL.md"), "my own skill\n")

  claude.install({
    dir = dir,
    confirm = function()
      return true
    end,
  })
  H.eq(storage.read_file(dir .. "/skills/iz/SKILL.md.bak"), "my own skill\n")
  H.eq(claude.status(dir).skill_current, true)
end

T["refuses to rewrite a settings.json that is not valid JSON"] = function()
  local dir = temp_dir()
  H.write(dir, "settings.json", "{ broken")
  H.eq(pcall(claude.install, { dir = dir }), false)
  H.eq(storage.read_file(dir .. "/settings.json"), "{ broken")
end

T["the hook writes the signal only in projects that use iz"] = function()
  local with_iz = H.repo()
  vim.fn.mkdir(with_iz .. "/.iz", "p")
  local without = H.repo()
  for _, root in ipairs({ with_iz, without }) do
    local res = vim.system({ "sh", "-c", claude.HOOK_COMMAND }, {
      env = { CLAUDE_PROJECT_DIR = root },
    }):wait()
    H.eq(res.code, 0)
    H.eq(res.stdout, "")
  end
  H.eq(vim.uv.fs_stat(with_iz .. "/.iz/stop") ~= nil, true)
  H.eq(vim.uv.fs_stat(without .. "/.iz"), nil)
end

return T
