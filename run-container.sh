#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
OUTPUT_DIR="${ARC_OUTPUT_DIR:-$SCRIPT_DIR}"
mkdir -p "$OUTPUT_DIR/campaigns"
OUTPUT_DIR="$(CDPATH= cd -- "$OUTPUT_DIR" && pwd)"
IMAGE="${ARC_IMAGE:-corteza-arcagi3:v5}"
MODEL="${ARC_MODEL:-claude-opus-5}"
PROVIDER="${ARC_PROVIDER:-anthropic}"
SLOTS="${ARC_SLOTS:-5}"
EFFORT="${ARC_EFFORT:-max}"
THINKING="${ARC_THINKING:-0}"
CAMPAIGN_LABEL="${ARC_CAMPAIGN_LABEL:-cold-$MODEL}"
CAMPAIGN_DIR="$OUTPUT_DIR/campaigns/$CAMPAIGN_LABEL"
TOKEN_CACHE="${ARC_TOKEN_CACHE:-$HOME/.cache/R/tinyoauth}"
COMPACT_PCT="${ARC_CONTEXT_COMPACT_PCT:-75}"
COMPACT_BYTES="${ARC_CONTEXT_COMPACT_BYTES:-900000}"
REQUEST_BUFFER_RETRIES="${ARC_REQUEST_BUFFER_RETRIES:-3}"
NET_RETRIES="${ARC_NET_RETRIES:-5}"
LIMIT_RETRIES="${ARC_LIMIT_RETRIES:-10}"
LIMIT_RETRY_SECS="${ARC_LIMIT_RETRY_SECS:-300}"
GAME_ARGS=("$@")

case "$CAMPAIGN_LABEL" in
  *[!A-Za-z0-9._-]*|[!A-Za-z0-9]*)
    echo "Invalid ARC_CAMPAIGN_LABEL: $CAMPAIGN_LABEL" >&2
    exit 1
    ;;
esac

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "ARC container image is missing: $IMAGE" >&2
  echo "Run $SCRIPT_DIR/build-container.sh first." >&2
  exit 1
fi
if [ -e "$CAMPAIGN_DIR" ] && [ "${ARC_CONTAINER_RESUME:-0}" != 1 ]; then
  echo "Refusing to reuse $CAMPAIGN_DIR; choose a fresh ARC_CAMPAIGN_LABEL." >&2
  exit 1
fi
mkdir -p "$CAMPAIGN_DIR"
mkdir -p "$TOKEN_CACHE"

SECRET_DIR="$(mktemp -d /tmp/corteza-arc-secret.XXXXXX)"
cleanup() {
  rm -rf -- "$SECRET_DIR"
}
trap cleanup EXIT INT TERM HUP
SECRET_FILE="$SECRET_DIR/Renviron"
r -e 'readRenviron("~/.Renviron")
    arc <- Sys.getenv("ARC_PRIZE", Sys.getenv("ARC_API_KEY", ""))
    if (!nzchar(arc)) stop("ARC_PRIZE/ARC_API_KEY is not configured")
    values <- c(ARC_PRIZE = arc)
    anthropic <- Sys.getenv("ANTHROPIC_API_KEY", "")
    if (nzchar(anthropic)) values <- c(values, ANTHROPIC_API_KEY = anthropic)
    quote_value <- function(value) {
        value <- gsub("([\\\\\047])", "\\\\\\1", value)
        paste0("\047", value, "\047")
    }
    writeLines(paste0(names(values), "=", vapply(values, quote_value, "")), argv[[1]])' \
  "$SECRET_FILE"
chmod 0600 "$SECRET_FILE"

# Mount only this campaign. The model-authored R process must not share a
# filesystem view with prior campaigns, records, transcripts, or manuals.
status=0
docker run --rm --init \
  --env ARC_SLOTS="$SLOTS" \
  --name "corteza-arcagi3-v5" \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --tmpfs /tmp:rw,nosuid,nodev,size=4g \
  --user "$(id -u):$(id -g)" \
  --env HOME=/home/arc \
  --env ARC_DIR=/opt/arcagi3 \
  --env ARC_OUTPUT_DIR=/data \
  --env ARC_CAMPAIGN_LABEL="$CAMPAIGN_LABEL" \
  --env ARC_EFFORT="$EFFORT" \
  --env ARC_THINKING="$THINKING" \
  --env ARC_MAX_TOKENS=32000 \
  --env ARC_EFFORT_HEADROOM=16000 \
  --env ARC_CONTEXT_COMPACT_PCT="$COMPACT_PCT" \
  --env ARC_CONTEXT_COMPACT_BYTES="$COMPACT_BYTES" \
  --env ARC_REQUEST_BUFFER_RETRIES="$REQUEST_BUFFER_RETRIES" \
  --env ARC_NET_RETRIES="$NET_RETRIES" \
  --env ARC_LIMIT_RETRIES="$LIMIT_RETRIES" \
  --env ARC_LIMIT_RETRY_SECS="$LIMIT_RETRY_SECS" \
  --env ARC_COMPACT_TIMEOUT=120 \
  --env ARC_CACHE=5m \
  --env DONE_SHAS= \
  --env DONE_WON_ANY_MODEL=0 \
  --mount "type=bind,src=$CAMPAIGN_DIR,dst=/data/campaigns/$CAMPAIGN_LABEL" \
  --mount "type=bind,src=$TOKEN_CACHE,dst=/home/arc/.cache/R/tinyoauth" \
  --mount "type=bind,src=$SECRET_FILE,dst=/home/arc/.Renviron,readonly" \
  "$IMAGE" \
  bash /opt/arcagi3/sweep.sh "$MODEL" "$PROVIDER" "$SLOTS" 2 "${GAME_ARGS[@]}" || status=$?

exit "$status"
