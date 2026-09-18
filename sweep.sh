#!/usr/bin/env bash
# Resumable ARC-AGI-3 catalog sweep: one driver invocation per game,
# N games at a time.
#
# Why a loop and not `driver.R <many slugs>`: the driver catches a
# failed game and moves to the next slug, so one rate-limit window
# would burn the whole remaining catalog into error records in a couple
# of minutes. Here each game is its own invocation, a 429 costs one
# attempt, and that game sleeps until the window is likely back.
#
# Parallelism is bounded by the provider's rate limit, not by cores:
# a game is I/O-bound (~0.1% CPU, parked in HTTP waits), so slots are
# about how many concurrent API conversations the account tolerates.
#
# Resumability: a game counts as done when a record exists for it with
# the CURRENT prompt hash, the current model, and a real scorecard (not
# a DRIVER ERROR). So this can be killed and restarted at any time.
# Changing the prompt makes every game un-done again, which is the
# point -- the corpus is meant to be uniform.
#
# Usage: sweep.sh [model] [provider] [slots] [max_fails_per_game] [slug ...]
# Clean shared scorecard: set ARC_CAMPAIGN_LABEL to a new label. Bounded
# workers clone the campaign seed cookies and play independent games on the
# same card; artifacts stay under campaigns/<label>/.
#
# Naming slugs runs only those games, in the order given, instead of the
# whole catalog -- for a controlled single-game comparison (the same
# board at two efforts) without committing to 25 games first.

set -uo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
source "$SCRIPT_DIR/worker-pool.sh"
ARC_DIR="${ARC_DIR:-$SCRIPT_DIR}"
ARC_OUTPUT_DIR="${ARC_OUTPUT_DIR:-$ARC_DIR}"
MODEL="${1:-claude-opus-5}"
PROVIDER="${2:-anthropic}"
SLOTS="${3:-5}"
MAX_FAILS="${4:-2}"      # non-rate-limit failures allowed per game
CAMPAIGN_LABEL="${ARC_CAMPAIGN_LABEL:-}"
case "$SLOTS" in
  ''|*[!0-9]*|0)
    echo "sweep: slots must be a positive integer" >&2
    exit 1
    ;;
esac
if [ -n "$CAMPAIGN_LABEL" ]; then
  case "$CAMPAIGN_LABEL" in
    *[!A-Za-z0-9._-]*|[!A-Za-z0-9]*)
      echo "sweep: invalid ARC_CAMPAIGN_LABEL '$CAMPAIGN_LABEL'" >&2
      exit 1
      ;;
  esac
  RUN_DIR="$ARC_OUTPUT_DIR/campaigns/$CAMPAIGN_LABEL"
else
  RUN_DIR="$ARC_OUTPUT_DIR"
fi
LOG="$RUN_DIR/sweep.log"
RUNS="$RUN_DIR/runs.jsonl"
mkdir -p "$RUN_DIR"
export ARC_DIR ARC_OUTPUT_DIR ARC_RUN_DIR="$RUN_DIR" ARC_SLOTS="$SLOTS"
MAX_WAITS=10             # rate-limit sleeps allowed per game (~50 min)
COOLDOWN=300             # 5 min: stay under ARC's 15-min inactivity deadline
# Wall clock per game: the driver sizes it to the action budget
# (budget / ARC_ACTIONS_PER_HOUR hours) and this is the floor.
export ARC_GAME_TIMEOUT=21600
export ARC_ACTIONS_PER_HOUR="${ARC_ACTIONS_PER_HOUR:-300}"
export ARC_MAX_TOKENS=32000
export ARC_CONTEXT_COMPACT_PCT="${ARC_CONTEXT_COMPACT_PCT:-75}"
export ARC_CONTEXT_COMPACT_BYTES="${ARC_CONTEXT_COMPACT_BYTES:-900000}"
export ARC_REQUEST_BUFFER_RETRIES="${ARC_REQUEST_BUFFER_RETRIES:-3}"
export ARC_COMPACT_TIMEOUT="${ARC_COMPACT_TIMEOUT:-120}"
export ARC_NET_RETRIES="${ARC_NET_RETRIES:-5}"
export ARC_LIMIT_RETRIES="${ARC_LIMIT_RETRIES:-10}"
export ARC_LIMIT_RETRY_SECS="${ARC_LIMIT_RETRY_SECS:-300}"

