local M = {}

function M.check()
  local h = vim.health
  h.start("iz.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    local v = vim.version()
    h.ok(("Neovim %d.%d.%d"):format(v.major, v.minor, v.patch))
  else
    h.error("Neovim 0.10 or newer is required")
  end

  if vim.fn.executable("git") == 1 then
    h.ok("git found")
  else
    h.error("git not found on PATH")
  end

  local status = require("iz.claude").status()
  if not status.skill then
    h.warn("Claude Code skill not installed", { "Run :IzInstallClaude" })
  elseif not status.skill_current then
    h.warn(
      "Claude Code skill is outdated or edited by hand",
      { "Run :IzInstallClaude to update it" }
    )
  else
    h.ok("Claude Code skill installed")
  end
  if status.hook then
    h.ok("Claude Code Stop hook installed")
  else
    h.warn(
      "Claude Code Stop hook missing; iz won't know when the agent finishes",
      { "Run :IzInstallClaude" }
    )
  end

  if vim.fn.has("mac") == 1 then
    if vim.fn.executable("pngpaste") == 1 then
      h.ok("image paste: pngpaste")
    else
      h.ok("image paste: osascript (install pngpaste for a faster path)")
    end
  elseif vim.fn.executable("wl-paste") == 1 or vim.fn.executable("xclip") == 1 then
    h.ok("image paste: " .. (vim.fn.executable("wl-paste") == 1 and "wl-paste" or "xclip"))
  else
    h.warn("image paste unavailable", { "Install wl-paste (Wayland) or xclip (X11)" })
  end

  if pcall(require, "snacks") then
    h.ok("snacks.nvim found")
  else
    h.info("snacks.nvim not found (optional)")
  end
end

return M
