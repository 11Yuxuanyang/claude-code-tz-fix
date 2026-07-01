---
name: claude-code-tz-fix
description: Diagnose and harden Claude Code startup environment against local timezone and ANTHROPIC_BASE_URL signals. Use when the user asks to inspect Claude Code regional detection, hide Asia/Shanghai or Asia/Urumqi from Claude Code, clear ANTHROPIC_BASE_URL for Claude Code, choose between UTC+8 non-China timezone protection and full US timezone protection, or make the Claude Code command default to a safer wrapper.
---

# Claude Code TZ Fix

## Overview

Use this skill to diagnose and patch the local `claude` command so Claude Code starts with a controlled timezone and without `ANTHROPIC_BASE_URL`.

There are two protection levels:

- **Level 1: UTC+8, non-China label** — set Claude Code to `Etc/GMT-8`. Time stays aligned with Beijing, but the timezone name is not `Asia/Shanghai` or `Asia/Urumqi`.
- **Level 2: US time** — set Claude Code to `America/Los_Angeles`. This is stronger because the timezone offset and label both stop looking like China. The tradeoff is that Claude Code's "today/yesterday/tomorrow" may follow US Pacific time.

## Workflow

1. Run diagnosis before changing anything:

   ```bash
   bash /Users/yuxuanyang/life-os/skills/claude-code-tz-fix/scripts/claude-code-tz-fix.sh diagnose
   ```

2. If the user explicitly chooses a level, apply that level. If they do not choose, explain the tradeoff and ask for the level.

   ```bash
   # Level 1: keep UTC+8 but hide the China timezone label
   bash /Users/yuxuanyang/life-os/skills/claude-code-tz-fix/scripts/claude-code-tz-fix.sh apply level1

   # Level 2: use US Pacific time
   bash /Users/yuxuanyang/life-os/skills/claude-code-tz-fix/scripts/claude-code-tz-fix.sh apply level2
   ```

3. Verify after applying:

   ```bash
   bash /Users/yuxuanyang/life-os/skills/claude-code-tz-fix/scripts/claude-code-tz-fix.sh verify level1
   bash /Users/yuxuanyang/life-os/skills/claude-code-tz-fix/scripts/claude-code-tz-fix.sh verify level2
   ```

4. When editing the skill or script, run the self-test:

   ```bash
   bash /Users/yuxuanyang/life-os/skills/claude-code-tz-fix/scripts/claude-code-tz-fix.sh self-test
   ```

## What The Script Changes

The script uses a managed wrapper instead of overwriting npm or Homebrew launchers:

- `~/.local/bin/claude-code-tz-fix/claude` — a controlled wrapper that clears `ANTHROPIC_BASE_URL`, hard-sets the selected `TZ`, preserves the user's existing `--dangerously-skip-permissions` default when detected, then execs the real Claude Code binary.
- `~/.zshrc` — appends or replaces only the managed block between `# BEGIN claude-code-tz-fix` and `# END claude-code-tz-fix`.

The script creates timestamped backups before edits. It does not mutate `~/.npm-global/bin/claude` or `/opt/homebrew/bin/claude` by default.

## Decision Rules

- Use **Level 1** when the user wants minimal side effects and only needs to avoid explicit `Asia/Shanghai` / `Asia/Urumqi` signals.
- Use **Level 2** when the user wants the harder stance and accepts US-date side effects.
- If an unmanaged `claude()` function already exists, leave it intact. The managed block is appended later in `.zshrc`, so zsh resolves `claude` to the managed function without deleting user code.
- Never claim this solves all Anthropic account risk. It only handles the local Claude Code startup signals covered by this workflow. Login IP, billing region, account history, browser/device signals, and server-side risk systems are separate.

## Reporting Back

Keep the answer short:

- Say which level is active.
- Say which files were changed.
- Say whether `claude --version` still works.
- Mention the tradeoff if Level 2 is active: Claude Code sees US Pacific date/time.
