# ARC-AGI-3 REST client. Base R + curl + jsonlite, nothing else.
#
# API (docs.arcprize.org, spec arc3v1.yaml, verified 2026-09-01):
#   base  https://three.arcprize.org, auth header X-API-Key
#   GET  /api/games                      -> [{game_id, title, ...}]
#   POST /api/scorecard/open             -> {card_id}
#   POST /api/scorecard/close {card_id}  -> ScorecardSummary
#   GET  /api/scorecard/{card_id}[/{game_id}]
#   POST /api/cmd/RESET   {game_id, card_id, guid?}   -> FrameResponse
#   POST /api/cmd/ACTION1..5,7 {game_id, guid, reasoning?}
#   POST /api/cmd/ACTION6 {game_id, guid, x, y, reasoning?}
# FrameResponse: {game_id, guid, frame [n x 64 x 64 ints 0-15],
#   state NOT_PLAYED|NOT_FINISHED|WIN|GAME_OVER, levels_completed,
#   win_levels, action_input}. Sessions are sticky via AWSALB cookies:
# one curl handle per client, cookie engine on, reused for every call.
# Rate limit 600 RPM with backoff; we honor Retry-After and cap retries.

arc_campaign_cookiejar <- function(value, manifest_path) {
    raw <- if (is.null(value) || !length(value)) {
        ""
    } else {
        as.character(value[[1]])
    }
    if (!nzchar(raw)) {
        return("")
    }
    local_path <- file.path(dirname(manifest_path), basename(raw))
    absolute <- startsWith(raw, "/") || grepl("^[A-Za-z]:[/\\\\]", raw)
    candidates <- unique(if (absolute) {
        c(path.expand(raw), local_path)
    } else {
        c(local_path, path.expand(raw))
    })
    existing <- candidates[nzchar(candidates) & file.exists(candidates)]
    if (length(existing)) {
        return(normalizePath(existing[[1]], mustWork = TRUE))
    }
    local_path
}

# Seed an independent game worker from the scorecard session without allowing
# that worker to rewrite the campaign's shared cookie file. ARC mutates its
# GAMESESSION and affinity cookies as requests proceed, so each concurrent game
# must persist those mutations to its own jar.
arc_clone_cookiejar <- function(source, target) {
    source <- path.expand(source)
    target <- path.expand(target)
    if (!file.exists(source)) {
        stop("campaign cookie jar is missing: ", source, call. = FALSE)
    }
    if (identical(normalizePath(source, mustWork = TRUE),
                  normalizePath(target, mustWork = FALSE))) {
        stop("worker cookie jar must differ from campaign cookie jar",
             call. = FALSE)
    }
    cookies <- readLines(source, warn = FALSE)
    cookies <- cookies[nzchar(cookies)]
    if (!length(cookies)) {
        stop("campaign cookie jar is empty: ", source, call. = FALSE)
    }
    dir.create(dirname(target), recursive = TRUE, showWarnings = FALSE)
    tmp <- paste0(target, ".", Sys.getpid(), ".tmp")
    writeLines(cookies, tmp)
    Sys.chmod(tmp, mode = "0600")
    if (!isTRUE(file.rename(tmp, target))) {
        unlink(tmp)
        stop("could not seed worker cookie jar: ", target, call. = FALSE)
    }
    invisible(target)
}

# Pick the newest worker cookie jar that has proved it can reach a game.
# A cloned jar is not authoritative until RESET has produced latest-frame.json;
# this excludes a freshly cloned jar whose bootstrap never succeeded.
arc_campaign_current_cookiejar <- function(manifest, manifest_path) {
    root <- dirname(manifest_path)
    seed <- arc_campaign_cookiejar(manifest$cookiejar, manifest_path)
    worker_jars <- list.files(file.path(root, "state"),
                              pattern = "^cookies[.]txt$", recursive = TRUE,
                              full.names = TRUE)
    prefix <- paste0(manifest$card_id, "--")
    worker_jars <- worker_jars[
        startsWith(basename(dirname(worker_jars)), prefix)
    ]
    proven <- worker_jars[vapply(worker_jars, function(path) {
        file.exists(file.path(dirname(path), "latest-frame.json"))
    }, logical(1))]
    candidates <- unique(if (length(proven)) proven else seed)
    candidates <- candidates[file.exists(candidates)]
    if (!length(candidates)) {
        stop("campaign has no usable cookie jar", call. = FALSE)
    }
    candidates[[which.max(as.numeric(file.info(candidates)$mtime))]]
}

