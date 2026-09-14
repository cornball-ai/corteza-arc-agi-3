#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
LABEL="${1:-${ARC_CAMPAIGN_LABEL:-cold-claude-opus-5}}"
SESSION="${2:-arc-agi-3}"
RUN_DIR="$SCRIPT_DIR/campaigns/$LABEL"

case "$SESSION" in
  ''|*[!A-Za-z0-9._-]*)
    echo "Invalid tmux session name: $SESSION" >&2
    exit 1
    ;;
esac
if tmux has-session -t "=$SESSION" 2>/dev/null; then
  echo "tmux session already exists: $SESSION" >&2
  echo "Attach with: tmux attach -t $SESSION" >&2
  exit 1
fi

created=0
cleanup_failed() {
  if [ "$created" -eq 1 ]; then
    tmux kill-session -t "$SESSION" 2>/dev/null || true
  fi
}
trap cleanup_failed ERR

printf -v score_cmd 'exec r %q %q 1' \
  "$SCRIPT_DIR/watch-scoreboard.R" "$RUN_DIR"
score_pane="$(tmux new-session -d -P -F '#{pane_id}' -s "$SESSION" \
  -n dashboard -x 240 -y 72 -c "$SCRIPT_DIR" "$score_cmd")"
created=1
tmux set-option -w -t "$score_pane" window-size manual >/dev/null
tmux resize-window -t "$score_pane" -x 240 -y 72
tmux select-pane -t "$score_pane" -T "Scoreboard"

board_cmd() {
  local index="$1"
  printf -v board_cmd 'ARC_WATCH_INDEX=%q exec r %q %q 1' \
    "$index" "$SCRIPT_DIR/watch-board.R" "$RUN_DIR"
}

board_cmd 1
game1="$(tmux split-window -h -l '67%' -d -P -F '#{pane_id}' \
  -t "$score_pane" -c "$SCRIPT_DIR" "$board_cmd")"
tmux select-pane -t "$game1" -T "Game 1"
board_cmd 2
game2="$(tmux split-window -h -l '50%' -d -P -F '#{pane_id}' \
  -t "$game1" -c "$SCRIPT_DIR" "$board_cmd")"
tmux select-pane -t "$game2" -T "Game 2"
board_cmd 3
game3="$(tmux split-window -v -l '50%' -d -P -F '#{pane_id}' \
  -t "$score_pane" -c "$SCRIPT_DIR" "$board_cmd")"
tmux select-pane -t "$game3" -T "Game 3"
board_cmd 4
game4="$(tmux split-window -v -l '50%' -d -P -F '#{pane_id}' \
  -t "$game1" -c "$SCRIPT_DIR" "$board_cmd")"
tmux select-pane -t "$game4" -T "Game 4"
board_cmd 5
game5="$(tmux split-window -v -l '50%' -d -P -F '#{pane_id}' \
  -t "$game2" -c "$SCRIPT_DIR" "$board_cmd")"
tmux select-pane -t "$game5" -T "Game 5"

tmux set-option -t "$SESSION" pane-border-status top >/dev/null
tmux set-option -t "$SESSION" pane-border-format \
  ' #[bold]#{pane_title}#[default] ' >/dev/null
tmux select-pane -t "$score_pane"
trap - ERR

echo "ARC monitor ready: $SESSION"
echo "Campaign: $RUN_DIR"
echo "Attach: tmux attach -t $SESSION"
