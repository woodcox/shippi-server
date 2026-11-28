#!/usr/bin/env bash
#
# Tests for shippi-report. This file is the executable runner; it sources
# shippi-report, whose main() never runs because the script is sourced, not
# executed.
#
# The interesting cases are the quiet ones: a clean update run must not post,
# the same update run must not post twice, and a reporting failure must not
# turn into a failure of the thing being reported on. A Campfire outage is
# not an apt failure.
#
# Run: ./test/shippi-report-test.sh
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$TEST_DIR/bin/shippi-report"
PASS=0
FAIL=0

TEST_TMP="$(mktemp -d "${HOME}/.shippi-report-test.XXXXXX")" || {
  echo "could not create a private temp dir under $HOME" >&2
  exit 1
}
export TMPDIR="$TEST_TMP"
trap 'rm -rf "$TEST_TMP"' EXIT

# shellcheck source=../bin/shippi-report
source "$SCRIPT"

assert_eq() {
  [[ "$1" == "$2" ]] && return 0
  printf '        expected: %q\n        actual:   %q\n' "$2" "$1"
  return 1
}

assert_contains() {
  [[ "$1" == *"$2"* ]] && return 0
  printf '        expected to contain: %q\n        actual: %q\n' "$2" "$1"
  return 1
}

# A fake curl that records the body and arguments. The real script only needs
# a status code on stdout and a zero exit to consider the POST successful.
make_curl() {
  local dir="$1"
  cat >"$dir/curl" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
body="$(cat)"
printf '%s' "$body" >"${SHIPPI_CURL_BODY:?}"
printf '%s\n' "$*" >"${SHIPPI_CURL_ARGS:?}"
if [[ ${SHIPPI_CURL_EXIT:-0} -ne 0 ]]; then
  printf 'curl: (7) failed to connect to %s\n' "${SHIPPI_CURL_URL:-unknown}" >&2
  exit "${SHIPPI_CURL_EXIT}"
fi
printf '%s' "${SHIPPI_CURL_STATUS:-201}"
EOF
  chmod +x "$dir/curl"
}

make_docker() {
  local dir="$1"
  cat >"$dir/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  ps)
    printf 'cid123\tghcr.io/basecamp/once-campfire\tonce-app-once-campfire.abc\n'
    ;;
  inspect)
    printf '172.18.0.4\n'
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$dir/docker"
}

write_config() {
  local path="$1" url="${2:-http://127.0.0.1:9999}"
  cat >"$path" <<EOF
SHIPPI_CAMPFIRE_URL=${url}
SHIPPI_CAMPFIRE_ROOM=2
SHIPPI_CAMPFIRE_BOT_KEY=3-testtoken
SHIPPI_CAMPFIRE_CONTAINER=once-campfire
EOF
}

