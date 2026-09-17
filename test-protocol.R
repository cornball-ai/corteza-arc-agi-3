library(tinytest)

arc_dir <- normalizePath(".")
source(file.path(arc_dir, "version.R"))
source(file.path(arc_dir, "client.R"))
source(file.path(arc_dir, "protocol.R"))
source(file.path(arc_dir, "schedule.R"))

make_frame <- function(value = 0L, state = "NOT_FINISHED", levels = 0L,
                       action = "RESET",
                       full_reset = identical(action, "RESET"),
                       available = 1:7, guid = "test-guid") {
    rows <- lapply(seq_len(64L), function(i) rep(as.integer(value), 64L))
    list(game_id = "test-game", state = state,
         levels_completed = as.integer(levels), win_levels = 3L,
         action_input = list(id = action, data = list(), reasoning = NULL),
         guid = guid, full_reset = full_reset,
         available_actions = as.list(as.integer(available)),
         frame = list(rows))
}

change_cell <- function(fr, x, y, value, action = "ACTION1") {
    out <- fr
    out$frame[[length(out$frame)]][[y + 1L]][x + 1L] <- as.integer(value)
    out$action_input <- list(id = action,
                             data = list(x = as.integer(x), y = as.integer(y)),
                             reasoning = "test")
    out$full_reset <- FALSE
    out
}

tmp <- tempfile("arc-protocol-")
dir.create(tmp)
cookie_dir <- file.path(tmp, "campaign")
dir.create(cookie_dir)
cookie_file <- file.path(cookie_dir, "cookies.txt")
writeLines("test-cookie", cookie_file)
manifest_file <- file.path(cookie_dir, "campaign.json")
expect_equal(arc_campaign_cookiejar("cookies.txt", manifest_file),
             normalizePath(cookie_file))
expect_equal(arc_campaign_cookiejar("/data/run/cookies.txt", manifest_file),
             normalizePath(cookie_file))
expect_equal(arc_campaign_cookiejar(cookie_file, manifest_file),
             normalizePath(cookie_file))
expect_equal(arc_campaign_cookiejar(NULL, manifest_file), "")
worker_a <- file.path(cookie_dir, "state", "test-card--a", "cookies.txt")
worker_b <- file.path(cookie_dir, "state", "test-card--b", "cookies.txt")
arc_clone_cookiejar(cookie_file, worker_a)
arc_clone_cookiejar(cookie_file, worker_b)
manifest <- list(card_id = "test-card", cookiejar = "cookies.txt")
expect_equal(normalizePath(arc_campaign_current_cookiejar(manifest, manifest_file)),
             normalizePath(cookie_file))
writeLines("worker-a-cookie", worker_a)
writeLines("{}", file.path(dirname(worker_a), "latest-frame.json"))
Sys.setFileTime(worker_a, Sys.time() + 1)
Sys.setFileTime(worker_b, Sys.time() + 2)
# A newer clone without a successful RESET must not displace a proven jar.
current_cookie <- arc_campaign_current_cookiejar(manifest, manifest_file)
expect_equal(normalizePath(current_cookie), normalizePath(worker_a))
writeLines("{}", file.path(dirname(worker_b), "latest-frame.json"))
current_cookie <- arc_campaign_current_cookiejar(manifest, manifest_file)
expect_equal(normalizePath(current_cookie), normalizePath(worker_b))
expect_equal(readLines(cookie_file), "test-cookie")
expect_error(arc_clone_cookiejar(cookie_file, cookie_file),
             pattern = "must differ")
expect_false(arc_card_missing_error(
    "ARC API 400 on /api/cmd/RESET: game test-game not found"))
expect_true(arc_card_missing_error(NULL,
    "ARC API 404 on /api/scorecard/test: card_id `test-card` not found"))

