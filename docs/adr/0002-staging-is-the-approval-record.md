# The git index is the record of approval

A Hunk is approved by staging it; iz keeps no separate "reviewed" flag. This makes the second pass trivial (index vs working tree is exactly what still needs a look) and reuses a tool the user already trusts, at the cost of tying approval to the index. iz deliberately does not restrict or detect the agent running `git add`/`git commit`: telling the agent not to touch the index is the user's call, and code the agent stages shows as approved.

## Consequences

- Each Session's Base is a snapshot of the index (`git write-tree`) taken when it opens, not HEAD, so uncommitted approved work from the previous Task does not leak into the next Session and commits during a Session do not shift the diff.
- The user's own edits during a Review are treated exactly like the agent's: they show as Unstaged until staged.