setup() {
  local slug="$1"
  CASE_DIR="$TEST_TMP/$slug"
  rm -rf "$CASE_DIR"
  mkdir -p "$CASE_DIR"
  make_curl "$CASE_DIR"
  make_docker "$CASE_DIR"
  write_config "$CASE_DIR/campfire.conf"
  CONFIG="$CASE_DIR/campfire.conf"
  SHIPPI_REPORT_STATE_DIR="$CASE_DIR/state"
  SHIPPI_UNATTENDED_LOG="$CASE_DIR/upgrade.log"
  CURL_BIN="$CASE_DIR/curl"
  DOCKER_BIN="$CASE_DIR/docker"
  SHIPPI_CURL_BODY="$CASE_DIR/body"
  SHIPPI_CURL_ARGS="$CASE_DIR/args"
  SHIPPI_CURL_STATUS=""
  SHIPPI_CURL_EXIT=0
  SHIPPI_CURL_URL=""
  # The fake curl is a child process, so these have to cross the fork.
  export SHIPPI_CURL_BODY SHIPPI_CURL_ARGS SHIPPI_CURL_STATUS
  export SHIPPI_CURL_EXIT SHIPPI_CURL_URL
  # The lock test runs the script as a subprocess, so the config, log, state
  # and fake curl have to cross the fork too.
  export SHIPPI_CURL="$CURL_BIN"
  export SHIPPI_CAMPFIRE_CONFIG="$CONFIG"
  export SHIPPI_UNATTENDED_LOG SHIPPI_REPORT_STATE_DIR
  DRY_RUN=0
  MAX_CHARS=6000
  # _config_load treats these as environment overrides, so a value left over
  # from the previous test would silently win over the new config file.
  SHIPPI_CAMPFIRE_URL=""
  SHIPPI_CAMPFIRE_ROOM=""
  SHIPPI_CAMPFIRE_BOT_KEY=""
  SHIPPI_CAMPFIRE_CONTAINER=""
  # Do not inherit a real apt-daily-upgrade state from the host: a developer
  # machine with a failed unit would otherwise make the clean-run tests post.
  SERVICE_RESULT="success"
  EXIT_CODE="exited"
  EXIT_STATUS="0"
  INVOCATION_ID=""
  # Keep the host's real /var/run/reboot-required out of every assertion.
  SHIPPI_REBOOT_REQUIRED="$CASE_DIR/no-reboot-required"
  SHIPPI_REBOOT_REQUIRED_PKGS="$CASE_DIR/no-reboot-pkgs"
  export SERVICE_RESULT EXIT_CODE EXIT_STATUS INVOCATION_ID
  export SHIPPI_REBOOT_REQUIRED SHIPPI_REBOOT_REQUIRED_PKGS
}

# ---------------------------------------------------------------------------
printf '\nCLI and config\n'

test_help_works() {
  local out rc=0
  out="$(main --help 2>&1)" || rc=1
  assert_contains "$out" "Usage:" || rc=1
  assert_contains "$out" "shippi-report" || rc=1
  return $rc
}

test_unknown_command_is_rejected() {
  setup unknown-command
  main nope >/dev/null 2>&1 && return 1
  return 0
}

test_unknown_global_option_is_rejected() {
  setup unknown-option
  main --nope >/dev/null 2>&1 && return 1
  return 0
}

test_send_posts_the_text_to_the_room() {
  setup send
  local rc=0
  main send "hello
world" >/dev/null 2>&1 || rc=1
  assert_eq "$(cat "$CASE_DIR/body" 2>/dev/null)" "hello
world" || rc=1
  assert_contains "$(cat "$CASE_DIR/args" 2>/dev/null)" \
    "http://127.0.0.1:9999/rooms/2/3-testtoken/messages.json" || rc=1
  assert_contains "$(cat "$CASE_DIR/args" 2>/dev/null)" \
    "Content-Type: text/plain; charset=utf-8" || rc=1
  return $rc
}

test_send_reads_stdin() {
  setup send-stdin
  local rc=0
  printf 'from a pipe\n' | main send >/dev/null 2>&1 || rc=1
  assert_eq "$(cat "$CASE_DIR/body" 2>/dev/null)" "from a pipe" || rc=1
  return $rc
}

test_send_dash_reads_stdin() {
  # The usage advertises `send -`; a literal "-" is not a message.
  setup send-dash
  local rc=0
  printf 'from stdin\n' | main send - >/dev/null 2>&1 || rc=1
  assert_eq "$(cat "$CASE_DIR/body" 2>/dev/null)" "from stdin" || rc=1
  return $rc
}

test_send_refuses_an_empty_message() {
  setup send-empty
  local rc=0
  printf '   \n\n' | main send >/dev/null 2>&1 && rc=1
  [[ ! -e $CASE_DIR/body ]] || {
    printf '        an empty message reached curl\n'
    rc=1
  }
  return $rc
}

test_send_without_config_fails() {
  setup send-no-config
  rm -f "$CONFIG"
  main send "hello" >/dev/null 2>&1 && return 1
  [[ ! -e $CASE_DIR/body ]] || return 1
  return 0
}

