# iz.nvim

Review the code your AI agent wrote without leaving Neovim, send it line-precise comments, and check its answers until the work is done.

```
:Iz  →  review, stage, comment  →  /iz in Claude Code  →  agent fixes and replies  →  :Iz  →  … → :IzDone
```

- **Staging is approval.** Stage a Hunk when you're happy with it. The next pass shows only what you haven't approved, including agent changes on top of approved code.
- **Comments go back with exact lines.** The agent gets a compact Brief (`.iz/brief.md`) with `file:line` for every comment it has to act on, not a vague paragraph.
- **The agent claims, you decide.** The agent replies `addressed`, `declined` or `question`; only you resolve a comment.
- **One Session per task.** Each Session diffs against a snapshot taken when it opened, so the previous task's uncommitted work stays out of the way.

No MCP server and no background process: Neovim and the agent talk only through files in `.iz/`.

## Requirements

- Neovim 0.10+ (0.12 recommended for character-level diff highlights)
- git
- Optional: `pngpaste` (macOS), `wl-paste` or `xclip` (Linux) for pasting screenshots into comments

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "akythedev/iz.nvim",
  version = "*", -- latest release; drop it to follow main
  cmd = { "Iz", "IzDone", "IzExport", "IzInstallClaude" },
  opts = {},
}
```

Then, once:

```vim
:IzInstallClaude
```

This writes the `/iz` skill to `~/.claude/skills/iz/SKILL.md` and adds a Stop hook to `~/.claude/settings.json`, so iz knows when the agent finishes a turn. The hook does nothing in projects without `.iz/`. A backup is written next to `settings.json`, and `:IzInstallClaude!` removes both again. Check the setup with `:checkhealth iz`.

## The loop

1. Give the agent a task.
2. `:Iz` opens the workspace: files on the left, the Base on the middle-left, the working tree on the middle-right, and comments on the right once there are any.
3. Stage what you approve and comment on what you don't.
4. Run `/iz` in Claude Code. It reads the Brief, fixes the code and writes its replies to `.iz/inbox/`.
5. iz picks up the replies and changes. With the filter (`<leader>if` / `f`) you see only what you haven't approved yet.
6. Resolve comments whose fix you've checked, or reply to send them back.
7. `:IzDone` when the task is finished, then start the next one with `:Iz`.

Using another agent? `:IzExport` copies the Brief, inbox instructions included, to the clipboard. Any agent that can write a file can answer.

## Keys

| Where | Key | Action |
| --- | --- | --- |
| File list | `<CR>` | open file in the diff |
| | `s` / `u` / `x` | stage / unstage / discard the file |
| | `U` | undo the last discard |
| | `c` | comment on the file |
| | `f` | toggle "unstaged only" |
| | `p` | toggle the comment panel |
| | `R` / `q` | refresh / close |
| Diff | `]h` / `[h` | next / previous hunk (continues into the next file) |
| | `<leader>is` / `iu` / `ix` | stage / unstage / discard hunk (visual: every hunk in range) |
| | `<leader>iU` | undo the last discard |
| | `<leader>ic` | comment on the line (visual: on the range) |
| | `<leader>iC` | comment on the hunk |
| | `<leader>if` / `ip` / `iq` | filter / panel / close |
| Panel | `<CR>` | go to the comment |
| | `a` | reply |
| | `r` / `i` / `o` | resolve / ignore / reopen |
| | `m` | move a comment to the cursor line in the diff |
| Comment editor | `<C-s>` or `:w` | save |
| | `q` | cancel |
| | `<C-v>` (insert) | paste a screenshot (falls back to normal `<C-v>`) |

Diff-window keys use `<leader>i` because the right side is your real file and stays editable. Your own edits show up as Unstaged like the agent's.

## Commands

| Command | |
| --- | --- |
| `:Iz` | open the workspace, starting a Session if none is active |
| `:Iz comment` | comment on the whole Session (screenshots welcome) |
| `:Iz history` | browse past Sessions and their threads |
| `:IzDone` | close the Session; open comments are ignored after you confirm |
| `:IzExport` | copy the Brief for any agent |
| `:IzInstallClaude[!]` | install (or remove) the Claude Code skill and hook |

## Configuration

Defaults, all optional:

```lua
require("iz").setup({
  files_width = 42,
  panel_width = 56,
  keymaps = {
    paste_image = "<C-v>",
    files = { open = "<CR>", stage = "s", unstage = "u", discard = "x", undo_discard = "U",
              toggle_filter = "f", comment = "c", toggle_panel = "p", refresh = "R", close = "q" },
    diff = { stage = "<leader>is", unstage = "<leader>iu", discard = "<leader>ix",
             undo_discard = "<leader>iU", toggle_filter = "<leader>if", comment = "<leader>ic",
             comment_hunk = "<leader>iC", toggle_panel = "<leader>ip", next_hunk = "]h",
             prev_hunk = "[h", close = "<leader>iq" },
    panel = { jump = "<CR>", reply = "a", resolve = "r", ignore = "i", reopen = "o",
              move = "m", close = "q" },
  },
})
```

Set a key to `""` to disable it. Highlight groups (`IzStaged`, `IzNewSinceApproval`, `IzComment`, `IzClaim`, …) are defined with `default = true`, so your colorscheme can override them.

## Files

`.iz/` lives at the repository root and is added to `.git/info/exclude`; your `.gitignore` is never touched.

```
.iz/
├── brief.md        what the agent reads (written by Neovim)
├── inbox/          agent replies, one file per Brief (written by the agent)
├── current         id of the active Session
└── sessions/<id>/  session.json, discarded hunks (trash/), screenshots (assets/)
```

## Development

```sh
make test
```

The domain language is in [CONTEXT.md](CONTEXT.md), the design decisions in [docs/adr/](docs/adr/), and the conventions for contributors and agents in [AGENTS.md](AGENTS.md).
