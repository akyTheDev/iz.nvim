# iz renders its own diff instead of building on codediff.nvim

The original plan was to render diffs with codediff.nvim and layer iz's UI on top. codediff (v4.0.6) exposes only navigation functions as public API, declares `codediff.core` and `codediff.ui` internal, has its own explorer and stage/discard that would compete with iz's, ships native binaries, and broke compatibility across two major versions in one week; diffview.nvim has a better embedding API but is unmaintained. So iz takes Hunks from `git diff` (which it needs anyway, as patches for `git apply --cached`) and draws the views itself with its own buffers and extmarks, with no native dependency.

## Considered Options

- **codediff.nvim as renderer**: best-looking diffs, but every integration point is internal (see codediff issue #577, unanswered).
- **diffview.nvim as renderer**: documented `CDiffView` API and hooks, but no commits since 2024 and no inline mode.

## Consequences

- "Writing the diff renderer" moves from out-of-scope into the MVP.
- codediff's `compute_diff` can still be added later as an optional adapter for finer character-level highlighting.