test_invalid_room_and_key_are_rejected() {
  setup invalid-config
  local rc=0
  write_config "$CONFIG"
  sed -i 's/^SHIPPI_CAMPFIRE_ROOM=.*/SHIPPI_CAMPFIRE_ROOM=abc/' "$CONFIG"
  main send "hello" >/dev/null 2>&1 && rc=1
  write_config "$CONFIG"
  sed -i 's/^SHIPPI_CAMPFIRE_BOT_KEY=.*/SHIPPI_CAMPFIRE_BOT_KEY=not-a-key/' "$CONFIG"
  main send "hello" >/dev/null 2>&1 && rc=1
  [[ ! -e $CASE_DIR/body ]] || rc=1
  return $rc
}

test_world_writable_config_is_refused() {
  # The config is sourced, so a group-/world-writable file would run its
  # contents as root on the next systemd hook. Refuse it before sourcing. A
  # leading setuid/setgid/sticky digit must not hide the group/other write bits.
  setup world-writable
  local rc=0 out mode
  for mode in 666 1002; do
    chmod "$mode" "$CONFIG"
    out="$(main send "hello" 2>&1)" && rc=1
    assert_contains "$out" "world-writable" || rc=1
  done
  [[ ! -e $CASE_DIR/body ]] || {
    printf '        a rejected config still reached curl\n'
    rc=1
  }
  return $rc
}

test_dry_run_does_not_post_or_write_state() {
  setup dry-run
  local rc=0 out
  out="$(main --dry-run send "hello" 2>&1)" || rc=1
  assert_contains "$out" "would post" || rc=1
  [[ ! -e $CASE_DIR/body ]] || {
    printf '        a dry run called curl\n'
    rc=1
  }
  [[ ! -e $SHIPPI_REPORT_STATE_DIR ]] || {
    printf '        a dry run created state\n'
    rc=1
  }
  return $rc
}

test_auto_discovers_the_campfire_container() {
  setup discover
  write_config "$CONFIG" auto
  local rc=0
  main test >/dev/null 2>&1 || rc=1
  assert_contains "$(cat "$CASE_DIR/args" 2>/dev/null)" \
    "http://172.18.0.4/rooms/2/3-testtoken/messages.json" || rc=1
  return $rc
}

test_http_error_is_reported() {
  setup http-error
  local rc=0 out
  SHIPPI_CURL_STATUS=500
  export SHIPPI_CURL_STATUS
  out="$(main send "hello" 2>&1)" && rc=1
  assert_contains "$out" "HTTP 500" || rc=1
  return $rc
}

test_curl_failure_redacts_the_bot_key() {
  setup curl-error
  local rc=0 out
  SHIPPI_CURL_EXIT=7
  SHIPPI_CURL_URL="http://127.0.0.1/rooms/2/3-testtoken/messages.json"
  export SHIPPI_CURL_EXIT SHIPPI_CURL_URL
  out="$(main send "hello" 2>&1)" && rc=1
  assert_contains "$out" "<redacted>" || rc=1
  [[ $out != *"3-testtoken"* ]] || {
    printf '        the bot key leaked into the error output\n'
    rc=1
  }
  return $rc
}

test_message_is_truncated() {
  setup truncate
  local rc=0
  MAX_CHARS=10
  main send "0123456789abcdef" >/dev/null 2>&1 || rc=1
  local body
  body="$(cat "$CASE_DIR/body" 2>/dev/null)"
  assert_eq "${body:0:10}" "0123456789" || rc=1
  assert_contains "$body" "truncated" || rc=1
  return $rc
}

# ---------------------------------------------------------------------------
printf '\nunattended-upgrades reports\n'

test_clean_run_posts_nothing() {
  setup clean
  cat >"$SHIPPI_UNATTENDED_LOG" <<'EOF'
2026-11-28 06:00:00,000 INFO Starting unattended upgrades script
2026-11-28 06:00:01,000 INFO No packages found that can be upgraded and no pending auto-removals
EOF
  local rc=0 out
  out="$(main updates 2>&1)" || rc=1
  [[ -z $out ]] || {
    printf '        a clean run printed something: %s\n' "$out"
    rc=1
  }
  [[ ! -e $CASE_DIR/body ]] || {
    printf '        a clean run posted to Campfire\n'
    rc=1
  }
  return $rc
}

