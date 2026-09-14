#!/usr/bin/env Rscript

# Read-only terminal scoreboard for one ARC campaign. This deliberately shares
# watch-board.R's trace accounting and table renderer so Matrix, board panes,
# and the aggregate pane do not grow separate definitions of an action.

args <- if (exists("argv")) argv else commandArgs(trailingOnly = TRUE)
if (!length(args)) {
    stop("usage: watch-scoreboard.R <campaign-dir> [interval]", call. = FALSE)
}
run_dir <- path.expand(args[[1L]])
interval_arg <- if (length(args) >= 2L) args[[2L]] else "1"
script_arg <- grep("^--file=", commandArgs(FALSE), value = TRUE)
script_dir <- if (length(script_arg)) {
    dirname(normalizePath(sub("^--file=", "", script_arg[[1L]])))
} else {
    normalizePath(".")
}

old_library <- Sys.getenv("ARC_WATCH_LIBRARY", unset = NA_character_)
Sys.setenv(ARC_WATCH_LIBRARY = "1")
source(file.path(script_dir, "watch-board.R"), local = globalenv())
if (is.na(old_library)) Sys.unsetenv("ARC_WATCH_LIBRARY") else
    Sys.setenv(ARC_WATCH_LIBRARY = old_library)
interval <- as.numeric(interval_arg)
if (!is.finite(interval) || interval <= 0) {
    stop("interval must be a positive number", call. = FALSE)
}

active_rows <- function(run_dir) {
    files <- list.files(file.path(run_dir, "inflight"), pattern = "[.]json$",
                        full.names = TRUE)
    rows <- list()
    for (file in files) {
        info <- read_json(file)
        if (is.null(info)) next
        run_id <- info$run_id %||% info$card_id
        if (file.exists(file.path(run_dir, "records", paste0(run_id, ".json")))) {
            next
        }
        trace <- trace_summary(run_dir, run_id)
        if (is.null(trace)) next
        slug <- info$slug %||% sub("^.*--", "", run_id)
        baseline <- baseline_for(run_dir, slug)
        n_levels <- length(baseline)
        completed <- min(trace$levels, n_levels)
        done <- if (completed > 0L) seq_len(completed) else integer()
        ours_done <- sum(head(trace$per_level, completed), na.rm = TRUE)
        human_done <- if (n_levels) sum(baseline[done], na.rm = TRUE) else NA
        human_total <- if (n_levels) sum(baseline, na.rm = TRUE) else NA
        trace_path <- file.path(run_dir, "traces", paste0(run_id, ".jsonl"))
        rows[[length(rows) + 1L]] <- c(
            slug, paste0(trace$levels, "/", trace$win_levels),
            paste0(table_value(ours_done), "/", table_value(human_done)),
            paste0(table_value(trace$actions), "/", table_value(human_total)),
            trace$attempts, trace$resets,
            format(file.info(trace_path)$mtime, "%H:%M:%S"))
    }
    if (!length(rows)) rows <- list(rep("—", 7L))
    rows
}

played_records <- function(run_dir) {
    files <- list.files(file.path(run_dir, "records"), pattern = "[.]json$",
                        full.names = TRUE)
    Filter(function(x) {
        !is.null(x) && (!is.null(x$official$levels_completed) ||
                       !is.null(x$trace_levels) && !is.na(x$trace_levels))
    }, lapply(files, read_json))
}

state_signature <- function(run_dir) {
    files <- c(file.path(run_dir, "campaign.json"),
               list.files(file.path(run_dir, "inflight"), full.names = TRUE),
               list.files(file.path(run_dir, "records"), full.names = TRUE),
               list.files(file.path(run_dir, "traces"), full.names = TRUE))
    files <- files[file.exists(files)]
    info <- file.info(files)
    paste(files, as.numeric(info$mtime), info$size, collapse = "|")
}

cat("\033[2J\033[H\033[?25l")
on.exit(cat("\033[?25h\033[0m\n"), add = TRUE)
last_signature <- NULL
repeat {
    signature <- state_signature(run_dir)
    if (!identical(signature, last_signature)) {
        cat("\033[H")
        manifest <- read_json(file.path(run_dir, "campaign.json"))
        if (is.null(manifest)) {
            cat("\033[2KARC-AGI-3 scoreboard\n\033[2KWaiting for ", run_dir,
                "/campaign.json\n\033[J", sep = "")
        } else {
            records <- played_records(run_dir)
            wins <- sum(vapply(records, function(record) {
                run_id <- record$run_id %||% record$card_id
                game_won(record, trace_summary(run_dir, run_id))
            }, logical(1)))
            total <- length(unlist(manifest$expected_games, use.names = FALSE))
            cat("\033[2KARC-AGI-3 ", manifest$label %||% basename(run_dir),
                " | ", manifest$model %||% "?", " | ",
                length(records), "/", total, " finished | ", wins, " won\n",
                "\033[2KCard ", manifest$card_id %||% "pending", "\n\n",
                sep = "")
            cat("\033[2KActive games\n")
            terminal_table(
                c("Game", "Levels", "Completed", "Total", "Attempts", "Resets",
                  "Updated"),
                active_rows(run_dir))
            cat("\033[2K\n\033[2KCompleted results\n")
            terminal_table(
                c("Game", "Result", "Levels", "Actions", "Human", "Attempts",
                  "Resets", "Time", "Cost"),
                completed_rows(run_dir))
            cat("\033[J")
        }
        last_signature <- signature
    }
    flush.console()
    Sys.sleep(interval)
}
