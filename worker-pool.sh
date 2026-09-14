#!/usr/bin/env bash
# Generic bounded worker pool for sweep.sh. The parent owns queue assignment;
# each child receives exactly one slug and returns 0 (done), 1 (incomplete), or
# 2 (the shared scorecard is invalid). A fatal status cancels active siblings.

declare -Ag ARC_POOL_ACTIVE=()
ARC_POOL_LAST_SLUG=""
ARC_POOL_FATAL_SLUG=""

arc_pool_terminate_tree() {
  local pid="$1" children="" child
  # Freeze each process before walking its children so it cannot fork between
  # discovery and termination. ARC runs only in the Linux container; /proc is
  # authoritative there. The fallback still terminates the direct worker.
  kill -STOP "$pid" 2>/dev/null || true
  if [ -r "/proc/$pid/task/$pid/children" ]; then
    read -r children < "/proc/$pid/task/$pid/children" || true
  fi
  for child in $children; do
    arc_pool_terminate_tree "$child"
  done
  kill -TERM "$pid" 2>/dev/null || true
  kill -CONT "$pid" 2>/dev/null || true
}

arc_pool_stop_workers() {
  local pid
  for pid in "${!ARC_POOL_ACTIVE[@]}"; do
    arc_pool_terminate_tree "$pid"
  done
  for pid in "${!ARC_POOL_ACTIVE[@]}"; do
    wait "$pid" 2>/dev/null || true
    unset 'ARC_POOL_ACTIVE[$pid]'
  done
}

arc_pool_wait_one() {
  local completed="" status=0
  if wait -n -p completed; then
    status=0
  else
    status=$?
  fi
  if [ -z "$completed" ]; then
    ARC_POOL_LAST_SLUG=""
    return 125
  fi
  ARC_POOL_LAST_SLUG="${ARC_POOL_ACTIVE[$completed]-unknown}"
  unset 'ARC_POOL_ACTIVE[$completed]'
  return "$status"
}

arc_run_pool() {
  local slots="${1:?arc_run_pool needs a slot count}"
  local worker="${2:?arc_run_pool needs a worker function}"
  shift 2
  case "$slots" in
    ''|*[!0-9]*|0)
      echo "arc_run_pool: slots must be a positive integer" >&2
      return 64
      ;;
  esac
  if ! declare -F "$worker" >/dev/null; then
    echo "arc_run_pool: unknown worker function '$worker'" >&2
    return 64
  fi

  ARC_POOL_ACTIVE=()
  ARC_POOL_LAST_SLUG=""
  ARC_POOL_FATAL_SLUG=""
  local incomplete=0 slug pid status
  for slug in "$@"; do
    "$worker" "$slug" &
    pid=$!
    ARC_POOL_ACTIVE[$pid]="$slug"
    while [ "${#ARC_POOL_ACTIVE[@]}" -ge "$slots" ]; do
      if arc_pool_wait_one; then status=0; else status=$?; fi
      if [ "$status" -eq 2 ]; then
        ARC_POOL_FATAL_SLUG="$ARC_POOL_LAST_SLUG"
        arc_pool_stop_workers
        return 2
      fi
      if [ "$status" -ne 0 ]; then
        incomplete=1
      fi
    done
  done

  while [ "${#ARC_POOL_ACTIVE[@]}" -gt 0 ]; do
    if arc_pool_wait_one; then status=0; else status=$?; fi
    if [ "$status" -eq 2 ]; then
      ARC_POOL_FATAL_SLUG="$ARC_POOL_LAST_SLUG"
      arc_pool_stop_workers
      return 2
    fi
    if [ "$status" -ne 0 ]; then
      incomplete=1
    fi
  done
  return "$incomplete"
}