test_completion_line_without_packages_is_silent() {
  # Some versions print "All upgrades installed" even when the package list
  # is empty. A message naming nothing is worse than no message.
  setup completion-only
  cat >"$SHIPPI_UNATTENDED_LOG" <<'EOF'
2026-11-28 06:00:00,000 INFO Starting unattended upgrades script
2026-11-28 06:00:01,000 INFO All upgrades installed
EOF
  local rc=0
  main updates >/dev/null 2>&1 || rc=1
  [[ ! -e $CASE_DIR/body ]] || {
    printf '        an empty completion line was posted\n'
    rc=1
  }
  return $rc
}

test_installed_packages_are_reported_once() {
  setup installed
  cat >"$SHIPPI_UNATTENDED_LOG" <<'EOF'
2026-11-27 06:14:24,810 INFO Starting unattended upgrades script
2026-11-27 06:14:28,553 INFO Packages that will be upgraded: exim4-base exim4-config
2026-11-27 06:14:33,155 INFO All upgrades installed
EOF
  local rc=0 body
  main updates >/dev/null 2>&1 || rc=1
  body="$(cat "$CASE_DIR/body" 2>/dev/null)"
  assert_contains "$body" "Installed: exim4-base exim4-config" || rc=1
  : >"$CASE_DIR/body"
  main updates >/dev/null 2>&1 || rc=1
  [[ ! -s $CASE_DIR/body ]] || {
    printf '        the same run was posted twice\n'
    rc=1
  }
  return $rc
}

test_auto_removed_and_kept_back_are_reported() {
  setup changed
  cat >"$SHIPPI_UNATTENDED_LOG" <<'EOF'
2026-11-26 06:08:34,000 INFO Starting unattended upgrades script
2026-11-26 06:08:36,334 INFO Packages that will be upgraded: 
2026-11-26 06:08:38,420 INFO Packages that were successfully auto-removed: libgpgme11
2026-11-26 06:08:39,000 INFO Packages that are kept back: rpi-eeprom
EOF
  local rc=0 body
  main updates >/dev/null 2>&1 || rc=1
  body="$(cat "$CASE_DIR/body" 2>/dev/null)"
  assert_contains "$body" "Auto-removed: libgpgme11" || rc=1
  assert_contains "$body" "Kept back" || rc=1
  assert_contains "$body" "rpi-eeprom" || rc=1
  return $rc
}

test_errors_keep_every_line() {
  # The first version split fields with `read`, which stops at the first
  # newline and silently dropped every error line after the first.
  setup errors
  cat >"$SHIPPI_UNATTENDED_LOG" <<'EOF'
2026-11-28 06:00:00,000 INFO Starting unattended upgrades script
2026-11-28 06:00:01,000 ERROR could not acquire the apt lock
2026-11-28 06:00:02,000 ERROR second failure line
EOF
  local rc=0 body
  main updates >/dev/null 2>&1 || rc=1
  body="$(cat "$CASE_DIR/body" 2>/dev/null)"
  assert_contains "$body" "could not acquire the apt lock" || rc=1
  assert_contains "$body" "second failure line" || rc=1
  return $rc
}

test_failed_upgrade_names_packages_to_upgrade() {
  # The "will be upgraded" list is a plan, not a completion, so a failed run
  # must label it "to upgrade", never "Installed".
  setup failed-with-packages
  cat >"$SHIPPI_UNATTENDED_LOG" <<'EOF'
2026-11-28 06:00:00,000 INFO Starting unattended upgrades script
2026-11-28 06:00:01,000 INFO Packages that will be upgraded: bash
2026-11-28 06:00:02,000 ERROR could not acquire the apt lock
EOF
  SERVICE_RESULT="exit-code" EXIT_CODE="exited" EXIT_STATUS="100" INVOCATION_ID="inv-fail"
  export SERVICE_RESULT EXIT_CODE EXIT_STATUS INVOCATION_ID
  local rc=0 body
  main updates >/dev/null 2>&1 || rc=1
  body="$(cat "$CASE_DIR/body" 2>/dev/null)"
  assert_contains "$body" "Packages to upgrade: bash" || rc=1
  [[ $body != *"Installed: bash"* ]] || {
    printf '        a failed run claimed the packages were installed\n'
    rc=1
  }
  assert_contains "$body" "could not acquire the apt lock" || rc=1
  return $rc
}

