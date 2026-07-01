#!/usr/bin/env bash
set -euo pipefail

ZSHRC="${ZSHRC:-$HOME/.zshrc}"
SAFE_WRAPPER="${CLAUDE_CODE_SAFE_WRAPPER:-$HOME/.local/bin/claude-code-tz-fix/claude}"
REAL_CLAUDE="${CLAUDE_CODE_REAL_BIN:-$HOME/.npm-global/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe}"
NPM_CLAUDE="${CLAUDE_CODE_NPM_ENTRY:-$HOME/.npm-global/bin/claude}"
HOMEBREW_CLAUDE="${HOMEBREW_CLAUDE:-/opt/homebrew/bin/claude}"
BEGIN_MARKER="# BEGIN claude-code-tz-fix"
END_MARKER="# END claude-code-tz-fix"

usage() {
  cat <<'EOF'
Usage:
  claude-code-tz-fix.sh diagnose
  claude-code-tz-fix.sh check-ip
  claude-code-tz-fix.sh apply   level1|level2 [keep|strip|<https-url>]
  claude-code-tz-fix.sh verify  level1|level2
  claude-code-tz-fix.sh gen-vps
  claude-code-tz-fix.sh self-test

Timezone levels:
  level1  Etc/GMT-8               UTC+8, non-China timezone label
  level2  America/Los_Angeles     US Pacific time

Base-url modes (3rd arg to apply; default: keep):
  keep    Leave ANTHROPIC_BASE_URL untouched. Safe default: never breaks a
          relay the user depends on.
  strip   unset ANTHROPIC_BASE_URL, forcing a direct connection to
          api.anthropic.com. Only safe if the user has a clean direct route.
  <url>   Pin ANTHROPIC_BASE_URL to the user's OWN clean relay, e.g.
          https://relay.example.com (see: gen-vps).

Why base-url matters (read this):
  Anthropic never sees ANTHROPIC_BASE_URL itself. It only sees the exit IP of
  whatever machine finally connects to it. A shared third-party relay means a
  dirty, shared exit IP. You cannot "clean" a dirty IP or hide a relay's IP;
  you can only SWAP to a clean exit. `check-ip` measures how dirty the current
  path looks; `gen-vps` scaffolds a self-hosted relay with a clean, dedicated IP.
EOF
}

tz_for_level() {
  case "${1:-}" in
    level1|1|utc8|beijing-safe|gmt8) printf '%s\n' "Etc/GMT-8" ;;
    level2|2|us|usa|pacific|la) printf '%s\n' "America/Los_Angeles" ;;
    *) return 1 ;;
  esac
}

resolve_base_url_mode() {
  local arg="${1:-}"
  local mode="${arg:-${CLAUDE_TZ_FIX_BASE_URL:-keep}}"
  case "$mode" in
    keep|strip) printf '%s\n' "$mode" ;;
    http://*|https://*) printf '%s\n' "$mode" ;;
    *)
      printf 'ERROR: base-url mode must be keep|strip|<http(s) url>, got: %s\n' "$mode" >&2
      return 2
      ;;
  esac
}

backup_path() {
  local path="$1" ts
  ts="$(date +%Y%m%d-%H%M%S)"
  if [ -e "$path" ] || [ -L "$path" ]; then
    cp -a "$path" "$path.bak.$ts"
    printf 'Backup: %s\n' "$path.bak.$ts"
  fi
}

find_real_claude() {
  if [ -x "$REAL_CLAUDE" ]; then
    printf '%s\n' "$REAL_CLAUDE"
    return 0
  fi

  for candidate in \
    "$HOME/.npm-global/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe" \
    "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  printf 'ERROR: Cannot find real Claude Code binary. Set CLAUDE_CODE_REAL_BIN.\n' >&2
  return 1
}

has_dangerous_default() {
  [ -e "$ZSHRC" ] && grep -q -- "--dangerously-skip-permissions" "$ZSHRC"
}

# ---------------------------------------------------------------------------
# Exit-IP diagnosis (network, best-effort)
# ---------------------------------------------------------------------------

url_host() {
  printf '%s\n' "$1" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#/.*$##; s#@.*$##; s#:[0-9]+$##'
}

resolve_host() {
  local host="$1"
  command -v python3 >/dev/null 2>&1 || return 0
  HOST_VALUE="$host" python3 -c '
import os, socket, sys
try:
    print(socket.gethostbyname(os.environ["HOST_VALUE"]))
except Exception:
    sys.exit(0)
'
}

