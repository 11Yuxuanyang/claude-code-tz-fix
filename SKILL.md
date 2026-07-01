---
name: claude-code-tz-fix
description: Diagnose and harden the local Claude Code startup environment against timezone and exit-IP signals. Use when the user asks to inspect Claude Code regional detection, hide Asia/Shanghai or Asia/Urumqi from Claude Code, decide what to do about ANTHROPIC_BASE_URL / a third-party relay, check whether their relay exit IP looks dirty, verify whether a third-party relay's upstream is genuinely Anthropic (not a watered-down or swapped model), or set up their own clean self-hosted relay so Claude Code connects from a clean, dedicated IP.
---

# Claude Code TZ Fix

## Overview

Use this skill to diagnose and patch the local `claude` command so Claude Code starts with a controlled timezone and a deliberate, understood network exit.

It addresses two independent startup signals:

1. **Timezone** — a `Asia/Shanghai` / `Asia/Urumqi` label leaks region. Fixed by hard-setting `TZ`.
2. **Network exit (`ANTHROPIC_BASE_URL`)** — a third-party relay changes *which IP Anthropic sees your traffic coming from*.

### What is actually true about `ANTHROPIC_BASE_URL` (read before acting)

Anthropic **never sees the `ANTHROPIC_BASE_URL` variable itself.** It is a local setting that only tells `claude` *where to send the request*. What Anthropic sees is the **exit IP of the machine that finally connects to it**:

```
claude ──> relay ══(relay's own IP connects to anthropic)══> Anthropic
                                                                ↑ only this IP is visible
```

Consequences that drive every decision in this skill:

