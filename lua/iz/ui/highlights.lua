local M = {}

M.ns = vim.api.nvim_create_namespace("iz")

local groups = {
  IzStaged = { link = "Comment" },
  IzStagedMark = { link = "DiagnosticOk" },
  IzNewSinceApproval = { link = "DiagnosticWarn" },
  IzDirectory = { link = "Directory" },
  IzKindAdded = { link = "Added" },
  IzKindChanged = { link = "Changed" },
  IzKindRemoved = { link = "Removed" },
  IzPartial = { link = "DiagnosticWarn" },
  IzUnstaged = { link = "DiagnosticInfo" },
  IzMuted = { link = "Comment" },
  IzComment = { link = "DiagnosticInfo" },
  IzClaim = { link = "DiagnosticHint" },
  IzThreadUser = { link = "Title" },
  IzThreadAgent = { link = "Special" },
  IzThreadCoreviewer = { link = "Constant" },
  IzSuggestion = { link = "DiagnosticHint" },
  IzSummary = { link = "Normal" },
  IzSummaryOutdated = { link = "Comment" },
}

function M.setup()
  for name, spec in pairs(groups) do
    -- `default` lets colorschemes and users override every group.
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", spec, { default = true }))
  end
end

return M
