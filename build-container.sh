#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
IMAGE="${ARC_IMAGE:-corteza-arcagi3:v5}"

BUILD_ROOT="$(mktemp -d /tmp/corteza-arc-build.XXXXXX)"
BUILD_CONTEXT="$BUILD_ROOT/context"
cleanup() {
  rm -rf -- "$BUILD_ROOT"
}
trap cleanup EXIT INT TERM HUP

mkdir -p "$BUILD_CONTEXT/src" "$BUILD_CONTEXT/arcagi3" "$BUILD_ROOT/fetch"
stage_repo() {
  local source="$1"
  local target="$2"
  shift 2
  mkdir -p "$target"
  git -C "$source" archive --format=tar HEAD -- "$@" | tar -C "$target" -xf -
}

# Only committed, explicitly listed harness files enter the runtime image.
git -C "$SCRIPT_DIR" show HEAD:runtime-files.txt > "$BUILD_ROOT/runtime-files.txt"
mapfile -t runtime_files < "$BUILD_ROOT/runtime-files.txt"
stage_repo "$SCRIPT_DIR" "$BUILD_CONTEXT/arcagi3" "${runtime_files[@]}"
LOCKFILE="$BUILD_CONTEXT/arcagi3/sources.lock"
while read -r package kind url revision; do
  case "$package" in ''|\#*) continue ;; esac
  case "$kind" in
    git)
      source_dir="$BUILD_ROOT/fetch/$package"
      git init --quiet "$source_dir"
      git -C "$source_dir" fetch --quiet --depth=1 "$url" "$revision"
      git -C "$source_dir" checkout --quiet --detach FETCH_HEAD
      test "$(git -C "$source_dir" rev-parse HEAD)" = "$revision"
      stage_repo "$source_dir" "$BUILD_CONTEXT/src/$package"
      ;;
    archive)
      archive="$BUILD_CONTEXT/src/$package.tar.gz"
      curl --fail --location --silent --show-error --retry 3 "$url" -o "$archive"
      printf '%s  %s\n' "$revision" "$archive" | sha256sum --check --status
      ;;
    *) echo "Unknown source kind: $kind" >&2; exit 1 ;;
  esac
done < "$LOCKFILE"
cp "$BUILD_CONTEXT/arcagi3/Dockerfile" "$BUILD_CONTEXT/Dockerfile"

tree_hash() {
  # Relative paths keep this hash independent of the temporary directory.
  ( cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | \
    xargs -0 sha256sum | sha256sum | awk '{print $1}' )
}

{
  printf 'built_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'base_image=%s\n' 'rocker/r2u:noble@sha256:061613c564c752437e54db7544afebad8be79a2a7f64f20730a47e07d729819e'
  while read -r package kind url revision; do
    case "$package" in ''|\#*) continue ;; esac
    printf '%s_source=%s\n' "$package" "$url"
    if [ "$kind" = archive ]; then
      printf '%s_sha256=%s\n' "$package" "$revision"
      continue
    fi
    staged_dir="$BUILD_CONTEXT/src/$package"
    version="$(sed -n 's/^Version: //p' "$staged_dir/DESCRIPTION")"
    printf '%s_version=%s\n' "$package" "$version"
    printf '%s_commit=%s\n' "$package" "$revision"
    printf '%s_tree_sha256=%s\n' "$package" \
      "$(tree_hash "$BUILD_CONTEXT/src/$package")"
  done < "$LOCKFILE"
  printf 'arc_protocol=5\n'
  printf 'arc_source=%s\n' 'git-archive'
  printf 'arc_commit=%s\n' "$(git -C "$SCRIPT_DIR" rev-parse HEAD)"
  printf 'arc_tree_sha256=%s\n' "$(tree_hash "$BUILD_CONTEXT/arcagi3")"
} > "$BUILD_CONTEXT/SOURCE-MANIFEST.txt"

docker build --pull=false --tag "$IMAGE" \
  --file "$BUILD_CONTEXT/Dockerfile" "$BUILD_CONTEXT"
docker image inspect "$IMAGE" \
  --format 'ARC image ready: {{.RepoTags}} {{.Id}} created={{.Created}}'
