# Open, validate, and close a multi-game ARC-AGI-3 scorecard campaign.
#
# A scorecard is session-affine: its card id must travel with the cookie
# jar that opened it. This manifest contains only non-secret provenance and
# the cookie *path*, never the cookies or API key.
#
# Usage:
#   r campaign.R open <manifest> <label> <model> <provider> <prompt_sha>
#                    <effort> <thinking> <max_tokens> <workers> <game ...>
#   r campaign.R validate <manifest> <label> <model> <provider> <prompt_sha>
#                        <effort> <thinking> <max_tokens> <workers> <game ...>
# The games supplied to open become the campaign's immutable expected set.
# A later validate may select any nonempty subset of that set.
#   r campaign.R close <manifest>
#   r campaign.R abandon <manifest>
#   r campaign.R status <manifest>

`%||%` <- function(a, b) if (is.null(a)) b else a

if (exists("argv")) {
    args <- argv
} else {
    args <- commandArgs(trailingOnly = TRUE)
}
usage <- paste(
               "usage: campaign.R <open|validate|close|abandon|status> <manifest> [metadata ...]",
               "See the header for command-specific arguments.")
if (length(args) < 2L ||
    !(args[[1]] %in% c("open", "validate", "close", "abandon", "status"))) {
    stop(usage, call. = FALSE)
}

if (file.exists("~/.Renviron")) {
    readRenviron("~/.Renviron")
}
harness_dir <- path.expand(Sys.getenv("ARC_HARNESS_DIR", getwd()))
source(file.path(harness_dir, "version.R"), local = TRUE)
source(file.path(harness_dir, "client.R"), local = TRUE)

read_manifest <- function(path) {
    if (!file.exists(path)) {
        stop("campaign manifest is missing: ", path, call. = FALSE)
    }
    x <- tryCatch(jsonlite::fromJSON(path, simplifyVector = FALSE),
                  error = function(e) NULL)
    if (is.null(x)) {
        stop("campaign manifest is invalid: ", path, call. = FALSE)
    }
    x
}

write_manifest <- function(x, path) {
    dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
    tmp <- paste0(path, ".tmp")
    writeLines(jsonlite::toJSON(x, auto_unbox = TRUE, null = "null",
                                pretty = TRUE), tmp)
    if (!isTRUE(file.rename(tmp, path))) {
        unlink(tmp)
        stop("could not atomically write campaign manifest: ", path,
             call. = FALSE)
    }
    invisible(path)
}

git_commit <- function(project = harness_dir) {
    out <- tryCatch(system2("git", c("-C", project, "rev-parse", "HEAD"),
                            stdout = TRUE, stderr = FALSE),
                    error = function(e) character())
    status <- attr(out, "status")
    if (length(status) && !is.na(status)) {
        out <- character()
    }
    if (length(out)) {
        trimws(out[[1]])
    } else {
        NA_character_
    }
}

campaign_args <- function(args) {
    if (length(args) < 11L) {
        stop(usage, call. = FALSE)
    }
    label <- args[[3]]
    games <- unique(args[11:length(args)])
    if (!length(games) ||
        any(!grepl("^[A-Za-z0-9][A-Za-z0-9._-]*$", games))) {
        stop("campaign requires a nonempty valid game selection",
             call. = FALSE)
    }
    if (!grepl("^[A-Za-z0-9][A-Za-z0-9._-]*$", label)) {
        stop("campaign label must contain only letters, digits, dot, underscore, or dash",
             call. = FALSE)
    }
    workers <- suppressWarnings(as.integer(args[[10]]))
    thinking <- suppressWarnings(as.integer(args[[8]]))
    max_tokens <- suppressWarnings(as.integer(args[[9]]))
    if (is.na(thinking) || thinking < 0L ||
        is.na(max_tokens) || max_tokens < 1L) {
        stop("thinking must be non-negative and max_tokens must be positive",
             call. = FALSE)
    }
    if (is.na(workers) || workers < 1L) {
        stop("workers must be a positive integer", call. = FALSE)
    }
    list(
         manifest = path.expand(args[[2]]),
         protocol_version = ARC_PROTOCOL_VERSION,
         label = label,
         model = args[[4]],
         provider = args[[5]],
         prompt_sha = args[[6]],
         effort = args[[7]],
         thinking = thinking,
         max_tokens = max_tokens,
         workers = workers,
         expected_games = games)
}

same_campaign <- function(x, y) {
    identical(as.integer(x$protocol_version %||% NA), y$protocol_version) &&
    identical(x$label, y$label) &&
    identical(x$model, y$model) &&
    identical(x$provider, y$provider) &&
    identical(x$prompt_sha, y$prompt_sha) &&
    identical(x$effort, y$effort) &&
    identical(as.integer(x$thinking), y$thinking) &&
    identical(as.integer(x$max_tokens), y$max_tokens) &&
    identical(as.integer(x$workers), y$workers)
}

