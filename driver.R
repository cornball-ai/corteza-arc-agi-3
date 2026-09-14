# Corteza plays ARC-AGI-3: one game per callr subprocess, rlm arm.
#
# The agent gets a persistent R analysis environment plus one
# transactional game_action tool. The analysis environment has the raw
# FrameResponse and model-authored state, but no ARC client. A
# controller outside that environment owns credentials, the immutable
# budget, action journaling, and authoritative reconciliation.
#
# Game-instance ids are SESSION-SCOPED: each cookie session sees its
# own hash-suffixed ids for the same game slugs (learned by 400 "game
# not found" on a cross-session id). Game SLUGS (e.g. "ls20") are
# therefore resolved inside the session that plays them. Normally a
# child owns its scorecard lifecycle. In campaign mode, independent children
# reuse one card while cloning its seed cookies into private per-game jars;
# local artifacts use card id + slug so the games remain distinct.
#
# Usage:
#   r driver.R <model> <provider> <max_turns> <n_games> [slug ...]

# Behavioral structure adapted from Prime Intellect's ARC-AGI-3 Prime Agent
# guidance (MIT):
# https://github.com/PrimeIntellect-ai/arc-agi-3-prime-agent/blob/main/AGENTS.md
# See THIRD_PARTY_NOTICES.md. The R execution model, one-action controller,
# action budget, checkpointing, reconciliation, and compaction are corteza's.
ARC_COMPACTION_PROMPT <- paste(
    "Compress the older portion of this ARC-AGI-3 trajectory so the same agent can continue without losing game evidence.",
    "Preserve only information supported by the trajectory: discovered mechanics and confidence, solved level paths, failed routes and their outcomes, current hypotheses and unresolved tests, budget or attempt facts when present, and the names and purposes of useful R bindings or helper functions.",
    "The persistent R workspace survives compaction, so describe reusable objects instead of reproducing their contents. Distinguish observations from inference. Do not invent rules, states, solutions, or actions.",
    sep = "\n"
)

ARC_SYSTEM <- paste0(
                     "You are playing one ARC-AGI-3 game. Your primary objective is to ",
                     "solve all levels. Your secondary objective is to minimize total ",
                     "cumulative actions. You have two tools with a hard ",
                     "separation of responsibilities. `run_r` evaluates code in a ",
                     "PERSISTENT analysis environment: assignments, notes, helper ",
                     "functions, and any history you build survive for the whole game. ",
                     "`game_action` ",
                     "commits exactly one game action. R analysis is free; game actions ",
                     "consume the score and the fixed run budget.\n\n",
                     "R runs in a supervised persistent worker with a maximum of ",
                     "600 seconds per call. The host shortens this as time since ",
                     "the last game action approaches ARC's 15-minute inactivity ",
                     "deadline, reserving time for another action. After a timeout, ",
                     "inspect retained state, improve or reuse helpers, split or ",
                     "reduce the work, parallelize independent work, or approximate. ",
                     "A timeout may leave completed assignments in place; a forced ",
                     "worker restart restores the last checkpoint.\n\n",
                     "Treat only this game's observations and your own retained conversation ",
                     "and analysis as game information. Never inspect game or engine source, ",
                     "another game, another session, a prior run, network resources, ",
                     "credentials, or unprovided files. Do not read or write game notes ",
                     "outside the isolated analysis environment.\n\n",
                     "The analysis environment is synchronized after every observation. ",
                     "`fr` is the latest unchanged ARC FrameResponse. Host-owned bindings ",
                     "`actions_used`, `actions_remaining`, `action_budget`, and `attempt` ",
                     "expose the fixed budget and current attempt. No derived grid, diff, frame history, action ",
                     "history, game helper, or simulator is supplied: construct and retain ",
                     "any analysis you need in R from `fr`. Large R results use corteza's ",
                     "normal reusable handles. The analysis environment has no live ARC ",
                     "client and cannot submit actions.\n\n",
                     "`fr$frame` is the complete response frame sequence in chronological ",
                     "order. Frame 1/N through frame N/N are temporal frames produced by ",
                     "the action; intermediate frames may reveal motion, contact, or ",
                     "causality. The final frame is the settled committed state and is ",
                     "the current board. Analyze these numeric matrices programmatically ",
                     "in R rather than relying on visual transcription. `fr` is replaced ",
                     "by the next response, so retain any observation or derived state you ",
                     "will need under your own binding. Useful analyses include color ",
                     "frequencies, connected components, positions, sizes, shapes, fixed-cell ",
                     "histories, and before/after or distant-turn diffs.\n\n",
                     "Cell values use the canonical ARC color map: 0 White, 1 Off-White, ",
                     "2 Light Gray, 3 Gray, 4 Off-Black, 5 Black, 6 Magenta, 7 Light ",
                     "Magenta, 8 Red, 9 Blue, 10 Light Blue, 11 Yellow, 12 Orange, ",
                     "13 Maroon, 14 Green, and 15 Purple.\n\n",
                     "Call `game_action(action, reasoning, x, y)` for one committed ",
                     "action. Input semantics are fixed: action 0 RESETs the current level; ",
                     "1 is Up, 2 Down, 3 Left, 4 Right, 5 Spacebar/interact, 6 a click, ",
                     "and 7 Undo. These define the inputs, not how a game responds; infer ",
                     "each game's mechanics from observations. ACTION6 requires zero-based ",
                     "x and y in 0..63. Only listed available actions may be submitted, ",
                     "plus RESET.\n\n",
                     "Before every action, provide a concise reasoning string stating the ",
                     "current hypothesis, expected change, shortest useful test or supported ",
                     "execution step, and remaining-budget implication. Never batch ",
                     "game_action calls or choose a second action ",
                     "from a stale observation: inspect each returned observation first. ",
                     "The controller rejects a second game action from the same model ",
                     "decision. The response reports state, level progress, legal actions, ",
                     "and the exact budget meter; the raw response is synchronized into ",
                     "`fr`. An increase in `fr$levels_completed` means the level was ",
                     "cleared.\n\n",
                     "After every observation, inspect the temporal sequence and settled ",
                     "state, compare expected with observed changes, and update a world ",
                     "model of likely players, walls, goals, hazards, UI, interactions, ",
                     "and timers. Reassess every fresh level or reset before acting. Never ",
                     "repeat an unchanged or losing sequence without a new evidence-based ",
                     "reason. Treat the persistent workspace as a small evolving R program: ",
                     "define and reuse helpers for recurring decoding or comparison. Maintain ",
                     "your own compact level-and-attempt ledger with starting state, tested ",
                     "route or action prefix, outcome, and new evidence; consult it before ",
                     "repeating a route. Put durable game knowledge there. Conversation ",
                     "history may be compacted at ",
                     "safe completed tool-result boundaries while your R workspace ",
                     "remains intact.\n\n",
                     "The total budget is exactly five times this game's summed human ",
                     "baseline and is enforced outside your R environment. Every committed ",
                     "action costs one, including RESET; only the bootstrap RESET that ",
                     "created the initial observation was free. You cannot raise the cap. ",
                     "Scoring makes actions the currency: uncompleted levels score zero, ",
                     "so reason in R before acting, choose discriminating probes, and then ",
                     "execute the leanest supported solution.\n\n",
                     "The rules are unknown by design. Keep durable hypotheses and solved ",
                     "paths in R and reuse them across levels. GAME_OVER may result from a ",
                     "hazard, timer, or per-attempt step limit. If state becomes GAME_OVER, ",
                     "RESET costs one action and begins a fresh attempt with your conversation ",
                     "and analysis intact.\n\n",
                     "You are fully autonomous: there is no user watching and no one to ",
                     "ask. Never request permission, confirmation, or preferences, and ",
                     "never end with a question. Do not stop merely because a hypothesis ",
                     "failed, no progress occurred, or a tool call was rejected. Correct ",
                     "the plan or call and proceed until WIN or enforced budget exhaustion.")

