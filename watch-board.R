#!/usr/bin/env Rscript

# Live true-colour terminal view of the newest ARC latest-frame checkpoint.
# Two grid rows are packed into each terminal row with an upper-half block.

args <- if (exists("argv")) argv else commandArgs(trailingOnly = TRUE)
root <- if (length(args)) args[[1L]] else {
    file.path(getwd(), "campaigns")
}
interval <- if (length(args) >= 2L) as.numeric(args[[2L]]) else 0.5
watch_slug <- Sys.getenv("ARC_WATCH_SLUG", "")
watch_index_raw <- Sys.getenv("ARC_WATCH_INDEX", "")
watch_index <- if (nzchar(watch_index_raw)) {
    suppressWarnings(as.integer(watch_index_raw))
} else {
    NA_integer_
}
if (!is.finite(interval) || interval <= 0) {
    stop("interval must be a positive number", call. = FALSE)
}
if (nzchar(watch_index_raw) && (is.na(watch_index) || watch_index < 1L)) {
    stop("ARC_WATCH_INDEX must be a positive integer", call. = FALSE)
}

palette <- grDevices::col2rgb(c(
    "#FFFFFF", "#CCCCCC", "#999999", "#666666",
    "#333333", "#000000", "#E53AA3", "#FF7BCC",
    "#F93C31", "#1E93FF", "#88D8F1", "#FFDC00",
    "#FF851B", "#921231", "#4FCC30", "#A356D6"
))

latest_path <- function(root) {
    if (file.exists(root) && !dir.exists(root)) return(root)
    paths <- list.files(root, pattern = "^latest-frame[.]json$",
                        recursive = TRUE, full.names = TRUE)
    if (nzchar(watch_slug)) {
        paths <- paths[endsWith(basename(dirname(paths)),
                                paste0("--", watch_slug))]
    }
    if (!is.na(watch_index)) {
        paths <- paths[vapply(paths, frame_active, logical(1))]
        paths <- paths[order(basename(dirname(paths)))]
        if (length(paths) < watch_index) {
            return(NA_character_)
        }
        return(paths[[watch_index]])
    }
    if (!length(paths)) return(NA_character_)
    paths[[which.max(file.info(paths)$mtime)]]
}

settled_grid <- function(fr) {
    rows <- fr$frame[[length(fr$frame)]]
    do.call(rbind, lapply(rows, function(x) as.integer(unlist(x))))
}

render_grid <- function(g) {
    for (i in seq.int(1L, nrow(g), by = 2L)) {
        top <- g[i, ] + 1L
        bottom <- g[min(i + 1L, nrow(g)), ] + 1L
        cells <- sprintf(
            "\033[38;2;%d;%d;%dm\033[48;2;%d;%d;%dm%s",
            palette[1L, top], palette[2L, top], palette[3L, top],
            palette[1L, bottom], palette[2L, bottom], palette[3L, bottom], "\u2580"
        )
        cat("\033[2K", cells, "\033[0m\n", sep = "")
    }
}

`%||%` <- function(x, y) if (is.null(x)) y else x

read_json <- function(path) {
    tryCatch(jsonlite::fromJSON(path), error = function(e) NULL)
}

run_dir_from_frame <- function(path) dirname(dirname(dirname(path)))
frame_active <- function(path) {
    run_id <- basename(dirname(path))
    run_dir <- run_dir_from_frame(path)
    file.exists(file.path(run_dir, "inflight", paste0(run_id, ".json"))) &&
        !file.exists(file.path(run_dir, "records", paste0(run_id, ".json")))
}


run_slug <- function(run_dir, run_id) {
    for (kind in c("inflight", "records")) {
        info <- read_json(file.path(run_dir, kind, paste0(run_id, ".json")))
        if (!is.null(info$slug) && nzchar(info$slug)) return(info$slug)
    }
    sub("^.*--", "", run_id)
}

baseline_for <- function(run_dir, slug) {
    path <- file.path(dirname(dirname(run_dir)), "baselines",
                      paste0(slug, ".json"))
    x <- read_json(path)
    if (is.null(x$baseline)) NULL else as.numeric(x$baseline)
}

read_trace <- function(path) {
    if (!file.exists(path)) return(list())
    rows <- lapply(readLines(path, warn = FALSE), function(line) {
        tryCatch(jsonlite::fromJSON(line), error = function(e) NULL)
    })
    Filter(Negate(is.null), rows)
}