validate_manifest <- file.path(cookie_dir, "validate-campaign.json")
validate_data <- list(
    protocol_version = ARC_PROTOCOL_VERSION,
    state = "open",
    card_id = "test-card",
    cookiejar = "cookies.txt",
    label = "pool-test",
    model = "claude-opus-5",
    provider = "anthropic",
    prompt_sha = "test-sha",
    effort = "max",
    thinking = 0L,
    max_tokens = 32000L,
    workers = 5L,
    expected_games = list("a", "b"))
writeLines(
    jsonlite::toJSON(validate_data, auto_unbox = TRUE, pretty = TRUE),
    validate_manifest)
validate_campaign <- function(workers) {
    out <- suppressWarnings(system2(
        "r",
        c(file.path(arc_dir, "campaign.R"),
          "validate", validate_manifest, "pool-test",
          "claude-opus-5", "anthropic", "test-sha", "max", "0",
          "32000", as.character(workers), "a"),
        env = paste0("ARC_HARNESS_DIR=", arc_dir),
        stdout = TRUE, stderr = TRUE))
    status <- attr(out, "status")
    if (is.null(status)) 0L else as.integer(status)
}
expect_equal(validate_campaign(5L), 0L)
expect_true(validate_campaign(4L) != 0L)


canonical <- arc_game_order(file.path(arc_dir, "baselines"))
baseline_total <- function(slug) {
    sum(jsonlite::fromJSON(
        file.path(arc_dir, "baselines", paste0(slug, ".json")))$baseline)
}
canonical_totals <- vapply(canonical, baseline_total, numeric(1))
expect_equal(length(canonical), 25L)
expect_true(all(diff(canonical_totals) >= 0))
expect_equal(arc_game_order(file.path(arc_dir, "baselines"),
                            c(canonical[[5]], canonical[[2]])),
             c(canonical[[2]], canonical[[5]],
               canonical[-c(2L, 5L)]))

trace <- file.path(tmp, "trace.jsonl")
latest <- file.path(tmp, "latest.json")
pending <- file.path(tmp, "pending.json")
reconcile_log <- file.path(tmp, "reconcile.jsonl")
workspace <- file.path(tmp, "workspace.RData")

initial <- make_frame()
.arc_trace(0L, NULL, NULL, initial, charged = FALSE, sequence = 0L,
           attempt = 1L, path = trace, latest_path = latest, strict = TRUE)
move <- change_cell(initial, 0L, 0L, 2L)
.arc_trace(1L, NULL, NULL, move, charged = TRUE, sequence = 1L,
           attempt = 1L, path = trace, latest_path = latest, strict = TRUE)
reset <- make_frame(action = "RESET")
.arc_trace(0L, NULL, NULL, reset, charged = TRUE, sequence = 2L,
           attempt = 2L, path = trace, latest_path = latest, strict = TRUE)

expect_equal(arc_actions_used(trace), 2L)
expect_equal(arc_resets_used(trace), 1L)
expect_equal(length(arc_trace_records(trace)), 3L)

legacy_trace <- file.path(tmp, "legacy-trace.jsonl")
writeLines(jsonlite::toJSON(list(action = 1L, state = "NOT_FINISHED"),
                            auto_unbox = TRUE),
           legacy_trace)
expect_error(arc_trace_records(legacy_trace),
             pattern = sprintf("not protocol v%d", ARC_PROTOCOL_VERSION))

obs <- arc_format_observation(move, used = 1L, budget = 10L, event = "ACTION1",
                              attempt = 2L)
expect_true(grepl("actions_remaining=9", obs, fixed = TRUE))
expect_true(grepl("reset_cost=1", obs, fixed = TRUE))
expect_true(grepl("available_actions=ACTION1", obs, fixed = TRUE))
expect_true(grepl("unchanged ARC FrameResponse", obs, fixed = TRUE))
expect_false(grepl("diff=", obs, fixed = TRUE))
expect_true(grepl("attempt=2", obs, fixed = TRUE))
expect_false(grepl("settled_grid_hex", obs, fixed = TRUE))

