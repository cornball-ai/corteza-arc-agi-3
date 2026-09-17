# ARC-AGI-3 protocol controller.
#
# The language model gets two capabilities: a persistent analysis environment
# and one transactional game_action tool. The live ARC client, session
# credentials, action counter, and pending-action journal stay outside the
# environment in which model-authored R is evaluated.

`%||%` <- function(a, b) if (is.null(a)) b else a

arc_atomic_json <- function(x, path) {
    dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
    tmp <- paste0(path, ".tmp")
    writeLines(jsonlite::toJSON(x, auto_unbox = TRUE, null = "null",
                                pretty = TRUE), tmp)
    if (!isTRUE(file.rename(tmp, path))) {
        unlink(tmp)
        stop("could not atomically replace ", path, call. = FALSE)
    }
    invisible(path)
}

arc_grid_sha <- function(fr) {
    substr(digest::digest(arc_grid(fr), algo = "sha256"), 1, 12)
}

arc_action_label <- function(action) {
    action <- as.integer(action)
    if (identical(action, 0L)) {
        "RESET"
    } else {
        paste0("ACTION", action)
    }
}

arc_available_actions <- function(fr) {
    ids <- suppressWarnings(as.integer(unlist(fr$available_actions)))
    ids <- ids[!is.na(ids) & ids >= 1L & ids <= 7L]
    unique(ids)
}

arc_format_observation <- function(fr, used, budget, event = "OBSERVE",
                                   reconciled = FALSE, attempt = NA_integer_) {
    if (is.na(budget)) {
        remaining <- NA_integer_
    } else {
        remaining <- max(0L, budget - used)
    }
    available <- arc_available_actions(fr)
    available_text <- if (length(available)) {
        paste(paste0("ACTION", available), collapse = ", ")
    } else {
        "none reported"
    }
    paste(c(
            sprintf("event=%s%s", event,
                if (isTRUE(reconciled)) {
                    " (authoritatively reconciled)"
                } else {
                    ""
                }),
            sprintf("state=%s levels=%s/%s attempt=%s", fr$state,
                    fr$levels_completed, fr$win_levels, attempt),
            sprintf(
                    "actions_used=%d actions_remaining=%s action_budget=%s reset_cost=1",
                    used, remaining, budget
            ),
            sprintf("available_actions=%s; RESET", available_text),
            paste(
                  "The persistent R binding `fr` is the unchanged ARC FrameResponse",
                  "for this observation; `fr$frame` contains its complete temporal",
                  "frame sequence. The action counters are synchronized in",
                  "`actions_used`, `actions_remaining`, `action_budget`, and",
                  "`attempt`."
            )
        ), collapse = "\n")
}

arc_analysis_new <- function(workspace = NULL) {
    env <- new.env(parent = baseenv())
    restored <- character()
    if (!is.null(workspace) && file.exists(workspace)) {
        restored <- tryCatch(load(workspace, envir = env),
                             error = function(e) character())
        stale_handles <- grep("^\\.h_[0-9]+$", restored, value = TRUE)
        if (length(stale_handles)) {
            rm(list = stale_handles, envir = env)
            restored <- setdiff(restored, stale_handles)
        }
        envelope <- env[[".corteza_worker_checkpoint"]]
        if (is.list(envelope) && identical(envelope$format, "corteza_workspace_v1")) {
            restored <- envelope$names
        }
    }
    list(env = env, restored = restored)
}

arc_analysis_update <- function(env, fr, used, budget, attempt = NA_integer_) {
    assign("fr", fr, envir = env)
    assign("actions_used", as.integer(used), envir = env)
    assign("actions_remaining",
        if (is.na(budget)) NA_integer_ else max(0L, budget - used),
           envir = env)
    assign("action_budget", as.integer(budget), envir = env)
    assign("attempt", as.integer(attempt), envir = env)
    invisible(env)
}

arc_analysis_save <- function(env, path) {
    reserved <- c("fr", "actions_used", "actions_remaining", "action_budget",
                  "attempt")
    objects <- setdiff(ls(env, all.names = TRUE), reserved)
    objects <- objects[!grepl("^\\.h_[0-9]+$", objects)]
    dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
    tmp <- paste0(path, ".tmp")
    save(list = objects, envir = env, file = tmp)
    if (!isTRUE(file.rename(tmp, path))) {
        unlink(tmp)
        stop("could not atomically replace ARC analysis workspace")
    }
    invisible(objects)
}