# Reasoning depth. Two knobs because the providers disagree: effort on
# the openai/codex wire, a thinking-token budget on Anthropic. The
# driver adds the thinking budget ON TOP of ARC_MAX_TOKENS, so usable
# output stays at 32000.
export ARC_EFFORT="${ARC_EFFORT:-high}"
case "${ARC_THINKING:-0}" in
  ''|*[!0-9]*) ARC_THINKING=0 ;;
esac
export ARC_THINKING

# The corpus key comes from depth.R -- the same function the driver
# resolves the session with -- rather than being restated here. Getting
# it wrong is silent in the direction that matters: too strict replays
# finished games (visible), too loose accepts a default-effort record as
# a result for a high-effort sweep (invisible).
# Separator is "|", not a tab: tab is IFS *whitespace*, so bash
# collapses a leading empty field and every value shifts one column
# left. An unset effort (the Anthropic case) is exactly that empty
# field, and the silent result was THINK_KEY holding the cap.
depth_line="$(r -e 'a <- if (exists("argv")) argv else commandArgs(TRUE)
        source(file.path(a[1], "depth.R"))
        d <- arc_depth(a[2])
        cat(d$effort, d$think, d$max_tokens, sep = "|")' \
    "$ARC_DIR" "$PROVIDER")" || {
  echo "sweep: depth.R could not resolve reasoning depth" >&2
  exit 1
}
IFS='|' read -r EFFORT_KEY THINK_KEY CAP_KEY <<< "$depth_line"
if [ -z "$CAP_KEY" ]; then
  echo "sweep: depth.R returned '$depth_line' -- cannot key the corpus" >&2
  exit 1
fi

# Deterministic shortest-to-longest priority queue. A genuinely live checkpoint
# goes first on process restart so its authoritative recording does not expire;
# those checkpoints retain the same baseline order. Every completion frees one
# worker, which greedily claims the next slug. Already-done games are skipped by
# is_done() regardless of where they sit. Explicit slugs after the four
# positional args override the whole order.
#
EXPLICIT_SELECTION=0
if [ "$#" -gt 4 ]; then
  EXPLICIT_SELECTION=1
  shift 4
  ORDER="$*"
else
  ORDER="$(r -e 'a <- if (exists("argv")) argv else commandArgs(TRUE)
        source(file.path(a[1], "schedule.R"))
        inprog <- character()
        for (f in list.files(file.path(a[2], "inflight"), full.names = TRUE)) {
            x <- tryCatch(jsonlite::fromJSON(f), error = function(e) NULL)
            if (is.null(x) || !isTRUE(x$model == a[3])) next
            id <- if (is.null(x$run_id)) x$card_id else x$run_id
            tr <- file.path(a[2], "traces", paste0(id, ".jsonl"))
            # a game instance outlives its process by minutes, not hours
            # (alive at 5 min, gone at 2.5 h): an older checkpoint is
            # not "in progress", it is a game to start over in its turn
            fresh <- file.exists(tr) &&
                as.numeric(difftime(Sys.time(), file.mtime(tr), units = "secs")) < 3600
            if (fresh && length(readLines(tr, warn = FALSE)) > 20) inprog <- c(inprog, x$slug)
        }
        cat(arc_game_order(file.path(a[1], "baselines"), inprog))' "$ARC_DIR" "$RUN_DIR" "$MODEL")"