analysis <- arc_analysis_new()
arc_analysis_update(analysis$env, initial, 0L, 10L, 1L)
arc_analysis_update(analysis$env, move, 1L, 10L, 2L)
expect_identical(get("fr", analysis$env), move)
expect_equal(get("actions_used", analysis$env), 1L)
expect_equal(get("actions_remaining", analysis$env), 9L)
expect_equal(get("attempt", analysis$env), 2L)
automatic <- c("grid", "previous_fr", "previous_grid", "last_diff",
               "frame_history", "action_history", "arc_grid",
               "arc_show", "arc_diff", "arc_frame_diff")
expect_false(any(vapply(automatic, exists, logical(1), envir = analysis$env,
                        inherits = FALSE)))

evaluated <- corteza::tool_run_r(
                                 paste0("grid <- matrix(unlist(fr$frame[[length(fr$frame)]]), ",
                                        "nrow = 64L, byrow = TRUE); ",
                                        "frame_history <- list(grid); note <- 'kept'; NULL"),
                                 envir = analysis$env
)
expect_false(isTRUE(evaluated$isError))
expect_equal(corteza::tool_run_r("note", envir = analysis$env)$content[[1]]$text,
             "[1] \"kept\"")
expect_false(exists("cl", envir = analysis$env, inherits = TRUE))

handled <- corteza::tool_run_r("matrix(1:4, 2, 2)", envir = analysis$env)
expect_true(grepl("stored as .h_001", handled$content[[1]]$text, fixed = TRUE))
expect_true(grepl(
                  "2 2",
                  corteza::tool_run_r("dim(.h_001)", envir = analysis$env)$content[[1]]$text,
                  fixed = TRUE
    ))
arc_analysis_save(analysis$env, workspace)
restored <- arc_analysis_new(workspace)
expect_equal(get("note", restored$env), "kept")
expect_equal(length(get("frame_history", restored$env)), 1L)
expect_equal(dim(get("grid", restored$env)), c(64L, 64L))
expect_false(exists(".h_001", envir = restored$env, inherits = FALSE))

# The per-call cap shrinks across repeated compute requests, preserving two
# minutes for a model response and a real game action. Reads cannot reset it.
clock_start <- as.POSIXct("2026-09-13 12:00:00", tz = "UTC")
expect_equal(arc_run_r_cap(clock_start, clock_start), 600)
expect_equal(arc_run_r_cap(clock_start, clock_start + 300), 480)
expect_equal(arc_run_r_cap(clock_start, clock_start + 700), 80)
expect_equal(arc_run_r_cap(clock_start, clock_start + 780), 0)
expect_equal(arc_run_r_cap(clock_start, clock_start + 1000), 0)
expect_error(arc_run_r_cap(NA, clock_start), pattern = "timestamp")

# Exercise the adapter against an actual supervised worker, without any ARC
# or model network calls. Persistent helpers see each new authoritative frame.
corteza::ensure_skills()
worker_session <- corteza::new_session("console")
worker_session$cwd <- tmp
worker_session$config <- list(run_r_mode = "worker", skill_timeout = 600,
                              skill_timeout_max = 600)
worker_env <- arc_analysis_new()$env
worker_path <- file.path(tmp, "worker-workspace.RData")
arc_analysis_update(worker_env, initial, 0L, 10L, 1L)
arc_analysis_checkpoint(worker_session, worker_env, worker_path)
worker_call <- function(code, timeout = NULL, elapsed = 0) {
    args <- list(code = code)
    if (!is.null(timeout)) args$timeout <- timeout
    arc_run_r(worker_session, args, worker_env, worker_path,
              clock_start, now = clock_start + elapsed)
}
worker_result <- worker_call(
    "read_level <- function() fr$levels_completed; kept <- 19L; read_level()")
