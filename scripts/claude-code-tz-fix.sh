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
  claude-code-tz-fix.sh apply level1|level2
  claude-code-tz-fix.sh verify level1|level2
  claude-code-tz-fix.sh self-test

Levels:
  level1  Etc/GMT-8               UTC+8, non-China timezone label
  level2  America/Los_Angeles     US Pacific time
EOF
}

tz_for_level() {
  case "${1:-}" in
    level1|1|utc8|beijing-safe|gmt8) printf '%s\n' "Etc/GMT-8" ;;
    level2|2|us|usa|pacific|la) printf '%s\n' "America/Los_Angeles" ;;
    *) return 1 ;;
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

write_safe_wrapper() {
  local tz="$1" real_bin="$2" dangerous_default="$3"
  mkdir -p "$(dirname "$SAFE_WRAPPER")"
  backup_path "$SAFE_WRAPPER"
  cat > "$SAFE_WRAPPER" <<EOF
#!/usr/bin/env bash
unset ANTHROPIC_BASE_URL
export TZ="$tz"
DEFAULT_ARGS=()
if [ "$dangerous_default" = "1" ]; then
  DEFAULT_ARGS+=(--dangerously-skip-permissions)
fi
exec "$real_bin" "\${DEFAULT_ARGS[@]}" "\$@"
EOF
  chmod +x "$SAFE_WRAPPER"
  printf 'Wrote managed wrapper: %s\n' "$SAFE_WRAPPER"
}

update_zshrc_managed_block() {
  local level="$1" tz="$2"
  [ -e "$ZSHRC" ] || touch "$ZSHRC"
  backup_path "$ZSHRC"
  BEGIN_MARKER_VALUE="$BEGIN_MARKER" \
  END_MARKER_VALUE="$END_MARKER" \
  SAFE_WRAPPER_VALUE="$SAFE_WRAPPER" \
  LEVEL_VALUE="$level" \
  TZ_VALUE="$tz" \
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
    f"# Managed by claude-code-tz-fix. Level: {level}. TZ: {tz}.\n"
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
}

apply_level() {
  local level="$1" tz real_bin dangerous_default
  tz="$(tz_for_level "$level")" || {
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

  write_safe_wrapper "$tz" "$real_bin" "$dangerous_default"
  update_zshrc_managed_block "$level" "$tz"
  verify_level "$level"
}

assert_wrapper_content() {
  local tz="$1"
  grep -qF "export TZ=\"$tz\"" "$SAFE_WRAPPER"
  grep -qF "unset ANTHROPIC_BASE_URL" "$SAFE_WRAPPER"
  if grep -qE 'Asia/Shanghai|Asia/Urumqi' "$SAFE_WRAPPER"; then
    printf 'ERROR: China timezone label found in wrapper.\n' >&2
    return 1
  fi
}

verify_level() {
  local level="$1" tz
  tz="$(tz_for_level "$level")" || {
    usage
    return 2
  }

  printf '== Verify Claude Code TZ fix (%s) ==\n' "$tz"
  assert_wrapper_content "$tz"

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

self_test() {
  local tmp out1 out2
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/bin" "$tmp/real"
  cat > "$tmp/real/claude.exe" <<'EOF'
#!/usr/bin/env bash
printf 'TZ=%s BASE=%s ARGS=%s\n' "${TZ:-unset}" "${ANTHROPIC_BASE_URL:-unset}" "$*"
EOF
  chmod +x "$tmp/real/claude.exe"
  printf '# test zshrc\nclaude() {\n    command claude --dangerously-skip-permissions "$@"\n}\n' > "$tmp/.zshrc"

  ZSHRC="$tmp/.zshrc" \
  CLAUDE_CODE_SAFE_WRAPPER="$tmp/bin/claude" \
  CLAUDE_CODE_REAL_BIN="$tmp/real/claude.exe" \
  CLAUDE_TZ_FIX_SKIP_ZSH_VERIFY=1 \
  "$0" apply level1 >/dev/null
  out1="$(ANTHROPIC_BASE_URL=x "$tmp/bin/claude" ping)"
  printf '%s\n' "$out1"
  grep -q 'TZ=Etc/GMT-8' <<<"$out1"
  grep -q 'BASE=unset' <<<"$out1"
  grep -q -- '--dangerously-skip-permissions ping' <<<"$out1"

  ZSHRC="$tmp/.zshrc" \
  CLAUDE_CODE_SAFE_WRAPPER="$tmp/bin/claude" \
  CLAUDE_CODE_REAL_BIN="$tmp/real/claude.exe" \
  CLAUDE_TZ_FIX_SKIP_ZSH_VERIFY=1 \
  "$0" apply level2 >/dev/null
  out2="$(ANTHROPIC_BASE_URL=x "$tmp/bin/claude" ping)"
  printf '%s\n' "$out2"
  grep -q 'TZ=America/Los_Angeles' <<<"$out2"
  grep -q 'BASE=unset' <<<"$out2"
  grep -q -- '--dangerously-skip-permissions ping' <<<"$out2"
  printf 'Self-test passed.\n'
}

cmd="${1:-}"
case "$cmd" in
  diagnose|"") diagnose ;;
  apply)
    apply_level "${2:-}"
    ;;
  verify)
    verify_level "${2:-}"
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