fi
ORDER_COUNT="$(set -- $ORDER; echo $#)"
if [ "$EXPLICIT_SELECTION" -eq 0 ] && [ "$ORDER_COUNT" -ne 25 ]; then
  echo "sweep: canonical catalog must contain exactly 25 games (found $ORDER_COUNT)" >&2
  exit 1
fi


say() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# Earlier prompts whose records still count as done. 86f7e38164dd is
# the prompt that let the model quit ("until you have exhausted your
# ideas"); its successor only withdrew that permission, so a game
# finished under it is a result, not something to replay. Override
# with DONE_SHAS= (empty) to replay everything under the live prompt.
DONE_SHAS="${DONE_SHAS-86f7e38164dd}"

# Hash of the live prompt, computed the way the driver does, so
# "already done" means done under THIS prompt.
SHA="$(r -e 'src <- readLines("'"$ARC_DIR"'/driver.R", warn = FALSE)
        i <- grep("^ARC_SYSTEM <- paste0\\(", src)[1]
        j <- grep("^play_one <- function", src)[1]
        eval(parse(text = paste(src[i:(j-1)], collapse = "\n")))
        cat(substr(digest::digest(ARC_SYSTEM, algo = "sha256"), 1, 12))')"
PROTOCOL_KEY="$(r -e 'source("'"$ARC_DIR"'/version.R"); cat(ARC_PROTOCOL_VERSION)')" || {
  echo "sweep: version.R could not resolve the protocol" >&2
  exit 1
}

CAMPAIGN_CLOSED=0
close_campaign() {
  [ -n "${ARC_CAMPAIGN:-}" ] || return 0
  [ "$CAMPAIGN_CLOSED" -eq 0 ] || return 0
  if ARC_HARNESS_DIR="$ARC_DIR" r "$ARC_DIR/campaign.R" close \
      "$ARC_CAMPAIGN" >>"$LOG" 2>&1; then
    CAMPAIGN_CLOSED=1
    return 0
  fi
  say "campaign close failed; run campaign.R close manually"
  return 1
}

campaign_signal() {
  local status="$1"
  trap - INT TERM HUP
  arc_pool_stop_workers
  say "sweep interrupted; campaign left open for authoritative resume"
  exit "$status"
}

if [ -n "$CAMPAIGN_LABEL" ]; then
  export ARC_CAMPAIGN="$RUN_DIR/campaign.json"
  campaign_cmd=open
  [ -f "$ARC_CAMPAIGN" ] && campaign_cmd=validate
  if ! ARC_HARNESS_DIR="$ARC_DIR" r "$ARC_DIR/campaign.R" "$campaign_cmd" \
      "$ARC_CAMPAIGN" "$CAMPAIGN_LABEL" "$MODEL" "$PROVIDER" "$SHA" \
      "$EFFORT_KEY" "$THINK_KEY" "$CAP_KEY" "$SLOTS" $ORDER >>"$LOG" 2>&1; then
    echo "sweep: could not $campaign_cmd campaign '$CAMPAIGN_LABEL'; see $LOG" >&2
    exit 1
  fi
  trap 'campaign_signal 130' INT
  trap 'campaign_signal 143' TERM
  trap 'campaign_signal 129' HUP
else
  unset ARC_CAMPAIGN
fi