# Runs in the callr subprocess: full lifecycle for one game.
play_one <- function(slug, model, provider, max_turns, arc_dir,
                     run_dir = arc_dir, arc_system, compaction_prompt,
                     action_budget = NA_integer_, baseline_total = NA_real_,
                     resume = NULL, campaign_path = NULL) {
    if (file.exists("~/.Renviron")) {
        readRenviron("~/.Renviron")
    }
    corteza::ensure_skills()
    source(file.path(arc_dir, "client.R"), local = FALSE)
    source(file.path(arc_dir, "depth.R"), local = FALSE)
    source(file.path(arc_dir, "version.R"), local = FALSE)
    source(file.path(arc_dir, "protocol.R"), local = FALSE)
    d <- arc_depth(provider)
    max_turns <- suppressWarnings(as.integer(max_turns))
    compact_pct <- suppressWarnings(as.numeric(
        Sys.getenv("ARC_CONTEXT_COMPACT_PCT", "75")
    ))
    compact_bytes <- suppressWarnings(as.numeric(
        Sys.getenv("ARC_CONTEXT_COMPACT_BYTES", "900000")
    ))
    request_buffer_retry_limit <- suppressWarnings(as.integer(
        Sys.getenv("ARC_REQUEST_BUFFER_RETRIES", "3")
    ))
    compact_timeout <- suppressWarnings(as.integer(
        Sys.getenv("ARC_COMPACT_TIMEOUT", "120")
    ))
    if (is.na(max_turns) || max_turns < 1L ||
        is.na(compact_pct) || compact_pct <= 0 || compact_pct >= 100 ||
        is.na(compact_bytes) || compact_bytes <= 0 ||
        is.na(request_buffer_retry_limit) || request_buffer_retry_limit < 0L ||
        is.na(compact_timeout) || compact_timeout < 1L) {
        stop("invalid ARC turn or compaction settings", call. = FALSE)
    }
    if (length(action_budget) != 1L || is.na(action_budget) ||
        action_budget < 1L) {
        stop("refusing to open an ARC game without a positive 5x baseline budget",
             call. = FALSE)
    }
    run_dir <- path.expand(run_dir)
    campaign <- if (is.null(campaign_path) || !nzchar(campaign_path)) {
        NULL
    } else {
        if (!file.exists(campaign_path)) {
            stop("campaign manifest is missing: ", campaign_path)
        }
        x <- tryCatch(jsonlite::fromJSON(campaign_path, simplifyVector = FALSE),
                      error = function(e) NULL)
        if (is.null(x) || !identical(x$state, "open") ||
            !nzchar(x$card_id %||% "") || !nzchar(x$cookiejar %||% "")) {
            stop("campaign manifest is not an open scorecard: ", campaign_path)
        }
        prompt_sha <- substr(digest::digest(arc_system, algo = "sha256"), 1, 12)
        same_config <- identical(as.integer(x$protocol_version %||% NA),
                                 ARC_PROTOCOL_VERSION) &&
        identical(x$model, model) &&
        identical(x$provider, provider) &&
        identical(x$prompt_sha, prompt_sha) &&
        identical(x$effort %||% "", d$effort) &&
        identical(as.integer(x$thinking), as.integer(d$think)) &&
        identical(as.integer(x$max_tokens), as.integer(d$max_tokens))
        if (!same_config) {
            stop("campaign model, prompt, or reasoning depth does not match this game")
        }
        x$cookiejar <- arc_campaign_cookiejar(x$cookiejar, campaign_path)
        if (!file.exists(x$cookiejar)) {
            stop("campaign cookie jar is missing: ", x$cookiejar)
        }
        x
    }
    cl <- NULL
    now_utc <- function() format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

    # Everything a game leaves on disk, keyed by card id in normal mode
    # and card id + slug in campaign mode. The trace and
    # inflight entry, transcript, model's R workspace and latest frame
    # form the checkpoint that makes a game resumable after its process dies.
    paths <- function(card_id) {
        run_id <- if (is.null(campaign)) card_id else {
            paste(card_id, slug, sep = "--")
        }
        list(
             run_id = run_id,
             trace = file.path(run_dir, "traces", paste0(run_id, ".jsonl")),
             inflight = file.path(run_dir, "inflight", paste0(run_id, ".json")),
             transcript = file.path(run_dir, "transcripts",
                                    paste0(run_id, ".json")),
             transcript_segments = file.path(run_dir, "transcripts",
                                             paste0(run_id, ".segments")),
             pending = file.path(run_dir, "state", run_id, "pending-action.json"),
             reconcile = file.path(run_dir, "state", run_id, "reconcile.jsonl"),
             context = file.path(run_dir, "state", run_id,
                                 "context-metrics.json"),
             workspace = file.path(run_dir, "state", run_id, "workspace.RData"),
             latest = file.path(run_dir, "state", run_id, "latest-frame.json"),
             manual = file.path(run_dir, "manuals", paste0(run_id, ".md")),
             # the private session cookies this game instance is bound to;
             # campaign workers seed from, but never write, the campaign jar.
             cookies = file.path(run_dir, "state", run_id, "cookies.txt"))
    }
    write_inflight <- function(p, card_id, game_id, guid, started, resumes) {
        arc_atomic_json(
            list(card_id = card_id, run_id = p$run_id, game_id = game_id,
                 slug = slug, model = model, pid = Sys.getpid(),
                 guid = guid %||% NA_character_,
                 replay = if (!is.null(guid)) {
                     paste0("https://arcprize.org/replay/", guid)
                 } else {
                     NA
                 },
                 started = started, resumes = resumes, updated = now_utc()),
            p$inflight)
    }

    if (is.null(resume)) {
        if (is.null(campaign)) {
            cl <- arc_client()
            game_id <- arc_resolve_game(arc_games(cl), slug)$game_id
            sc <- arc_scorecard_open(
                cl, tags = list("corteza", "rlm", "cold", model),
                opaque = list(harness = "corteza",
                    protocol_version = ARC_PROTOCOL_VERSION,
                    budget_multiplier = 5L,
                    arm = "rlm", model = model,
                    provider = provider,
                    max_turns = max_turns,
                    action_budget = action_budget))
            card_id <- sc$card_id
        } else {
            card_id <- campaign$card_id
            sc <- list(card_id = card_id)
        }
        p <- paths(card_id)
        if (!is.null(campaign)) {
            seed <- arc_campaign_current_cookiejar(campaign, campaign_path)
            arc_clone_cookiejar(seed, p$cookies)
            cl <- arc_client(cookies = p$cookies)
            game_id <- arc_resolve_game(arc_games(cl), slug)$game_id
        }
        for (subdir in c("traces", "transcripts", "inflight")) {
            dir.create(file.path(run_dir, subdir), showWarnings = FALSE)
        }
        dir.create(dirname(p$workspace), recursive = TRUE, showWarnings = FALSE)
        # Save the session cookies from here on: the RESET below creates
        # the game instance and the cookies it is bound to. Campaign clients
        # already point at their private clone; standalone clients begin here.
        if (is.null(campaign)) {
            cl$cookiejar <- p$cookies
        }
        # Per-action trace and latest frame, set before the first RESET
        # so the opening frame is recorded too.
        Sys.setenv(ARC_TRACE = p$trace, ARC_LATEST_FRAME = p$latest)
        # In-flight record, written the moment the card exists. A game
        # is otherwise invisible until it ends, and a killed run leaves
        # no trace at all.
        started <- now_utc()
        resumes <- 0L
        write_inflight(p, card_id, game_id, NULL, started, resumes)
        # Bootstrap observation: the only uncharged RESET in the run.
        fr0 <- arc_reset(
                         cl, game_id, card_id, trace_path = p$trace,
                         latest_path = p$latest, charged = FALSE, sequence = 0L,
                         attempt = 1L, trace_strict = TRUE)
        guid <- fr0$guid
        # The play guid is what arcprize.org/replay/{guid} keys on, and
        # the only way to reach a game's scorecard from outside its
        # session while the card is still open.
        write_inflight(p, card_id, game_id, guid, started, resumes)
        history <- NULL
        latest <- fr0
    } else {
        # Same card, same guid, no RESET (a RESET restarts the level):
        # the server-side game is exactly where the dead process left
        # it. Restore what the process held: its R workspace (the
        # model's variables and helpers, checkpointed every
        # ARC_CHECKPOINT_SECS), the conversation, and the latest frame.
        # A game with no checkpoint (one that ran before checkpoints
        # existed) resumes cold: same session, empty conversation, and
        # the trace's reasoning log as notes.
        card_id <- resume
        p <- paths(card_id)
        # The dead process's session cookies: the game instance answers
        # only to a handle that carries them.
        if (!file.exists(p$cookies)) {
            stop("cannot resume ", card_id, ": no saved session cookies at ",
                 p$cookies, " (the game is bound to them)")
        }
        cl <- arc_client(cookies = p$cookies)
        inf <- jsonlite::fromJSON(p$inflight)
        game_id <- inf$game_id
        guid <- inf$guid
        started <- inf$started
        resumes <- as.integer(inf$resumes %||% 0L) + 1L
        # Is the game instance itself still there? The scorecard route is
        # insufficient: it can remain readable after the play recording has
        # expired. Recovery needs the recording, so probe that exact
        # authoritative resource and require at least one observation. This is
        # read-only and spends no action.
        alive <- tryCatch({
            rec <- arc_recording(cl, game_id, guid)
            frames <- arc_recording_frames(rec, guid)
            if (!length(frames)) {
                stop("recording contains no observations", call. = FALSE)
            }
            TRUE
        }, error = function(e) {
            bootstrap <- arc_local_bootstrap_frame(
                p$trace, p$latest, p$pending, guid)
            if (is.null(bootstrap)) conditionMessage(e) else TRUE
        })
        if (!isTRUE(alive)) {
            dir.create(file.path(run_dir, "done"), showWarnings = FALSE)
            file.rename(p$inflight, file.path(run_dir, "done", basename(p$inflight)))
            stop("cannot resume ", card_id,
                 ": authoritative game recording is gone (", alive, ")")
        }
        if (!identical(inf$slug, slug)) {
            warning("resuming card ", card_id, " recorded for slug ", inf$slug,
                    " under slug ", slug)
        }
        sc <- list(card_id = card_id)
        dir.create(dirname(p$workspace), recursive = TRUE, showWarnings = FALSE)
        Sys.setenv(ARC_TRACE = p$trace, ARC_LATEST_FRAME = p$latest)
        latest <- if (file.exists(p$latest)) {
            tryCatch(jsonlite::fromJSON(p$latest, simplifyVector = FALSE),
                     error = function(e) NULL)
        }
        if (is.null(latest)) {
            # The recording is authoritative and read-only. It restores the
            # board without spending an action.
            latest <- tryCatch({
                rec <- arc_recording_frames(arc_recording(cl, game_id, guid),
                    guid)
                if (length(rec)) rec[[length(rec)]]
            }, error = function(e) NULL)
        }
        if (is.null(latest)) {
            stop("cannot resume ", card_id,
                 ": no local frame and no authoritative observation")
        }
        latest$guid <- guid
        fr0 <- latest
        history <- if (file.exists(p$transcript)) {
            tryCatch(jsonlite::fromJSON(p$transcript, simplifyVector = FALSE),
                     error = function(e) NULL)
        }
        if (!length(history)) {
            history <- NULL
        }
        # A checkpoint can land between an assistant message and the
        # tool_result that answers its tool_use: the observer fires on
        # the tool event, the result is appended after. Anthropic
        # rejects a history whose tool_use has no tool_result in the
        # next message (a 400 that killed the first resume test), so
        # drop a trailing assistant message still waiting on one. The
        # workspace holds whatever that tool did; the resume message
        # tells the model to check what it holds against the board.
        # Two dialects. Anthropic: an assistant message whose content
        # has tool_use blocks, answered by tool_result blocks in the
        # next user message. Codex (OpenAI Responses via llm.api): a
        # ".openai_codex_output" item holding the response's output
        # items, whose function_call items are answered by separate
        # function_call_output items keyed by call_id ("No tool output
        # found for function call ..." is that wire's 400).
        has_tool_use <- function(m) {
            identical(m$role, "assistant") && is.list(m$content) &&
            any(vapply(m$content, function(b) identical(b$type, "tool_use"),
                       logical(1)))
        }
        answered <- function(h) {
            unlist(lapply(h, function(m) {
                if (identical(m$type, "function_call_output")) m$call_id
            }))
        }
        unanswered_calls <- function(m, h) {
            if (!identical(m$type, ".openai_codex_output")) {
                return(FALSE)
            }
            ids <- unlist(lapply(m$output, function(o) {
                if (identical(o$type, "function_call")) o$call_id
            }))
            length(ids) && !all(ids %in% answered(h))
        }
        while (length(history)) {
            last <- history[[length(history)]]
            if (has_tool_use(last) || unanswered_calls(last, history)) {
                history <- history[-length(history)]
            } else {
                break
            }
        }
        if (!length(history)) {
            history <- NULL
        }
        write_inflight(p, card_id, game_id, guid, started, resumes)
    }
    inflight <- p$inflight
    retire_inflight <- function() {
        if (!file.exists(inflight)) {
            return(invisible(FALSE))
        }
        done <- file.path(run_dir, "done", basename(inflight))
        dir.create(dirname(done), showWarnings = FALSE)
        if (!isTRUE(file.rename(inflight, done))) {
            unlink(inflight)
        }
        invisible(TRUE)
    }

    # The controller owns the live client and fixed budget outside the
    # model-authored R environment. On every process resume, reconcile the
    # local journal against the authoritative server recording before the
    # model sees or submits another action.
    last_arc_activity <- arc_last_action_time(p$trace)
    controller <- arc_new_controller(
                                     cl, game_id, card_id, guid, latest, as.integer(action_budget),
                                     p$trace, p$latest, p$pending, p$reconcile)
    if (!is.null(resume)) {
        recovery <- controller$reconcile()
        latest <- recovery$frame
        fr0 <- latest
    }

    analysis_state <- arc_analysis_new(
        if (!is.null(resume)) p$workspace else NULL)
    analysis_env <- analysis_state$env
    restored <- analysis_state$restored
    arc_analysis_update(
                        analysis_env, latest, controller$used(), controller$budget(),
                        controller$attempt())

    # The transport client already holds the ARC key. Do not leave the key in
    # the environment visible to model-authored analysis code.
    Sys.unsetenv(c("ARC_PRIZE", "ARC_API_KEY", "ARC_ACTION_BUDGET"))

    # Generated R programs need output headroom. Use one binding for the
    # session and run record so the recorded cap is the cap sent.
    # Reasoning depth and the output cap that goes with it, resolved by
    # depth.R so sweep.sh's corpus key reads the same function this
    # does. The two provider families take different knobs (corteza
    # 0.7.1.41), so exactly one is ever in play and the other stays
    # NULL: corteza drops the wrong one anyway, but keeping them NULL
    # here means the run record says which knob actually applied.
    mt <- d$max_tokens
    effort <- d$effort
    think <- d$think
    cache_ttl <- Sys.getenv("ARC_CACHE", "5m")
    # The benchmark protocol does not ask for commentary between tool calls;
    # an injected narration nudge changes the prompt and wastes decision
    # context. Non-finite disables Corteza's generic silent-tool nudge.
    options(corteza.narration_streak = Inf)

    s <- corteza::new_session(
                              channel = "console",
                              provider = provider,
                              model_map = list(cloud = model),
                              tools_filter = c("run_r", "game_action"),
                              web_search = FALSE,
                              max_turns = max_turns,
                              approval_cb = function(call, decision) TRUE,
                              system = arc_system,
                              max_tokens = mt,
                              reasoning_effort = if (nzchar(effort)) effort,
                              thinking_budget_tokens = if (think > 0L) think,
                              # Billing-only: byte-identical input either
                              # way, so it cannot move a score and does
                              # not belong in prompt_sha. Needs llm.api
                              # >= 0.1.9.6 to cover the history. The record
                              # carries the read/write token classes, so
                              # the saving is measured, not assumed.
                              cache = if (nzchar(cache_ttl)) cache_ttl,
                              compaction_prompt = compaction_prompt)

    # Use corteza's canonical safe-cut compactor. ARC supplies only the
    # lifecycle boundary and benchmark-fixed thresholds; it does not carry a
    # second summarizer or history-rewrite implementation.
    compact_cfg <- corteza:::load_config(arc_dir)
    compact_cfg$context_compact_pct <- compact_pct
    compact_cfg$context_compact_bytes <- compact_bytes
    compact_cfg$context_request_buffer_retries <- request_buffer_retry_limit
    compact_cfg$subagents$context_compaction$mode <- "inherit_strict"
    compact_cfg$subagents$context_compaction$compact_pct <- compact_pct
    compact_cfg$subagents$context_compaction$keep_recent_turns <- 1L
    compact_cfg$subagents$context_compaction$keep_recent_tokens <- 20000L
    compact_cfg$subagents$context_compaction$min_messages <- 6L
    compact_cfg$subagents$context_compaction$timeout_seconds <- compact_timeout
    compact_cfg$run_r_mode <- "worker"
    compact_cfg$skill_timeout <- 600
    compact_cfg$skill_timeout_max <- 600
    s$config <- compact_cfg
    s$cwd <- arc_dir
    s$run_r_timeout_cap <- function() arc_run_r_cap(last_arc_activity)
    on.exit(corteza:::.run_r_worker_close(s), add = TRUE)
    s$context_window <- corteza::context_limit_for_model(
        model, provider = provider)

    # Per-turn progress log: one line per tool call, flushed as it
    # happens, so `tail -f` shows a live game instead of 30 silent
    # minutes. callr buffers the child's stdout until exit, and the
    # session is verbose = FALSE, so this file is the only in-run
    # signal. Errors inside an observer are swallowed by corteza, so
    # a logging failure can never take down a game.
    progress <- file.path(run_dir, "progress", paste0(p$run_id, ".log"))
    dir.create(dirname(progress), showWarnings = FALSE)
    if (!is.null(history)) {
        s$history <- history
    }

    # Checkpoint the conversation and only the isolated analysis
    # environment. The ARC client, credentials, controller, budget, and pending
    # journal cannot enter this workspace. Game actions force a checkpoint;
    # analysis-only calls retain the configurable throttle.
    last_ckpt <- Sys.time() - 3600
    checkpoint <- function(force = FALSE) {
        every <- as.numeric(Sys.getenv("ARC_CHECKPOINT_SECS", "20"))
        if (!force &&
            as.numeric(difftime(Sys.time(), last_ckpt, units = "secs")) < every) {
            return(invisible(FALSE))
        }
        tryCatch({
            tmp <- paste0(p$transcript, ".tmp")
            writeLines(jsonlite::toJSON(s$history %||% list(),
                                        auto_unbox = TRUE, null = "null"), tmp)
            if (!isTRUE(file.rename(tmp, p$transcript))) {
                unlink(tmp)
                stop("could not atomically replace ARC transcript")
            }
            arc_analysis_checkpoint(s, analysis_env, p$workspace)
            last_ckpt <<- Sys.time()
        }, error = function(e) {
            cat(sprintf("%s checkpoint failed: %s\n",
                        format(Sys.time(), "%H:%M:%S"), conditionMessage(e)),
                file = progress, append = TRUE)
        })
        invisible(TRUE)
    }

    tools <- arc_game_tools()
    add_usage <- function(a, b) {
        a <- a %||% list()
        b <- b %||% list()
        for (k in union(names(a), names(b))) {
            x <- a[[k]]
            y <- b[[k]]
            a[[k]] <- if (is.list(x) || is.list(y)) {
                add_usage(x %||% list(), y %||% list())
            } else if (is.numeric(x) || is.numeric(y)) {
                values <- c(as.numeric(x %||% 0), as.numeric(y %||% 0))
                if (anyNA(values)) NA_real_ else sum(values)
            } else {
                y %||% x
            }
        }
        a
    }
    prior_context <- if (file.exists(p$context)) {
        tryCatch(jsonlite::fromJSON(p$context, simplifyVector = FALSE),
                 error = function(e) list())
    } else {
        list()
    }
    prior_segments <- if (dir.exists(p$transcript_segments)) {
        length(list.files(p$transcript_segments,
                          pattern = "^segment-[0-9]+[.]json$"))
    } else {
        0L
    }
    compaction_count <- max(
        as.integer(prior_context$compactions %||% 0L), prior_segments)
    context_peak_tokens <- as.integer(prior_context$peak_tokens %||% 0L)
    context_last_tokens <- as.integer(prior_context$last_tokens %||% 0L)
    context_peak_request_bytes <- as.numeric(
        prior_context$peak_request_bytes %||% 0)
    context_last_request_bytes <- as.numeric(
        prior_context$last_request_bytes %||% 0)
    compaction_usage <- prior_context$summary_usage %||% list()

    context_tokens <- function(history = s$history %||% list()) {
        corteza::estimate_live_context_tokens(
            list(history = history),
            system_prompt = s$system,
            tools = tools
        )
    }
    live_context_tokens <- function() context_tokens()
    context_request_bytes <- function(history = s$history %||% list()) {
        corteza:::.estimate_live_request_bytes(
            list(history = history), system_prompt = s$system, tools = tools)
    }
    live_context_request_bytes <- function() context_request_bytes()
    persist_context_metrics <- function() {
        arc_atomic_json(
            list(
                protocol_version = ARC_PROTOCOL_VERSION,
                compactions = compaction_count,
                peak_tokens = context_peak_tokens,
                last_tokens = context_last_tokens,
                peak_request_bytes = context_peak_request_bytes,
                last_request_bytes = context_last_request_bytes,
                compact_bytes = compact_bytes,
                request_buffer_retry_limit = request_buffer_retry_limit,
                compact_pct = compact_pct,
                context_limit = s$context_window,
                summary_usage = compaction_usage,
                last_failure = s$last_compaction_failure %||% NULL,
                updated = now_utc()
            ),
            p$context
        )
    }
    s$on_compaction_failure <- function(event) {
        persist_context_metrics()
        cat(sprintf(
            paste0("%s context compaction failed at %d tokens (%.1f%%), ",
                   "request %.0f/%.0f bytes: %s\n"),
            format(Sys.time(), "%H:%M:%S"),
            as.integer(event$tokens_before %||% 0L),
            as.numeric(event$context_pct %||% 0),
            as.numeric(event$request_bytes %||% NA_real_),
            as.numeric(event$byte_limit %||% compact_bytes),
            substr(gsub("\\s+", " ", event$error %||% "unknown error"),
                   1L, 240L)),
            file = progress, append = TRUE)
        invisible(TRUE)
    }

    s$on_compaction <- function(event) {
        next_count <- compaction_count + 1L
        dir.create(p$transcript_segments, recursive = TRUE,
                   showWarnings = FALSE)
        segment <- file.path(
            p$transcript_segments,
            sprintf("segment-%04d.json", next_count)
        )
        # The hook runs before destructive history replacement. Both the exact
        # provider-native prefix and the replacement history must be durable;
        # any write error propagates and prevents corteza from discarding the
        # live prefix.
        arc_atomic_json(event$history_before, segment)
        arc_atomic_json(event$history_after, p$transcript)
        arc_analysis_checkpoint(s, analysis_env, p$workspace)

        compaction_count <<- next_count
        compaction_usage <<- add_usage(compaction_usage, event$usage)
        context_peak_tokens <<- max(context_peak_tokens,
                                    as.integer(event$tokens_before %||% 0L))
        context_last_tokens <<- context_tokens(event$history_after)
        context_peak_request_bytes <<- max(
            context_peak_request_bytes,
            as.numeric(event$request_bytes %||% 0), na.rm = TRUE)
        context_last_request_bytes <<- context_request_bytes(
            event$history_after)
        persist_context_metrics()
        cat(sprintf(
            paste0("%s context %s/%s: %d tokens (%.1f%%), ",
                   "request %.0f/%.0f bytes, live=%d tokens/%.0f bytes, ",
                   "count=%d\n"),
            format(Sys.time(), "%H:%M:%S"), event$reason %||% "threshold",
            event$trigger %||% "tokens", event$tokens_before,
            event$context_pct, event$request_bytes %||% NA_real_,
            event$byte_limit %||% compact_bytes, context_last_tokens,
            context_last_request_bytes, compaction_count
        ), file = progress, append = TRUE)
        invisible(TRUE)
    }
    turn_epoch <- 0L
    tool_executor <- function(name, args, context = NULL) {
        if (identical(name, "run_r")) {
            return(arc_run_r(s, args, analysis_env, p$workspace,
                             last_arc_activity))
        }
        if (!identical(name, "game_action")) {
            return(corteza:::err(paste("unknown ARC tool:", name)))
        }
        tx <- controller$act(args, context)
        last_arc_activity <<- Sys.time()
        latest <<- tx$frame
        arc_analysis_update(analysis_env, tx$frame, tx$used, tx$budget,
                            tx$attempt)
        # The action and frame are already durable in the controller journal.
        # Persist analysis immediately too; the transcript callback lands the
        # tool result immediately after this executor returns.
        checkpoint(force = TRUE)
        corteza:::ok(tx$text)
    }

    corteza::add_observer(s, function(event) {
        detail <- if (!is.null(event$call$args$code)) {
            event$call$args$code
        } else {
            jsonlite::toJSON(event$call$args %||% list(), auto_unbox = TRUE)
        }
        cat(sprintf("%s turn=%s %s [%s] %s\n",
                    format(Sys.time(), "%H:%M:%S"),
                    event$turn_number %||% NA,
                    event$call$tool %||% "?",
                    event$outcome %||% "?",
                    substr(gsub("\\s+", " ", detail), 1, 160)),
            file = progress, append = TRUE)
        if (!is.null(event$execution)) {
            cat(sprintf("%s run_r execution=%s timeout=%ss state_retained=%s\n",
                        format(Sys.time(), "%H:%M:%S"),
                        event$execution$status,
                        event$execution$timeout_seconds,
                        event$execution$state_retained),
                file = progress, append = TRUE)
        }
        if (identical(event$outcome, "ran") || !is.null(event$execution)) {
            checkpoint(force = !is.null(event$execution))
        }
    })

    # A dropped model connection does not end the game. Conversation is
    # mirrored after each tool result, the analysis workspace is checkpointed,
    # and every game action has its own durable intent/result boundary. Before
    # retrying a transient provider failure, query the authoritative ARC
    # recording and reconcile it with the local journal. This avoids both the
    # old "nothing changed" assumption and a duplicate action after an
    # interrupted response. Non-transient provider errors still surface.
    play_turn <- function(
        prompt, session,
        net_retries = as.integer(Sys.getenv("ARC_NET_RETRIES", "5")),
        limit_retries = as.integer(Sys.getenv("ARC_LIMIT_RETRIES", "10"))
    ) {
        if (is.na(net_retries) || net_retries < 0L ||
            is.na(limit_retries) || limit_retries < 0L) {
            stop("ARC retry counts must be non-negative integers")
        }
        net_attempts <- 0L
        limit_attempts <- 0L
        repeat {
            turn_epoch <<- turn_epoch + 1L
            controller$set_epoch(turn_epoch)
            r <- tryCatch(
                          corteza::turn(prompt, session, tool_executor = tool_executor,
                                        tools = tools),
                          arc_game_gone = function(e) {
                              retire_inflight()
                              stop(conditionMessage(e), call. = FALSE)
                          },
                          error = function(e) e)
            if (!inherits(r, "error")) {
                return(r)
            }
            limited <- isTRUE(corteza:::.is_limit_error(r))
            if (!arc_retryable_model_error(r)) {
                stop(r)
            }
            if (limited) {
                limit_attempts <- limit_attempts + 1L
                retry <- limit_attempts
                retry_limit <- limit_retries
                kind <- "provider limit"
            } else {
                net_attempts <- net_attempts + 1L
                retry <- net_attempts
                retry_limit <- net_retries
                kind <- "transport error"
            }
            if (retry > retry_limit) {
                stop(r)
            }

            # A provider disconnect may occur after one or more tool results.
            # Query the authoritative ARC session before retrying so the next
            # model request starts from reconciled state rather than assuming
            # that the game did not change.
            recovery <- tryCatch(controller$reconcile(), error = function(e) e)
            reconcile_note <- if (inherits(recovery, "error")) {
                paste("Authoritative reconciliation also failed:",
                      conditionMessage(recovery))
            } else {
                latest <<- recovery$frame
                arc_analysis_update(
                                    analysis_env, latest, recovery$used,
                                    controller$budget(), recovery$attempt)
                paste0(
                       "The authoritative ARC session was queried and reconciled.\n",
                       arc_format_observation(
                        latest, recovery$used, controller$budget(),
                        event = "MODEL_RECONNECT",
                        reconciled = TRUE, attempt = recovery$attempt))
            }
            checkpoint(force = TRUE)
            delay <- arc_model_retry_delay(
                r, session$provider %||% provider,
                limit_seconds = as.integer(
                    Sys.getenv("ARC_LIMIT_RETRY_SECS", "1800")))
            cat(sprintf("%s %s, retry %d/%d in %ds: %s\n",
                        format(Sys.time(), "%H:%M:%S"), kind, retry,
                        retry_limit, delay,
                        substr(gsub("\\s+", " ", conditionMessage(r)), 1, 160)),
                file = progress, append = TRUE)
            Sys.sleep(delay)
            prompt <- sprintf(paste0(
                                     "The connection to the model dropped mid-turn (%s). ",
                                     "%s\nContinue from this reconciled observation."),
                              substr(gsub("\\s+", " ", conditionMessage(r)), 1, 120),
                              reconcile_note)
        }
    }

    t0 <- Sys.time()
    opening_observation <- arc_format_observation(
        latest, controller$used(), controller$budget(),
        event = if (is.null(resume)) {
            "INITIAL"
        } else {
            "PROCESS_RESUME"
        }, reconciled = !is.null(resume), attempt = controller$attempt())
    opening <- if (is.null(resume)) {
        paste0(
               "Play game ", game_id,
               ". This is a cold start: no prior-run manual or knowledge was ",
               "loaded. The bootstrap RESET was free; all future actions, ",
               "including RESET, cost one.\n\n", opening_observation,
               "\n\nDiscover the mechanics and win within the fixed budget.")
    } else {
        # The authoritative recording has already been queried and reconciled.
        # A resume with no usable transcript receives only its own action
        # reasons as fallback notes; no other run's knowledge is introduced.
        notes <- ""
        if (is.null(history) && file.exists(p$trace)) {
            rows <- utils::tail(arc_trace_records(p$trace), 40)
            rs <- vapply(rows, function(x) {
                if (is.null(x$reasoning)) return("")
                sprintf("- [L%s] %s: %s", x$levels_completed,
                        arc_action_label(x$action), x$reasoning)
            }, "")
            rs <- rs[nzchar(rs)]
            if (length(rs)) {
                notes <- paste0("\n\nYour last actions and their reasoning:",
                                "\n", paste(rs, collapse = "\n"))
            }
        }
        paste0(
               "This process restarted mid-game (resume ", resumes, ", guid ",
               guid, "). Before accepting another action, the harness queried ",
               "the authoritative ARC session and reconciled its local journal. ",
               "No RESET was issued by recovery. ",
            if (length(restored)) {
                sprintf(
                        "Your isolated R workspace restored %d objects: %s.",
                        length(restored),
                        paste(utils::head(restored, 40), collapse = ", "))
            } else {
                "No analysis workspace was recoverable; rebuild from fr."
            },
            if (!is.null(history)) {
                " Your conversation was restored through its last complete tool result."
            } else {
                notes
            },
               "\n\n", opening_observation,
               "\n\nContinue until WIN or enforced budget exhaustion.")
    }
    out <- play_turn(opening, s)
    checkpoint(force = TRUE)

    # A prose reply is only a pause while the game is unfinished. The
    # controller, not the model, decides termination: WIN, the immutable action
    # budget, the wall clock, the LLM turn cap, or ARC_STALL_NUDGES consecutive
    # nudges with no committed action. Conversation and analysis state remain
    # continuous across nudges and levels.
    trace_state <- function() {
        rows <- arc_trace_records(p$trace)
        if (!length(rows)) {
            return(NULL)
        }
        rows[[length(rows)]]
    }
    nudges <- 0L
    stall <- 0L
    stalled <- FALSE
    max_stall <- as.integer(Sys.getenv("ARC_STALL_NUDGES", "5"))
    usage_sum <- out$usage %||% list()
    turns_sum <- out$raw$turns %||% 0L
    overflow_retries <- as.integer(isTRUE(out$raw$corteza_overflow_retry))
    request_buffer_retries <- as.integer(
        out$raw$corteza_request_buffer_retries %||% 0L)
    repeat {
        st <- trace_state()
        # A response cut off at the output cap is not an ending either:
        # llm.api drops the partial message and runs none of its tool
        # calls, so the history is consistent and the game untouched.
        # The overall game turn cap alone
        # terminates model work; shared runtime compaction does not end a turn.
        truncated <- isTRUE(out$raw$truncated)
        overall_turn_cap <- turns_sum >= max_turns
        if (overall_turn_cap || is.null(st) || identical(st$state, "WIN") ||
            controller$used() >= controller$budget()) {
            break
        }
        if (stall >= max_stall) {
            stalled <- TRUE
            break
        }
        nudges <- nudges + 1L
        before <- controller$used()
        s$max_turns <- max_turns - turns_sum
        cat(sprintf("%s nudge %d: state=%s levels=%s/%s actions=%d/%d\n",
                    format(Sys.time(), "%H:%M:%S"), nudges,
                    st$state, st$levels_completed, st$win_levels,
                    before, controller$budget()),
            file = progress, append = TRUE)
        out <- play_turn(if (truncated) sprintf(paste0(
                    "Your previous response ran past the output limit and was cut ",
                    "off; nothing in it ran and the game did not change (state %s, ",
                    "%s of %s levels completed). Work in smaller steps: shorter ",
                    "code per call, fewer printed frames, one probe at a time. ",
                    "Keep playing until state is WIN."),
                st$state, st$levels_completed, st$win_levels)
            else sprintf(paste0(
                                "The game is not over: state %s, %s of %s levels completed, ",
                                "%d of %d actions remain. A prose reply is a pause, not ",
                                "termination. Inspect fr and keep playing. If the level is ",
                                "stuck or state is GAME_OVER, game_action(action=0, reasoning=...) ",
                                "resets it at a cost of one action while preserving your ",
                                "conversation and R analysis."),
                         st$state, st$levels_completed, st$win_levels,
                         controller$budget() - controller$used(), controller$budget()),
                         out$session)
        checkpoint(force = TRUE)
        usage_sum <- add_usage(usage_sum, out$usage %||% list())
        turns_sum <- turns_sum + (out$raw$turns %||% 0L)
        overflow_retries <- overflow_retries +
            as.integer(isTRUE(out$raw$corteza_overflow_retry))
        request_buffer_retries <- request_buffer_retries + as.integer(
            out$raw$corteza_request_buffer_retries %||% 0L)
        if (controller$used() > before) {
            stall <- 0L
        } else {
            stall <- stall + 1L
        }
    }
    # Manual creation is deliberately outside gameplay. No distillation,
    # summarization, or manual injection occurs at level boundaries or during
    # the cold run. Once the run has terminated, make one no-tools call over
    # the completed conversation and save its answer as an optional artifact
    # for a separately designated warm run.
    final_state <- trace_state()
    termination_reason <- if (identical(final_state$state, "WIN")) {
        "WIN"
    } else if (controller$used() >= controller$budget()) {
        "ACTION_BUDGET"
    } else if (stalled) {
        "STALL_GUARD"
    } else if (turns_sum >= max_turns) {
        "LLM_TURN_CAP"
    } else {
        "HARNESS_END"
    }
    manual_reply <- NA_character_
    manual_error <- NA_character_
    manual_usage <- list()
    manual_session <- corteza::new_session(
        channel = "console", history = s$history,
        provider = provider, model_map = list(cloud = model),
        tools_filter = character(), web_search = FALSE,
        max_turns = 1L,
        approval_cb = function(call, decision) FALSE,
        system = paste(
                       "You distill a completed ARC-AGI-3 run into a factual manual.",
                       "Gameplay is over. You have no tools and cannot act.",
                       "Use only evidence in the supplied run conversation."),
        max_tokens = 4000L,
        reasoning_effort = if (nzchar(effort)) "low",
        cache = if (nzchar(cache_ttl)) cache_ttl)
    manual_out <- tryCatch(
                           corteza::turn(
            paste0(
                   "Gameplay has now terminated with reason ", termination_reason,
                   ". No game tools are available and you must not attempt more ",
                   "actions. Distill a concise game manual from this run only. ",
                   "Separate verified mechanics, action meanings, solved-level ",
                   "procedures, failure/reset lessons, and unresolved hypotheses. ",
                   "Do not claim guesses as facts. This artifact will be used only ",
                   "if a future run is explicitly designated warm."),
            manual_session, tool_executor = function(name, args, context = NULL) {
        corteza:::err("gameplay has terminated")
    },
            tools = list()),
                           error = function(e) e)
    if (inherits(manual_out, "error")) {
        manual_error <- conditionMessage(manual_out)
    } else {
        manual_reply <- manual_out$reply %||% ""
        manual_usage <- manual_out$usage %||% list()
        tryCatch({
            dir.create(dirname(p$manual), recursive = TRUE,
                       showWarnings = FALSE)
            tmp <- paste0(p$manual, ".tmp")
            writeLines(c(
                         paste0("# ARC-AGI-3 game manual: ", slug),
                         "",
                         paste0("- run: ", p$run_id),
                         paste0("- model: ", model),
                         paste0("- termination: ", termination_reason),
                         paste0("- generated: ", now_utc()),
                         "- provenance: distilled after game termination; never injected into this cold run",
                         "",
                         manual_reply), tmp)
            if (!isTRUE(file.rename(tmp, p$manual))) {
                unlink(tmp)
                stop("could not atomically replace manual")
            }
        }, error = function(e) {
            manual_error <<- conditionMessage(e)
        })
    }
    checkpoint(force = TRUE)

    # Preserve scorecard-fetch errors separately from game outcomes.
    # Session-affinity failures must not erase local evidence of play.
    official_error <- NA_character_
    official <- tryCatch(arc_scorecard(cl, sc$card_id, game_id),
                         error = function(e) {
        official_error <<- conditionMessage(e)
        NULL
    })
    closed <- if (is.null(campaign)) {
        tryCatch(arc_scorecard_close(cl, sc$card_id), error = function(e) NULL)
    } else {
        NULL
    }

    # Second opinion from the website's route, readable only once the
    # card is closed. Store the official totals alongside local observations
    # and flag discrepancies. Best-effort: NA on any failure.
    v3 <- if (is.null(campaign)) {
        tryCatch(arc_scorecard_v3(cl, sc$card_id), error = function(e) NULL)
    } else {
        NULL
    }
    v3_runs <- unlist(lapply(v3$environments %||% list(),
                             function(e) e$runs %||% list()),
                      recursive = FALSE)
    v3_best <- if (length(v3_runs)) {
        v3_runs[[which.max(vapply(v3_runs, function(r) r$actions %||% 0, 1))]]
    }
    api_actions <- as.integer(v3_best$actions %||% official$total_actions %||% NA)
    api_levels <- as.integer(v3_best$levels_completed %||%
                             official$levels_completed %||% NA)
    api_score <- as.numeric(v3_best$score %||% official$score %||% NA)
    api_guid <- v3_best$guid %||% guid %||% NA_character_

    # The local trace is the fallback account of the run: client.R logs
    # levels_completed off every frame the server returned, so the
    # result survives a scorecard we could not fetch. Not a substitute
    # for the official record -- it is our own count, and it is marked
    # as such -- but a finished game with a local count is worth more
    # than a replay.
    trace_levels <- NA_integer_
    trace_actions <- NA_integer_
    trace_events <- NA_integer_
    tryCatch({
        rows <- arc_trace_records(p$trace)
        if (length(rows)) {
            lv <- vapply(rows, function(x) {
                if (is.null(x$levels_completed)) NA_integer_ else
                as.integer(x$levels_completed)
            }, integer(1))
            # Charged actions match ARC scoring: the bootstrap observation is
            # excluded; every later RESET and ACTION1..7 is included.
            trace_actions <- arc_actions_used(p$trace)
            trace_events <- length(rows)
            if (any(!is.na(lv))) {
                trace_levels <- max(lv, na.rm = TRUE)
            }
        }
    }, error = function(e) invisible(NULL))

    # Full conversation to disk, keyed by card id so it joins the
    # official record. Without this the run's only survivors are a
    # 2000-char summary and the server-side action replay.
    transcript <- p$transcript
    dir.create(dirname(transcript), showWarnings = FALSE)
    tryCatch(writeLines(jsonlite::toJSON(out$session$history %||% list(),
                auto_unbox = TRUE,
                null = "null"), transcript),
             error = function(e) transcript <<- NA_character_)

    # The shared estimator understands provider-native Codex output and opaque
    # reasoning payloads. Record both the largest pre-compaction context and
    # the exact live context left at termination.
    ctx_request_bytes <- tryCatch(live_context_request_bytes(),
                                  error = function(e) NA_real_)
    if (!is.na(ctx_request_bytes)) {
        context_last_request_bytes <- ctx_request_bytes
        context_peak_request_bytes <- max(context_peak_request_bytes,
                                          ctx_request_bytes)
    }
    ctx_tokens <- tryCatch(live_context_tokens(),
                           error = function(e) NA_integer_)
    if (!is.na(ctx_tokens)) {
        context_last_tokens <- ctx_tokens
        context_peak_tokens <- max(context_peak_tokens, ctx_tokens)
    }
    persist_context_metrics()

    # Moved, not deleted. A dead process cannot write its own
    # tombstone, so "still in inflight/" is what marks a run that died
    # without writing a record -- but encoding that bit by destroying
    # the file throws away the start time and pid for every run that
    # succeeds. Retiring it to done/ keeps both and preserves the
    # signal: inflight/ = died, done/ = finished.
    retire_inflight()

    u <- add_usage(usage_sum, compaction_usage)
    list(game_id = game_id, card_id = sc$card_id, run_id = p$run_id,
         campaign = campaign$label %||% NA_character_,
         nudges = nudges,
         stalled = stalled,
         resumed = !is.null(resume),
         resumes = resumes,
         protocol_version = ARC_PROTOCOL_VERSION,
         termination_reason = termination_reason,
         run_r_mode = "worker",
         run_r_timeout_max = 600,
         run_r_idle_reserve = 120,
         action_budget = controller$budget(),
         baseline_total = baseline_total,
         budget_exhausted = controller$used() >= controller$budget(),
         # The play guid, not the card id, is what arcprize.org/replay/
         # keys on, allowing a replay to be matched back to its record.
         guid = guid %||% NA_character_,
         progress = progress,
         reconcile_log = p$reconcile,
         reply = out$reply %||% "",
         llm_turns_capped = turns_sum >= max_turns,
         turns = turns_sum,
         overflow_retries = overflow_retries,
         request_buffer_retries = request_buffer_retries,
         truncated = isTRUE(out$raw$truncated),
         truncation_reason = out$raw$truncation_reason %||% NA,
         max_tokens = mt,
         effort = if (nzchar(effort)) effort else NA_character_,
         thinking = think,
         cache = if (nzchar(cache_ttl)) cache_ttl else NA_character_,
         official_error = official_error,
         trace_levels = trace_levels,
         trace_actions = trace_actions,
         trace_events = trace_events,
         api_actions = api_actions,
         api_levels = api_levels,
         api_score = api_score,
         api_guid = api_guid,
         # TRUE when ARC's count of the run differs from what the client
         # saw; NA when either side is unknown.
         api_divergence = if (is.na(api_actions) || is.na(trace_actions)) NA
        else api_actions != trace_actions,
         corteza_version = as.character(utils::packageVersion("corteza")),
         llm_api_version = as.character(utils::packageVersion("llm.api")),
         transcript = transcript,
         transcript_segments = p$transcript_segments,
         ctx_tokens = ctx_tokens,
         context_peak_tokens = context_peak_tokens,
         context_window = s$context_window,
         context_compact_pct = compact_pct,
         context_compact_bytes = compact_bytes,
         context_request_bytes = ctx_request_bytes,
         context_peak_request_bytes = context_peak_request_bytes,
         request_buffer_retry_limit = request_buffer_retry_limit,
         compaction_prompt_sha = substr(digest::digest(
             compaction_prompt, algo = "sha256"), 1, 12),
         compactions = compaction_count,
         compaction_input_tokens =
         compaction_usage$input_tokens %||% NA_real_,
         compaction_output_tokens =
         compaction_usage$output_tokens %||% NA_real_,
         compaction_cost = compaction_usage$cost %||% NA_real_,
         elapsed = as.numeric(difftime(Sys.time(), t0, units = "secs")),
         input_tokens = u$input_tokens %||% NA_real_,
         output_tokens = u$output_tokens %||% NA_real_,
         # Cache accounting, cumulative over the game. Anthropic bills
         # these at different rates (reads 0.1x input, 5m writes 1.25x,
         # 1h writes 2x), so a dollar figure needs all three, not just
         # input_tokens. Per-request granularity would need an llm.api
         # hook; the game total is what prices the game.
         cache_read_tokens = u$cache_read_input_tokens %||% NA_real_,
         cache_write_5m_tokens =
         u$cache_creation$ephemeral_5m_input_tokens %||% NA_real_,
         cache_write_1h_tokens =
         u$cache_creation$ephemeral_1h_input_tokens %||% NA_real_,
         cost = u$cost %||% NA_real_,
         manual = if (file.exists(p$manual)) p$manual else NA_character_,
         manual_error = manual_error,
         manual_input_tokens = manual_usage$input_tokens %||% NA_real_,
         manual_output_tokens = manual_usage$output_tokens %||% NA_real_,
         manual_cost = manual_usage$cost %||% NA_real_,
         official = official,
         final_score = closed$score %||% official$score %||% NA)
}