expect_false(isTRUE(worker_result$isError))
expect_equal(worker_result$execution$timeout_seconds, 600)
expect_equal(worker_result$content[[1]]$text, "[1] 0")
expect_false(exists("read_level", worker_env, inherits = FALSE))
arc_analysis_checkpoint(worker_session, worker_env, worker_path)
arc_analysis_update(worker_env, make_frame(levels = 2L), 2L, 10L, 1L)
expect_equal(worker_call("read_level()")$content[[1]]$text, "[1] 2")
worker_call("rm(kept)")
expect_equal(worker_call("exists('kept', inherits = FALSE)")$content[[1]]$text,
             "[1] FALSE")
expect_equal(worker_call("1", elapsed = 700)$execution$timeout_seconds, 80)
blocked <- worker_call("should_not_run <- TRUE", elapsed = 780)
expect_true(blocked$isError)
expect_equal(worker_call("exists('should_not_run', inherits = FALSE)")$content[[1]]$text,
             "[1] FALSE")
expect_true(worker_call("1", timeout = 601)$isError)
timed <- worker_call("partial <- 3L; repeat {}", timeout = 0.1)
expect_true(timed$isError)
expect_equal(timed$execution$status, "timeout")
expect_true(timed$execution$state_retained)
expect_equal(worker_call("partial")$content[[1]]$text, "[1] 3")
arc_analysis_checkpoint(worker_session, worker_env, worker_path)
before_loss <- digest::digest(file = worker_path)
corteza:::.run_r_worker_close(worker_session)
# An observer after forced termination cannot overwrite a good worker snapshot
# using the stale host seed. A fresh worker must recover helpers and partials.
arc_analysis_checkpoint(worker_session, worker_env, worker_path)
expect_equal(digest::digest(file = worker_path), before_loss)
arc_analysis_update(worker_env, make_frame(levels = 3L), 4L, 10L, 2L)
expect_equal(worker_call("read_level()")$content[[1]]$text, "[1] 3")
expect_equal(worker_call("partial")$content[[1]]$text, "[1] 3")
expect_equal(worker_call("exists('kept', inherits = FALSE)")$content[[1]]$text,
             "[1] FALSE")
expect_equal(worker_session$.run_r_worker_generation, 2L)
corteza:::.run_r_worker_close(worker_session)

controller_trace <- file.path(tmp, "controller.jsonl")
controller_latest <- file.path(tmp, "controller-latest.json")
controller_pending <- file.path(tmp, "controller-pending.json")
.arc_trace(0L, NULL, NULL, initial, charged = FALSE, sequence = 0L,
           attempt = 1L, path = controller_trace,
           latest_path = controller_latest, strict = TRUE)
live <- initial
sender <- function(action, x, y, reasoning, sequence, attempt) {
    live <<- if (identical(action, 0L)) {
        make_frame(action = "RESET")
    } else {
        change_cell(live, sequence - 1L, 0L, sequence, arc_action_label(action))
    }
    .arc_trace(action, x, y, live, reasoning, charged = TRUE,
               sequence = sequence, attempt = attempt,
               path = controller_trace, latest_path = controller_latest,
               strict = TRUE)
    live
}
controller <- arc_new_controller(NULL, "test-game", "test-card",
                                 "test-guid", initial, 2L, controller_trace,
                                 controller_latest, controller_pending,
                                 send = sender)
controller$set_epoch(1L)
first <- controller$act(list(action = 1L, reasoning = "first probe"),
                        list(agent_turn = 1L, call_index = 1L, call_count = 2L))
expect_equal(first$used, 1L)
expect_error(
             controller$act(list(action = 1L, reasoning = "stale second"),
                            list(agent_turn = 1L, call_index = 2L, call_count = 2L)),
             pattern = "stale action batch")
second <- controller$act(
                         list(action = 0L, reasoning = "counted reset"),
                         list(agent_turn = 2L, call_index = 1L, call_count = 1L))
expect_equal(second$used, 2L)
expect_equal(second$attempt, 2L)
expect_equal(controller$used(), 2L)
expect_equal(arc_actions_used(controller_trace), 2L)
expect_equal(arc_resets_used(controller_trace), 1L)
expect_error(
             controller$act(list(action = 1L, reasoning = "over cap"),
                            list(agent_turn = 3L, call_index = 1L, call_count = 1L)),
             pattern = "budget exhausted")