arc_card_missing_error <- function(summary = "", official_error = "") {
    summary <- if (is.null(summary)) "" else as.character(summary)
    official_error <- if (is.null(official_error)) "" else
        as.character(official_error)
    evidence <- paste(c(summary, official_error), collapse = " ")
    grepl("card_id .*not found", evidence, ignore.case = TRUE, perl = TRUE)
}

arc_client <- function(key = Sys.getenv("ARC_PRIZE", Sys.getenv("ARC_API_KEY")),
                       base = "https://three.arcprize.org", cookies = NULL) {
    if (!nzchar(key)) {
        stop("no ARC key: set ARC_PRIZE (or ARC_API_KEY) in ~/.Renviron")
    }
    cl <- new.env(parent = emptyenv())
    cl$base <- base
    cl$key <- key
    # cookiefile = "" turns on libcurl's in-memory cookie engine; the
    # affinity cookies then ride every request on this handle.
    #
    # A game instance is bound to those cookies (GAMESESSION plus the
    # AWSALBAPP-* routing set): the same guid from a handle without them
    # gets "game <id> not found", and a fresh handle carrying them plays
    # on (measured 2026-09-02 on cd82). So `cookies` names a file the
    # jar is saved to after every request (see .arc_req) and loaded
    # from here, which is what lets a new process resume a dead one's
    # game. Set cl$cookiejar later to start saving once a card exists.
    cl$handle <- curl::new_handle(cookiefile = "")
    cl$cookiejar <- cookies
    if (!is.null(cookies) && file.exists(cookies)) {
        ck <- readLines(cookies, warn = FALSE)
        ck <- ck[nzchar(ck)]
        if (length(ck)) {
            curl::handle_setopt(cl$handle, cookie = paste(ck, collapse = "; "))
        }
    }
    cl
}

.arc_req <- function(cl, method, path, body = NULL, tries = 5L) {
    url <- paste0(cl$base, path)
    for (attempt in seq_len(tries)) {
        curl::handle_setheaders(cl$handle, "X-API-Key" = cl$key,
                                "Content-Type" = "application/json",
                                Accept = "application/json")
        if (identical(method, "POST")) {
            json <- if (is.null(body)) {
                "{}"
            } else {
                jsonlite::toJSON(body, auto_unbox = TRUE, null = "null")
            }
            curl::handle_setopt(cl$handle, post = TRUE, postfields = json)
        } else {
            curl::handle_setopt(cl$handle, post = FALSE, httpget = TRUE)
        }
        res <- curl::curl_fetch_memory(url, handle = cl$handle)
        txt <- rawToChar(res$content)
        if (res$status_code == 429L && attempt < tries) {
            hdrs <- tryCatch(curl::parse_headers_list(res$headers),
                             error = function(e) list())
            wait <- suppressWarnings(as.numeric(hdrs[["retry-after"]]))
            if (is.na(wait) || !length(wait)) {
                wait <- 2 ^ attempt
            }
            Sys.sleep(min(wait, 60))
            next
        }
        if (res$status_code >= 400L) {
            stop("ARC API ", res$status_code, " on ", path, ": ",
                 substr(txt, 1, 300), call. = FALSE)
        }
        .arc_save_cookies(cl)
        return(jsonlite::fromJSON(txt, simplifyVector = FALSE))
    }
    stop("ARC API: rate-limited after ", tries, " attempts on ", path,
         call. = FALSE)
}

# The handle's cookies to cl$cookiejar, one name=value per line, via a
# temp file and rename. Best-effort: a failure here must never fail the
# request that just succeeded.
.arc_save_cookies <- function(cl) {
    if (is.null(cl$cookiejar)) {
        return(invisible(FALSE))
    }
    tryCatch({
        ck <- curl::handle_cookies(cl$handle)
        if (nrow(ck)) {
            dir.create(dirname(cl$cookiejar), recursive = TRUE,
                       showWarnings = FALSE)
            tmp <- paste0(cl$cookiejar, ".", Sys.getpid(), ".tmp")
            writeLines(sprintf("%s=%s", ck$name, ck$value), tmp)
            Sys.chmod(tmp, mode = "0600")
            if (!isTRUE(file.rename(tmp, cl$cookiejar))) {
                unlink(tmp)
                stop("could not replace cookie jar")
            }
        }
        invisible(TRUE)
    }, error = function(e) invisible(FALSE))
}