# `argv`, not commandArgs(): under littler, script arguments land in
# argv and commandArgs(TRUE) comes back empty -- which made every game
# look un-done, i.e. a full replay of an already finished game.
# Reasoning depth is part of the corpus key, alongside prompt and
# model. A record written at the provider's default effort is not a
# result for a sweep running at ARC_EFFORT=high: same prompt, same
# model, different thinking. Records predating the effort field carry
# no `effort` at all, so they read as a mismatch and get replayed --
# which is the correct answer for them too.
is_done() {
  r -e 'args <- if (exists("argv")) argv else commandArgs(TRUE)
        fs <- list.files(args[1], full.names = TRUE, pattern = "[.]json$")
        ok <- vapply(fs, function(f) {
            x <- tryCatch(jsonlite::fromJSON(f), error = function(e) NULL)
            if (is.null(x)) return(FALSE)
            eff <- if (is.null(x$effort) || is.na(x$effort)) "" else x$effort
            thk <- if (is.null(x$thinking) || is.na(x$thinking)) "0" else
                   as.character(x$thinking)
            # Played counts if EITHER account of the run survived. The
            # official scorecard is authoritative, but its fetch can
            # fail on a long game (session-scoped card ids behind an
            # affinity cookie) -- and keying only on it discarded a
            # finished 5-of-6 run and replayed it for 105 minutes.
            # trace_levels is the local count off the frames the server
            # actually returned; a game with one is played.
            # (No apostrophes in here: this R snippet lives inside a
            # single-quoted shell string, and one ends it early.)
            played <- !is.null(x$official$levels_completed) ||
                      (!is.null(x$trace_levels) && !is.na(x$trace_levels))
            same_config <- identical(as.integer(x$protocol_version),
                                     as.integer(args[8])) &&
                isTRUE(x$prompt_sha %in% strsplit(args[3], ",")[[1]]) &&
                isTRUE(x$model == args[4]) &&
                identical(eff, args[5]) && identical(thk, args[6]) &&
                isTRUE(played)
            # A game some model already scored 100 on is done for the
            # sweep whatever model this pass runs (DONE_WON_ANY_MODEL=1,
            # the default): the second model is for the games the
            # first did not win, not for replaying the ones it did.
            won_any <- identical(args[7], "1") &&
                (isTRUE(x$api_score >= 99.99) || isTRUE(x$final_score >= 99.99))
            isTRUE(x$slug == args[2]) && (same_config || won_any)
        }, logical(1))
        quit(status = if (any(ok)) 0L else 1L)' \
    "$RUN_DIR/records" "$1" "$SHA${DONE_SHAS:+,$DONE_SHAS}" "$MODEL" "$EFFORT_KEY" "$THINK_KEY" \
    "${DONE_WON_ANY_MODEL:-1}" "$PROTOCOL_KEY" \
    >/dev/null 2>&1
}

# Did this game's own last attempt die on a retryable provider fault?
# Reads that game's own log, never the shared stream -- with parallel
# slots the tail of runs.jsonl belongs to whichever game finished last.
#
# Two distinct provider faults belong here, both transient and both
# worth waiting out rather than counting as failures: Anthropic's
# usage-limit 429 ("rate limit") and the Codex backend's overload
# ("servers are currently overloaded"), which kills a game in about
# two seconds.
#
# Note the mandatory argument: called bare under `set -u`, the unbound
# $1 is a fatal error that silently kills the calling subshell -- which
# is exactly what happened, giving every game one attempt and no
# retries at all while logging nothing.
# Reads the failure RECORD, not the game log: the driver catches the
# error and writes it into the record's `summary`, while stdout only
# ever gets "-> won: ?". A detector pointed at the log could never see
# the evidence -- and silently classified every fault as permanent.
# Failure records are named by slug (a successful one is named by card
# id), so records/<slug>.json is exactly "this game's last failure".
#
# The limit family is decided by corteza's own .is_limit_error() rather
# than restated as a shell pattern. The shell pattern was already
# wrong: it listed "rate limit" and "overloaded" but not "usage limit",
# so `API error (429): The usage limit has been reached` -- the Codex
# backend's own wording -- read as a permanent failure and the game was
# abandoned after MAX_FAILS attempts instead of waiting out a window
# that reopens on its own. corteza has to answer the same question
# inside a turn and covers rate/usage limit, quota, overloaded and the
# 429/503/529 prefixes; there is no reason for a second copy here to
# drift from it.
#
# Timeouts are terminal, not retryable. The wall clock is now sized to
# the game's action budget, so a game that hits it has genuinely
# played that long; replaying it from scratch would spend the same
# hours again for the same outcome. (A game that dies to a limit error
# dies at its first model call and is cheap to retry; that is the only
# retryable class.)
retryable_fault() {
  local slug="${1:?retryable_fault needs a slug}"
  local rec="$RUN_DIR/records/$slug.json"
  [ -f "$rec" ] || return 1
  r -e 'a <- if (exists("argv")) argv else commandArgs(TRUE)
        x <- tryCatch(jsonlite::fromJSON(a[1]), error = function(e) NULL)
        s <- if (is.null(x$summary)) "" else as.character(x$summary)
        limit <- isTRUE(corteza:::.is_limit_error(simpleError(s)))
        quit(status = if (limit) 0L else 1L)' "$rec" >/dev/null 2>&1
}