- You **cannot hide a relay's IP** while still using the relay. If you route through a relay, Anthropic sees the relay's exit IP — full stop. Wanting it to see "your own IP" instead means connecting **directly**, which is not using a relay at all.
- You **cannot "clean" a dirty IP.** An IP's reputation lives in Anthropic's (and third parties') systems; you can't edit it. The only real move is to **swap to a different, clean exit IP.**
- A **shared** commercial relay = a shared, frequently-flagged exit IP = high risk. A **self-hosted** relay on your own VPS = a dedicated, clean exit IP = same effect as a clean direct connection.

So the second problem is not "strip the variable." It is: **figure out whether the current exit is dirty, and if so, swap to a clean one.**

## Timezone levels

- **Level 1: UTC+8, non-China label** — `Etc/GMT-8`. Time stays Beijing-aligned, but the label is not `Asia/Shanghai` / `Asia/Urumqi`.
- **Level 2: US time** — `America/Los_Angeles`. Stronger: offset and label both stop looking like China. Tradeoff: Claude Code's "today/yesterday/tomorrow" follow US Pacific time.

## Base-url modes (the second problem)

`apply` takes an optional third argument controlling `ANTHROPIC_BASE_URL`. **Default is `keep` — never silently break a user who depends on their relay.**

- **`keep`** (default) — leave `ANTHROPIC_BASE_URL` untouched. Safe default.
- **`strip`** — `unset ANTHROPIC_BASE_URL`, forcing a direct connection to `api.anthropic.com`. Only correct if the user has a clean direct route (VPN).
- **`<https-url>`** — pin `ANTHROPIC_BASE_URL` to the user's **own** clean relay, e.g. `https://relay.example.com`.

## Workflow

1. **Diagnose** (includes an exit-IP check):

   ```bash
   bash scripts/claude-code-tz-fix.sh diagnose
   ```

2. **Check the exit** in isolation — is the current path dirty?

   ```bash
   bash scripts/claude-code-tz-fix.sh check-ip
   ```

   It reports the direct exit IP + geo, and (if a base-url is set) the relay entry IP + geo, flagging a China entry. It is honest about its limit: the relay's *exit* IP can't be measured from the client; the entry geo is only a hint — but for a self-hosted VPS relay, entry == exit, so it is accurate.

3. **Probe the relay's upstream** — is it really Anthropic, or watered down?

   ```bash
   bash scripts/claude-code-tz-fix.sh probe-relay              # probes ANTHROPIC_BASE_URL / wrapper-pinned relay
   bash scripts/claude-code-tz-fix.sh probe-relay https://some-relay.example.com
   ```

   Needs `ANTHROPIC_API_KEY` (or `ANTHROPIC_AUTH_TOKEN`). It asks for the **expensive
   models** — `claude-opus-4-8` and `claude-sonnet-4-6` — because those are what a
   watered-down relay downgrades; **haiku is deliberately not probed** (nobody bothers
   swapping it). With tiny `max_tokens`, per model it checks four hard-to-fake-together
   fingerprints: official response headers (`request-id`, `anthropic-ratelimit-*`,
   `cf-ray`), body structure (`type: message`, `id: msg_…`, `usage`), `count_tokens`
   consistency (its token count must match the message's `usage.input_tokens`), and
   the **downgrade check** — is the model you asked for the model you got back? Reports
   per model: genuine Anthropic / real-Anthropic-behind-a-relay / **model swap** /
   suspicious. An honest relay echoes the real backend model, so a downgrade shows up
   in the model field; a relay that lies there is still caught by the other three
   fingerprints. Override the model list with `CLAUDE_TZ_FIX_PROBE_MODELS`.

   Risk: the probe exits from the **same IP** as normal use, so it adds a few normal
   requests of exposure — the risk is that exit IP (if dirty), not the probe itself.
   For zero added risk, switch to a clean exit first.

4. **Apply.** Choose a timezone level, and a base-url mode if the exit needs changing:

   ```bash
   # Timezone only, leave the relay alone (safe default)
   bash scripts/claude-code-tz-fix.sh apply level2

   # Force direct connection (only with a clean VPN)
   bash scripts/claude-code-tz-fix.sh apply level2 strip

   # Route through the user's own clean relay
   bash scripts/claude-code-tz-fix.sh apply level2 https://relay.example.com
   ```

5. **If the exit is dirty and the user wants to fix it: guided self-hosted relay.**

   ```bash
   bash scripts/claude-code-tz-fix.sh gen-vps
   ```

   This scaffolds `claude-relay-vps-setup.sh` (a Caddy reverse proxy to `api.anthropic.com`) and prints the step-by-step flow:
   1. Rent a VPS with a clean, dedicated IP (US/JP/SG; avoid blacklisted datacenter ranges).
   2. Point a domain's A record at the VPS.
   3. Run the generated script on the VPS.
   4. `apply level2 https://your.domain.com` locally.
   5. `check-ip` to confirm the exit changed.

   The skill scaffolds and verifies; **the user provides the VPS** (renting hardware and running the command on their box is theirs to do — do not ask for or use their VPS credentials).

6. **Verify:**

   ```bash
   bash scripts/claude-code-tz-fix.sh verify level2
   ```

7. **Self-test** when editing the script (hermetic, no network):

   ```bash
   bash scripts/claude-code-tz-fix.sh self-test
   ```

## What The Script Changes

A managed wrapper, never the npm/Homebrew launchers:

- `~/.local/bin/claude-code-tz-fix/claude` — sets the chosen `TZ`, applies the chosen base-url mode (`keep` / `strip` / pin-to-relay), preserves an existing `--dangerously-skip-permissions` default when detected, then execs the real binary.
- `~/.zshrc` — appends/replaces only the block between `# BEGIN claude-code-tz-fix` and `# END claude-code-tz-fix`.

Timestamped backups are created before edits. `~/.npm-global/bin/claude` and `/opt/homebrew/bin/claude` are not touched by default.

## Decision Rules

- **Timezone**: Level 1 for minimal side effects; Level 2 for the harder stance (accepts US-date side effects).
- **Base-url**: default to `keep`. Only `strip` when `check-ip` shows the user has a clean direct route. Only pin a `<url>` when it is the user's **own** clean relay.
- Never claim you can hide a relay's IP or clean a dirty IP. The honest options are: use a clean direct route, or stand up a clean self-hosted exit.
- **Consistency matters more than a clean exit alone.** A clean US exit for `claude` paired with a China login IP on `anthropic.com` is itself a signal. Advise aligning the exit region with the login region (and the timezone already set).
- If an unmanaged `claude()` already exists, leave it intact; the managed block is appended later so zsh resolves to it.
- This only handles local Claude Code startup signals. Login IP, billing region, account history, browser/device signals, and server-side risk systems are separate and out of scope.

## Reporting Back

Keep it short:

- Which timezone level is active, and which base-url mode.
- What `check-ip` showed (direct exit geo; relay entry geo if any; whether it looks dirty).
- Which files changed and whether `claude --version` still works.
- Mention the Level 2 tradeoff (US Pacific date/time) and the consistency point if relevant.
