#!/usr/bin/env bash

set -euo pipefail

case ${0##*/} in
  sp | ghostty)
    printf '%s\n' "$@" >"$SUPATERM_SSH_CAPTURE"
    exit 0
    ;;
  ssh)
    exit 99
    ;;
esac

script_path=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/${BASH_SOURCE[0]##*/}
readonly script_path
repo_root=$(cd -- "$(dirname -- "$script_path")/../.." && pwd)
readonly repo_root
test_root=$(mktemp -d)
readonly test_root
readonly capture_path=$test_root/capture
readonly expected_path=$test_root/expected
readonly prompt_capture_path=$test_root/prompt-capture
readonly prompt_expected_path=$test_root/prompt-expected
trap 'rm -rf "$test_root"' EXIT

ln -s "$script_path" "$test_root/sp"
ln -s "$script_path" "$test_root/ssh"
ln -s "$script_path" "$test_root/ghostty"

readonly -a test_env=(
  env
  GHOSTTY_SHELL_FEATURES=
  GHOSTTY_BIN_DIR="$test_root/missing"
  SUPATERM_CLI_PATH="$test_root/sp"
  SUPATERM_SSH_CAPTURE="$capture_path"
  PATH="$test_root:$PATH"
)

assert_route() {
  local shell_name=$1
  if ! cmp -s "$expected_path" "$capture_path"; then
    printf '%s\n' "$shell_name route failed" >&2
    diff -u "$expected_path" "$capture_path" >&2 || true
    exit 1
  fi
  rm -f "$capture_path"
  printf '%s\n' "$shell_name route passed"
}

printf '%s\n' ssh -- -p 2222 'user@example host' >"$expected_path"

"${test_env[@]}" bash --noprofile --norc -i -c \
  "source \"\$1\"; ssh -p 2222 \"user@example host\"" \
  bash "$repo_root/src/shell-integration/bash/ghostty.bash" \
  >/dev/null 2>&1
assert_route bash

"${test_env[@]}" zsh -dfi -c \
  "source \"\$1\"; _ghostty_deferred_init; ssh -p 2222 \"user@example host\"" \
  zsh "$repo_root/src/shell-integration/zsh/ghostty-integration" \
  >/dev/null 2>&1
assert_route zsh

printf '\033]133;B\a' >"$prompt_expected_path"
env GHOSTTY_SHELL_FEATURES= zsh -dfi -c "
  source \"\$1\"
  _ghostty_deferred_init >/dev/null
  _ghostty_fd=1
  PS1=\$'%{\\e]133;A;cl=line\\a%}ready%{\\e]133;B\\a%}'
  _ghostty_zle_line_init
" zsh "$repo_root/src/shell-integration/zsh/ghostty-integration" \
  >"$prompt_capture_path" 2>/dev/null
if ! cmp -s "$prompt_expected_path" "$prompt_capture_path"; then
  printf '%s\n' 'zsh line-init emitted wrong prompt markers' >&2
  od -An -tx1 "$prompt_expected_path" >&2
  od -An -tx1 "$prompt_capture_path" >&2
  exit 1
fi
printf '%s\n' 'zsh prompt route passed'

"${test_env[@]}" \
  GHOSTTY_TEST_INTEGRATION="$repo_root/src/shell-integration/fish/vendor_conf.d/ghostty-shell-integration.fish" \
  fish --no-config -i \
  -C "source \"\$GHOSTTY_TEST_INTEGRATION\"" \
  -C '__ghostty_setup' \
  -c 'ssh -p 2222 "user@example host"' \
  >/dev/null 2>&1
assert_route fish

"${test_env[@]}" expect -f /dev/stdin \
  "$repo_root/src/shell-integration/elvish/lib/ghostty-integration.elv" \
  >/dev/null <<'EOF'
log_user 0
set timeout 10
set integration [lindex $argv 0]
spawn elvish -rc $integration
expect "> "
send -- "ssh -p 2222 \"user@example host\"\r"
expect "> "
send -- "exit\r"
expect eof
EOF
assert_route elvish

"${test_env[@]}" nu -n \
  -I "$repo_root/src/shell-integration/nushell/vendor/autoload" \
  -c 'source ghostty.nu; use ghostty *; ssh -p 2222 "user@example host"' \
  >/dev/null 2>&1
assert_route nushell

printf '%s\n' +ssh --terminfo=false -- -p 2222 'user@example host' >"$expected_path"
env -u GHOSTTY_BIN_DIR -u SUPATERM_CLI_PATH \
  GHOSTTY_SHELL_FEATURES=ssh-env \
  SUPATERM_SSH_CAPTURE="$capture_path" \
  PATH="$test_root:$PATH" \
  nu -n \
  -I "$repo_root/src/shell-integration/nushell/vendor/autoload" \
  -c 'source ghostty.nu; use ghostty *; ssh -p 2222 "user@example host"' \
  >/dev/null 2>&1
assert_route 'nushell native'