# An ARC lease is an external constraint supplied to corteza's standard
# supervised dispatcher. Reserve two minutes for the next model/action round
# trip; repeated analysis calls cannot each claim a fresh 600-second allowance.
arc_run_r_cap <- function(last_activity, now = Sys.time()) {
    elapsed <- as.numeric(difftime(now, last_activity, units = "secs"))
    if (length(elapsed) != 1L || !is.finite(elapsed)) {
        stop("ARC last activity must be one valid timestamp", call. = FALSE)
    }
    max(0, min(600, 900 - 120 - max(0, elapsed)))
}

arc_last_action_time <- function(trace) {
    rows <- Filter(function(x) identical(x$source, "live"),
                   arc_trace_records(trace))
    if (!length(rows)) {
        stop("ARC journal has no live action timestamp", call. = FALSE)
    }
    stamp <- as.POSIXct(rows[[length(rows)]]$ts,
                       format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
    if (length(stamp) != 1L || is.na(stamp)) {
        stop("ARC journal has an invalid action timestamp", call. = FALSE)
    }
    stamp
}

arc_analysis_reserved <- function() {
    c("fr", "actions_used", "actions_remaining", "action_budget", "attempt")
}

arc_analysis_bindings <- function(session, env, path) {
    dynamic <- mget(arc_analysis_reserved(), envir = env, inherits = FALSE)
    if (corteza:::.run_r_worker_is_alive(session)) {
        return(dynamic)
    }
    # Rehydrate only when starting a worker. Re-sending all the old bindings
    # on every call would resurrect model-deleted state and overwrite updates.
    seed <- new.env(parent = baseenv())
    if (file.exists(path)) {
        load(path, envir = seed)
    } else {
        list2env(as.list(env, all.names = TRUE), envir = seed)
    }
    list2env(dynamic, envir = seed)
    as.list(seed, all.names = TRUE)
}

arc_analysis_checkpoint <- function(session, env, path) {
    if (corteza:::.run_r_worker_is_alive(session)) {
        return(corteza:::.run_r_worker_save(
            session, path, exclude = arc_analysis_reserved()))
    }
    # If a worker died, preserve its last good checkpoint. The host holds only
    # dynamic bindings and an old seed, never the worker's current program.
    if (as.integer(session$.run_r_worker_generation %||% 0L) > 0L) {
        if (!file.exists(path)) {
            stop("R worker was lost before a workspace checkpoint", call. = FALSE)
        }
        return(invisible(FALSE))
    }
    arc_analysis_save(env, path)
}

arc_run_r <- function(session, args, env, workspace, last_activity,
                      now = Sys.time()) {
    cap <- arc_run_r_cap(last_activity, now)
    if (cap <= 0) {
        return(corteza:::err(paste(
            "No safe R compute time remains before ARC's inactivity deadline.",
            "Choose the next supported game_action now; RESET also costs one",
            "action. Do not repeat analysis calls while the game is idle.")))
    }
    result <- corteza:::call_skill(
        "run_r", args,
        ctx = list(session = session, cwd = session$cwd,
                   run_r_bindings = arc_analysis_bindings(session, env, workspace),
                   timeout_cap = cap))
    if (isTRUE(result$isError) && !is.null(result$execution)) {
        result$content[[1L]]$text <- paste(
            result$content[[1L]]$text,
            "ARC's inactivity clock continues between calls. Consider the next",
            "supported game action before requesting more analysis.")
    }
    result
}

arc_read_pending <- function(path) {
    if (!file.exists(path)) {
        return(NULL)
    }
    tryCatch(jsonlite::fromJSON(path, simplifyVector = FALSE),
             error = function(e) NULL)
}

arc_recording_frames <- function(recording, guid = NULL) {
    frames <- lapply(recording, function(x) x$data %||% x)
    frames <- Filter(function(x) !is.null(x$frame), frames)
    if (!is.null(guid)) {
        frames <- Filter(function(x) identical(x$guid %||% "", guid), frames)
    }
    frames
}

arc_retryable_transport_error <- function(e) {
    grepl(paste0("Timeout was reached|Operation too slow|Recv failure|",
                 "Send failure|Connection reset|Could not resolve|",
                 "Empty reply|Failure when receiving|Couldn't connect|",
                 "connection to .* failed|SSL|OpenSSL|Transferred a partial|",
                 "cannot open the connection|HTTP/2 (stream|framing)|",
                 "Stream error in the HTTP/2 framing layer|",
                 "API error \\((502|503|504|529)\\)|overloaded|",
                 "token request failed \\(HTTP (429|500|502|503|504|529)\\)|",
                 "upstream connect error|disconnect/reset before headers"),
          conditionMessage(e), ignore.case = TRUE)
}

arc_retryable_model_error <- function(e) {
    arc_retryable_transport_error(e) ||
        isTRUE(corteza:::.is_limit_error(e))
}
arc_authoritative_game_gone <- function(e) {
    grepl(paste0("ARC API 404 .*?/api/recordings/|",
                 "ARC API (400|404) .*?/api/cmd/.*game .*not found|",
                 "authoritative (ARC )?game (recording )?is gone"),
          conditionMessage(e), ignore.case = TRUE, perl = TRUE)
}

# `corteza` deliberately turns ordinary custom-executor errors into tool
# results so an agent can repair a bad call. A vanished server-side game is not
# repairable by the model. A dedicated non-error condition crosses that inner
# boundary; the driver converts it to a plain error before crossing callr.
arc_game_gone_condition <- function(action_error, recovery_error) {
    structure(
        list(message = paste0(
            "authoritative ARC game is gone: action failed: ",
            conditionMessage(action_error),
            "; recording reconciliation failed: ",
            conditionMessage(recovery_error)),
             call = NULL),
        class = c("arc_game_gone", "condition"))
}

arc_model_retry_delay <- function(e, provider, now = Sys.time(),
                                  transport_seconds = 30L,
                                  limit_seconds = 1800L) {
    transport_seconds <- suppressWarnings(as.integer(transport_seconds))
    limit_seconds <- suppressWarnings(as.integer(limit_seconds))
    if (is.na(transport_seconds) || transport_seconds < 0L ||
        is.na(limit_seconds) || limit_seconds < 0L) {
        stop("ARC retry delays must be non-negative integers")
    }
    if (!isTRUE(corteza:::.is_limit_error(e))) {
        return(transport_seconds)
    }
    deadline <- tryCatch(corteza:::.fallback_until(provider),
                         error = function(e) NULL)
    if (!is.null(deadline) && length(deadline) == 1L && !is.na(deadline)) {
        remaining <- as.numeric(difftime(deadline, now, units = "secs"))
        if (is.finite(remaining) && remaining > 0) {
            return(as.integer(ceiling(remaining) + 5L))
        }
    }
    limit_seconds
}

# ARC does not publish a recording until a charged action exists. A process
# can therefore die after the free bootstrap observation yet before the
# recording endpoint exists. In that one immutable state, the strictly
# persisted bootstrap response is sufficient to reconnect: there is no remote
# mutation to reconcile and the first charged action will still prove whether
# the game session is live. Never use this fallback after an action or while an
# action outcome is pending.
arc_local_bootstrap_frame <- function(trace_path, latest_path, pending_path,
                                      guid = NULL) {
    if (file.exists(pending_path) || !file.exists(latest_path)) {
        return(NULL)
    }
    local <- tryCatch(arc_trace_records(trace_path), error = function(e) list())
    if (length(local) != 1L) {
        return(NULL)
    }
    event <- local[[1L]]
    bootstrap <- !isTRUE(event$charged) &&
        identical(as.integer(event$sequence %||% NA), 0L) &&
        identical(as.integer(event$action %||% NA), 0L) &&
        identical(event$source %||% "", "live")
    if (!bootstrap) {
        return(NULL)
    }
    frame <- tryCatch(jsonlite::fromJSON(latest_path, simplifyVector = FALSE),
                      error = function(e) NULL)
    if (is.null(frame) || is.null(frame$frame) ||
        !identical(arc_grid_sha(frame), event$grid_sha %||% "") ||
        !is.null(guid) && !identical(frame$guid %||% "", guid)) {
        return(NULL)
    }
    frame
}

arc_action_from_frame <- function(fr) {
    input <- fr$action_input %||% list()
    label <- as.character(input$id %||% "")
    action <- if (identical(label, "RESET")) {
        0L
    } else {
        suppressWarnings(as.integer(sub("^ACTION", "", label)))
    }
    data <- input$data %||% list()
    list(action = action, x = data$x %||% NULL, y = data$y %||% NULL,
         reasoning = input$reasoning %||% NULL)
}

arc_append_reconcile_log <- function(path, record) {
    if (!nzchar(path)) {
        return(invisible(NULL))
    }
    dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
    cat(jsonlite::toJSON(record, auto_unbox = TRUE, null = "null"), "\n",
        file = path, append = TRUE, sep = "")
    invisible(path)
}

# Query the authoritative session history and make the local journal an exact
# prefix of it. Missing observations are backfilled; a local-ahead or divergent
# history is refused because replaying an uncertain remote action could execute
# it twice.
arc_reconcile_session <- function(cl, game_id, guid, trace_path, latest_path,
                                  pending_path, reconcile_log = "") {
    recording <- tryCatch(arc_recording(cl, game_id, guid), error = identity)
    recovery_source <- "authoritative_recording"
    if (inherits(recording, "error")) {
        bootstrap <- arc_local_bootstrap_frame(
            trace_path, latest_path, pending_path, guid)
        if (is.null(bootstrap)) {
            stop(recording)
        }
        remote <- list(bootstrap)
        recovery_source <- "local_bootstrap_before_first_action"
    } else {
        remote <- arc_recording_frames(recording, guid)
        if (!length(remote)) {
            stop("authoritative ARC recording contains no observations",
                 call. = FALSE)
        }
    }
    session_summary <- tryCatch(arc_session(cl, guid),
                                error = function(e) {
        list(error = conditionMessage(e))
    })
    local <- arc_trace_records(trace_path)
    if (length(local) > length(remote)) {
        stop(sprintf("local ARC journal is ahead of authoritative session (%d > %d)",
                     length(local), length(remote)), call. = FALSE)
    }
    if (length(local)) {
        remote_sha <- vapply(remote[seq_along(local)], arc_grid_sha, "")
        local_sha <- vapply(local, function(x) x$grid_sha %||% "", "")
        mismatch <- which(nzchar(local_sha) & local_sha != remote_sha)
        if (length(mismatch)) {
            stop(sprintf("ARC journal diverges from authoritative session at event %d",
                         mismatch[[1]]), call. = FALSE)
        }
    }

    pending <- arc_read_pending(pending_path)
    local_before <- length(local)
    used <- arc_actions_used(trace_path)
    attempt <- 1L + arc_resets_used(trace_path)
    if (length(remote) > length(local)) {
        for (i in seq.int(length(local) + 1L, length(remote))) {
            fr <- remote[[i]]
            action <- arc_action_from_frame(fr)
            bootstrap <- i == 1L && isTRUE(fr$full_reset)
            if (identical(action$action, 0L) && !bootstrap) {
                attempt <- attempt + 1L
            }
            if (!bootstrap) {
                used <- used + 1L
            }
            .arc_trace(
                       action$action %||% NA_integer_, action$x, action$y, fr,
                       action$reasoning, charged = !bootstrap,
                       sequence = if (bootstrap) 0L else used,
                       attempt = attempt, source = "reconcile",
                       path = trace_path, latest_path = latest_path, strict = TRUE)
        }
    }

    local_after <- arc_trace_records(trace_path)
    pending_committed <- FALSE
    if (!is.null(pending)) {
        pending_committed <- any(vapply(local_after, function(x) {
            identical(as.integer(x$sequence %||% NA),
                      as.integer(pending$sequence %||% NA)) &&
            identical(as.integer(x$action %||% NA),
                      as.integer(pending$action %||% NA))
        }, logical(1)))
        unlink(pending_path)
    }
    current <- remote[[length(remote)]]
    arc_append_reconcile_log(reconcile_log, list(
            ts = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
            game_id = game_id, guid = guid,
            local_events_before = local_before,
            authoritative_events = length(remote),
            local_events_after = length(local_after),
            backfilled = length(local_after) - local_before,
            pending = !is.null(pending),
            pending_committed = pending_committed,
            recovery_source = recovery_source,
            state = current$state,
            levels_completed = current$levels_completed,
            session_error = session_summary$error %||% NULL))
    list(frame = current, pending = pending,
         pending_committed = pending_committed,
         used = used, attempt = attempt, recovery_source = recovery_source)
}

arc_new_controller <- function(cl, game_id, card_id, guid, frame,
                               action_budget, trace_path, latest_path,
                               pending_path, reconcile_log = "", send = NULL) {
    if (length(action_budget) != 1L || is.na(action_budget) ||
        action_budget < 1L) {
        stop("ARC controller requires a positive immutable action budget",
             call. = FALSE)
    }
    budget <- as.integer(action_budget)
    current <- frame
    used_count <- arc_actions_used(trace_path)
    attempt_count <- 1L + arc_resets_used(trace_path)
    epoch <- 0L
    last_action_key <- NULL

    if (is.null(send)) {
        send <- function(action, x, y, reasoning, sequence, attempt) {
            if (identical(action, 0L)) {
                arc_reset(cl, game_id, card_id, guid,
                          reasoning = reasoning,
                          trace_path = trace_path,
                          latest_path = latest_path,
                          charged = TRUE, sequence = sequence,
                          attempt = attempt, trace_strict = TRUE)
            } else {
                arc_action(cl, game_id, guid, action, x, y, reasoning,
                           trace_path = trace_path,
                           latest_path = latest_path,
                           charged = TRUE, sequence = sequence,
                           attempt = attempt, trace_strict = TRUE)
            }
        }
    }

    set_epoch <- function(value) {
        epoch <<- as.integer(value)
        invisible(epoch)
    }

    reconcile <- function() {
        out <- arc_reconcile_session(
                                     cl, game_id, guid, trace_path, latest_path,
                                     pending_path, reconcile_log)
        current <<- out$frame
        used_count <<- out$used
        attempt_count <<- out$attempt
        out
    }

    act <- function(args, context) {
        turn <- suppressWarnings(as.integer(context$agent_turn %||% NA))
        if (is.na(turn)) {
            stop("game_action requires model-call context; no action was sent",
                 call. = FALSE)
        }
        key <- paste(epoch, turn, sep = ":")
        if (identical(key, last_action_key)) {
            stop(paste0("stale action batch rejected: only one game_action may ",
                        "be committed per model decision. Observe the first ",
                        "result before choosing another action."), call. = FALSE)
        }
        # Mark the decision before validation as well: a second call in the
        # same assistant batch was generated without seeing this result.
        last_action_key <<- key
        if (file.exists(pending_path)) {
            before_pending <- current
            recovery <- reconcile()
            if (isTRUE(recovery$pending_committed)) {
                prior <- recovery$pending
                return(list(
                            frame = recovery$frame,
                            previous = before_pending,
                            action = as.integer(prior$action),
                            reasoning = prior$reasoning %||% "reconciled pending action",
                            used = used_count,
                            budget = budget,
                            attempt = attempt_count,
                            reconciled = TRUE,
                            text = paste0(
                            "A prior ambiguous action was authoritatively ",
                            "reconciled as committed. The newly requested action ",
                            "was not sent because it was chosen from stale state.\n",
                            arc_format_observation(
                                recovery$frame, used_count, budget,
                                event = paste0("RECONCILED_",
                                    arc_action_label(prior$action)),
                                reconciled = TRUE,
                                attempt = attempt_count))))
            }
        }

        action <- suppressWarnings(as.integer(args$action))
        if (length(action) != 1L || is.na(action) || action < 0L ||
            action > 7L) {
            stop("action must be one integer: 0 (RESET) or 1..7", call. = FALSE)
        }
        reasoning <- trimws(as.character(args$reasoning %||% ""))
        if (!nzchar(reasoning)) {
            stop("reasoning must briefly state what this action tests or does",
                 call. = FALSE)
        }
        available <- arc_available_actions(current)
        if (action != 0L && length(available) && !action %in% available) {
            stop(sprintf("%s is not currently available; allowed: %s",
                         arc_action_label(action),
                         paste(paste0("ACTION", available), collapse = ", ")),
                 call. = FALSE)
        }
        x <- args$x %||% NULL
        y <- args$y %||% NULL
        if (identical(action, 6L)) {
            x <- suppressWarnings(as.integer(x))
            y <- suppressWarnings(as.integer(y))
            if (length(x) != 1L || length(y) != 1L ||
                is.na(x) || is.na(y) || x < 0L || x > 63L ||
                y < 0L || y > 63L) {
                stop("ACTION6 requires integer x and y in 0..63", call. = FALSE)
            }
        } else {
            x <- y <- NULL
        }

        used_before <- used_count
        if (used_before >= budget) {
            stop(sprintf("action budget exhausted: %d/%d; no action was sent",
                         used_before, budget), call. = FALSE)
        }
        if (identical(current$state, "WIN")) {
            stop("game is already WIN; no action was sent", call. = FALSE)
        }
        if (identical(current$state, "GAME_OVER") && action != 0L) {
            stop("state is GAME_OVER; RESET is the only accepted action",
                 call. = FALSE)
        }
        next_attempt <- attempt_count +
        if (identical(action, 0L)) {
            1L
        } else {
            0L
        }
        sequence <- used_before + 1L
        intent <- list(
                       version = ARC_PROTOCOL_VERSION,
                       protocol_version = ARC_PROTOCOL_VERSION,
                       ts = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
                       sequence = sequence, action = action, x = x, y = y,
                       reasoning = reasoning, attempt = next_attempt,
                       before_grid_sha = arc_grid_sha(current),
                       before_state = current$state,
                       before_levels = current$levels_completed)
        arc_atomic_json(intent, pending_path)
        before <- current

        result <- tryCatch(
                           send(action, x, y, reasoning, sequence, next_attempt),
                           error = function(e) e)
        reconciled <- FALSE
        if (inherits(result, "error")) {
            recovery <- tryCatch(reconcile(), error = function(e) e)
            if (inherits(recovery, "error")) {
                if (arc_authoritative_game_gone(result) &&
                    arc_authoritative_game_gone(recovery)) {
                    stop(arc_game_gone_condition(result, recovery))
                }
                stop(paste0("action outcome is ambiguous and remains locked: ",
                            conditionMessage(result), "; authoritative ",
                            "reconciliation failed: ", conditionMessage(recovery)),
                     call. = FALSE)
            }
            if (!isTRUE(recovery$pending_committed)) {
                stop(paste0("action request failed; the authoritative session ",
                            "confirms it was not committed: ",
                            conditionMessage(result)), call. = FALSE)
            }
            result <- recovery$frame
            reconciled <- TRUE
        } else {
            # The real sender returns only after strict trace + latest-frame
            # persistence. Advance the private counters without reparsing the
            # entire journal on every action.
            used_count <<- used_before + 1L
            attempt_count <<- next_attempt
            unlink(pending_path)
        }

        current <<- result
        used <- used_count
        attempt <- attempt_count
        event <- arc_action_label(action)
        list(
             frame = result,
             previous = before,
             action = action,
             reasoning = reasoning,
             used = used,
             budget = budget,
             attempt = attempt,
             reconciled = reconciled,
             text = arc_format_observation(
                result, used, budget, event = event,
                reconciled = reconciled, attempt = attempt))
    }

    list(
         act = act,
         set_epoch = set_epoch,
         reconcile = reconcile,
         current = function() current,
         used = function() used_count,
         attempt = function() attempt_count,
         budget = function() budget)
}

arc_game_tools <- function() {
    list(
         list(
              name = "run_r",
              description = paste(
                                  "Evaluate R code in the persistent analysis environment.",
                                  "Use it for free computation, hypotheses, notes, and inspection",
                                  "of the raw FrameResponse in fr. It cannot submit game actions."),
              input_schema = list(
                                  type = "object",
                                  properties = list(code = list(type = "string",
                        description = "R code to evaluate persistently."),
                        timeout = list(type = "number", description = paste(
                            "Optional wall-clock seconds, at most 600.",
                            "The host may shorten this near ARC's inactivity deadline."))),
                                  required = list("code"))),
         list(
              name = "game_action",
              description = paste(
                                  "Commit exactly one ARC game action, then return a fresh",
                                  "authoritative observation. Never batch calls: choose the next",
                                  "action only after seeing this result. action=0 is RESET and",
                                  "costs one action; ACTION6 requires zero-based x and y."),
              input_schema = list(
                                  type = "object",
                                  properties = list(
                    action = list(type = "integer",
                                  description = "0 RESET, or ACTION id 1..7.",
                                  enum = as.list(0:7)),
                    x = list(type = "integer",
                             description = "ACTION6 x coordinate, 0..63."),
                    y = list(type = "integer",
                             description = "ACTION6 y coordinate, 0..63."),
                    reasoning = list(
                                     type = "string",
                                     description = paste(
                            "Short statement of what this single action tests",
                            "or executes; stored with the replay."))),
                                  required = list("action", "reasoning"))))
}
