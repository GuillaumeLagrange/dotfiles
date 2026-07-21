### Session based workflow

- Define an env var for the whole zellij session so that these tools are aware which session is active
  - avoid having something too rigid -> we should easily have the different repos back up to the "original" repo
- entrypoint = branch name `cod-2931-prepare-compatibility-with-vitest-5`
- create a subdirectory `cod-2931/platform`
  - OR: simply `cod-2931--platform` (or `cod-2931-platform`)
- easy way to add/remove repos to the session worktree? both at creation and while created
- easy way to clean up
- easy way to move stuff back into the "main" workspace
- Have a high level way of saying "i want to pop back into this"
  - Auto check out branches across the repos if available?
  - "force resync" of an existing outdated zellij session, or at least a way to handle drift
- Problem: how to manage having a terminal on screen while having vim on the other for a given session?
- Zellij session name should not just be `cod-2931`, much more readable this way