# Authoritative recovery backfills a committed action after a local process
# lost its response/trace tail, and clears the pending intent.
reconcile_trace <- file.path(tmp, "reconcile-trace.jsonl")
reconcile_latest <- file.path(tmp, "reconcile-latest.json")
reconcile_pending <- file.path(tmp, "reconcile-pending.json")
remote_move <- change_cell(initial, 3L, 4L, 5L, "ACTION6")
remote_move$action_input$data <- list(game_id = "test-game", x = 3L, y = 4L)
remote_move$action_input$reasoning <- "ambiguous click"
.arc_trace(0L, NULL, NULL, initial, charged = FALSE, sequence = 0L,
           attempt = 1L, path = reconcile_trace,
           latest_path = reconcile_latest, strict = TRUE)
arc_atomic_json(
                list(sequence = 1L, action = 6L, x = 3L, y = 4L,
                     reasoning = "ambiguous click"), reconcile_pending)
authoritative <- list(list(data = initial), list(data = remote_move))
assign("arc_recording", function(cl, game_id, guid) authoritative,
       envir = globalenv())
assign("arc_session",
       function(cl, guid) list(guid = guid, state = "NOT_FINISHED"),
       envir = globalenv())

recovered <- arc_reconcile_session(NULL, "test-game", "test-guid",
                                   reconcile_trace, reconcile_latest,
                                   reconcile_pending, reconcile_log)
expect_true(recovered$pending_committed)
expect_equal(recovered$used, 1L)
expect_equal(length(arc_trace_records(reconcile_trace)), 2L)
expect_false(file.exists(reconcile_pending))
expect_true(file.exists(reconcile_log))
expect_equal(arc_grid_sha(recovered$frame), arc_grid_sha(remote_move))

expect_true(arc_retryable_transport_error(simpleError(
    paste0("Stream error in the HTTP/2 framing layer [chatgpt.com]:\n",
           "HTTP/2 stream 1 was not closed cleanly: INTERNAL_ERROR (err 2)"))))
expect_false(arc_retryable_transport_error(simpleError("invalid tool input")))
expect_true(arc_retryable_transport_error(simpleError(
    "OAuth token refresh failed: token request failed (HTTP 503): unavailable")))
expect_false(arc_retryable_transport_error(simpleError(
    "OAuth token refresh failed: token request failed (HTTP 400): invalid_grant")))
limit_error <- simpleError(paste("every provider is in a limit cooldown:",
                                 "openai_codex until 20:20"))
overload_error <- simpleError(paste(
    "OpenAI Codex request failed: Our servers are currently overloaded.",
    "Please try again later."))
expect_true(arc_retryable_model_error(limit_error))
expect_true(arc_retryable_model_error(overload_error))
expect_false(arc_retryable_model_error(simpleError("invalid tool input")))
corteza:::.fallback_reset()
retry_now <- as.POSIXct("2026-09-08 12:00:00", tz = "UTC")
corteza:::.fallback_mark_until("openai_codex", retry_now + 60)
expect_equal(arc_model_retry_delay(limit_error, "openai_codex",
                                   now = retry_now), 65L)
corteza:::.fallback_reset()
expect_equal(arc_model_retry_delay(limit_error, "openai_codex",
                                   now = retry_now), 1800L)
expect_equal(arc_model_retry_delay(simpleError("HTTP/2 stream error"),
                                   "openai_codex", now = retry_now), 30L)
expect_error(arc_model_retry_delay(limit_error, "openai_codex",
                                   limit_seconds = NA_integer_),
             "non-negative integers")

# Before the first charged action ARC has no recording endpoint. The strict
# local bootstrap response is the only safe recording-free recovery case.
bootstrap_trace <- file.path(tmp, "bootstrap-only.jsonl")
bootstrap_latest <- file.path(tmp, "bootstrap-only-latest.json")
bootstrap_pending <- file.path(tmp, "bootstrap-only-pending.json")
bootstrap_log <- file.path(tmp, "bootstrap-only-reconcile.jsonl")
.arc_trace(0L, NULL, NULL, initial, charged = FALSE, sequence = 0L,
           attempt = 1L, path = bootstrap_trace,
           latest_path = bootstrap_latest, strict = TRUE)