arc_health <- function(cl) .arc_req(cl, "GET", "/api/healthcheck")
arc_games <- function(cl) .arc_req(cl, "GET", "/api/games")

# Catalog entry for a slug: a pure number is a position in the catalog,
# anything else a game_id prefix ("ls20" -> "ls20-..."). Game ids are
# session-scoped, so resolve in the session that will play.
arc_resolve_game <- function(catalog, slug) {
    ids <- vapply(catalog, function(g) g$game_id, "")
    if (grepl("^[0-9]+$", slug)) {
        idx <- as.integer(slug)
        if (idx < 1L || idx > length(ids)) {
            stop("index ", idx, " out of range: ", length(ids), " games")
        }
        return(catalog[[idx]])
    }
    hit <- which(startsWith(ids, slug))
    if (!length(hit)) {
        stop("no game matching '", slug, "' in this session's catalog")
    }
    catalog[[hit[1]]]
}

# Action budget for a catalog entry: fixed 5x human baseline
# times the human baseline summed over the game's levels, which
# /api/games publishes as baseline_actions. NA when the field is
# missing, so the caller says so rather than inventing a number.
arc_game_budget <- function(g, mult = 5) {
    bl <- as.numeric(unlist(g$baseline_actions))
    if (!length(bl) || !all(is.finite(bl))) {
        return(list(baseline_total = NA_real_, action_budget = NA_integer_))
    }
    list(baseline_total = sum(bl),
         action_budget = as.integer(ceiling(mult * sum(bl))))
}

arc_scorecard_open <- function(cl, tags = NULL, opaque = NULL,
                               source_url = NULL) {
    body <- Filter(Negate(is.null),
                   list(tags = tags, opaque = opaque, source_url = source_url))
    .arc_req(cl, "POST", "/api/scorecard/open",
        if (length(body)) body else NULL)
}

arc_scorecard_close <- function(cl, card_id) {
    .arc_req(cl, "POST", "/api/scorecard/close", list(card_id = card_id))
}

# The action-by-action recording of a play, NDJSON, one line per action
# with the FrameResponse under $data. Served for open sessions too, so
# a process that has to resume a game with no checkpoint can read the
# board from here instead of spending an action to see it.
arc_recording <- function(cl, game_id, guid) {
    curl::handle_setheaders(cl$handle, "X-API-Key" = cl$key, Accept = "*/*")
    curl::handle_setopt(cl$handle, post = FALSE, httpget = TRUE)
    res <- curl::curl_fetch_memory(
                                   paste0(cl$base, "/api/recordings/", game_id, "/", guid), handle = cl$handle)
    txt <- rawToChar(res$content)
    if (res$status_code >= 400L) {
        stop("ARC API ", res$status_code, " on /api/recordings/", game_id,
             "/", guid, ": ", substr(txt, 1, 300), call. = FALSE)
    }
    lines <- strsplit(txt, "\n", fixed = TRUE)[[1]]
    lines <- lines[nzchar(trimws(lines))]
    lapply(lines, jsonlite::fromJSON, simplifyVector = FALSE)
}

# A play by its replay guid, readable from any handle with the key
# (unlike /api/scorecard/{card}, which is session-affine): per-level
# actions, human baselines and scores. This is what arcprize.org/replay
# renders from.
arc_session <- function(cl, guid) .arc_req(cl, "GET",
    paste0("/api/sessions/", guid))

arc_scorecard <- function(cl, card_id, game_id = NULL) {
    path <- paste0("/api/scorecard/", card_id,
        if (!is.null(game_id)) paste0("/", game_id) else "")
    .arc_req(cl, "GET", path)
}

