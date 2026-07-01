# Claude Code TZ Fix

A Codex/Claude Code skill for hardening the local `claude` startup environment against timezone and `ANTHROPIC_BASE_URL` signals.

It provides two levels:

- **Level 1**: `Etc/GMT-8` — keeps UTC+8 / Beijing-aligned time, but avoids the explicit `Asia/Shanghai` or `Asia/Urumqi` timezone labels.
- **Level 2**: `America/Los_Angeles` — switches Claude Code to US Pacific time. Stronger, but "today/yesterday/tomorrow" follow Pacific time.

The script also clears `ANTHROPIC_BASE_URL` for Claude Code and preserves an existing `--dangerously-skip-permissions` default when detected.

## Install

Copy this repository into your skills directory:

```bash
mkdir -p ~/.codex/skills
cp -R claude-code-tz-fix ~/.codex/skills/
```

Or, if your Codex skills are symlinked to another source directory, place it there.

## Use

Diagnose first:

```bash
bash scripts/claude-code-tz-fix.sh diagnose
```

Apply Level 1:

```bash
bash scripts/claude-code-tz-fix.sh apply level1
```

Apply Level 2:

```bash
bash scripts/claude-code-tz-fix.sh apply level2
```

Verify:

```bash
bash scripts/claude-code-tz-fix.sh verify level2
```

Run the isolated self-test:

```bash
bash scripts/claude-code-tz-fix.sh self-test
```

## What It Changes

By default it does not overwrite npm or Homebrew launchers.

It creates:

```text
~/.local/bin/claude-code-tz-fix/claude
```

and manages only this block in `~/.zshrc`:

```text
# BEGIN claude-code-tz-fix
...
# END claude-code-tz-fix
```

Backups are created before edits.

## Scope

This only handles local Claude Code startup signals. It does not claim to solve broader account, billing, login IP, browser/device, or server-side risk checks.

## License

MIT