trace_summary <- function(run_dir, run_id) {
    trace <- read_trace(file.path(run_dir, "traces", paste0(run_id, ".jsonl")))
    if (!length(trace)) return(NULL)
    charged <- vapply(trace, function(x) isTRUE(x$charged), logical(1))
    action <- vapply(trace,
                     function(x) as.integer(x$action %||% NA_integer_),
                     integer(1))
    sequence <- vapply(trace,
                       function(x) as.integer(x$sequence %||% NA_integer_),
                       integer(1))
    source <- vapply(trace, function(x) x$source %||% "", character(1))
    levels <- vapply(trace,
                     function(x) as.integer(x$levels_completed %||% 0L),
                     integer(1))
    idx <- which(charged)
    before <- vapply(idx, function(i) {
        if (i > 1L) levels[[i - 1L]] else 0L
    }, integer(1))
    resets <- sum(charged & !is.na(action) & action == 0L)
    bootstraps <- sum(!charged & !is.na(action) & action == 0L &
                      !is.na(sequence) & sequence == 0L & source == "live")
    last <- trace[[length(trace)]]
    list(actions = sum(charged), per_level = tabulate(before + 1L),
         levels = as.integer(last$levels_completed %||% 0L),
         win_levels = as.integer(last$win_levels %||% 0L),
         state = last$state %||% "",
         attempts = max(1L, bootstraps + resets), resets = resets)
}

table_value <- function(x, missing = "—") {
    if (!length(x) || is.na(x)) missing else format(x, trim = TRUE)
}

terminal_table <- function(headers, rows) {
    table <- do.call(rbind, c(list(as.character(headers)), rows))
    widths <- apply(table, 2L, function(x) max(nchar(x, type = "width")))
    emit <- function(row) {
        cells <- mapply(function(x, width, first) {
            padding <- strrep(" ", max(0L, width - nchar(x, type = "width")))
            if (first) paste0(x, padding) else paste0(padding, x)
        }, row, widths, seq_along(widths) == 1L, USE.NAMES = FALSE)
        cat("\033[2K", paste(cells, collapse = "  "), "\n", sep = "")
    }
    emit(table[1L, ])
    cat("\033[2K", paste(vapply(widths, function(width) strrep("-", width), ""),
                          collapse = "  "), "\n", sep = "")
    if (nrow(table) > 1L) {
        for (i in 2L:nrow(table)) emit(table[i, ])
    }
}

live_table <- function(frame_path, fr) {
    run_id <- basename(dirname(frame_path))
    run_dir <- run_dir_from_frame(frame_path)
    baseline <- baseline_for(run_dir, run_slug(run_dir, run_id))
    if (is.null(baseline)) return(invisible(NULL))
    score <- trace_summary(run_dir, run_id)
    if (is.null(score)) return(invisible(NULL))
    n_levels <- length(baseline)
    ours <- c(score$per_level, rep(NA_integer_,
              max(0L, n_levels - length(score$per_level))))
    ours <- head(ours, n_levels)
    completed <- min(as.integer(fr$levels_completed), n_levels)
    done <- if (completed > 0L) seq_len(completed) else integer()
    levels <- paste(
        paste0(vapply(ours, table_value, character(1)), "/",
               vapply(baseline, table_value, character(1))),
        collapse = ","
    )
    fields <- c(
        paste0("L:", levels),
        paste0("A:", score$attempts),
        paste0("R:", score$resets),
        paste0("C:", sum(ours[done], na.rm = TRUE), "/",
               sum(baseline[done], na.rm = TRUE)),
        paste0("T:", score$actions, "/", sum(baseline, na.rm = TRUE))
    )
    cat("\033[2K", paste(fields, collapse = " "), "\n", sep = "")
}

record_cost <- function(x) {
    if (is.null(x$input_tokens) || is.na(x$input_tokens)) return(NA_real_)
    usage <- list(
        input_tokens = x$input_tokens,
        output_tokens = x$output_tokens,
        cache_read_input_tokens = x$cache_read_tokens %||% 0,
        cache_creation = list(
            ephemeral_5m_input_tokens = x$cache_write_5m_tokens %||% 0,
            ephemeral_1h_input_tokens = x$cache_write_1h_tokens %||% 0
        )
    )
    tryCatch(llm.api::usage_cost(usage, model = x$model, provider = x$provider),
             error = function(e) NA_real_)
}

game_won <- function(record, trace) {
    if (!is.null(trace) && (identical(trace$state, "WIN") ||
            trace$win_levels > 0L && trace$levels >= trace$win_levels)) {
        return(TRUE)
    }
    scores <- suppressWarnings(as.numeric(c(record$api_score,
                 record$final_score, record$official$score)))
    isTRUE(record$official$won) || any(!is.na(scores) & scores >= 99.99)
}