# geo_lookup [ip]  ->  "COUNTRYCODE|COUNTRY|CITY|ORG|IP"  (empty on failure)
# Empty ip queries this machine's own direct exit IP.
geo_lookup() {
  local ip="${1:-}"
  command -v curl >/dev/null 2>&1 || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  local url="http://ip-api.com/json/${ip}?fields=status,country,countryCode,city,isp,org,as,query"
  local json
  json="$(curl -fsS --max-time 6 "$url" 2>/dev/null)" || return 0
  [ -n "$json" ] || return 0
  BASE_JSON="$json" python3 -c '
import json, os, sys
try:
    d = json.loads(os.environ["BASE_JSON"])
except Exception:
    sys.exit(0)
if d.get("status") == "success":
    print("|".join(str(d.get(k, "")) for k in ("countryCode", "country", "city", "org", "query")))
'
}

check_ip() {
  printf '== Exit IP check ==\n'
  if ! command -v curl >/dev/null 2>&1; then
    printf '  curl not available; skipping IP check.\n'
    return 0
  fi

  local direct cc country city org query
  direct="$(geo_lookup "")"
  if [ -n "$direct" ]; then
    IFS='|' read -r cc country city org query <<<"$direct"
    printf '  Direct exit (no relay): %s  [%s %s / %s]\n' "$query" "$cc" "$country" "$org"
  else
    printf '  Direct exit (no relay): <lookup failed / offline>\n'
  fi

  local base="${ANTHROPIC_BASE_URL:-}"
  if [ -z "$base" ]; then
    local wm
    wm="$(wrapper_base_url_mode)"
    case "$wm" in
      http://*|https://*)
        base="$wm"
        printf '  (env unset; using base-url pinned in managed wrapper: %s)\n' "$base"
        ;;
    esac
  fi

  if [ -z "$base" ]; then
    printf '  ANTHROPIC_BASE_URL: <unset> -> claude connects directly to api.anthropic.com\n'
  else
    local host ip relay
    host="$(url_host "$base")"
    ip="$(resolve_host "$host")"
    printf '  Relay: %s  (host %s -> %s)\n' "$base" "$host" "${ip:-<unresolved>}"
    if [ -n "$ip" ]; then
      relay="$(geo_lookup "$ip")"
      if [ -n "$relay" ]; then
        IFS='|' read -r cc country city org query <<<"$relay"
        printf '  Relay entry IP:  %s  [%s %s / %s]\n' "$query" "$cc" "$country" "$org"
        if [ "$cc" = "CN" ]; then
          printf '  [!] Relay entry sits in China (CN) -> high-risk exit signal. Swap to a clean exit.\n'
        fi
      fi
    fi
    printf '  Note: Anthropic sees the relay EXIT IP (relay -> anthropic), which a client cannot measure.\n'
    printf '        The entry geo above is only a hint. For a self-hosted VPS relay, entry == exit, so it is accurate.\n'
  fi

  printf '  Consistency: this exit region should match the IP you log into anthropic.com with.\n'
  printf '               A China login IP + US exit IP is itself a risk signal.\n'
}

# ---------------------------------------------------------------------------
# Wrapper + managed zshrc block
# ---------------------------------------------------------------------------

write_safe_wrapper() {
  local tz="$1" real_bin="$2" dangerous_default="$3" base_url_mode="$4"
  mkdir -p "$(dirname "$SAFE_WRAPPER")"
  backup_path "$SAFE_WRAPPER"

  local marker directive
  case "$base_url_mode" in
    keep)
      marker="keep"
      directive="# ANTHROPIC_BASE_URL left untouched (mode: keep)"
      ;;
    strip)
      marker="strip"
      directive="unset ANTHROPIC_BASE_URL"
      ;;
    http://*|https://*)
      marker="redirect"
      directive="export ANTHROPIC_BASE_URL=\"$base_url_mode\""
      ;;
    *)
      printf 'ERROR: invalid base-url mode: %s\n' "$base_url_mode" >&2
      return 1
      ;;
  esac

  cat > "$SAFE_WRAPPER" <<EOF
#!/usr/bin/env bash
# Managed by claude-code-tz-fix. Do not edit by hand; re-run apply instead.
# base-url mode: $marker
$directive
export TZ="$tz"
DEFAULT_ARGS=()
if [ "$dangerous_default" = "1" ]; then
  DEFAULT_ARGS+=(--dangerously-skip-permissions)
