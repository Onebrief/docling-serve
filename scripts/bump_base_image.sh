#!/usr/bin/env bash
# Bump (or verify) the python-fips base image pins in the Dockerfile.
#
# The Dockerfile pins the Chainguard python-fips base by version *and* by
# multi-arch index digest (PYTHON_MAJOR/MINOR/PATCH + PYTHON_DEV_DIGEST /
# PYTHON_RUNTIME_DIGEST). The tags are mutable and BuildKit keys every layer
# on the resolved digest, so the digests must be refreshed together with the
# version or the layer cache (and reproducibility) is lost. This script does
# that in one step so a bump cannot leave the two out of sync.
#
# Usage:
#   scripts/bump_base_image.sh                 # refresh digests for the current version
#   scripts/bump_base_image.sh 3.13.17         # bump version and refresh digests
#   scripts/bump_base_image.sh --check         # exit 1 if the pinned digests are stale
#
# Needs either `docker buildx` or `skopeo` to read the registry (Nexus login
# as for a normal `docker pull`).
set -euo pipefail

REPO="nexus.int.onebrief.tools/cgr.dev/onebrief.com/python-fips"
DOCKERFILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Dockerfile"

check_only=0
version=""
for arg in "$@"; do
  case "$arg" in
    --check) check_only=1 ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) version="$arg" ;;
  esac
done

arg_value() { sed -nE "s/^ARG $1=(.*)$/\1/p" "$DOCKERFILE"; }
set_arg()   { sed -i.bak -E "s|^ARG $1=.*$|ARG $1=$2|" "$DOCKERFILE" && rm -f "$DOCKERFILE.bak"; }

cur_version="$(arg_value PYTHON_MAJOR).$(arg_value PYTHON_MINOR).$(arg_value PYTHON_PATCH)"
cur_dev_digest="$(arg_value PYTHON_DEV_DIGEST)"
cur_runtime_digest="$(arg_value PYTHON_RUNTIME_DIGEST)"
version="${version:-$cur_version}"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must look like 3.13.17, got '$version'" >&2; exit 2
fi

# Multi-arch index digest of a tag, as `docker buildx imagetools inspect`
# reports it on the "Digest:" line. Falls back to skopeo when no daemon/buildx.
index_digest() {
  local ref="$REPO:$1"
  if docker buildx version >/dev/null 2>&1; then
    docker buildx imagetools inspect "$ref" --format '{{.Manifest.Digest}}' 2>/dev/null && return
  fi
  if command -v skopeo >/dev/null 2>&1; then
    local raw
    raw="$(skopeo inspect --raw "docker://$ref")" || return 1
    printf 'sha256:%s\n' "$(printf '%s' "$raw" | shasum -a 256 | cut -d' ' -f1)"
    return
  fi
  echo "error: need docker buildx or skopeo to read $ref" >&2; return 1
}

# Both tags must exist for both architectures the Dockerfile builds.
platforms() {
  local ref="$REPO:$1"
  if docker buildx version >/dev/null 2>&1; then
    docker buildx imagetools inspect "$ref" --format '{{range .Manifest.Manifests}}{{if .Platform}}{{if ne .Platform.Architecture "unknown"}}{{.Platform.OS}}/{{.Platform.Architecture}} {{end}}{{end}}{{end}}' 2>/dev/null && return
  fi
  skopeo inspect --raw "docker://$ref" | python3 -c '
import json,sys
for m in json.load(sys.stdin).get("manifests", []):
    p = m.get("platform", {})
    if p.get("architecture") not in (None, "unknown"):
        print(f"{p.get(\"os\")}/{p[\"architecture\"]}", end=" ")'
}

echo "python-fips $version"
dev_digest="$(index_digest "$version-dev")"      || { echo "error: tag $version-dev not found in $REPO" >&2; exit 1; }
runtime_digest="$(index_digest "$version")"      || { echo "error: tag $version not found in $REPO" >&2; exit 1; }
for tag in "$version-dev" "$version"; do
  plats="$(platforms "$tag")"
  case "$plats" in
    *linux/amd64*linux/arm64*|*linux/arm64*linux/amd64*) ;;
    *) echo "error: $REPO:$tag is missing a platform we build (have: ${plats:-none})" >&2; exit 1 ;;
  esac
done
echo "  $version-dev  -> $dev_digest"
echo "  $version      -> $runtime_digest"

if [[ "$version" == "$cur_version" && "$dev_digest" == "$cur_dev_digest" && "$runtime_digest" == "$cur_runtime_digest" ]]; then
  echo "Dockerfile pins are up to date."
  exit 0
fi

if (( check_only )); then
  echo "Dockerfile pins are STALE:" >&2
  [[ "$version" != "$cur_version" ]]               && echo "  version        $cur_version -> $version" >&2
  [[ "$dev_digest" != "$cur_dev_digest" ]]         && echo "  dev digest     $cur_dev_digest -> $dev_digest" >&2
  [[ "$runtime_digest" != "$cur_runtime_digest" ]] && echo "  runtime digest $cur_runtime_digest -> $runtime_digest" >&2
  echo "Run scripts/bump_base_image.sh${version:+ $version} to refresh them." >&2
  exit 1
fi

IFS=. read -r major minor patch <<< "$version"
set_arg PYTHON_MAJOR "$major"
set_arg PYTHON_MINOR "$minor"
set_arg PYTHON_PATCH "$patch"
set_arg PYTHON_DEV_DIGEST "$dev_digest"
set_arg PYTHON_RUNTIME_DIGEST "$runtime_digest"
echo "Updated $DOCKERFILE:"
git -C "$(dirname "$DOCKERFILE")" --no-pager diff --stat -- Dockerfile 2>/dev/null || true
echo "Next: build + grype the image, then commit (python-fips $cur_version -> $version)."