assign("arc_recording", function(cl, game_id, guid) {
    stop("ARC API 404 on /api/recordings/test-game/test-guid: recording not found",
         call. = FALSE)
}, envir = globalenv())
bootstrap_recovered <- arc_reconcile_session(
    NULL, "test-game", "test-guid", bootstrap_trace, bootstrap_latest,
    bootstrap_pending, bootstrap_log)
expect_equal(bootstrap_recovered$used, 0L)
expect_equal(bootstrap_recovered$attempt, 1L)
expect_identical(bootstrap_recovered$recovery_source,
                 "local_bootstrap_before_first_action")
expect_equal(arc_grid_sha(bootstrap_recovered$frame), arc_grid_sha(initial))

# Once any action exists, a missing authoritative recording remains fatal.
post_action_trace <- file.path(tmp, "post-action.jsonl")
post_action_latest <- file.path(tmp, "post-action-latest.json")
.arc_trace(0L, NULL, NULL, initial, charged = FALSE, sequence = 0L,
           attempt = 1L, path = post_action_trace,
           latest_path = post_action_latest, strict = TRUE)
.arc_trace(1L, NULL, NULL, move, charged = TRUE, sequence = 1L,
           attempt = 1L, path = post_action_trace,
           latest_path = post_action_latest, strict = TRUE)
expect_error(arc_reconcile_session(
    NULL, "test-game", "test-guid", post_action_trace, post_action_latest,
    file.path(tmp, "post-action-pending.json")), pattern = "404")
# A definitive action 404 plus recording 404 escapes corteza's ordinary tool
# error boundary, so the scheduler can advance instead of paying for a loop.
gone_trace <- file.path(tmp, "gone-trace.jsonl")
gone_latest <- file.path(tmp, "gone-latest.json")
gone_pending <- file.path(tmp, "gone-pending.json")
.arc_trace(0L, NULL, NULL, initial, charged = FALSE, sequence = 0L,
           attempt = 1L, path = gone_trace, latest_path = gone_latest,
           strict = TRUE)
gone_controller <- arc_new_controller(
    NULL, "test-game", "test-card", "test-guid", initial, 10L,
    gone_trace, gone_latest, gone_pending,
    send = function(...) {
        stop("ARC API 400 on /api/cmd/ACTION1: game test-game not found",
             call. = FALSE)
    })
gone_controller$set_epoch(1L)
gone <- tryCatch(
    gone_controller$act(
        list(action = 1L, reasoning = "test terminal loss"),
        list(agent_turn = 1L, call_index = 1L, call_count = 1L)),
    arc_game_gone = identity,
    error = identity)
expect_true(inherits(gone, "arc_game_gone"))
expect_false(inherits(gone, "interrupt"))
expect_true(grepl("authoritative ARC game is gone", conditionMessage(gone),
                  fixed = TRUE))
expect_false(arc_authoritative_game_gone(simpleError("invalid tool input")))
# Corteza's ordinary custom-executor error wrapper must not turn this terminal
# controller signal into another model-visible tool error.
not_swallowed <- tryCatch(
    tryCatch(stop(gone), error = function(e) "swallowed"),
    arc_game_gone = identity)
expect_true(inherits(not_swallowed, "arc_game_gone"))
crossed <- tryCatch(
    callr::r(
        function(path) {
            source(path, local = TRUE)
            signal <- arc_game_gone_condition(
                simpleError("action game not found"),
                simpleError("recording not found"))
            tryCatch(
                stop(signal),
                arc_game_gone = function(e) {
                    stop(conditionMessage(e), call. = FALSE)
                })
        },
        args = list(file.path(arc_dir, "protocol.R")),
        package = FALSE),
    error = identity)