.completed_cache <- new.env(parent = emptyenv())
.completed_cache$signature <- NULL
.completed_cache$rows <- NULL

completed_rows <- function(run_dir) {
    files <- list.files(file.path(run_dir, "records"), pattern = "[.]json$",
                        full.names = TRUE)
    info <- file.info(files)
    signature <- paste(files, as.numeric(info$mtime), info$size, collapse = "|")
    if (identical(signature, .completed_cache$signature)) {
        return(.completed_cache$rows)
    }
    records <- Filter(function(x) {
        !is.null(x) && (!is.null(x$official$levels_completed) ||
                       !is.null(x$trace_levels) && !is.na(x$trace_levels))
    }, lapply(files, read_json))
    if (length(records)) {
        records <- records[order(vapply(records, function(x) x$ts %||% "",
                                        character(1)))]
    }
    rows <- list()
    for (x in records) {
        run_id <- x$run_id %||% x$card_id
        trace <- trace_summary(run_dir, run_id)
        baseline <- baseline_for(run_dir, x$slug)
        levels <- if (!is.null(trace)) trace$levels else
                  x$trace_levels %||% x$official$levels_completed
        win_levels <- if (!is.null(trace)) trace$win_levels else
                      length(baseline %||% x$official$level_baseline_actions)
        actions <- if (!is.null(trace)) trace$actions else
                   x$trace_actions %||% NA_real_
        human <- if (is.null(baseline)) NA_real_ else sum(baseline, na.rm = TRUE)
        cost <- record_cost(x)
        rows[[length(rows) + 1L]] <- c(
            x$slug, if (game_won(x, trace)) "WIN" else "incomplete",
            paste0(levels %||% "?", "/", if (win_levels) win_levels else "?"),
            table_value(actions), table_value(human),
            table_value(if (is.null(trace)) NA else trace$attempts),
            table_value(if (is.null(trace)) NA else trace$resets),
            if (!is.null(x$elapsed) && !is.na(x$elapsed))
                sprintf("%.0f min", x$elapsed / 60) else "—",
            if (is.finite(cost)) sprintf("~$%.2f", cost) else "—"
        )
    }
    if (!length(rows)) rows <- list(rep("—", 9L))
    .completed_cache$signature <- signature
    .completed_cache$rows <- rows
    rows
}

completed_table <- function(frame_path) {
    run_dir <- run_dir_from_frame(frame_path)
    cat("\033[2K\n\033[2KCompleted results\n")
    terminal_table(c("Game", "Result", "Levels", "Actions", "Human",
                     "Attempts", "Resets", "Time", "Cost"),
                   completed_rows(run_dir))
}

records_signature <- function(frame_path) {
    run_dir <- run_dir_from_frame(frame_path)
    files <- list.files(file.path(run_dir, "records"), pattern = "[.]json$",
                        full.names = TRUE)
    info <- file.info(files)
    paste(files, as.numeric(info$mtime), info$size, collapse = "|")
}

watch_board <- function() {
cat("\033[2J\033[H\033[?25l")
on.exit(cat("\033[?25h\033[0m\n"), add = TRUE)
last_signature <- NULL
selected_path <- NA_character_

repeat {
    path <- if (is.na(watch_index) && !is.na(selected_path) &&
                frame_active(selected_path)) {
        selected_path
    } else {
        latest_path(root)
    }
    selected_path <- path
    if (is.na(path)) {
        signature <- paste0("missing:", root)
        if (!identical(signature, last_signature)) {
            cat("\033[H\033[2KWaiting for an ARC latest-frame.json under ",
                root, "\n\033[J", sep = "")
            last_signature <- signature
        }
    } else {
        info <- file.info(path)
        signature <- paste(path, as.numeric(info$mtime), info$size, sep = "|")
        if (!identical(signature, last_signature)) {
            fr <- tryCatch(jsonlite::fromJSON(path, simplifyVector = FALSE),
                           error = identity)
            cat("\033[H")
            if (inherits(fr, "error")) {
                cat("\033[2KCould not read ", path, ": ",
                    conditionMessage(fr), "\n", sep = "")
            } else {
                run_id <- basename(dirname(path))
                slug <- run_slug(run_dir_from_frame(path), run_id)
                cat("\033]2;", slug, "\007", sep = "")
                render_grid(settled_grid(fr))
                live_table(path, fr)
                cat("\033[J")
                last_signature <- signature
            }
        }
    }
    flush.console()
    Sys.sleep(interval)
}
}

if (!identical(Sys.getenv("ARC_WATCH_LIBRARY", ""), "1")) {
    watch_board()
}
