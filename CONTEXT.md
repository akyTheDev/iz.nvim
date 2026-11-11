# iz.nvim

A Neovim plugin for reviewing code written by an AI coding agent and sending line-precise feedback back to it, then checking the agent's answers until the work is approved.

## Language

### Units of work

**Task**:
The piece of work the user hands to the agent. Lives outside iz; iz never models it directly.
_Avoid_: using it as a synonym for Session

**Session**:
One review loop over the changes produced for a single Task, measured against its Base. Each git worktree has at most one active Session.
_Avoid_: Review (as a noun for the loop), review session

**Base**:
The snapshot of the git index taken when a Session opens; the Session's diff is everything that changed since it. Untracked files are never part of it, so files the agent created before the Session opened still show up as new.
_Avoid_: base commit, HEAD

**Review**:
The act of looking at the Session's changes and approving or commenting on them. A verb, not a thing that is stored.

**Hunk**:
One contiguous block of change between the Base and the working tree; the unit of approval and of discarding.

**Staged**:
A Hunk whose whole content is in the git index, meaning the user has approved it. The index is the record of approval; there is no separate "reviewed" flag.
_Avoid_: reviewed, approved (as a stored state)

**Unstaged**:
A Hunk with any content not yet in the index, whoever wrote it: new agent changes, agent changes on top of an approved Hunk, and the user's own edits.

### Feedback

**Comment**:
Feedback anchored to a line, a Hunk, a file, or the whole Session, made of a root message and its Replies.
_Avoid_: note, annotation

**Reply**:
One message in a Comment's thread, written either by the user or by the agent.
_Avoid_: response, answer

**Brief**:
The compact, prompt-ready digest of every open Comment in the active Session whose latest message is the user's. The only input the agent receives from iz.
_Avoid_: review.md, export, summary

**Anchor**:
The place in the code a Comment is attached to. An Anchor is either found or lost; a lost Anchor does not change the Comment's Status.
_Avoid_: stale (as a Status)

**Status**:
Where a Comment stands from the user's side: `open`, `resolved`, or `ignored`. Only the user sets it; the agent never does.

**Claim**:
What the agent's Reply asserts about a Comment (`addressed`, `declined`, or `question`), present only while the agent wrote the latest Reply. A Claim never closes a Comment; a new Reply from the user clears it.
_Avoid_: wont_fix, agent status