# A failed environment is local to one slug; only an explicit card-id error is
# fatal to every later slug. A fresh game missing on its bootstrap RESET may
# be an affinity failure, so retry it without stopping healthy siblings.
campaign_invalid_fault() {
  local slug="${1:?campaign_invalid_fault needs a slug}"
  [ -n "$CAMPAIGN_LABEL" ] || return 1
  r -e 'a <- if (exists("argv")) argv else commandArgs(TRUE)
        dirs <- file.path(a[2], c("records", "failures"))
        fs <- unlist(lapply(dirs[file.exists(dirs)], function(d)
            list.files(d, pattern = "[.]json$", full.names = TRUE)))
        source(file.path(a[1], "client.R"))
        if (!length(fs)) quit(status = 1L)
        recs <- lapply(fs, function(f) {
            x <- tryCatch(jsonlite::fromJSON(f, simplifyVector = FALSE),
                          error = function(e) NULL)
            if (is.null(x) || !isTRUE(x$slug == a[3])) return(NULL)
            list(x = x, mtime = file.mtime(f))
        })
        recs <- Filter(Negate(is.null), recs)
        if (!length(recs)) quit(status = 1L)
        rec <- recs[[which.max(vapply(recs, function(z)
            as.numeric(z$mtime), 0))]]$x
        summary <- if (is.null(rec$summary)) "" else rec$summary
        official <- if (is.null(rec$official_error)) "" else rec$official_error
        card_gone <- arc_card_missing_error(summary, official)
        quit(status = if (card_gone) 0L else 1L)' \
    "$ARC_DIR" "$RUN_DIR" "$slug" >/dev/null 2>&1
}

# A server-side game can disappear while the shared scorecard remains valid.
# This is terminal only for that slug: do not let the model loop on tool errors
# and do not create a second trajectory for the same game on this card.
authoritative_game_gone_fault() {
  local slug="${1:?authoritative_game_gone_fault needs a slug}"
  local rec="$RUN_DIR/records/$slug.json"
  [ -f "$rec" ] || return 1
  r -e 'a <- if (exists("argv")) argv else commandArgs(TRUE)
        x <- tryCatch(jsonlite::fromJSON(a[1]), error = function(e) NULL)
        summary <- if (is.null(x$summary)) "" else as.character(x$summary)
        gone <- grepl("authoritative ARC game (recording )?is gone",
                      summary, ignore.case = TRUE, perl = TRUE)
        quit(status = if (gone) 0L else 1L)' "$rec" >/dev/null 2>&1
}

# The card of a game that died mid-play, if any: the newest inflight/
# entry for this slug whose trace moved within ARC_RESUME_MAX_AGE
# seconds (default 6h). A finished game retires its entry to done/, so
# "still in inflight/" is exactly "died without a record". Prints
# nothing when there is nothing to resume.
resumable_card() {
  r -e 'a <- if (exists("argv")) argv else commandArgs(TRUE)
        fs <- list.files(file.path(a[1], "inflight"), pattern = "[.]json$", full.names = TRUE)
        fs <- fs[order(file.mtime(fs), decreasing = TRUE)]
        for (f in fs) {
            x <- tryCatch(jsonlite::fromJSON(f), error = function(e) NULL)
            if (is.null(x) || !isTRUE(x$slug == a[2]) || !isTRUE(x$model == a[4])) next
            id <- if (is.null(x$run_id)) x$card_id else x$run_id
            tr <- file.path(a[1], "traces", paste0(id, ".jsonl"))
            if (!file.exists(tr)) next
            age <- as.numeric(difftime(Sys.time(), file.mtime(tr), units = "secs"))
            if (age > as.numeric(a[3])) next
            cat(x$card_id); break
        }' "$RUN_DIR" "$1" "${ARC_RESUME_MAX_AGE:-21600}" "$MODEL" 2>/dev/null
}

