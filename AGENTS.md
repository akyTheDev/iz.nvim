# AGENTS.md

Guidance for AI agents and humans working on iz.nvim.

## What this is

A Neovim plugin for reviewing code an AI agent wrote and sending line-precise feedback back to it.

Read `CONTEXT.md` before changing behaviour: it is the domain language. Use its terms (Session, Base, Hunk, Staged, Comment, Reply, Status, Claim, Anchor, Brief) in code, tests and messages; avoid the words it lists under _Avoid_.

## Commands

```sh
make test                              # all tests (clones mini.nvim into deps/ on first run)
make test FILE=tests/test_ops.lua      # one file
```

Tests run in headless Neovim with `scripts/minimal_init.lua`. CI runs them on Neovim stable and nightly.

Type check (config in `.luarc.json`); keep it at zero problems:

```sh
VIMRUNTIME=$(nvim --headless --clean -c 'lua io.write(vim.env.VIMRUNTIME)' -c q) \
  lua-language-server --check=. --checklevel=Warning
```

## Layout

```
lua/iz/
  async.lua          coroutine runner: async.run / await / block_on
  git/init.lua       the only place that spawns git (git.run)
  git/diff.lua       unified diff parser and patch builder
  git/trees.lua      Base snapshot and index/work-tree snapshots on a temp index
  git/hunks.lua      Session view: Hunks between Base and the work tree, Staged/Unstaged
  git/ops.lua        stage / unstage / discard / undo
  session/init.lua   session.json lifecycle (create, load, open, complete)
  storage/           .iz/ paths, atomic JSON, lock
  diff/backend.lua   the diff-drawing seam; native.lua is the only backend
  ui/workspace.lua   the review tab: layout, actions, refresh, keymaps
  ui/files.lua       file list rendering (pure: render() returns lines + highlights)
  ui/highlights.lua  highlight groups (all `default = true`) and the shared namespace
  session/comments.lua  Comment / Reply model; Status and Claim rules
  session/anchor.lua    capture and relocation of Anchors (exact match only)
  ui/editor.lua      floating markdown editor for comments and replies
  ui/inline.lua      open comments as virtual lines in the diff
  ui/panel.lua       comment panel rendering (pure render + draw): a summary per Comment
  ui/thread.lua      a Comment's whole thread in a float, with reply/resolve keys
  ui/help.lua        `?`: the keys of the current window, read from config
  ui/format.lua      labels shared by panel, inline and thread (location, "line changed")
  clipboard.lua      clipboard image -> PNG file
  brief.lua          renders .iz/brief.md, the agent's only input
  inbox.lua          parses .iz/inbox/*.jsonl into agent Replies
  claude.lua         installs/removes the /iz skill and the Stop hook
  signal.lua         watches .iz/stop (written by the Stop hook)
  lifecycle.lua      :IzDone and session history
  health.lua         :checkhealth iz
  version.lua        the release version, bumped by release-please
doc/iz.txt           :help iz; keep it in sync with README.md when keys or commands change
  commands.lua       :Iz subcommand registry; plugin/iz.lua only wires commands
tests/               test_*.lua (mini.test) + helpers.lua
```

## Rules that keep the design intact

- **Never block the event loop on git.** Call `git.run` inside `async.run`; it yields until git exits. `vim.system():wait()` and `async.block_on` are for tests only.
- **The user's index changes only on an explicit stage or unstage.** Anything that needs a tree (snapshots, diffs) works on a temp index via `GIT_INDEX_FILE`, see `git/trees.lua`. A temp index must keep the original index's mtime, or git trusts stale stat data and misses same-size edits (racy git).
- **Never edit the user's Claude Code config by hand-rolled string edits.** `claude.lua` parses `settings.json`, adds or removes only entries marked `# iz.nvim`, keeps a `.bak`, and refuses invalid JSON. Hook commands must exit 0 with no output: anything else changes Claude's behaviour.
- **Async UI work must not race.** Anything that awaits and then replaces shared state (`W.view`, the file shown) runs inside `exclusive()` in `workspace.lua`. It is not re-entrant: call `show()` from inside it, never `exclusive()` again.
- **One writer per file.** Neovim writes `session.json` (atomically, through `storage.write_json`); the agent writes only to `.iz/inbox/`. Keep it that way. A read-only Neovim re-reads `session.json` instead of trusting its copy, and reloads it when it takes the lock over. Only the lock owner consumes `.iz/stop`.
- **Ids come from `util.random_hex`**, not `math.random`, which starts from the same seed in every Neovim.
- **Approval lives in the git index.** Staged means approved. Don't add a "reviewed" flag: it would drift from what the user actually commits.
- **Refuse stale operations.** Hunk ops recompute the file and fail with `ops.STALE` rather than apply a patch to code the user hasn't seen.
- **`.iz/` stays invisible:** excluded via `.git/info/exclude`, never `.gitignore`, and filtered from every file list.
- **Bump `session.SCHEMA_VERSION`** when `session.json` changes shape, and keep loading older versions or fail loudly; never silently overwrite.
- **Something staged before a Session opens is part of its Base**, not an approval. Tests that need a Staged hunk must open the Session first, then stage.
- **Status changes only through `comments.set_status`**, and only from user actions. Agent input goes through `comments.agent_reply`, which can't touch Status. A Claim is derived from the last message; never store it separately.
- **The Brief is a token budget.** Only Comments waiting for the agent, grouped by file, one line each; snippets only for lost Anchors and deleted lines; from a thread only the agent's last note and the reviewer's latest message. Any change to its format needs a test in `test_brief.lua` that pins the exact text.
- **Agent input is untrusted data.** Validate every inbox line (id exists, claim is one of three); never let it change Status, files, or anything outside the thread.
- **Anchors match exactly or get lost.** No fuzzy matching: a lost Comment is visible and fixable, a misplaced one is not. Old-side (`side = "old"`) Comments point at Base lines and are never relocated.