fi
exec "$real_bin" "\${DEFAULT_ARGS[@]}" "\$@"
EOF
  chmod +x "$SAFE_WRAPPER"
  printf 'Wrote managed wrapper: %s (base-url mode: %s)\n' "$SAFE_WRAPPER" "$base_url_mode"
}

wrapper_base_url_mode() {
  if [ ! -f "$SAFE_WRAPPER" ]; then
    printf 'unknown\n'
    return
  fi
  local m
  m="$(sed -n 's/^# base-url mode: //p' "$SAFE_WRAPPER" | head -n1)"
  case "$m" in
    keep|strip)
      printf '%s\n' "$m"
      ;;
    redirect)
      grep -E '^export ANTHROPIC_BASE_URL=' "$SAFE_WRAPPER" \
        | sed -E 's/^export ANTHROPIC_BASE_URL="?([^"]*)"?.*/\1/' \
        | head -n1
      ;;
    *)
      printf 'unknown\n'
      ;;
  esac
}

update_zshrc_managed_block() {
  local level="$1" tz="$2" base_url_mode="$3"
  [ -e "$ZSHRC" ] || touch "$ZSHRC"
  backup_path "$ZSHRC"
  BEGIN_MARKER_VALUE="$BEGIN_MARKER" \
  END_MARKER_VALUE="$END_MARKER" \
  SAFE_WRAPPER_VALUE="$SAFE_WRAPPER" \
  LEVEL_VALUE="$level" \
  TZ_VALUE="$tz" \
  BASE_URL_MODE_VALUE="$base_url_mode" \
  python3 - "$ZSHRC" <<'PY'
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
begin = os.environ["BEGIN_MARKER_VALUE"]
end = os.environ["END_MARKER_VALUE"]
safe_wrapper = os.environ["SAFE_WRAPPER_VALUE"]
level = os.environ["LEVEL_VALUE"]
tz = os.environ["TZ_VALUE"]
base_url_mode = os.environ["BASE_URL_MODE_VALUE"]

text = path.read_text() if path.exists() else ""
lines = text.splitlines(keepends=True)

out = []
inside = False
for line in lines:
    if line.rstrip("\n") == begin:
        inside = True
        continue
    if line.rstrip("\n") == end:
        inside = False
        continue
    if not inside:
        out.append(line)

block = (
    f"{begin}\n"
    f"# Managed by claude-code-tz-fix. Level: {level}. TZ: {tz}. base-url: {base_url_mode}.\n"
    "claude() {\n"
    f"    {safe_wrapper} \"$@\"\n"
    "}\n"
    f"{end}\n"
)

if out and not out[-1].endswith("\n"):
    out[-1] += "\n"
if out and out[-1].strip():
    out.append("\n")
out.append(block)

path.write_text("".join(out))
PY
  printf 'Updated managed zsh block: %s\n' "$ZSHRC"
}

diagnose_unmanaged_claude_function() {
  if [ ! -e "$ZSHRC" ]; then
    return 0
  fi
  if grep -q '^claude() {' "$ZSHRC" && ! grep -qF "$BEGIN_MARKER" "$ZSHRC"; then
    printf 'Note: existing unmanaged claude() found in %s. Apply will append a managed block later in the file, leaving existing code intact.\n' "$ZSHRC"
  fi
}

