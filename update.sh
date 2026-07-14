#!/usr/bin/env bash
# shellcheck shell=bash

# -e fail on error
# -u treat unset variables as error
# -o pipefail make a pipeline fail if any command within it fails
set -euo pipefail

# Change into the directory this script is running in.
cd "$(dirname "$0")"

# Use the flake's pinned development tools instead of the legacy NIX_PATH.
if [[ "${ROC_NIGHTLY_DEV_SHELL:-}" != 1 ]]; then
  exec nix develop --command env ROC_NIGHTLY_DEV_SHELL=1 "$0" "$@"
fi

# Helper to show usage message on bad CLI use.
usage() {
  echo "usage: ./update.sh [release-tag]" >&2
  exit 2
}

# Show usage() if more than 1 arg is passed.
[[ $# -le 1 ]] || usage

# Make temp dir
tmpdir=$(mktemp -d)
# "do rm -rf on the tmpdir" if the shell exits,
# gets interrupted e.g. ctrl-c,
# or if it terminates upon request from another program.
trap 'rm -rf "$tmpdir"' EXIT INT TERM

api_headers=(
  -H "Accept: application/vnd.github+json"
  -H "X-GitHub-Api-Version: 2022-11-28"
)
# Optional: set GITHUB_TOKEN for higher rate limits.
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  api_headers+=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi

fetch_api() {
  # @ expands every array element as its own argument, so each header is
  # passed to curl separately.
  curl --fail --silent --show-error --location \
    --retry 3 --retry-delay 1 \
    "${api_headers[@]}" "$1"
}

# - if they passed in a cmd arg of the nightly tag (i.e.
#   in the case where they wanted a specific source added
#   that may have been skipped over or missed by cron or one
#   in the past before this existed), then use that release url
# - else just get the latest nightly release
if [[ $# -eq 1 ]]; then
  requested_tag=$1
  release_url="https://api.github.com/repos/roc-lang/nightlies/releases/tags/$requested_tag"
else
  requested_tag=""
  release_url="https://api.github.com/repos/roc-lang/nightlies/releases/latest"
fi

# call the fetch api with the release url and put the result in
# tmpdir/release.json.
release_json="$tmpdir/release.json"
fetch_api "$release_url" >"$release_json"

# extract the tag name from the release_json
tag=$(jq -er '.tag_name' "$release_json")
# Don't fail if no tag was requested or the requested tag
# matches the tag from the actual release.
[[ -z "$requested_tag" || "$tag" == "$requested_tag" ]] || {
  echo "error: API returned tag '$tag', expected '$requested_tag'" >&2
  exit 1
}

# Match the tag against expected regex or fail.
if [[ ! "$tag" =~ ^nightly-([0-9]{4})-([A-Za-z]+)-([0-9]{2})-([0-9a-f]{7,40})$ ]]; then
  echo "error: unexpected release tag: $tag" >&2
  exit 1
fi
# what is BASH_REMATCH?
year=${BASH_REMATCH[1]}
month=${BASH_REMATCH[2]}
day=${BASH_REMATCH[3]}
short_commit=${BASH_REMATCH[4]}
release_date=$(date --date="$month $day $year" +%Y-%m-%d)

# Refuse mutable releases since they're non-reproducible.
[[ $(jq -er '.immutable' "$release_json") == true ]] || {
  echo "error: release '$tag' is not immutable" >&2
  exit 1
}

published_at=$(jq -er '.published_at' "$release_json")
url_prefix="https://github.com/roc-lang/nightlies/releases/download/$tag/"
assets_jsonl="$tmpdir/assets.jsonl"
: >"$assets_jsonl"

# Find one asset with the constructed filename.
while IFS=$'\t' read -r system stem; do
  asset_name="${stem}-${release_date}-${short_commit}.tar.gz"
  asset=$(jq -ec --arg name "$asset_name" '
    [.assets[] | select(.name == $name)]
    | if length == 1 then .[0] else error("expected exactly one asset named " + $name) end
  ' "$release_json")

  # sha256 digest for integrity/repro.
  digest=$(jq -er '.digest' <<<"$asset")
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    echo "error: missing or invalid SHA-256 digest for $asset_name" >&2
    exit 1
  }

  # <<< "here-string", sends $asset to jq's stdin
  url=$(jq -er '.browser_download_url' <<<"$asset")
  [[ "$url" == "${url_prefix}${asset_name}" ]] || {
    echo "error: unexpected download URL for $asset_name: $url" >&2
    exit 1
  }

  # SRI: subresource integrity - base64 encoded digest
  # Here we convert the hex github digest to the nix
  # base64 one.
  sha256=$(nix hash convert --hash-algo sha256 --to sri "$digest")
  jq -cn \
    --arg system "$system" \
    --arg asset "$asset_name" \
    --arg url "$url" \
    --arg sha256 "$sha256" \
    '{system: $system, value: {asset: $asset, url: $url, sha256: $sha256}}' \
    >>"$assets_jsonl"
done <<EOF
x86_64-linux	roc_nightly-linux_x86_64
aarch64-linux	roc_nightly-linux_arm64
x86_64-darwin	roc_nightly-macos_x86_64
aarch64-darwin	roc_nightly-macos_apple_silicon
EOF

# Query roc repo to:
# 1. Confirm that the commit exists.
# 2. Resolve it to the full commit SHA.
# 3. Confirm that the full SHA starts with the tag’s prefix.
# 4. Store an unambiguous compiler commit in sources.json.
# 5. Derive the expected compiler version.
#
# This provides stronger provenance than storing only a seven-character prefix.
commit_json="$tmpdir/commit.json"
fetch_api "https://api.github.com/repos/roc-lang/roc/commits/$short_commit" >"$commit_json"
compiler_commit=$(jq -er '.sha' "$commit_json")
[[ "$compiler_commit" == "$short_commit"* ]] || {
  echo "error: tag commit '$short_commit' resolved to '$compiler_commit'" >&2
  exit 1
}
compiler_version="release-fast-${compiler_commit:0:8}"

# Construct mapping for which OS and arch each archive supports.
systems_json="$tmpdir/systems.json"
jq -s 'map({(.system): .value}) | add' "$assets_jsonl" >"$systems_json"
entry_json="$tmpdir/entry.json"
jq -n \
  --arg tag "$tag" \
  --arg compilerCommit "$compiler_commit" \
  --arg compilerVersion "$compiler_version" \
  --arg publishedAt "$published_at" \
  --slurpfile systems "$systems_json" \
  '{
    tag: $tag,
    compilerCommit: $compilerCommit,
    compilerVersion: $compilerVersion,
    publishedAt: $publishedAt,
    systems: $systems[0]
  }' >"$entry_json"

if jq -e --arg tag "$tag" '.releases | has($tag)' sources.json >/dev/null; then
  echo "$tag is already recorded; no changes."
  exit 0
fi

jq -S \
  --arg tag "$tag" \
  --slurpfile entry "$entry_json" \
  '
    .releases[$tag] = $entry[0]
    | if $entry[0].publishedAt > .releases[.latest].publishedAt
      then .latest = $tag
      else .
      end
  ' \
  sources.json >"$tmpdir/sources.json"
mv "$tmpdir/sources.json" sources.json

nix fmt
nix flake check

echo "Recorded $tag."