test_systemd_failure_is_reported_even_without_a_log() {
  setup unit-failure
  rm -f "$SHIPPI_UNATTENDED_LOG"
  SERVICE_RESULT="exit-code" EXIT_CODE="exited" EXIT_STATUS="100" INVOCATION_ID="inv-1"
  export SERVICE_RESULT EXIT_CODE EXIT_STATUS INVOCATION_ID
  local rc=0 body
  main updates >/dev/null 2>&1 || rc=1
  body="$(cat "$CASE_DIR/body" 2>/dev/null)"
  assert_contains "$body" "apt-daily-upgrade.service failed" || rc=1
  : >"$CASE_DIR/body"
  main updates >/dev/null 2>&1 || rc=1
  [[ ! -s $CASE_DIR/body ]] || {
    printf '        the same failed invocation was posted twice\n'
    rc=1
  }
  return $rc
}

test_unit_failure_is_silent_on_success() {
  setup unit-success
  SERVICE_RESULT="success"
  export SERVICE_RESULT
  local rc=0
  main unit-failure --unit apt-daily.service >/dev/null 2>&1 || rc=1
  [[ ! -e $CASE_DIR/body ]] || {
    printf '        a successful unit was reported as failed\n'
    rc=1
  }
  return $rc
}

test_apt_daily_failure_names_stale_lists() {
  setup apt-daily
  SERVICE_RESULT="exit-code" EXIT_CODE="exited" EXIT_STATUS="100" INVOCATION_ID="inv-2"
  export SERVICE_RESULT EXIT_CODE EXIT_STATUS INVOCATION_ID
  local rc=0 body
  main unit-failure --unit apt-daily.service >/dev/null 2>&1 || rc=1
  body="$(cat "$CASE_DIR/body" 2>/dev/null)"
  assert_contains "$body" "apt-daily.service failed" || rc=1
  assert_contains "$body" "Package lists may be stale" || rc=1
  return $rc
}

test_updates_dry_run_writes_no_state() {
  # A preview must not create the state directory, and it certainly must not
  # record the run as delivered.
  setup updates-dry
  cat >"$SHIPPI_UNATTENDED_LOG" <<'EOF'
2026-11-28 06:00:00,000 INFO Starting unattended upgrades script
2026-11-28 06:00:01,000 INFO Packages that will be upgraded: bash
2026-11-28 06:00:02,000 INFO All upgrades installed
EOF
  local rc=0 out
  out="$(main --dry-run updates 2>&1)" || rc=1
  assert_contains "$out" "would post" || rc=1
  [[ ! -e $SHIPPI_REPORT_STATE_DIR ]] || {
    printf '        a dry run created state\n'
    rc=1
  }
  [[ ! -e $CASE_DIR/body ]] || {
    printf '        a dry run posted\n'
    rc=1
  }
  return $rc
}

test_unit_failure_dry_run_writes_no_state() {
  setup unit-dry
  SERVICE_RESULT="exit-code" EXIT_CODE="exited" EXIT_STATUS="100" INVOCATION_ID="inv-dry"
  export SERVICE_RESULT EXIT_CODE EXIT_STATUS INVOCATION_ID
  local rc=0 out
  out="$(main --dry-run unit-failure --unit apt-daily.service 2>&1)" || rc=1
  assert_contains "$out" "would post" || rc=1
  [[ ! -e $SHIPPI_REPORT_STATE_DIR ]] || {
    printf '        a dry run created state\n'
    rc=1
  }
  [[ ! -e $CASE_DIR/body ]] || {
    printf '        a dry run posted\n'
    rc=1
  }
  return $rc
}