diagnose() {
  printf '== Claude Code TZ diagnosis ==\n'
  printf 'which claude: '
  command -v claude || true

  printf '\nCurrent shell signals:\n'
  printf '  TZ=%s\n' "${TZ:-<unset>}"
  if [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
    printf '  ANTHROPIC_BASE_URL=<set>\n'
  else
    printf '  ANTHROPIC_BASE_URL=<unset>\n'
  fi

  if command -v node >/dev/null 2>&1; then
    printf '  node timezone: '
    node -p "Intl.DateTimeFormat().resolvedOptions().timeZone + ' | ' + new Date().toString()" || true
  fi

  diagnose_unmanaged_claude_function

  printf '\nManaged files:\n'
  for path in "$ZSHRC" "$SAFE_WRAPPER"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      printf -- '--- %s\n' "$path"
      ls -l "$path" || true
      if [ "$path" = "$ZSHRC" ]; then
        awk "/${BEGIN_MARKER}/{flag=1} flag{print} /${END_MARKER}/{flag=0}" "$path" || true
      else
        sed -n '1,12p' "$path" 2>/dev/null || true
      fi
    else
      printf -- '--- %s missing\n' "$path"
    fi
  done

  printf '\nUnmanaged Claude entries, not modified by default:\n'
  for path in "$NPM_CLAUDE" "$HOMEBREW_CLAUDE"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      ls -l "$path" || true
    else
      printf '%s missing\n' "$path"
    fi
  done

  if [ "${CLAUDE_TZ_FIX_SKIP_IP_CHECK:-0}" != "1" ]; then
    printf '\n'
    check_ip
  fi
}

apply_level() {
  local level="$1" mode_arg="${2:-}"
  local tz real_bin dangerous_default base_url_mode
  tz="$(tz_for_level "$level")" || {
    usage
    return 2
  }
  base_url_mode="$(resolve_base_url_mode "$mode_arg")" || {
    usage
    return 2
  }

  diagnose
  real_bin="$(find_real_claude)"
  if has_dangerous_default; then
    dangerous_default="1"
  else
    dangerous_default="0"
  fi

  write_safe_wrapper "$tz" "$real_bin" "$dangerous_default" "$base_url_mode"
  update_zshrc_managed_block "$level" "$tz" "$base_url_mode"

  case "$base_url_mode" in
    keep)
      printf 'base-url: kept as-is. If your relay is a shared/dirty exit, run check-ip and consider gen-vps.\n'
      ;;
    strip)
      printf 'base-url: stripped. claude now connects directly to api.anthropic.com -- make sure you have a clean direct route.\n'
      ;;
    http://*|https://*)
      printf 'base-url: pinned to your relay %s. Run check-ip to confirm the exit IP is clean.\n' "$base_url_mode"
      ;;
  esac

  verify_level "$level"
}

assert_wrapper_content() {
  local tz="$1" mode="$2"
  grep -qF "export TZ=\"$tz\"" "$SAFE_WRAPPER"
  case "$mode" in
    keep) grep -qF "# base-url mode: keep" "$SAFE_WRAPPER" ;;
    strip) grep -qF "unset ANTHROPIC_BASE_URL" "$SAFE_WRAPPER" ;;
    http://*|https://*) grep -qF "export ANTHROPIC_BASE_URL=\"$mode\"" "$SAFE_WRAPPER" ;;
    *) : ;;
  esac
  if grep -qE 'Asia/Shanghai|Asia/Urumqi' "$SAFE_WRAPPER"; then
    printf 'ERROR: China timezone label found in wrapper.\n' >&2
    return 1
  fi
}

verify_level() {
  local level="$1" tz mode
  tz="$(tz_for_level "$level")" || {
    usage
    return 2
  }
  mode="$(wrapper_base_url_mode)"

  printf '== Verify Claude Code TZ fix (tz: %s, base-url: %s) ==\n' "$tz" "$mode"
  assert_wrapper_content "$tz" "$mode"

  if command -v node >/dev/null 2>&1; then
    printf '  selected node timezone: '
    TZ="$tz" node -p "Intl.DateTimeFormat().resolvedOptions().timeZone + ' | ' + new Date().toString()"
  fi

  printf '  managed wrapper version: '
  "$SAFE_WRAPPER" --version

  if [ "${CLAUDE_TZ_FIX_SKIP_ZSH_VERIFY:-0}" != "1" ] && command -v zsh >/dev/null 2>&1; then
    printf '  interactive zsh version: '
    zsh -ic 'claude --version'
  fi
}

# ---------------------------------------------------------------------------
# Self-hosted clean relay scaffolding
# ---------------------------------------------------------------------------

gen_vps() {
  local out="${CLAUDE_TZ_FIX_VPS_SCRIPT:-$PWD/claude-relay-vps-setup.sh}"
  cat > "$out" <<'VPSEOF'
#!/usr/bin/env bash
# Self-hosted Anthropic relay on YOUR OWN clean VPS (Debian/Ubuntu).
# This gives Claude Code a dedicated, clean exit IP instead of a shared relay.
#
# Run this ON THE VPS as root, AFTER pointing an A record of your domain at it:
#   sudo bash claude-relay-vps-setup.sh your.domain.com
set -euo pipefail
DOMAIN="${1:?usage: claude-relay-vps-setup.sh your.domain.com}"

apt-get update
apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
apt-get update
apt-get install -y caddy

# Caddy auto-provisions HTTPS for $DOMAIN and reverse-proxies to Anthropic.
cat > /etc/caddy/Caddyfile <<CADDY
${DOMAIN} {
    reverse_proxy https://api.anthropic.com {
        header_up Host api.anthropic.com
    }
}
CADDY