## UI conventions

- The right diff window is the user's real, editable file. Never map plain editing keys there (`s`, `u`, `x`, `c`...): diff-window keys use the `<leader>i` prefix; plain keys are fine only in iz's own read-only buffers. Remove buffer-local maps from real buffers when the workspace closes.
- Don't change global options (`diffopt`, `fillchars`...). Window-local options are fine on iz's windows.
- Replace a scratch buffer by putting the new one into its window first. Wiping a buffer that a window still shows closes the window (see `place_scratch` in `diff/native.lua`). Match buffers by exact name; `bufnr()` also matches partially.
- On close, clear iz namespaces from every buffer, not just the ones in iz windows: `:tabclose` can remove the windows first.
- User commands take `bar = true` so they chain with `|`.
- An action that runs git on a file refuses while that file's buffer has unsaved changes.
- UI work goes through `job()` in `workspace.lua` so errors surface as notifications and tests can wait on `workspace.idle()`.
- Hunk positions come from the file on disk; refuse hunk actions while the buffer has unsaved changes.
- Every highlight group is `default = true` and linked to a standard group, so colorschemes and users can override it.
- Keep rendering pure where possible (`files.render` returns lines and highlight ranges); test the pure part, then test the wiring with a real workspace in `test_workspace.lua`.

## Code style

- Lua formatted to `.stylua.toml` (2 spaces, 100 columns, double quotes). Run `stylua lua plugin tests` before committing; CI does not check it yet.
- LuaCATS annotations (`---@class`, `---@param`) on public functions and data shapes; they are the type documentation.
- Comments in English, only where the code can't say it: why something is done, a non-obvious invariant, a workaround. No comments that restate the code.
- Errors meant for users are plain strings without a stack (`error(msg, 0)`); the caller decides how to show them.
- Small modules with a narrow public surface (`local M = {} ... return M`); keep helpers `local`.

## Tests

- Every behaviour change ships with a test. Git behaviour is tested against a real temporary repo (`H.repo()`), not mocks.
- Wrap async code in `H.run(function() ... end)` (`async.block_on`).
- Name cases by the behaviour they protect ("a stale hunk is refused"), not by the function they call.
- When a test passes on the first try, make sure it can fail: break the code or the assertion once.
- A flaky test is a bug report, not noise. Run the suite several times after touching async or file-watching code; find the cause before adding waits (the racy-git fix came from one).
- Tests that depend on the clock (same-second edits, debounce) say so in a comment and wait explicitly.
- Tests reproduce the real order of events. The user usually opens `:Iz` *after* the agent worked, and `.iz/` may not exist when Neovim starts; tests that set things up in a friendlier order hid two bugs.

## Commits and releases

- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org): `feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `ci:`, `chore:`. release-please reads them to pick the next version and write `CHANGELOG.md`, so the type matters: only `feat` and `fix` (and `!` for breaking changes) reach the changelog.
- Mark breaking changes with `!` (`feat!: ...`) or a `BREAKING CHANGE:` footer; they bump the major version, and users pinned to `1.x` won't get them until they choose to. A `session.SCHEMA_VERSION` bump, a removed command or a changed default key is breaking.
- Don't edit `CHANGELOG.md`, `version.txt`, `lua/iz/version.lua` or `.release-please-manifest.json` by hand; merging the release PR that release-please opens on `main` updates them and tags the release (`vX.Y.Z`).

## Checking UI changes by eye

Unit tests don't show what the screen looks like. After a visible change, drive a real Neovim in tmux and read the screen:

```sh
tmux new-session -d -s iz -x 190 -y 24 "cd <demo repo> && nvim --clean --cmd 'set rtp^=<this repo>'"
tmux send-keys -t iz ':Iz' Enter; sleep 2; tmux capture-pane -t iz -p
```

You can stand in for the agent by editing files, writing `.iz/inbox/<brief-id>.jsonl` and touching `.iz/stop`. Four bugs were found this way.

## Language

Code, comments, UI strings, the Brief and these docs are in English.

`README.md` is the source of truth; `README.tr.md` is its Turkish translation. Change both in the same commit and keep the same sections in the same order, so a missing update shows up in the diff. Domain terms (Session, Hunk, Brief, Staged...) and everything in code blocks stay in English in the translation. `doc/iz.txt` is English only.
