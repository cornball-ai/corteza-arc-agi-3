# Deterministic ARC game ordering from the published human baselines.
#
# A restarted campaign puts only genuinely live checkpoints first so their
# server-side recordings do not expire. Both that subset and the remaining
# queue retain the same baseline order and alphabetical tie break.
arc_game_order <- function(baseline_dir, inprogress = character(),
                           longest_first = FALSE) {
    files <- list.files(baseline_dir, pattern = "[.]json$", full.names = TRUE)
    if (!length(files)) {
        stop("no ARC baseline files found in ", baseline_dir, call. = FALSE)
    }
    totals <- vapply(files, function(file) {
        baseline <- jsonlite::fromJSON(file)$baseline
        value <- sum(as.numeric(baseline))
        if (!length(baseline) || !is.finite(value)) {
            stop("invalid ARC baseline file: ", file, call. = FALSE)
        }
        value
    }, numeric(1))
    names(totals) <- sub("[.]json$", "", basename(files))
    if (anyDuplicated(names(totals))) {
        stop("duplicate ARC baseline slugs", call. = FALSE)
    }
    key <- if (isTRUE(longest_first)) -totals else totals
    ordered <- names(totals)[order(key, names(totals))]
    inprogress <- unique(as.character(inprogress))
    inprogress <- ordered[ordered %in% inprogress]
    c(inprogress, setdiff(ordered, inprogress))
}
