---
title: Skip permissions still asks before an `rm` Claude Code can't resolve
description: A session started with Skip permissions still stops on rm and rmdir aimed at a critical path (root, home, the working directory or a parent of it) or at a target Claude Code can't resolve statically, such as `cd dir && rm -f out/h-wide/*`. The prompt reads "Dangerous rm operation on statically-unresolvable target". Bypass mode, allow rules and hooks don't approve it. Anyone who runs unattended sessions with Skip permissions on stalls at that prompt.
impact: An unattended session stops on a prompt nobody sees, and a routine cleanup in a build folder blocks it. The only way past it today is to start claude by hand with an environment variable Varnick never sets.
severity: low
evidence: Claude Code's permission-modes documentation, section "Turn off the critical-path removal prompt in bypassPermissions mode" (code.claude.com/docs/en/permission-modes.md), read 2026-11-11. It names `CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS=1` (Claude Code 2.1.311 and later), read from the launch environment only and effective only in bypassPermissions mode.
status: closed
---
