#!/usr/bin/env bash
# Exercise the real retry loop with a fake driver, no network or credentials.
set -uo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
RUN_DIR="${1:?temporary test directory required}"
scenario="${2:?test scenario required}"
mkdir -p "$RUN_DIR/records"
ARC_DIR="$RUN_DIR"
MODEL=test-model
PROVIDER=test-provider
MAX_FAILS=2
MAX_WAITS=3
COOLDOWN=30
ARC_MAX_RESUMES=2
failures=1
keep_checkpoint=1
retryable=0
expected_status=0
expected_calls="fresh test-card"
outer=absent
unset ARC_RESUME was_resume

case "$scenario" in
  fresh-error) ;;
  fresh-retryable) retryable=1 ;;
  resume-error)
    touch "$RUN_DIR/checkpoint"
    expected_calls="test-card test-card"
    ;;
  resume-retryable)
    touch "$RUN_DIR/checkpoint"
    retryable=1
    failures=2
    ARC_MAX_RESUMES=1
    expected_calls="test-card test-card test-card"
    ;;
  fresh-exhausted)
    keep_checkpoint=0
    failures=2
    expected_status=1
    expected_calls="fresh fresh"
    ;;
  inherited-state)
    was_resume=parent-sentinel
    outer=parent-sentinel
    ;;
  separate-games)
    touch "$RUN_DIR/checkpoint"
    failures=0
    expected_calls="test-card fresh"
    ;;
  recording-gone)
    # A resume attempt that proves the authoritative recording is gone must
    # halt the whole campaign (return 2), not silently drop the game and
    # continue, so the shared scorecard never gains a second trajectory.
    touch "$RUN_DIR/checkpoint"
    keep_checkpoint=0
    failures=99
    expected_status=2
    expected_calls="test-card"
    ;;
  *) echo "Unknown test scenario: $scenario" >&2; exit 1 ;;
esac

say() { printf '%s\n' "$*" >> "$RUN_DIR/messages"; }
sleep() { printf '%s\n' "$*" >> "$RUN_DIR/waits"; }
resumable_card() {
  if [ -f "$RUN_DIR/checkpoint" ]; then printf 'test-card\n'; fi
}
campaign_invalid_fault() { return 1; }
authoritative_game_gone_fault() { return 1; }
is_done() { test -f "$RUN_DIR/finished"; }
retryable_fault() { test "$retryable" -eq 1; }
r() {
  # play_game runs its driver in a subshell, so counters live in test files.
  printf '%s\n' "${ARC_RESUME:-fresh}" >> "$RUN_DIR/calls"
  local n
  n="$(wc -l < "$RUN_DIR/calls")"
  if [ "$n" -le "$failures" ]; then
    printf '{"summary":"synthetic driver failure"}\n' > "$RUN_DIR/records/test-game.json"
    if [ "$keep_checkpoint" -eq 1 ]; then
      touch "$RUN_DIR/checkpoint"
    else
      rm -f "$RUN_DIR/checkpoint"
    fi
    return 1
  fi
  touch "$RUN_DIR/finished"
  printf ' -> test WIN\n'
}

# Source only the production function; sourcing the whole sweep would launch it.
source <(sed -n '/^play_game() {$/,/^}$/p' "$SCRIPT_DIR/sweep.sh")
declare -F play_game >/dev/null || exit 1
play_game test-game
status=$?
[ "$status" -eq "$expected_status" ] || exit 1
[ "${was_resume-absent}" = "$outer" ] || exit 1

if [ "$scenario" = separate-games ]; then
  rm -- "$RUN_DIR/checkpoint" "$RUN_DIR/finished"
  play_game second-game || exit 1
  [ "${was_resume-absent}" = "$outer" ] || exit 1
fi

mapfile -t calls < "$RUN_DIR/calls"
[ "${calls[*]}" = "$expected_calls" ] || exit 1
if [ "$scenario" = fresh-exhausted ]; then
  grep -q 'GIVING UP after 2 non-rate-limit failures' "$RUN_DIR/messages" || exit 1
elif [ "$scenario" = recording-gone ]; then
  grep -q 'authoritative recording is gone; stopping clean campaign' \
    "$RUN_DIR/messages" || exit 1
elif [ "$failures" -gt 0 ]; then
  # The retry uses the checkpoint, archives the old error, and preserves logs.
  grep -q 'resuming card test-card (resume 1/' "$RUN_DIR/messages" || exit 1
  test -d "$RUN_DIR/failures" || exit 1
  grep -q 'synthetic driver failure' "$RUN_DIR"/failures/test-game-*.json || exit 1
fi
if [ "$scenario" = fresh-retryable ]; then
  grep -q 'resuming card test-card (resume 1/.*waits=1 fails=0)' "$RUN_DIR/messages" || exit 1
fi
if [ "$scenario" = resume-retryable ]; then
  grep -q 'resuming card test-card (resume 1/1, waits=2 fails=0)' "$RUN_DIR/messages" || exit 1
fi
printf '%s passed\n' "$scenario"
