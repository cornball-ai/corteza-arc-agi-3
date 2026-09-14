# Post ARC sweep progress to a configured Matrix room on a fixed cadence.
#
# Why local state: the live scorecard is invisible from outside the
# playing session (AWSALB affinity; GET /api/scorecard/{card} 404s from
# any other handle), but /api/sessions/{guid} and
# /api/recordings/{game}/{guid} answer to the API key from anywhere
# once a guid is known -- and a record carries the guid only when the
# driver writes it at game end. So: mid-game from traces/, finished
# games from records/ plus the sessions route.
#
# The Matrix config is re-read per call and refreshed tokens are persisted
# by the messaging client. The token is never read or printed here.
#
# Usage: r watch-room.R [interval_seconds]   (default 1800)
#   ARC_WATCH_ONCE=1   post once and exit (used for the first message)
# Required: ARC_MATRIX_ROOM, ARC_MATRIX_CONFIG, ARC_MATRIX_INSTANCE_DIR.

required_setting <- function(name) {
    value <- Sys.getenv(name, "")
    if (!nzchar(trimws(value))) {
        stop("set ", name, " before running the Matrix watcher", call. = FALSE)
    }
    value
}
room <- required_setting("ARC_MATRIX_ROOM")
matrix_config <- path.expand(required_setting("ARC_MATRIX_CONFIG"))
instance_dir <- path.expand(required_setting("ARC_MATRIX_INSTANCE_DIR"))
if (!file.exists(matrix_config) || !dir.exists(instance_dir)) {
    stop("Matrix config file and instance directory must exist", call. = FALSE)
}

arc_dir <- path.expand(Sys.getenv("ARC_DIR", getwd()))
`%||%` <- function(a, b) if (is.null(a)) b else a
read_json <- function(f) tryCatch(jsonlite::fromJSON(f),
                                  error = function(e) NULL)

run_dir_env <- Sys.getenv("ARC_RUN_DIR", "")
campaign_label <- Sys.getenv("ARC_CAMPAIGN_LABEL", "")
if (nzchar(run_dir_env)) {
    run_dir <- path.expand(run_dir_env)
} else if (nzchar(campaign_label)) {
    run_dir <- file.path(arc_dir, "campaigns", campaign_label)
} else {
    # Without an explicit campaign label, prefer the newest open
    # supported protocol campaign, then the newest closed campaign.
    manifests <- list.files(file.path(arc_dir, "campaigns"),
                            pattern = "^campaign[.]json$", recursive = TRUE,
                            full.names = TRUE)
    metadata <- lapply(manifests, read_json)
    usable <- which(vapply(metadata, function(x) {
        !is.null(x) &&
        as.integer(x$protocol_version %||% NA) %in% c(2L, 3L, 4L, 5L)
    }, logical(1)))
    if (length(usable)) {
        open <- usable[vapply(metadata[usable], function(x)
                              identical(x$state, "open"), logical(1))]
        if (length(open)) {
            candidates <- open
        } else {
            candidates <- usable
        }
        chosen <- candidates[[which.max(file.info(manifests[candidates])$mtime)]]
        run_dir <- dirname(manifests[[chosen]])
    } else {
        stop("no supported ARC protocol-v2/v3/v4/v5 campaign is available to monitor",
             call. = FALSE)
    }
}
campaign <- read_json(file.path(run_dir, "campaign.json"))
if (is.null(campaign) ||
    !as.integer(campaign$protocol_version %||% NA) %in% c(2L, 3L, 4L, 5L)) {
    stop("ARC watcher requires a protocol-v2/v3/v4/v5 campaign", call. = FALSE)
}

watch_state_path <- file.path(run_dir, "watch-state.json")
watch_state <- function() {
    read_json(watch_state_path) %||% list()
}
posted_finished_details <- function(state = watch_state()) {
    unique(c(as.character(state$finished_detail_run_ids %||% character()),
             as.character(state$last_finished_detail_run_id %||% character())))
}