#' The scorecard as the website sees it. Undocumented in arc3v1.yaml;
#' it is what arcprize.org/scorecards/{card_id} fetches. Unlike
#' /api/scorecard/{card_id} it is not tied to the AWSALB session that
#' played the card, so any handle with the key can read it -- but only
#' once the card is CLOSED (an open card 404s "No scorecard found").
#' Returns per-environment runs, each with the replay guid, level
#' scores, level actions and human baseline actions; that guid keys
#' arcprize.org/replay/{guid} and /api/recordings/{game_id}/{guid}.
arc_scorecard_v3 <- function(cl, card_id) {
    .arc_req(cl, "GET", paste0("/api/v3/scorecards/", card_id))
}

#' Start a new run (guid = NULL) or reset the current level (guid set).
#'
#' The controller passes `charged = FALSE` only for the bootstrap RESET
#' that obtains the first observation. Every model-requested RESET is a
#' committed action and is charged exactly like ACTION1..7.
arc_reset <- function(cl, game_id, card_id, guid = NULL, reasoning = NULL,
                      trace_path = Sys.getenv("ARC_TRACE"),
                      latest_path = Sys.getenv("ARC_LATEST_FRAME"),
                      charged = TRUE, sequence = NULL, attempt = NULL,
                      source = "live", trace_strict = FALSE) {
    body <- list(game_id = game_id, card_id = card_id)
    if (!is.null(guid)) {
        body$guid <- guid
    }
    if (!is.null(reasoning)) {
        body$reasoning <- reasoning
    }
    fr <- .arc_req(cl, "POST", "/api/cmd/RESET", body)
    .arc_trace(0L, NULL, NULL, fr, reasoning, charged = charged,
               sequence = sequence, attempt = attempt, source = source,
               path = trace_path, latest_path = latest_path,
               strict = trace_strict)
    fr
}

# Read the local transaction log. A malformed tail can result from a hard
# process kill during append. The current protocol fails closed: a damaged or older
# journal cannot be resumed or scored as a current run.
arc_trace_records <- function(path = Sys.getenv("ARC_TRACE")) {
    if (!nzchar(path) || !file.exists(path)) {
        return(list())
    }
    lines <- Filter(nzchar, readLines(path, warn = FALSE))
    rows <- lapply(seq_along(lines), function(i) {
        tryCatch(jsonlite::fromJSON(lines[[i]], simplifyVector = FALSE),
                 error = function(e) {
            stop(sprintf("malformed ARC protocol v%d trace at event %d",
                         ARC_PROTOCOL_VERSION, i),
                 call. = FALSE)
        })
    })
    valid <- vapply(rows, function(x) {
        identical(as.integer(x$protocol_version %||% NA),
                  ARC_PROTOCOL_VERSION) &&
        !is.null(x$charged) && !is.null(x$sequence)
    }, logical(1))
    if (any(!valid)) {
        stop(sprintf("ARC trace event %d is not protocol v%d",
                     which(!valid)[[1]], ARC_PROTOCOL_VERSION), call. = FALSE)
    }
    rows
}

# Charged actions committed in this protocol run.
arc_actions_used <- function(path = Sys.getenv("ARC_TRACE")) {
    rows <- arc_trace_records(path)
    if (!length(rows)) {
        return(0L)
    }
    sum(vapply(rows, function(x) isTRUE(x$charged), logical(1)))
}

arc_resets_used <- function(path = Sys.getenv("ARC_TRACE")) {
    rows <- arc_trace_records(path)
    if (!length(rows)) {
        return(0L)
    }
    sum(vapply(rows, function(x) {
        identical(as.integer(x$action), 0L) && isTRUE(x$charged)
    }, logical(1)))
}

#' Execute action `id` in 1..7 (6 needs x, y in 0..63).
#'
#' This is deliberately a low-level transport primitive. The model never gets
#' this function; the external controller owns the immutable budget and calls
#' it once per accepted game_action tool invocation.
arc_action <- function(cl, game_id, guid, id, x = NULL, y = NULL,
                       reasoning = NULL,
                       trace_path = Sys.getenv("ARC_TRACE"),
                       latest_path = Sys.getenv("ARC_LATEST_FRAME"),
                       charged = TRUE, sequence = NULL, attempt = NULL,
                       source = "live", trace_strict = FALSE) {
    id <- as.integer(id)
    stopifnot(id >= 1L, id <= 7L)
    body <- list(game_id = game_id, guid = guid)
    if (id == 6L) {
        stopifnot(!is.null(x), !is.null(y))
        body$x <- as.integer(x)
        body$y <- as.integer(y)
    }
    if (!is.null(reasoning)) {
        body$reasoning <- reasoning
    }
    fr <- .arc_req(cl, "POST", paste0("/api/cmd/ACTION", id), body)
    .arc_trace(id, x, y, fr, reasoning, charged = charged,
               sequence = sequence, attempt = attempt, source = source,
               path = trace_path, latest_path = latest_path,
               strict = trace_strict)
    fr
}

