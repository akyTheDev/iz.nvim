if vim.g.loaded_iz then
  return
end
vim.g.loaded_iz = true

local command = vim.api.nvim_create_user_command

command("Iz", function(args)
  require("iz.commands").iz(args.fargs)
end, {
  nargs = "*",
  bar = true,
  desc = "Open the iz review workspace",
  complete = function()
    return require("iz.commands").subcommands()
  end,
})

command("IzDone", function()
  require("iz.commands").done()
end, { bar = true, desc = "Close the active iz session" })

command("IzExport", function()
  require("iz.commands").export()
end, { bar = true, desc = "Copy the Brief to the clipboard for any agent" })

command("IzInstallClaude", function(args)
  require("iz.commands").install_claude(args.bang)
end, {
  bang = true,
  bar = true,
  desc = "Install the /iz skill and Stop hook for Claude Code (! removes them)",
})

local group = vim.api.nvim_create_augroup("iz", { clear = true })

vim.api.nvim_create_autocmd({ "VimEnter", "DirChanged" }, {
  group = group,
  callback = function()
    require("iz.signal").start()
  end,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function()
    local ws = package.loaded["iz.ui.workspace"] and require("iz.ui.workspace").get()
    if ws and not ws.readonly then
      require("iz.storage.lock").release(ws.root)
    end
  end,
})
