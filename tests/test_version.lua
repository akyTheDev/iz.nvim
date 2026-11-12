local H = require("tests.helpers")

local T = MiniTest.new_set()

-- release-please bumps both; if only one moves, its config is wrong.
T["the version matches the release manifest"] = function()
  -- Other tests chdir into temp repos, so find the manifest from the plugin's own files.
  local source = vim.api.nvim_get_runtime_file("lua/iz/version.lua", false)[1]
  local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
  local manifest = vim.json.decode(H.read(root, ".release-please-manifest.json"))
  H.eq(require("iz").version, manifest["."])
  H.eq(require("iz").version:match("^%d+%.%d+%.%d+$") ~= nil, true)
end

return T