# Append one durable transaction row and atomically replace the latest frame.
# In controller mode strict=TRUE: a trace failure after the remote action is
# ambiguous and must flow through authoritative reconciliation before play can
# continue. Other callers retain the old best-effort instrumentation behavior.
.arc_trace <- function(id, x, y, fr, reasoning = NULL, charged = TRUE,
                       sequence = NULL, attempt = NULL, source = "live",
                       path = Sys.getenv("ARC_TRACE"),
                       latest_path = Sys.getenv("ARC_LATEST_FRAME"),
                       strict = FALSE) {
    if (!nzchar(path)) {
        return(invisible(NULL))
    }
    write_trace <- function() {
        g <- arc_grid(fr)
        rec <- list(
                    protocol_version = ARC_PROTOCOL_VERSION,
                    ts = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
                    sequence = sequence,
                    action = as.integer(id), x = x, y = y,
                    charged = isTRUE(charged),
                    attempt = attempt,
                    source = source,
                    state = fr$state,
                    levels_completed = fr$levels_completed,
                    win_levels = fr$win_levels,
                    grid_sha = substr(digest::digest(g, algo = "sha256"), 1, 12),
                    nonzero = sum(g != 0L),
                    reasoning = reasoning)
        dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
        cat(jsonlite::toJSON(rec, auto_unbox = TRUE, null = "null"), "\n",
            file = path, append = TRUE, sep = "")
        if (nzchar(latest_path)) {
            dir.create(dirname(latest_path), recursive = TRUE,
                       showWarnings = FALSE)
            tmp <- paste0(latest_path, ".tmp")
            writeLines(jsonlite::toJSON(fr, auto_unbox = TRUE, null = "null"), tmp)
            if (!isTRUE(file.rename(tmp, latest_path))) {
                unlink(tmp)
                stop("could not atomically replace latest ARC frame")
            }
        }
        invisible(rec)
    }
    if (isTRUE(strict)) {
        write_trace()
    } else {
        tryCatch(write_trace(), error = function(e) invisible(NULL))
    }
}

# -- frame helpers ----------------------------------------------------

# A FrameResponse's $frame is a list of frames; each frame is a list of
# 64 rows of 64 ints (0-15). Last frame = settled state.
arc_grid <- function(fr) {
    f <- fr$frame[[length(fr$frame)]]
    do.call(rbind, lapply(f, function(row) as.integer(unlist(row))))
}

#' Render a frame as 64 lines of hex digits (0-f), with a header the
#' agent can act on. Compact enough to print in a REPL turn.
arc_show <- function(fr) {
    g <- arc_grid(fr)
    hex <- c(0:9, letters[1:6])
    rows <- apply(g, 1, function(r) paste(hex[r + 1L], collapse = ""))
    header <- sprintf("state=%s levels=%s/%s guid=%s", fr$state,
                      fr$levels_completed, fr$win_levels,
                      substr(fr$guid %||% "?", 1, 8))
    paste(c(header, rows), collapse = "\n")
}

#' Diff two frames: how many cells changed, and where (bounding box).
#' Cheap signal for "did that action do anything".
arc_diff <- function(fr_a, fr_b) {
    a <- arc_grid(fr_a)
    b <- arc_grid(fr_b)
    ch <- which(a != b, arr.ind = TRUE)
    if (nrow(ch) == 0L) {
        return("no change")
    }
    sprintf("%d cells changed in rows %d-%d, cols %d-%d", nrow(ch),
            min(ch[, 1]), max(ch[, 1]), min(ch[, 2]), max(ch[, 2]))
}

`%||%` <- function(a, b) if (is.null(a)) b else a