systemctl restart caddy
echo
echo "Relay is up at https://${DOMAIN}"
echo "On your local machine, point Claude Code at it:"
echo "  bash claude-code-tz-fix.sh apply level2 https://${DOMAIN}"
VPSEOF
  chmod +x "$out"
  printf 'Wrote VPS relay setup script: %s\n\n' "$out"
  printf 'Guided flow to swap a dirty exit for a clean one:\n'
  printf '  1) Rent a VPS with a clean, dedicated IP (US/JP/SG; avoid blacklisted datacenter ranges).\n'
  printf '  2) Point an A record (your.domain.com) at the VPS IP.\n'
  printf '  3) Copy %s to the VPS and run:  sudo bash %s your.domain.com\n' "$(basename "$out")" "$(basename "$out")"
  printf '  4) Back here:  bash %s apply level2 https://your.domain.com\n' "$(basename "$0")"
  printf '  5) Confirm the exit changed:  bash %s check-ip\n' "$(basename "$0")"
  printf '\nNote: the VPS itself is infrastructure you provide. This script only scaffolds the relay;\n'
  printf 'it does not rent hardware or touch your VPS for you.\n'
}

# ---------------------------------------------------------------------------
# Self-test (hermetic; no network)
# ---------------------------------------------------------------------------

self_test() {
  local tmp out
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/bin" "$tmp/real"
  cat > "$tmp/real/claude.exe" <<'EOF'
#!/usr/bin/env bash
printf 'TZ=%s BASE=%s ARGS=%s\n' "${TZ:-unset}" "${ANTHROPIC_BASE_URL:-unset}" "$*"
EOF
  chmod +x "$tmp/real/claude.exe"
  printf '# test zshrc\nclaude() {\n    command claude --dangerously-skip-permissions "$@"\n}\n' > "$tmp/.zshrc"

  run_apply() {
    ZSHRC="$tmp/.zshrc" \
    CLAUDE_CODE_SAFE_WRAPPER="$tmp/bin/claude" \
    CLAUDE_CODE_REAL_BIN="$tmp/real/claude.exe" \
    CLAUDE_TZ_FIX_SKIP_ZSH_VERIFY=1 \
    CLAUDE_TZ_FIX_SKIP_IP_CHECK=1 \
    "$0" apply "$@" >/dev/null
  }

  # strip mode: ANTHROPIC_BASE_URL removed, level1 timezone.
  run_apply level1 strip
  out="$(ANTHROPIC_BASE_URL=x "$tmp/bin/claude" ping)"
  printf 'strip:    %s\n' "$out"
  grep -q 'TZ=Etc/GMT-8' <<<"$out"
  grep -q 'BASE=unset' <<<"$out"
  grep -q -- '--dangerously-skip-permissions ping' <<<"$out"

  # keep mode (default): ANTHROPIC_BASE_URL passes through untouched.
  run_apply level2
  out="$(ANTHROPIC_BASE_URL=x "$tmp/bin/claude" ping)"
  printf 'keep:     %s\n' "$out"
  grep -q 'TZ=America/Los_Angeles' <<<"$out"
  grep -q 'BASE=x' <<<"$out"

  # redirect mode: ANTHROPIC_BASE_URL pinned to the user's relay.
  run_apply level2 https://relay.example.com
  out="$(ANTHROPIC_BASE_URL=x "$tmp/bin/claude" ping)"
  printf 'redirect: %s\n' "$out"
  grep -q 'TZ=America/Los_Angeles' <<<"$out"
  grep -q 'BASE=https://relay.example.com' <<<"$out"

  printf 'Self-test passed.\n'
}

cmd="${1:-}"
case "$cmd" in
  diagnose|"") diagnose ;;
  check-ip) check_ip ;;
  apply)
    apply_level "${2:-}" "${3:-}"
    ;;
  verify)
    verify_level "${2:-}"
    ;;
  gen-vps)
    gen_vps
    ;;
  self-test)
    self_test
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