test_reboot_only_is_reported_once() {
  # A manual upgrade can leave a reboot pending with no unattended package
  # changes. That is still an issue, and it must not be reported every day.
  setup reboot-only
  cat >"$SHIPPI_UNATTENDED_LOG" <<'EOF'
2026-11-28 06:00:00,000 INFO Starting unattended upgrades script
2026-11-28 06:00:01,000 INFO No packages found that can be upgraded and no pending auto-removals
EOF
  printf 'linux-image-test\n' >"$SHIPPI_REBOOT_REQUIRED_PKGS"
  : >"$SHIPPI_REBOOT_REQUIRED"
  local rc=0 body
  main updates >/dev/null 2>&1 || rc=1
  body="$(cat "$CASE_DIR/body" 2>/dev/null)"
  assert_contains "$body" "Reboot required (linux-image-test)" || rc=1
  [[ $body != *"Installed"* ]] || {
    printf '        the reboot-only report also claimed packages\n'
    rc=1
  }
  : >"$CASE_DIR/body"
  main updates >/dev/null 2>&1 || rc=1
  [[ ! -s $CASE_DIR/body ]] || {
    printf '        the pending reboot was reported twice\n'
    rc=1
  }
  return $rc
}

test_reboot_is_reported_without_an_upgrade_run() {
  # The log may not exist yet (no unattended-upgrades run), but a pending
  # reboot is still an issue on its own.
  setup reboot-no-log
  rm -f "$SHIPPI_UNATTENDED_LOG"
  printf 'linux-image-test\n' >"$SHIPPI_REBOOT_REQUIRED_PKGS"
  : >"$SHIPPI_REBOOT_REQUIRED"
  local rc=0 body
  main updates >/dev/null 2>&1 || rc=1
  body="$(cat "$CASE_DIR/body" 2>/dev/null)"
  assert_contains "$body" "Reboot required (linux-image-test)" || rc=1
  return $rc
}

test_new_reboot_posts_after_upgrade_already_reported() {
  # The package run was already reported; a reboot that became pending since
  # then must not be suppressed by the unchanged run key.
  setup new-reboot-after-report
  cat >"$SHIPPI_UNATTENDED_LOG" <<'EOF'
2026-11-27 06:14:24,810 INFO Starting unattended upgrades script
2026-11-27 06:14:28,553 INFO Packages that will be upgraded: bash
2026-11-27 06:14:33,155 INFO All upgrades installed
EOF
  local rc=0 body
  main updates >/dev/null 2>&1 || rc=1
  body="$(cat "$CASE_DIR/body" 2>/dev/null)"
  assert_contains "$body" "Installed: bash" || rc=1
  : >"$CASE_DIR/body"

  printf 'linux-image-test\n' >"$SHIPPI_REBOOT_REQUIRED_PKGS"
  : >"$SHIPPI_REBOOT_REQUIRED"

  main updates >/dev/null 2>&1 || rc=1
  body="$(cat "$CASE_DIR/body" 2>/dev/null)"
  assert_contains "$body" "Reboot required (linux-image-test)" || rc=1
  [[ $body != *"Installed: bash"* ]] || {
    printf '        the already-reported package run was posted again\n'
    rc=1
  }
  return $rc
}