crossed_message <- conditionMessage(crossed)
expect_true(inherits(crossed, "error"))
expect_true(grepl("authoritative ARC game is gone", crossed_message,
                  fixed = TRUE))
expect_false(grepl("subprocess interrupted", crossed_message, fixed = TRUE))

# The callr worker receives every prompt dependency explicitly. A global
# constant is not visible when callr serializes play_one into a clean process.
driver_expr <- parse(file.path(arc_dir, "driver.R"))
expect_identical(deparse(driver_expr[[length(driver_expr)]]), "main()")
driver_env <- new.env(parent = globalenv())
for (expr in driver_expr[-length(driver_expr)]) eval(expr, driver_env)
expect_true("compaction_prompt" %in% names(formals(driver_env$play_one)))
worker_globals <- codetools::findGlobals(driver_env$play_one, merge = FALSE)$variables
expect_false("ARC_COMPACTION_PROMPT" %in% worker_globals)
play_text <- paste(deparse(body(driver_env$play_one)), collapse = "\n")
expect_true(grepl("arc_game_gone = function(e)", play_text, fixed = TRUE))
expect_true(grepl("stop(conditionMessage(e), call. = FALSE)", play_text, fixed = TRUE))
expect_true(grepl("context_compact_bytes <- compact_bytes", play_text,
                  fixed = TRUE))
expect_true(grepl("context_request_buffer_retries <- request_buffer_retry_limit",
                  play_text, fixed = TRUE))
expect_true(grepl("corteza_request_buffer_retries", play_text, fixed = TRUE))
expect_true(grepl("context_peak_request_bytes", play_text, fixed = TRUE))
expect_true(grepl("ARC_LIMIT_RETRIES", play_text, fixed = TRUE))
expect_true(grepl("arc_model_retry_delay", play_text, fixed = TRUE))

container_text <- paste(readLines(file.path(arc_dir, "run-container.sh"),
                                  warn = FALSE), collapse = "\n")
expect_true(grepl("ARC_CONTEXT_COMPACT_BYTES", container_text,
                  fixed = TRUE))
expect_true(grepl("ARC_REQUEST_BUFFER_RETRIES", container_text,
                  fixed = TRUE))
expect_true(grepl("ARC_LIMIT_RETRIES", container_text, fixed = TRUE))
expect_true(grepl('SLOTS="${ARC_SLOTS:-5}"', container_text, fixed = TRUE))
expect_true(grepl('MODEL="${ARC_MODEL:-claude-opus-5}"', container_text,
                  fixed = TRUE))
expect_true(grepl('PROVIDER="${ARC_PROVIDER:-anthropic}"', container_text,
                  fixed = TRUE))
campaign_text <- paste(readLines(file.path(arc_dir, "campaign.R"), warn = FALSE),
                       collapse = "\n")
expect_true(grepl("workers = wanted$workers", campaign_text, fixed = TRUE))
expect_equal(vapply(arc_game_tools(), function(x) x$name, ""),
             c("run_r", "game_action"))
expect_true("timeout" %in% names(arc_game_tools()[[1]]$input_schema$properties))
expect_true(grepl('run_r_mode <- "worker"', play_text, fixed = TRUE))
expect_true(grepl("skill_timeout_max <- 600", play_text, fixed = TRUE))
expect_true(grepl("arc_analysis_checkpoint", play_text, fixed = TRUE))
build_text <- paste(readLines(file.path(arc_dir, "build-container.sh"),
                              warn = FALSE), collapse = "\n")
expect_true(grepl("stage_repo", build_text, fixed = TRUE))
expect_true(grepl("git -C \"$source\" archive --format=tar HEAD", build_text,
                  fixed = TRUE))

sweep_text <- paste(readLines(file.path(arc_dir, "sweep.sh"), warn = FALSE),
                    collapse = "\n")
