# Claude Code TZ Fix

A Codex/Claude Code skill for hardening the local `claude` startup environment against two independent signals: **timezone** and **network exit IP** (`ANTHROPIC_BASE_URL`).

## The two problems

**1. Timezone.** An `Asia/Shanghai` / `Asia/Urumqi` label leaks region. Two levels:

- **Level 1** — `Etc/GMT-8`: keeps UTC+8 / Beijing-aligned time, but drops the explicit China label.
- **Level 2** — `America/Los_Angeles`: switches Claude Code to US Pacific time. Stronger, but "today/yesterday/tomorrow" follow Pacific time.

**2. Network exit (`ANTHROPIC_BASE_URL`).** This is the subtle one, so be precise:

> Anthropic never sees the `ANTHROPIC_BASE_URL` variable. It only sees the **exit IP** of whatever machine finally connects to it.
>
> ```
> claude ──> relay ══(relay's own IP)══> Anthropic   ← only this IP is visible
> ```

That means:

- You **can't hide a relay's IP** while using the relay — Anthropic sees the relay's exit, period.
- You **can't "clean" a dirty IP** — reputation lives in Anthropic's systems, not yours. You can only **swap** to a clean exit.
- A **shared** commercial relay = a shared, flagged exit = high risk. A **self-hosted** relay on your own VPS = a clean, dedicated exit = as good as a clean direct connection.

So the fix for problem 2 is not "delete the variable." It's: **measure whether the exit is dirty, then either connect directly (clean VPN) or swap to your own clean relay.** This skill's default is to **leave your relay alone** and help you decide.

## Install

```bash
mkdir -p ~/.codex/skills
cp -R claude-code-tz-fix ~/.codex/skills/
```

Or place it wherever your Codex/Claude Code skills live.

## Use

Diagnose (includes an exit-IP check):

```bash
bash scripts/claude-code-tz-fix.sh diagnose
```

Check the exit IP in isolation — is the current path dirty?

```bash
bash scripts/claude-code-tz-fix.sh check-ip
```

Apply a timezone level, plus a base-url mode if the exit needs changing:

```bash
bash scripts/claude-code-tz-fix.sh apply level2                          # timezone only, relay left alone (default: keep)
bash scripts/claude-code-tz-fix.sh apply level2 strip                    # force direct connection (needs a clean VPN)
bash scripts/claude-code-tz-fix.sh apply level2 https://relay.example.com # route through your OWN clean relay
```

Stand up your own clean relay (guided):

```bash
bash scripts/claude-code-tz-fix.sh gen-vps
```

Verify / self-test:

```bash
bash scripts/claude-code-tz-fix.sh verify level2
bash scripts/claude-code-tz-fix.sh self-test
```

## Base-url modes

| Mode | Effect | Use when |
| --- | --- | --- |
| `keep` (default) | Leaves `ANTHROPIC_BASE_URL` untouched | You don't want to risk breaking a relay you depend on |
| `strip` | `unset ANTHROPIC_BASE_URL`, direct to `api.anthropic.com` | You have a clean direct route (VPN) |
| `<https-url>` | Pins `ANTHROPIC_BASE_URL` to your own relay | You self-host a clean relay (see `gen-vps`) |

## Guided flow to swap a dirty exit for a clean one

`gen-vps` writes `claude-relay-vps-setup.sh` (a Caddy reverse proxy to `api.anthropic.com`) and prints the steps:

1. Rent a VPS with a clean, dedicated IP (US/JP/SG; avoid blacklisted datacenter ranges).
2. Point a domain's A record at the VPS.
3. Run the generated script on the VPS: `sudo bash claude-relay-vps-setup.sh your.domain.com`.
4. Locally: `apply level2 https://your.domain.com`.
5. Confirm: `check-ip`.

The skill scaffolds and verifies; **you provide the VPS.** It never asks for or uses your VPS credentials.

## What it changes

By default it does not overwrite npm or Homebrew launchers. It creates a managed wrapper:

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

## A clean exit is necessary, not sufficient

A clean US exit for `claude` paired with a **China login IP** on `anthropic.com` is itself a signal. Align the exit region with your login region (and the timezone this skill sets). Login IP, billing region, account history, and browser/device signals are separate and out of scope for this skill.

## License

MIT