test_unit_failure_does_not_clobber_upgrade_state() {
  # A daily apt-daily failure used to overwrite updates.state, so the next
  # successful update check re-posted an unchanged run.
  setup state-split
  cat >"$SHIPPI_UNATTENDED_LOG" <<'EOF'
2026-11-28 06:00:00,000 INFO Starting unattended upgrades script
2026-11-28 06:00:01,000 INFO Packages that will be upgraded: bash
2026-11-28 06:00:02,000 INFO All upgrades installed
EOF
  local rc=0
  main updates >/dev/null 2>&1 || rc=1
  [[ -s $CASE_DIR/body ]] || rc=1
  : >"$CASE_DIR/body"

  SERVICE_RESULT="exit-code" EXIT_CODE="exited" EXIT_STATUS="100" INVOCATION_ID="inv-split"
  export SERVICE_RESULT EXIT_CODE EXIT_STATUS INVOCATION_ID
  main unit-failure --unit apt-daily.service >/dev/null 2>&1 || rc=1
  [[ -s $CASE_DIR/body ]] || rc=1
  : >"$CASE_DIR/body"

  SERVICE_RESULT="success" EXIT_CODE="exited" EXIT_STATUS="0" INVOCATION_ID=""
  export SERVICE_RESULT EXIT_CODE EXIT_STATUS INVOCATION_ID
  main updates >/dev/null 2>&1 || rc=1
  [[ ! -s $CASE_DIR/body ]] || {
    printf '        the unchanged upgrade run was posted again after a unit failure\n'
    rc=1
  }
  return $rc
}

test_unit_failures_do_not_clobber_each_other() {
  # apt-daily and apt-daily-upgrade failures are different reports; one must
  # not suppress the other's dedupe key.
  setup unit-per-unit
  SERVICE_RESULT="exit-code" EXIT_CODE="exited" EXIT_STATUS="100"
  export SERVICE_RESULT EXIT_CODE EXIT_STATUS

  INVOCATION_ID="inv-daily"
  export INVOCATION_ID
  main unit-failure --unit apt-daily.service >/dev/null 2>&1 || return 1
  [[ -s $CASE_DIR/body ]] || {
    printf '        the apt-daily failure did not post\n'
    return 1
  }
  : >"$CASE_DIR/body"

  INVOCATION_ID="inv-upgrade"
  export INVOCATION_ID
  main unit-failure --unit apt-daily-upgrade.service >/dev/null 2>&1 || return 1
  [[ -s $CASE_DIR/body ]] || {
    printf '        the upgrade-unit failure was suppressed by the apt-daily state\n'
    return 1
  }
  : >"$CASE_DIR/body"

  INVOCATION_ID="inv-daily"
  export INVOCATION_ID
  main unit-failure --unit apt-daily.service >/dev/null 2>&1 || return 1
  [[ ! -s $CASE_DIR/body ]] || {
    printf '        the same apt-daily failure was posted again\n'
    return 1
  }
  return 0
}

test_executed_updates_serializes_through_a_lock() {
  # The in-process tests call main() directly. This is the one that proves the
  # real executable path re-execs under flock, so two overlapping hooks cannot
  # both post the same run.
  command -v flock >/dev/null 2>&1 || return 0
  setup lock
  cat >"$SHIPPI_UNATTENDED_LOG" <<'EOF'
2026-11-28 06:00:00,000 INFO Starting unattended upgrades script
2026-11-28 06:00:01,000 INFO Packages that will be upgraded: bash
2026-11-28 06:00:02,000 INFO All upgrades installed
EOF
  local rc=0
  "$SCRIPT" --config "$CONFIG" updates >/dev/null 2>&1 || rc=1
  [[ -e $SHIPPI_REPORT_STATE_DIR/report.lock ]] || {
    printf '        the executed updates command did not take the lock\n'
    rc=1
  }
  [[ -s $CASE_DIR/body ]] || {
    printf '        the executed updates command did not post\n'
    rc=1
  }
  return $rc
}

test_updates_without_config_is_a_quiet_noop() {
  # A box that never configured Campfire must not log a complaint every day
  # just because the update run was clean (or its log was not there yet).
  setup updates-no-config
  rm -f "$CONFIG"
  cat >"$SHIPPI_UNATTENDED_LOG" <<'EOF'
2026-11-28 06:00:00,000 INFO Starting unattended upgrades script
2026-11-28 06:00:01,000 INFO No packages found that can be upgraded and no pending auto-removals
EOF
  local rc=0 out
  out="$(main updates 2>&1)" || rc=1
  [[ -z $out ]] || {
    printf '        a clean unconfigured run printed something: %s\n' "$out"
    rc=1
  }
  [[ ! -e $CASE_DIR/body ]] || rc=1
  return $rc
}