play_game() {
  local slug="$1"
  local glog="$RUN_DIR/logs/$slug.log"
  mkdir -p "$RUN_DIR/logs"
  local waits=0 fails=0 resumes=0 attempts=0 card="" was_resume=0
  while :; do
    was_resume=0
    attempts=$((attempts + 1))
    # Preserve every failed attempt. The driver records the actual exception
    # in records/<slug>.json while stdout only carries a score summary; deleting
    # that record and truncating this log erased the only diagnosis of the
    # first protocol-v3 process failure. Archive the prior record before the
    # next attempt and keep one append-only game log.
    if [ -f "$RUN_DIR/records/$slug.json" ]; then
      mkdir -p "$RUN_DIR/failures"
      mv "$RUN_DIR/records/$slug.json" \
        "$RUN_DIR/failures/$slug-$(date -u +%Y%m%dT%H%M%SZ)-attempt-$(printf '%03d' "$((attempts - 1))").json"
    fi
    printf '\n== attempt %d at %s ==\n' "$attempts" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$glog"
    # A game that died mid-play is resumed, not replayed: same card,
    # same guid, the checkpointed conversation and workspace restored.
    card="$(resumable_card "$slug")"
    if [ -n "$card" ] && [ "$resumes" -ge "${ARC_MAX_RESUMES:-5}" ]; then
      say "$slug: unrecoverable after $resumes resume attempts; stopping clean campaign"
      return 1
    fi
    if [ -n "$card" ] && [ "$resumes" -lt "${ARC_MAX_RESUMES:-5}" ]; then
      resumes=$((resumes + 1))
      was_resume=1
      say "$slug: resuming card $card (resume $resumes/${ARC_MAX_RESUMES:-5}, waits=$waits fails=$fails)"
      ( cd "$ARC_DIR" && ARC_RESUME="$card" r "$ARC_DIR/driver.R" \
          "$MODEL" "$PROVIDER" 100000 1 "$slug" ) >>"$glog" 2>&1
    else
      say "$slug: starting (waits=$waits fails=$fails)"
      ( cd "$ARC_DIR" && r "$ARC_DIR/driver.R" \
          "$MODEL" "$PROVIDER" 100000 1 "$slug" ) >>"$glog" 2>&1
    fi
    if campaign_invalid_fault "$slug"; then
      say "$slug: shared scorecard is no longer authoritative; stopping campaign immediately"
      return 2
    fi
    if authoritative_game_gone_fault "$slug"; then
      say "$slug: authoritative game vanished; leaving it incomplete and advancing the queue"
      return 1
    fi
    if is_done "$slug"; then
      say "$slug: DONE -- $(grep -- '->' "$glog" | tail -1 | tr -s ' ')"
      return 0
    fi
    # Two budgets, because the two failures cost differently. A 429 is
    # cheap (dies at the first model call) and self-healing once the
    # window resets, so it gets patient retries. Anything else is a bug
    # or a dead game and gets few, or one broken game eats hours.
    if retryable_fault "$slug"; then
      # A provider fault on a resume attempt spent no resume: give it
      # back, or five 30-minute usage-limit waits exhaust
      # ARC_MAX_RESUMES without making progress.
      [ "$was_resume" = 1 ] && resumes=$((resumes - 1))
      waits=$((waits + 1))
      if [ "$waits" -gt "$MAX_WAITS" ]; then
        say "$slug: provider still faulting after $MAX_WAITS waits, giving up"
        return 1
      fi
      say "$slug: provider fault, sleeping ${COOLDOWN}s (wait $waits/$MAX_WAITS)"
      sleep "$COOLDOWN"
    elif [ "$was_resume" = 1 ]; then
      # If the driver proved the authoritative recording is gone, it retired
      # inflight/ to done/. Starting this slug fresh on the same scorecard
      # would make a supposedly clean run contain two trajectories. Halt the
      # whole campaign (return 2 trips the worker-pool circuit breaker) so the
      # scorecard stays clean; an operator opens a genuinely fresh card.
      if [ -z "$(resumable_card "$slug")" ]; then
        say "$slug: authoritative recording is gone; stopping clean campaign"
        return 2
      fi
      say "$slug: resume of $card failed, retrying in 60s (resume $resumes/${ARC_MAX_RESUMES:-5})"
      sleep 60
    else
      fails=$((fails + 1))
      if [ "$fails" -ge "$MAX_FAILS" ]; then
        say "$slug: GIVING UP after $fails non-rate-limit failures"
        return 1
      fi
      say "$slug: failed (not a provider fault), retrying in 60s"
      sleep 60
    fi
  done
}

