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
#
# Two tag formats exist upstream. Releases up to
# nightly-2026-August-05-24f0b47 spell the month out in English
# ("nightly-2026-July-14-c9147c2"); from nightly-2026-08-06-61bbb59 onwards the
# month is a two-digit number ("nightly-2026-08-07-8d23662"). Both are accepted
# so that older tags can still be backfilled by hand.
tag_regex='^nightly-([0-9]{4})-([A-Za-z]+|[0-9]{2})-([0-9]{2})-([0-9a-f]{7,40})$'

if [[ $# -eq 1 ]]; then
  requested_tag=$1
  # Validate before the tag ever reaches a URL; curl collapses `..` path
  # segments, so an unchecked argument could redirect the query elsewhere.
  [[ "$requested_tag" =~ $tag_regex ]] || {
    echo "error: invalid release tag: $requested_tag" >&2
    exit 1
  }
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
if [[ ! "$tag" =~ $tag_regex ]]; then
  echo "error: unexpected release tag: $tag" >&2
  exit 1
fi

year=${BASH_REMATCH[1]}
month=${BASH_REMATCH[2]}
day=${BASH_REMATCH[3]}
short_commit=${BASH_REMATCH[4]}
# Asset names always use the numeric date, so a spelled-out month has to be
# converted. LC_ALL=C so the English month name from the tag parses regardless
# of the locale configured on the machine running this script. Both branches go
# through `date`, which rejects an impossible date such as 2026-13-40.
if [[ "$month" =~ ^[0-9]{2}$ ]]; then
  release_date=$(LC_ALL=C date --date="$year-$month-$day" +%Y-%m-%d)
else
  release_date=$(LC_ALL=C date --date="$month $day $year" +%Y-%m-%d)
fi

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
# What `roc version` prints changed upstream. roc-lang/nightlies commit afe85e78
# ("use new version string", 2026-07-31T18:15:11Z) started passing
# `-Dcompiler-version=<tag>` to `zig build build-release`, so from then on the
# binary reports the release tag. Before it, the version was derived from the
# build profile and the commit: `release-fast-<first 8 of sha>`.
#
# Verified against the two releases either side of that commit:
#   nightly-2026-July-31-f5556d8  -> release-fast-f5556d8c
#   nightly-2026-August-01-1c1cecc -> nightly-2026-August-01-1c1cecc
#
# The cutoff is kept so that backfilling an older tag by hand
# (`./update.sh nightly-2026-July-14-c9147c2`) still records the version that
# release actually reports. Both timestamps are ISO-8601 UTC, so a string
# comparison orders them correctly.
version_scheme_cutoff="2026-07-31T18:15:11Z"
if [[ "$published_at" > "$version_scheme_cutoff" ]]; then
  compiler_version="$tag"
else
  compiler_version="release-fast-${compiler_commit:0:8}"
fi

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

# Retention. Every recorded nightly is kept by default, which is what
# oxalica/rust-overlay does: they carry every nightly since 2025 and prune
# nothing, because old nightlies are what you need to bisect a compiler
# regression. At roughly 1.6 KB per release, a year of dailies is ~600 KB and
# three years ~1.8 MB, so there is no size pressure to act on yet.
#
# If evaluation ever does get slow, deleting history is the wrong first move.
# The real inefficiency is that default.nix does
# `builtins.fromJSON (builtins.readFile ./sources.json)`, which parses every
# release on every evaluation even when only `nightly` is referenced.
# rust-overlay avoids that by giving each release its own file behind a lazy
# `import`, so evaluation costs only what you actually reference. Splitting
# sources.json that way preserves history; pruning does not.
#
# Pruning is therefore opt-in. Set ROC_OVERLAY_KEEP_RECENT=<n> to keep only the
# newest n releases, plus the newest release of every calendar month, plus
# whatever .latest points at. Note that dropping an entry does not break a
# consumer who pinned it: their flake.lock pins a commit of *this* overlay, and
# that commit still records the release. Only
# `nix shell 'github:roc-lang/roc-overlay#<pruned-tag>'` against the default
# branch stops resolving.
keep_recent=${ROC_OVERLAY_KEEP_RECENT:-0}

if jq -e --arg tag "$tag" '.releases | has($tag)' sources.json >/dev/null; then
  already_recorded=1
else
  already_recorded=0
fi

# Add the release if it is new and move .latest forward if this release is newer
# than the current one. Prune only when retention is switched on.
jq -S \
  --arg tag "$tag" \
  --argjson keepRecent "$keep_recent" \
  --slurpfile entry "$entry_json" \
  '
    (
      .releases[$tag] //= $entry[0]
      | if $entry[0].publishedAt > .releases[.latest].publishedAt
        then .latest = $tag
        else .
        end
    )
    | if $keepRecent <= 0 then . else
        . as $root
        | (.releases | to_entries | sort_by(.value.publishedAt)) as $sorted
        | (
            # newest $keepRecent by publish time
            ($sorted | .[(if length > $keepRecent then length - $keepRecent else 0 end):])
            # plus the newest release within each YYYY-MM bucket
            + ($sorted | group_by(.value.publishedAt[0:7]) | map(max_by(.value.publishedAt)))
            | map(.key)
          ) as $keep
        | .releases |= with_entries(
            . as $e
            | select($e.key == $root.latest or ($keep | index($e.key)) != null)
          )
      end
  ' \
  sources.json >"$tmpdir/sources.json"

# Nothing to do when the release was already recorded and nothing was pruned.
if cmp -s "$tmpdir/sources.json" sources.json; then
  echo "$tag is already recorded; no changes."
  exit 0
fi

pruned=$(jq -r --slurpfile new "$tmpdir/sources.json" '
  (.releases | keys) - ($new[0].releases | keys) | join(", ")
' sources.json)

mv "$tmpdir/sources.json" sources.json

nix fmt
nix flake check

if [[ "$already_recorded" -eq 1 ]]; then
  echo "$tag was already recorded; applied retention policy only."
else
  echo "Recorded $tag."
fi
[[ -z "$pruned" ]] || echo "Pruned by ROC_OVERLAY_KEEP_RECENT=$keep_recent: $pruned"
