# Reasoning depth for a run: which knob this provider takes, and the
# output cap that keeps usable output at ARC_MAX_TOKENS once reasoning
# spend is accounted for.
#
# One implementation, two readers. driver.R's play_one() builds the
# session from it; sweep.sh calls it to compute the corpus key that
# is_done() compares against a record's `effort`/`thinking` fields. The
# sweep must never restate this logic: a drift between the two is
# silent in the direction that matters, accepting a default-effort
# record as a result for a high-effort sweep.
#
# Env inputs:
#   ARC_MAX_TOKENS       usable output budget (default 32000)
#   ARC_EFFORT           openai/codex reasoning effort (default "high")
#   ARC_THINKING         Anthropic thinking budget in tokens (default 0)
#   ARC_EFFORT_HEADROOM  cap headroom for undeclared reasoning spend
#
# Both wires spend reasoning tokens out of the SAME cap they spend the
# answer from -- Anthropic counts thinking against max_tokens, the
# Responses API counts reasoning against max_output_tokens -- so
# thinking harder under a fixed cap buys depth by taking it out of the
# reply. Add the reasoning budget to the cap to preserve usable output.

# Defined here, not borrowed: sweep.sh sources depth.R on its own to
# compute the corpus key, without client.R, so anything this file uses
# has to be in this file.
`%||%` <- function(a, b) if (is.null(a)) b else a

.arc_int_env <- function(name, default) {
    v <- suppressWarnings(as.integer(Sys.getenv(name, default)))
    if (is.na(v)) {
        stop(name, " did not parse as an integer: ",
             deparse(Sys.getenv(name)), call. = FALSE)
    }
    v
}

arc_depth <- function(provider) {
    base <- .arc_int_env("ARC_MAX_TOKENS", "32000")
    effort <- Sys.getenv("ARC_EFFORT", "high")
    # Anthropic's own floor. Below it llm.api refuses the request, so
    # treat a too-small budget as "thinking off" rather than an error.
    think <- .arc_int_env("ARC_THINKING", "0")
    if (think < 1024L) {
        think <- 0L
    }

    # Ask corteza which knobs this provider's wire carries instead of
    # restating its provider lists. Restating them here would let the
    # record claim an effort corteza had dropped.
    #
    # Effort comes back under whichever name the wire uses:
    # `reasoning_effort` on openai/codex, `output_config$effort` on
    # Anthropic (the API's own scale is low/medium/high/xhigh/max).
    # Reading only the first would record "no effort" for every
    # Anthropic run that had one.
    kept <- corteza:::.gate_reasoning_args(
        list(reasoning_effort = if (nzchar(effort)) effort,
             thinking_budget_tokens = if (think > 0L) think),
        provider)
    effort <- kept$reasoning_effort %||% kept$output_config$effort %||% ""
    think <- if (is.null(kept$thinking_budget_tokens)) {
        0L
    } else {
        kept$thinking_budget_tokens
    }

    cap <- base + if (think > 0L) {
        # llm.api rejects a budget at or above max_tokens, so the
        # headroom is the declared budget itself.
        think
    } else if (nzchar(effort)) {
        # Nothing declared on this wire: reasoning spend is the model's
        # business and invisible until the cap bites. This is the guess
        # at its ceiling; a record's `truncated` flag says whether it
        # held.
        .arc_int_env("ARC_EFFORT_HEADROOM", "16000")
    } else {
        0L
    }
    list(effort = effort, think = think, max_tokens = cap)
}
