# Varnick

## Agent skills

### Issue tracker

Work starts from a problem in `docs/problems/<slug>/` (committed); each option file there is the spec. Tickets live as local markdown under `.scratch/<feature>/issues/` (gitignored). See `docs/agents/issue-tracker.md`.

### Triage labels

The five default triage roles, each label string equal to its name. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## Writing docs, agents and skills

Each meaning lives in one place; everywhere else points to it. Agents in `.claude/agents/` say only their role, the skills they load and what differs for Varnick, and point to `docs/agents/`, `CODING_STANDARDS.md` and the rest for everything else. Leave to the environment what it already answers (the source tree, the `Makefile`, `git log`); write down only what looking can't find: conventions, reasons, gotchas. When creating or editing any of these, load `mattpocock-skills:writing-for-agents`.

## Working here

- Build and run through the `Makefile` (`make build`, `make run`): it also codesigns and fetches the prebuilt `mlx.metallib` that plain `swift build` lacks.
- Restarting Varnick ends every Claude session open in it, possibly the one you're running in. `make run` restarts it however it was started. `launchctl kickstart -k` restarts only an instance the LaunchAgent started, and beside one `make run` started it starts a second Varnick. Leave restarts to the user unless they ask for one.
- No test target yet: verification is `make build`, then checking by hand after a restart.

## Coding standards

How code here is wired and styled: see `CODING_STANDARDS.md`. What a change can break even when it follows them: see `docs/agents/where-it-breaks.md`.