mark_finished_detail <- function(run_ids) {
    state <- watch_state()
    ids <- unique(c(posted_finished_details(state), as.character(run_ids)))
    state$finished_detail_run_ids <- ids
    state$last_finished_detail_run_id <- utils::tail(ids, 1L)
    state$last_finished_detail_posted_at <-
        format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
    tmp <- tempfile("watch-state-", tmpdir = run_dir)
    writeLines(jsonlite::toJSON(state, auto_unbox = TRUE, pretty = TRUE), tmp)
    if (!isTRUE(file.rename(tmp, watch_state_path))) {
        unlink(tmp)
        warning("could not persist ARC watcher state", call. = FALSE)
        return(FALSE)
    }
    TRUE
}

if (exists("argv")) {
    args <- argv
} else {
    args <- commandArgs(TRUE)
}
if (length(args)) {
    interval <- as.numeric(args[[1]])
} else {
    interval <- 1800
}

utc <- function(s) as.POSIXct(s, tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ")
mins <- function(a, b) round(as.numeric(difftime(b, a, units = "mins")))

# Human baselines come from /api/sessions/{guid}: per-level actions,
# per-level human baseline actions, per-level scores. littler does not
# load ~/.Renviron, and the routine runs under littler, so the key is
# read explicitly; without a key every baseline is simply omitted.
if (file.exists("~/.Renviron")) {
    readRenviron("~/.Renviron")
}
source(file.path(arc_dir, "client.R"), local = TRUE)
arc_cl <- tryCatch(arc_client(), error = function(e) NULL)
session_levels <- function(guid) {
    if (is.null(arc_cl) || is.null(guid) || is.na(guid)) {
        return(NULL)
    }
    tryCatch({
        runs <- arc_session(arc_cl, guid)$environments[[1]]$runs
        run <- Filter(function(r) identical(r$guid, guid), runs)
        run <- if (length(run)) run[[1]] else runs[[1]]
        num <- function(v) vapply(v, function(z) if (is.null(z)) {
                NA_real_
            } else {
                as.numeric(z)
            }, 1)
        list(actions = num(run$level_actions),
             baseline = num(run$level_baseline_actions),
             scores = num(run$level_scores))
    }, error = function(e) NULL)
}
# The sessions route 404s while a card is still open, so a live game
# cannot read its own baselines. The baseline is a property of the
# game, not the run: /api/games publishes baseline_actions per level
# for the whole catalog. Cached per slug so a post costs one catalog
# fetch at most, ever.
game_baseline <- function(slug) {
    cache <- file.path(arc_dir, "baselines", paste0(slug, ".json"))
    if (file.exists(cache)) {
        return(read_json(cache))
    }
    if (is.null(arc_cl)) {
        return(NULL)
    }
    found <- NULL
    tryCatch({
        dir.create(dirname(cache), showWarnings = FALSE)
        for (g in arc_games(arc_cl)) {
            bl <- as.numeric(unlist(g$baseline_actions))
            if (!length(bl)) next
            s <- sub("-.*$", "", g$game_id)
            writeLines(jsonlite::toJSON(list(baseline = bl), digits = NA),
                       file.path(dirname(cache), paste0(s, ".json")))
            if (identical(s, slug)) found <- list(baseline = bl)
        }
    }, error = function(e) NULL)
    found
}
fmt_levels <- function(v) paste(ifelse(is.na(v), "·", format(v, trim = TRUE)),
                                collapse = "/")

fmt_table_value <- function(x) {
    if (!length(x) || is.na(x)) "—" else format(x, trim = TRUE)
}

action_table <- function(baseline, ours, completed_levels, total_actions,
                         attempts, resets) {
    baseline <- as.numeric(baseline)
    ours <- as.numeric(ours)
    n_levels <- length(baseline)
    if (!n_levels) {
        return(character())
    }
    completed_levels <- min(as.integer(completed_levels), n_levels)
    ours <- c(ours, rep(NA_real_, max(0L, n_levels - length(ours))))
    ours <- head(ours, n_levels)
    completed <- if (completed_levels > 0L) seq_len(completed_levels) else integer()
    human_completed <- if (length(completed)) {
        sum(baseline[completed], na.rm = TRUE)
    } else {
        0
    }
    ours_completed <- if (length(completed)) {
        sum(ours[completed], na.rm = TRUE)
    } else {
        0
    }
    headers <- c("", paste0("L", seq_len(n_levels)), "Attempts", "Resets",
                 "Completed", "Total")
    align <- c(":---", rep("---:", length(headers) - 1L))
    human <- c("Human", vapply(baseline, fmt_table_value, ""), "—", "—",
               fmt_table_value(human_completed),
               fmt_table_value(sum(baseline, na.rm = TRUE)))
    agent <- c("corteza", vapply(ours, fmt_table_value, ""),
               fmt_table_value(attempts), fmt_table_value(resets),
               fmt_table_value(ours_completed), fmt_table_value(total_actions))
    c(paste0("| ", paste(headers, collapse = " | "), " |"),
      paste0("| ", paste(align, collapse = " | "), " |"),
      paste0("| ", paste(agent, collapse = " | "), " |"),
      paste0("| ", paste(human, collapse = " | "), " |"))
}

# A suffix for an already printed total action count. During a live
# partial game, compare only completed levels; actions on the current
# level are included in the headline total but not the comparison.
baseline_text <- function(sl, levels, per_level = NULL) {
    if (is.null(sl) || !length(sl$baseline)) {
        return("")
    }
    baseline <- as.numeric(sl$baseline)
    if (levels < 1L) {
        return(sprintf("; human baseline %s total (%s by level)",
                       sum(baseline, na.rm = TRUE), fmt_levels(baseline)))
    }
    cleared <- seq_len(min(levels, length(sl$baseline)))
    human <- sum(baseline[cleared], na.rm = TRUE)
    if (!is.null(per_level)) {
        ours <- per_level
    } else {
        ours <- sl$actions
    }
    if (is.null(ours) || !length(ours)) {
        return(sprintf("; human used %s over %d completed level%s",
                       human, length(cleared),
                if (length(cleared) == 1L) "" else "s"))
    }
    ours_cleared <- sum(ours[cleared], na.rm = TRUE)
    per_ours <- fmt_levels(ours[cleared])
    per_human <- fmt_levels(baseline[cleared])
    if (levels >= length(baseline)) {
        sprintf(" vs human %s (%s vs %s by level)", human, per_ours, per_human)
    } else {
        sprintf("; %s actions on %d completed level%s vs human %s (%s vs %s by level)",
                ours_cleared, length(cleared),
            if (length(cleared) == 1L) "" else "s",
                human, per_ours, per_human)
    }
}

# Protocol v2+ states whether each event is charged: the bootstrap RESET is
# free; every model-requested RESET and ACTION1..7 costs one. Reject older
# traces rather than silently applying their incompatible accounting.
trace_charged <- function(x) {
    if (!as.integer(x$protocol_version %||% NA) %in% c(2L, 3L, 4L, 5L) ||
        is.null(x$charged)) {
        stop("ARC trace event is not protocol v2/v3/v4", call. = FALSE)
    }
    isTRUE(x$charged)
}

trace_attempts <- function(tr) {
    charged <- vapply(tr, trace_charged, logical(1))
    action <- vapply(tr, function(x)
                     as.integer(x$action %||% NA_integer_), integer(1))
    sequence <- vapply(tr, function(x)
                       as.integer(x$sequence %||% NA_integer_), integer(1))
    source <- vapply(tr, function(x) x$source %||% "", "")
    resets <- sum(charged & !is.na(action) & action == 0L)
    # Each fresh driver attempt starts with one free sequence-zero RESET.
    # Reconciliation events are not attempts; model RESETs are.
    bootstraps <- sum(!charged & !is.na(action) & action == 0L &
                      !is.na(sequence) & sequence == 0L & source == "live")
    list(attempts = max(1L, bootstraps + resets), resets = resets)
}

# A response records levels_completed after its action, so charge each action
# to the level visible on the preceding response.
level_actions <- function(tr) {
    lv <- vapply(tr, function(x) as.integer(x$levels_completed %||% 0L), 1L)
    idx <- which(vapply(tr, trace_charged, logical(1)))
    if (!length(idx)) {
        return(integer())
    }
    before <- vapply(idx, function(i) if (i > 1L) lv[[i - 1L]] else 0L,
                     integer(1))
    tabulate(before + 1L)
}

trace_summary <- function(x) {
    run_id <- x$run_id %||% x$card_id
    tp <- file.path(run_dir, "traces", paste0(run_id, ".jsonl"))
    if (!file.exists(tp)) {
        return(NULL)
    }
    lines <- readLines(tp, warn = FALSE)
    tr <- lapply(lines, function(line)
                 tryCatch(jsonlite::fromJSON(line), error = function(e) NULL))
    tr <- Filter(Negate(is.null), tr)
    if (!length(tr)) {
        return(NULL)
    }
    last <- tr[[length(tr)]]
    attempts <- trace_attempts(tr)
    list(actions = sum(vapply(tr, trace_charged, logical(1))),
         levels = as.integer(last$levels_completed %||% 0L),
         win_levels = as.integer(last$win_levels %||% 0L),
         state = last$state %||% "", per_level = level_actions(tr),
         attempts = attempts$attempts, resets = attempts$resets)
}

game_won <- function(x) {
    tr <- trace_summary(x)
    if (!is.null(tr) && (identical(tr$state, "WIN") ||
            tr$win_levels > 0L && tr$levels >= tr$win_levels)) {
        return(TRUE)
    }
    scores <- suppressWarnings(as.numeric(c(x$api_score, x$final_score,
                x$official$score)))
    isTRUE(x$official$won) || any(!is.na(scores) & scores >= 99.99)
}

# The game in flight, if any: newest inflight/ entry whose card has no
# record yet and whose trace moved in the last hour.
live_games <- function() {
    if (!is.null(campaign) && !identical(campaign$state, "open")) {
        return(list())
    }
    inf <- list.files(file.path(run_dir, "inflight"), full.names = TRUE)
    if (!length(inf)) {
        return(list())
    }
    inf <- inf[order(file.mtime(inf), decreasing = TRUE)]
    out <- list()
    for (f in inf) {
        j <- read_json(f) ; if (is.null(j)) next
        run_id <- j$run_id %||% j$card_id
        if (file.exists(file.path(run_dir, "records", paste0(run_id, ".json")))) {
            next
        }
        tp <- file.path(run_dir, "traces", paste0(run_id, ".jsonl"))
        if (!file.exists(tp)) {
            next
        }
        if (difftime(Sys.time(), file.mtime(tp), units = "mins") > 60) {
            next
        }
        lines <- readLines(tp, warn = FALSE)
        tr <- lapply(lines,
                     function(l) tryCatch(jsonlite::fromJSON(l),
                error = function(e) NULL))
        tr <- Filter(Negate(is.null), tr)
        if (!length(tr)) {
            next
        }
        last <- tr[[length(tr)]]
        attempts <- trace_attempts(tr)
        out[[length(out) + 1L]] <- list(
            slug = j$slug, model = j$model, card = j$card_id,
            guid = j$guid %||% NA_character_,
            replay = j$replay %||% NA_character_,
            started = utc(j$started),
            actions = sum(vapply(tr, trace_charged, logical(1))),
            levels = last$levels_completed, win_levels = last$win_levels,
            state = last$state, last_ts = utc(last$ts),
            last_reasoning = last$reasoning %||% "",
            per_level = level_actions(tr), attempts = attempts$attempts,
            resets = attempts$resets)
    }
    out
}

# Finished games under the current corpus, newest first.
finished <- function(n = NULL) {
    fs <- list.files(file.path(run_dir, "records"), pattern = "[.]json$",
                     full.names = TRUE)
    rs <- Filter(Negate(is.null), lapply(fs, read_json))
    played <- function(x) !is.null(x$official$levels_completed) ||
    !is.null(x$trace_levels) && !is.na(x$trace_levels)
    if (!is.null(campaign)) {
        rs <- Filter(function(x)
                     identical(x$campaign, campaign$label) &&
                     identical(x$model, campaign$model) &&
                     identical(x$provider, campaign$provider) &&
                     identical(x$prompt_sha, campaign$prompt_sha) &&
                     identical(x$effort, campaign$effort) &&
                     identical(as.integer(x$thinking), as.integer(campaign$thinking)) &&
                     played(x), rs)
    }
    rs <- rs[order(vapply(rs, function(x) x$ts, ""), decreasing = TRUE)]
    if (is.null(n)) {
        rs
    } else {
        head(rs, n)
    }
}

snapshot_cost <- function(x) {
    if (is.null(x$input_tokens) || is.na(x$input_tokens)) {
        return(NA_real_)
    }
    u <- list(input_tokens = x$input_tokens, output_tokens = x$output_tokens,
              cache_read_input_tokens = x$cache_read_tokens %||% 0,
              cache_creation = list(
                                    ephemeral_5m_input_tokens = x$cache_write_5m_tokens %||% 0,
                                    ephemeral_1h_input_tokens = x$cache_write_1h_tokens %||% 0))
    tryCatch(llm.api::usage_cost(u, model = x$model, provider = x$provider),
             error = function(e) NA_real_)
}

compose <- function() {
    now <- Sys.time()
    finished_detail_ids <- character()
    live <- live_games()
    completed <- rev(finished())
    label <- campaign$label %||% "sweep"
    model <- campaign$model %||%
    if (!length(live)) "opus -> codex" else live[[1L]]$model
    effort <- campaign$effort %||% "max"
    workers <- as.integer(campaign$workers %||% max(1L, length(live)))
    total <- length(unlist(campaign$expected_games, use.names = FALSE))
    if (!total) {
        total <- length(list.files(file.path(arc_dir, "baselines"),
                                   pattern = "[.]json$"))
    }
    won <- sum(vapply(completed, game_won, logical(1)))
    out <- c(
             sprintf("**ARC-AGI-3 %s** · %s · effort %s · %d workers · %s",
                     label, model, effort, workers, format(now, "%H:%M %Z")),
             sprintf("Card `%s`", campaign$card_id %||% "legacy"),
             sprintf("%d/%d games finished · %d won", length(completed), total,
                     won))

    if (!length(live)) {
        out <- c(out, "", "_No game in flight._")
    } else {
        for (g in live) {
            stale <- mins(g$last_ts, now)
            sl <- game_baseline(g$slug)
            out <- c(out, "",
                     sprintf(paste0("**Live: %s** · level %d/%d · %d min in · ",
                                    "last action %d min ago%s"),
                             g$slug, g$levels, g$win_levels,
                             mins(g$started, now), stale,
                             if (stale > 20) " ⚠ quiet" else ""))
            if (!is.null(sl) && length(sl$baseline)) {
                out <- c(out, "", action_table(
                    sl$baseline, g$per_level, g$levels, g$actions,
                    g$attempts, g$resets))
            }
        }
    }

    if (length(completed)) {
        posted <- posted_finished_details()
        for (latest in completed) {
            tr <- trace_summary(latest)
            baseline <- game_baseline(latest$slug)
            latest_id <- latest$run_id %||% latest$card_id
            finished_at <- if (is.null(latest$ts)) {
                as.POSIXct(NA_character_, tz = "UTC")
            } else {
                utc(latest$ts)
            }
            age <- as.numeric(difftime(now, finished_at, units = "mins"))
            unseen <- !latest_id %in% posted
            if (is.finite(age) && age >= 0 && age <= 30 && unseen &&
                !is.null(tr) && !is.null(baseline) &&
                length(baseline$baseline)) {
                out <- c(
                    out, "", sprintf("**Latest finished: %s**", latest$slug),
                    "", action_table(
                        baseline$baseline, tr$per_level, tr$levels, tr$actions,
                        tr$attempts, tr$resets))
                finished_detail_ids <- c(finished_detail_ids, latest_id)
            }
        }
    }

    out <- c(out,
             "",
             "**Completed results**",
             "| Game | Result | Levels | Actions | Human | Attempts | Resets | Time | Cost |",
             "|:---|:---:|---:|---:|---:|---:|---:|---:|---:|")

    if (!length(completed)) {
        out <- c(out, "| — | — | — | — | — | — | — | — | — |")
    } else {
        for (x in completed) {
            tr <- trace_summary(x)
            attempts <- if (is.null(tr)) NA_integer_ else tr$attempts
            resets <- if (is.null(tr)) NA_integer_ else tr$resets
            if (!is.null(tr)) {
                lv <- tr$levels
            } else {
                lv <- x$trace_levels %||% x$official$levels_completed
            }

            wl <- if (!is.null(tr)) tr$win_levels else {
                n <- length(x$official$level_baseline_actions %||% integer())
                if (n) {
                    n
                } else {
                    length(game_baseline(x$slug)$baseline)
                }
            }

            actions <- if (!is.null(tr)) tr$actions else
                       x$trace_actions %||% NA_real_


            baseline <- game_baseline(x$slug)
            if (is.null(baseline)) {
                human <- NA_real_
            } else {
                human <- sum(as.numeric(baseline$baseline), na.rm = TRUE)
            }

            cost <- snapshot_cost(x)
            out <- c(out, sprintf(
                                  "| %s | %s | %s/%s | %s | %s | %s | %s | %s | %s |",
                                  x$slug,
                    if (game_won(x)) "WIN" else "incomplete",
                                  lv %||% "?", if (wl) wl else "?",
                    if (is.finite(actions)) {
                        format(actions, trim = TRUE)
                    } else {
                        "—"
                    },
                    if (is.finite(human)) format(human, trim = TRUE) else "—",
                    fmt_table_value(attempts),
                    fmt_table_value(resets),
                    if (!is.null(x$elapsed) && !is.na(x$elapsed))
                                  sprintf("%.0f min", x$elapsed / 60) else "—",
                    if (!is.na(cost)) sprintf("~$%.2f", cost) else "—"))
        }
    }
    list(text = paste(out, collapse = "\n"),
         finished_detail_ids = finished_detail_ids)
}

post <- function(text) {
    id <- tryCatch(cerebro::matrix_send(text, room = room,
                                        matrix_config = matrix_config,
                                        instance_dir = instance_dir,
                                        markdown = TRUE),
                   error = function(e) { message("post failed: ", conditionMessage(e)) ; NULL })
    cat(format(Sys.time(), "%H:%M:%S"),
        if (is.null(id)) {
            "POST FAILED"
        } else {
            "posted"
        }, "\n")
    invisible(id)
}

repeat {
    message <- compose()
    event_id <- post(message$text)
    if (!is.null(event_id) && length(message$finished_detail_ids)) {
        mark_finished_detail(message$finished_detail_ids)
    }
    if (nzchar(Sys.getenv("ARC_WATCH_ONCE"))) {
        break
    }
    Sys.sleep(interval)
}
