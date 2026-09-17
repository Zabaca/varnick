# Machines rebuild from git and zmx at launch; nothing is persisted

A Restart is how landed work starts running, so it is frequent. At launch the Host reads `git worktree list` and `zmx ls` and builds its actors from what it finds; no Snapshot is written to disk or restored. Git and zmx are already the durable state, and a persisted snapshot that disagrees with them is the class of bug the previous version's session mirror produced for seven launches running.