main <- function() {
    if (exists("argv")) {
        args <- argv
    } else {
        args <- commandArgs(trailingOnly = TRUE)
    }
    if (length(args) < 4L) {
        stop("usage: driver.R <model> <provider> <max_turns> <n_games> [slug ...]")
    }
    model <- args[[1]]
    provider <- args[[2]]
    max_turns <- as.integer(args[[3]])
    n_games <- as.integer(args[[4]])
    arc_dir <- path.expand(Sys.getenv("ARC_DIR", getwd()))
    source(file.path(arc_dir, "version.R"), local = FALSE)
    run_dir <- path.expand(Sys.getenv("ARC_RUN_DIR", arc_dir))
    campaign_path <- Sys.getenv("ARC_CAMPAIGN", "")
    if (nzchar(campaign_path)) {
        campaign_path <- path.expand(campaign_path)
    } else {
        campaign_path <- NULL
    }
    slugs <- if (length(args) > 4L) {
        args[5:length(args)]
    } else {
        as.character(seq_len(n_games))
    }

    log_path <- file.path(run_dir, "runs.jsonl")

    # Prompt provenance: ARC_SYSTEM can change between runs. Persist its text
    # once per unique hash; records carry the hash.
    prompt_sha <- substr(digest::digest(ARC_SYSTEM, algo = "sha256"), 1, 12)
    prompt_file <- file.path(run_dir, "prompts", paste0(prompt_sha, ".txt"))
    dir.create(dirname(prompt_file), showWarnings = FALSE)
    if (!file.exists(prompt_file)) {
        writeLines(ARC_SYSTEM, prompt_file)
    }

    # Budget and wall clock per game, from the catalog. /api/games
    # publishes baseline_actions per level, so both are known before
    # the first action. The clock is sized to the budget -- budget /
    # ARC_ACTIONS_PER_HOUR hours, never below ARC_GAME_TIMEOUT.
    # Baselines are per game and stable; game ids are session-scoped,
    # so the child resolves its own game_id and only the numbers cross.
    if (file.exists("~/.Renviron")) {
        readRenviron("~/.Renviron")
    }
    source(file.path(arc_dir, "client.R"), local = FALSE)
    catalog <- tryCatch(arc_games(arc_client()), error = function(e) list())
    if (!length(catalog)) {
        stop("could not load the ARC catalog; refusing to run without baselines",
             call. = FALSE)
    }
    floor_s <- as.numeric(Sys.getenv("ARC_GAME_TIMEOUT", "3600"))
    rate <- as.numeric(Sys.getenv("ARC_ACTIONS_PER_HOUR", "300"))
    # ARC_RESUME=<card id>: continue that card's game instead of opening
    # a new one (see the resume branch of play_one). The sweep sets it
    # when a game's process died with its inflight entry still present.
    resume <- Sys.getenv("ARC_RESUME", "")
    if (nzchar(resume)) {
        resume <- resume
    } else {
        resume <- NULL
    }

    for (slug in slugs) {
        cat("== ", slug, "\n")
        g <- tryCatch(arc_resolve_game(catalog, slug), error = function(e) NULL)
        if (is.null(g)) {
            stop("could not resolve ARC game ", slug, call. = FALSE)
        }
        b <- arc_game_budget(g, mult = 5)
        if (is.na(b$action_budget)) {
            stop("ARC game ", slug, " has no valid human baseline; refusing to run",
                 call. = FALSE)
        }
        game_timeout <- if (is.na(b$action_budget)) {
            floor_s
        } else {
            max(floor_s, ceiling(b$action_budget / rate * 3600))
        }
        cat(sprintf("   human baseline %s, budget %s actions, wall clock %.1f h\n",
                    b$baseline_total, b$action_budget, game_timeout / 3600))
        res <- tryCatch(
                        callr::r(play_one,
                                 args = list(slug = slug, model = model,
                    provider = provider, max_turns = max_turns,
                    arc_dir = arc_dir, run_dir = run_dir,
                    arc_system = ARC_SYSTEM,
                    compaction_prompt = ARC_COMPACTION_PROMPT,
                    action_budget = b$action_budget,
                    baseline_total = b$baseline_total,
                    resume = resume,
                    campaign_path = campaign_path),
                                 timeout = game_timeout,
                                 package = FALSE, spinner = FALSE),
                        error = function(e) list(reply = paste("DRIVER ERROR:",
                    conditionMessage(e))))
        rec <- list(ts = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
                    slug = slug, model = model, provider = provider,
                    max_turns = max_turns,
                    game_timeout = game_timeout,
                    prompt_sha = prompt_sha,
                    game_id = res$game_id %||% NA,
                    card_id = res$card_id %||% NA,
                    run_id = res$run_id %||% res$card_id %||% NA,
                    campaign = res$campaign %||% NA,
                    guid = res$guid %||% NA,
                    replay = if (is.null(res$guid)) NA else
                    paste0("https://arcprize.org/replay/", res$guid),
                    ctx_tokens = res$ctx_tokens %||% NA,
                    context_peak_tokens = res$context_peak_tokens %||% NA,
                    context_window = res$context_window %||% NA,
                    context_compact_pct = res$context_compact_pct %||% NA,
                    context_compact_bytes = res$context_compact_bytes %||% NA,
                    context_request_bytes = res$context_request_bytes %||% NA,
                    context_peak_request_bytes =
                    res$context_peak_request_bytes %||% NA,
                    request_buffer_retry_limit =
                    res$request_buffer_retry_limit %||% NA,
                    compactions = res$compactions %||% NA,
                    overflow_retries = res$overflow_retries %||% NA,
                    request_buffer_retries =
                    res$request_buffer_retries %||% NA,
                    capped = res$llm_turns_capped %||% NA,
                    turns = res$turns %||% NA,
                    nudges = res$nudges %||% NA,
                    stalled = res$stalled %||% NA,
                    resumed = res$resumed %||% NA,
                    resumes = res$resumes %||% NA,
                    protocol_version = res$protocol_version %||% NA,
                    termination_reason = res$termination_reason %||% NA,
                    run_r_mode = res$run_r_mode %||% NA,
                    run_r_timeout_max = res$run_r_timeout_max %||% NA,
                    run_r_idle_reserve = res$run_r_idle_reserve %||% NA,
                    action_budget = res$action_budget %||% NA,
                    baseline_total = res$baseline_total %||% NA,
                    budget_exhausted = res$budget_exhausted %||% NA,
                    truncated = res$truncated %||% NA,
                    truncation_reason = res$truncation_reason %||% NA,
                    max_tokens = res$max_tokens %||% NA,
                    # Which reasoning knob was actually in play. Read by
                    # sweep.sh's is_done(), so raising effort makes every
                    # game un-done rather than leaving the corpus a
                    # mixture of depths that all look alike in the record.
                    effort = res$effort %||% NA,
                    thinking = res$thinking %||% NA,
                    cache = res$cache %||% NA,
                    official_error = res$official_error %||% NA,
                    trace_levels = res$trace_levels %||% NA,
                    api_actions = res$api_actions %||% NA,
                    api_levels = res$api_levels %||% NA,
                    api_score = res$api_score %||% NA,
                    api_guid = res$api_guid %||% NA,
                    api_divergence = res$api_divergence %||% NA,
                    trace_actions = res$trace_actions %||% NA,
                    trace_events = res$trace_events %||% NA,
                    corteza_version = res$corteza_version %||% NA,
                    llm_api_version = res$llm_api_version %||% NA,
                    transcript = res$transcript %||% NA,
                    transcript_segments = res$transcript_segments %||% NA,
                    reconcile_log = res$reconcile_log %||% NA,
                    progress = res$progress %||% NA,
                    elapsed = res$elapsed %||% NA,
                    input_tokens = res$input_tokens %||% NA,
                    output_tokens = res$output_tokens %||% NA,
                    cache_read_tokens = res$cache_read_tokens %||% NA,
                    cache_write_5m_tokens = res$cache_write_5m_tokens %||% NA,
                    cache_write_1h_tokens = res$cache_write_1h_tokens %||% NA,
                    cost = res$cost %||% NA,
                    compaction_input_tokens =
                    res$compaction_input_tokens %||% NA,
                    compaction_output_tokens =
                    res$compaction_output_tokens %||% NA,
                    compaction_cost = res$compaction_cost %||% NA,
                    manual = res$manual %||% NA,
                    manual_error = res$manual_error %||% NA,
                    manual_input_tokens = res$manual_input_tokens %||% NA,
                    manual_output_tokens = res$manual_output_tokens %||% NA,
                    manual_cost = res$manual_cost %||% NA,
                    summary = substr(res$reply %||% "", 1, 2000),
                    official = res$official,
                    final_score = res$final_score %||% NA)
        line <- jsonlite::toJSON(rec, auto_unbox = TRUE, null = "null")

        # Per-game record file is the authoritative copy: one writer,
        # no contention, survives anything that mangles the stream.
        rec_dir <- file.path(run_dir, "records")
        dir.create(rec_dir, showWarnings = FALSE)
        rec_path <- file.path(rec_dir,
                              paste0(res$run_id %||% res$card_id %||% slug, ".json"))
        rec_tmp <- paste0(rec_path, ".", Sys.getpid(), ".tmp")
        writeLines(line, rec_tmp)
        if (!isTRUE(file.rename(rec_tmp, rec_path))) {
            unlink(rec_tmp)
            stop("could not atomically write ARC game record: ", rec_path,
                 call. = FALSE)
        }

        # The shared stream stays for convenience, but a record is far
        # bigger than the 4KB an append is atomic up to, so parallel
        # games would interleave mid-line and corrupt it. Serialize
        # appends behind a directory lock (atomic create everywhere);
        # a stale lock is broken after 60s so a killed game can't
        # wedge the sweep.
        lock <- paste0(log_path, ".lock")
        deadline <- Sys.time() + 30
        locked <- FALSE
        repeat {
            if (dir.create(lock, showWarnings = FALSE)) {
                locked <- TRUE
                break
            }
            age <- tryCatch(as.numeric(difftime(Sys.time(),
                        file.info(lock)$mtime,
                        units = "secs")),
                            error = function(e) 0)
            if (!is.na(age) && age > 60) {
                unlink(lock, recursive = TRUE)
                next
            }
            if (Sys.time() > deadline) {
                break # record file already has it; don't stall
            }
            Sys.sleep(0.05)
        }
        if (locked) {
            cat(line, "\n", file = log_path, append = TRUE, sep = "")
            unlink(lock, recursive = TRUE)
        }
        o <- res$official
        cat("   -> won:", o$won %||% "?", "| levels:",
            o$levels_completed %||% "?", "| actions:",
            o$total_actions %||% "?", "| score:",
            res$final_score %||% "?", "\n")
    }
}

`%||%` <- function(a, b) if (is.null(a)) b else a

main()