say "sweep starting | model=$MODEL provider=$PROVIDER slots=$SLOTS campaign=${CAMPAIGN_LABEL:-none}"\
    "protocol=$PROTOCOL_KEY prompt_sha=$SHA effort=${EFFORT_KEY:-none} thinking=$THINK_KEY"\
    "cap=$CAP_KEY compact=$ARC_CONTEXT_COMPACT_PCT%/$ARC_CONTEXT_COMPACT_BYTES bytes"\
    "request_buffer_retries=$ARC_REQUEST_BUFFER_RETRIES"\
    "model_retries=$ARC_NET_RETRIES/$ARC_LIMIT_RETRIES limit_wait=$ARC_LIMIT_RETRY_SECS"\
    "games=$(set -- $ORDER; echo $#)"

PENDING=()
for slug in $ORDER; do
  if is_done "$slug"; then
    say "$slug: already done under this prompt+model, skipping"
  else
    PENDING+=("$slug")
  fi
done

pool_status=0
if [ "${#PENDING[@]}" -gt 0 ]; then
  arc_run_pool "$SLOTS" play_game "${PENDING[@]}" || pool_status=$?
fi
if [ "$pool_status" -eq 2 ]; then
  say "${ARC_POOL_FATAL_SLUG:-unknown}: expired-card circuit breaker opened; active workers stopped and remaining games were not attempted"
  exit 2
elif [ "$pool_status" -ne 0 ]; then
  say "sweep incomplete: at least one game failed; full-set verification follows"
fi

VERIFY_ORDER="$ORDER"
if [ -n "$CAMPAIGN_LABEL" ]; then
  VERIFY_ORDER="$(r -e 'a <- if (exists("argv")) argv else commandArgs(TRUE)
        x <- tryCatch(jsonlite::fromJSON(a[1], simplifyVector = FALSE),
                      error = function(e) NULL)
        games <- unlist(x$expected_games, use.names = FALSE)
        if (!length(games)) quit(status = 1L)
        cat(games)' "$ARC_CAMPAIGN")" || {
    say "sweep incomplete: campaign expected-game set is missing or invalid"
    exit 1
  }
fi

missing=
for slug in $VERIFY_ORDER; do
  if ! is_done "$slug"; then
    missing="${missing}${missing:+ }$slug"
  fi
done
if [ -n "$missing" ]; then
  say "sweep incomplete after full-set verification; missing: $missing"
  exit 1
fi
if [ -n "$CAMPAIGN_LABEL" ]; then
  say "sweep finished; every expected campaign game has a matching completed record"
else
  say "sweep finished; every selected game has a matching completed record"
fi
close_campaign