test_updates_change_without_config_is_a_quiet_noop() {
  # The change is real, but there is nowhere to send it. Say so once (the
  # manual invocation needs an explanation) and do not fail the hook.
  setup updates-no-config-change
  rm -f "$CONFIG"
  cat >"$SHIPPI_UNATTENDED_LOG" <<'EOF'
2026-11-28 06:00:00,000 INFO Starting unattended upgrades script
2026-11-28 06:00:01,000 INFO Packages that will be upgraded: bash
2026-11-28 06:00:02,000 INFO All upgrades installed
EOF
  local rc=0 out
  out="$(main updates 2>&1)" || rc=1
  assert_contains "$out" "not configured" || rc=1
  [[ ! -e $CASE_DIR/body ]] || rc=1
  return $rc
}

# ---------------------------------------------------------------------------
_t() {
  local name="$1" fn="$2"
  if ! declare -F "$fn" >/dev/null 2>&1; then
    printf '  FAIL  %s\n' "$name"
    FAIL=$((FAIL + 1))
    return
  fi
  if "$fn"; then
    printf '  ok    %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$name"
    FAIL=$((FAIL + 1))
  fi
}

_t 'help works'                                  test_help_works
_t 'unknown command is rejected'                 test_unknown_command_is_rejected
_t 'unknown global option is rejected'           test_unknown_global_option_is_rejected
_t 'send posts the text to the room'             test_send_posts_the_text_to_the_room
_t 'send reads stdin'                            test_send_reads_stdin
_t 'send - reads stdin'                          test_send_dash_reads_stdin
_t 'send refuses an empty message'               test_send_refuses_an_empty_message
_t 'send without config fails'                   test_send_without_config_fails
_t 'invalid room and key are rejected'           test_invalid_room_and_key_are_rejected
_t 'dry run posts and writes nothing'            test_dry_run_does_not_post_or_write_state
_t 'auto-discovers the container address'        test_auto_discovers_the_campfire_container
_t 'HTTP errors are reported'                    test_http_error_is_reported
_t 'curl errors redact the bot key'              test_curl_failure_redacts_the_bot_key
_t 'long messages are truncated'                 test_message_is_truncated
_t 'a clean update run stays silent'             test_clean_run_posts_nothing
_t 'an empty completion line stays silent'       test_completion_line_without_packages_is_silent
_t 'installed packages are reported once'        test_installed_packages_are_reported_once
_t 'auto-removed and kept-back are reported'     test_auto_removed_and_kept_back_are_reported
_t 'every error line is kept'                    test_errors_keep_every_line
_t 'systemd failure posts without a log'         test_systemd_failure_is_reported_even_without_a_log
_t 'unit failure is silent on success'           test_unit_failure_is_silent_on_success
_t 'apt-daily failure names stale lists'         test_apt_daily_failure_names_stale_lists
_t 'updates dry run writes no state'             test_updates_dry_run_writes_no_state
_t 'unit failure dry run writes no state'        test_unit_failure_dry_run_writes_no_state
_t 'a pending reboot posts once'                  test_reboot_only_is_reported_once
_t 'a reboot posts with no upgrade run yet'       test_reboot_is_reported_without_an_upgrade_run
_t 'a new reboot posts after the run was reported' test_new_reboot_posts_after_upgrade_already_reported
_t 'unit failure keeps upgrade state separate'    test_unit_failure_does_not_clobber_upgrade_state
_t 'executed updates runs under a lock'          test_executed_updates_serializes_through_a_lock
_t 'updates without config is a quiet no-op'     test_updates_without_config_is_a_quiet_noop
_t 'a change without config explains itself'     test_updates_change_without_config_is_a_quiet_noop
_t 'a world-writable config is refused'          test_world_writable_config_is_refused
_t 'a failed upgrade names packages to upgrade'   test_failed_upgrade_names_packages_to_upgrade
_t 'unit failures do not clobber each other'     test_unit_failures_do_not_clobber_each_other

printf '\n%s passed, %s failed\n\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