campaign_missing_records <- function(manifest, path) {
    expected <- unlist(manifest$expected_games, use.names = FALSE)
    if (!length(expected)) {
        stop("campaign manifest has no expected game set", call. = FALSE)
    }
    files <- list.files(file.path(dirname(path), "records"),
                        pattern = "[.]json$", full.names = TRUE)
    records <- lapply(files, function(file) {
        tryCatch(jsonlite::fromJSON(file, simplifyVector = FALSE),
                 error = function(e) NULL)
    })
    records <- Filter(Negate(is.null), records)
    matched <- vapply(expected, function(slug) {
        any(vapply(records, function(x) {
            effort <- x$effort %||% ""
            thinking <- as.integer(x$thinking %||% 0L)
            played <- !is.null(x$official$levels_completed) ||
                (!is.null(x$trace_levels) && !is.na(x$trace_levels))
            isTRUE(x$slug == slug) &&
                isTRUE(x$card_id == manifest$card_id) &&
                identical(as.integer(x$protocol_version),
                          as.integer(manifest$protocol_version)) &&
                isTRUE(x$prompt_sha == manifest$prompt_sha) &&
                isTRUE(x$model == manifest$model) &&
                identical(effort, manifest$effort) &&
                identical(thinking, as.integer(manifest$thinking)) &&
                isTRUE(played)
        }, logical(1)))
    }, logical(1))
    expected[!matched]
}

cmd <- args[[1]]
manifest_path <- path.expand(args[[2]])

if (cmd %in% c("open", "validate")) {
    wanted <- campaign_args(args)
    if (cmd == "validate") {
        manifest <- read_manifest(wanted$manifest)
        if (!identical(manifest$state, "open") ||
            !same_campaign(manifest, wanted)) {
            stop("campaign manifest does not match this sweep", call. = FALSE)
        }
        expected <- unlist(manifest$expected_games, use.names = FALSE)
        if (!length(expected)) {
            stop("campaign manifest has no expected game set", call. = FALSE)
        }
        if (length(setdiff(wanted$expected_games, expected))) {
            stop("selected games are outside the campaign expected set",
                 call. = FALSE)
        }
        cookiejar <- arc_campaign_cookiejar(manifest$cookiejar, wanted$manifest)
        if (!file.exists(cookiejar)) {
            stop("campaign cookie jar is missing", call. = FALSE)
        }
        cat("campaign ready | label=", manifest$label, " card=",
            manifest$card_id, "\n", sep = "")
    } else {
        if (file.exists(wanted$manifest)) {
            stop("refusing to overwrite campaign manifest: ", wanted$manifest,
                 call. = FALSE)
        }
        dir.create(dirname(wanted$manifest), recursive = TRUE, showWarnings = FALSE)
        cookiejar <- file.path(dirname(wanted$manifest), "cookies.txt")
        cl <- arc_client()
        cl$cookiejar <- cookiejar
        sc <- arc_scorecard_open(
                                 cl,
                                 tags = c("corteza", "rlm", "cold", wanted$model),
                                 opaque = list(
                harness = "corteza",
                protocol_version = wanted$protocol_version,
                budget_multiplier = 5L,
                arm = "rlm",
                run_label = wanted$label,
                model = wanted$model,
                provider = wanted$provider,
                prompt_sha = wanted$prompt_sha,
                workers = wanted$workers,
                effort = wanted$effort,
                thinking = wanted$thinking,
                max_tokens = wanted$max_tokens,
                commit = git_commit()))
        if (!file.exists(cookiejar)) {
            stop("scorecard opened but its session cookie jar was not saved",
                 call. = FALSE)
        }
        Sys.chmod(cookiejar, mode = "0600")
        manifest <- c(
                      list(version = ARC_PROTOCOL_VERSION, state = "open",
                           card_id = sc$card_id,
                           cookiejar = basename(cookiejar),
                           created = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")),
                      wanted[-1])
        write_manifest(manifest, wanted$manifest)
        cat("campaign opened | label=", manifest$label, " card=", manifest$card_id,
            "\n", sep = "")
    }
} else {
    manifest <- read_manifest(manifest_path)
    if (cmd == "status") {
        cat("campaign ", manifest$state %||% "unknown", " | label=",
            manifest$label %||% "?", " card=", manifest$card_id %||% "?", "\n",
            sep = "")
    } else if (manifest$state %in% c("closed", "abandoned")) {
        cat("campaign already ", manifest$state, " | label=", manifest$label,
            " card=", manifest$card_id, "\n", sep = "")
    } else {
        if (identical(cmd, "close")) {
            missing <- campaign_missing_records(manifest, manifest_path)
            if (length(missing)) {
                stop("refusing to close incomplete campaign; missing matching records: ",
                     paste(missing, collapse = " "), call. = FALSE)
            }
        }
        cookiejar <- arc_campaign_current_cookiejar(manifest, manifest_path)
        cl <- arc_client(cookies = cookiejar)
        cl$cookiejar <- cookiejar
        final <- arc_scorecard_close(cl, manifest$card_id)
        manifest$state <- if (identical(cmd, "abandon")) "abandoned" else "closed"
        manifest$ended <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
        # The API response may contain account fields; retain only safe summary data.
        manifest$final <- list(
                               score = final$score %||% NA_real_,
                               won = final$won %||% NA_integer_,
                               played = final$played %||% NA_integer_,
                               total_actions = final$total_actions %||% NA_integer_)
        write_manifest(manifest, manifest_path)
        cat("campaign ", manifest$state, " | label=", manifest$label, " card=", manifest$card_id,
            "\n", sep = "")
    }
}