expect_true(grepl("ARC_CONTEXT_COMPACT_BYTES", sweep_text, fixed = TRUE))
expect_true(grepl("ARC_REQUEST_BUFFER_RETRIES", sweep_text, fixed = TRUE))

expect_true(grepl("arc_card_missing_error", sweep_text, fixed = TRUE))
expect_false(grepl("bootstrap_gone", sweep_text, fixed = TRUE))
expect_true(grepl("ARC_LIMIT_RETRIES", sweep_text, fixed = TRUE))
expect_true(grepl(
    'full-set verification follows',
    sweep_text, fixed = TRUE))
expect_true(grepl('source "$SCRIPT_DIR/worker-pool.sh"', sweep_text,
                  fixed = TRUE))
expect_true(grepl('arc_game_order(file.path(a[1], "baselines"), inprog)',
                  sweep_text, fixed = TRUE))
expect_false(grepl("shared-scorecard campaign requires slots=1", sweep_text,
                   fixed = TRUE))
expect_false(grepl(
    'sweep incomplete at $slug; campaign left open',
    sweep_text, fixed = TRUE))
main_text <- paste(deparse(body(driver_env$main)), collapse = "\n")
expect_true(grepl("arc_campaign_current_cookiejar", play_text, fixed = TRUE))
expect_true(grepl("compaction_prompt = ARC_COMPACTION_PROMPT", main_text,
                  fixed = TRUE))

pool_script <- file.path(tmp, "test-worker-pool.sh")
pool_log <- file.path(tmp, "pool.log")
writeLines(c(
    "set -uo pipefail",
    sprintf("source %s", shQuote(file.path(arc_dir, "worker-pool.sh"))),
    sprintf("pool_log=%s", shQuote(pool_log)),
    "worker() {",
    "  printf 'start:%s\\n' \"$1\" >> \"$pool_log\"",
    "  case \"$1\" in a) sleep 0.4;; b) sleep 0.05;; c) sleep 0.05;; esac",
    "  printf 'end:%s\\n' \"$1\" >> \"$pool_log\"",
    "  [ \"$1\" != c ]",
    "}",
    "status=0",
    "arc_run_pool 2 worker a b c || status=$?",
    "[ \"$status\" -eq 1 ]",
    "expected=$(printf 'start:a\\nstart:b\\nend:b\\nstart:c\\nend:c\\nend:a')",
    "[ \"$(cat \"$pool_log\")\" = \"$expected\" ]",
    ": > \"$pool_log\"",
    "fatal_worker() {",
    "  printf 'start:%s\\n' \"$1\" >> \"$pool_log\"",
    "  case \"$1\" in",
    "    x) (sleep 0.4; printf 'orphan:x\\n' >> \"$pool_log\") & wait;;",
    "    y) sleep 0.05; return 2;;",
    "    z) return 0;;",
    "  esac",
    "}",
    "status=0",
    "arc_run_pool 2 fatal_worker x y z || status=$?",
    "[ \"$status\" -eq 2 ]",
    "[ \"$ARC_POOL_FATAL_SLUG\" = y ]",
    "! grep -q 'start:z' \"$pool_log\"",
    "sleep 0.5",
    "! grep -q 'orphan:x' \"$pool_log\""
), pool_script)
expect_equal(system2("bash", pool_script), 0L)

# Run the actual sweep retry loop, including fresh failures before any resume.
for (scenario in c("fresh-error", "fresh-retryable", "resume-error",
                    "resume-retryable", "fresh-exhausted", "inherited-state",
                    "separate-games")) {
    retry_output <- suppressWarnings(system2(
        "bash", c(shQuote(file.path(arc_dir, "test-sweep.sh")),
                  shQuote(file.path(tmp, scenario)), shQuote(scenario)),
        stdout = TRUE, stderr = TRUE))
    retry_status <- attr(retry_output, "status") %||% 0L
    expect_equal(retry_status, 0L,
                 info = paste(scenario, paste(retry_output, collapse = "\n")))
}
unlink(tmp, recursive = TRUE)
cat("ARC protocol checks complete\n")
