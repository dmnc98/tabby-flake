#!/usr/bin/env bash
# Discover the newest Tabby release on GitHub and rewrite
# pkgs/tabby/sources.json to point at it.
#
# Exits 0 and prints "updated=false" when already current, so CI can branch on
# it without treating "nothing to do" as a failure.
#
#   ./scripts/update.sh                    # bump to the newest stable release
#   ./scripts/update.sh --version 1.0.237  # pin a specific version
#   ./scripts/update.sh --pre              # consider pre-releases too
#   ./scripts/update.sh --dry-run          # report only, touch nothing
set -euo pipefail

REPO="Eugeny/tabby"
API="https://api.github.com/repos/$REPO"
# Nix systems to pin, in the order they are written to sources.json. Keeping
# this an ordered list (not just the associative array) makes the generated
# JSON byte-stable, so the bot never commits a pure key-reordering diff.
SYSTEMS=(x86_64-linux aarch64-linux)
# Nix system -> the architecture slug Tabby uses in its .deb filenames. Upstream
# also ships armv7l, but no CI runner can build it, so it stays unpinned.
declare -A ARCHES=(
  [x86_64-linux]=x64
  [aarch64-linux]=arm64
)
# An update is only published when every system listed here has a .deb.
REQUIRED_SYSTEMS=(x86_64-linux)

# Resolve the repo root. Under `nix run .#update` the script itself lives in
# the store, so $0 is useless — prefer the git checkout we were invoked from.
if [ -n "${TABBY_FLAKE_ROOT:-}" ]; then
  repo_root=$TABBY_FLAKE_ROOT
elif repo_root=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$repo_root" ]; then
  :
else
  repo_root=$(CDPATH="" cd -- "$(dirname -- "$0")/.." && pwd)
fi

sources_file="$repo_root/pkgs/tabby/sources.json"
if [ ! -f "$sources_file" ]; then
  echo "update.sh: $sources_file not found." >&2
  echo "update.sh: run this from a tabby-flake checkout, or set TABBY_FLAKE_ROOT." >&2
  exit 1
fi

want_version=""
dry_run=false
allow_pre=false
while [ $# -gt 0 ]; do
  case "$1" in
    --version) want_version="${2:?--version needs an argument}"; shift 2 ;;
    --pre) allow_pre=true; shift ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "update.sh: unknown argument '$1'" >&2; exit 64 ;;
  esac
done

emit() {
  echo "$1"
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1" >>"$GITHUB_OUTPUT"
  return 0
}

api() { # path
  local -a auth=()
  # CI gets 60 anonymous requests an hour per IP; a token lifts that.
  [ -n "${GITHUB_TOKEN:-}" ] && auth=(--header "Authorization: Bearer $GITHUB_TOKEN")
  curl --fail --silent --show-error --location --retry 3 \
    --header "Accept: application/vnd.github+json" \
    "${auth[@]}" "$API/$1"
}

old_version=$(jq -r '.version' "$sources_file")

# One page is ~15 releases, far more history than we ever need.
releases=$(api "releases?per_page=30")

# version<TAB>space-separated asset names, newest release first. GitHub returns
# releases in publication order, which is what "newest" means for Tabby: its
# version numbers are monotonic but the tag is the authority.
candidates=$(
  jq -r --argjson pre "$allow_pre" '
    .[]
    | select(.draft == false)
    | select($pre or (.prerelease == false))
    | (.tag_name | ltrimstr("v")) as $v
    | [$v, ([.assets[].name] | join(" "))] | @tsv
  ' <<<"$releases"
)
if [ -z "$candidates" ]; then
  echo "update.sh: no usable releases in $API/releases — did the API shape change?" >&2
  exit 1
fi

assets_for() { # version
  awk -F'\t' -v v="$1" '$1 == v { print $2; exit }' <<<"$candidates"
}

has_deb() { # assets, version, arch
  grep -qw -- "tabby-$2-linux-$3.deb" <<<"$1"
}

if [ -n "$want_version" ]; then
  new_version="$want_version"
  if [ -z "$(assets_for "$new_version")" ]; then
    echo "update.sh: $new_version is not among the last 30 releases of $REPO" >&2
    exit 1
  fi
else
  # Newest release that covers every required system.
  new_version=""
  while IFS=$'\t' read -r candidate assets; do
    complete=true
    for system in "${REQUIRED_SYSTEMS[@]}"; do
      has_deb "$assets" "$candidate" "${ARCHES[$system]}" || complete=false
    done
    if $complete; then new_version="$candidate"; break; fi
  done <<<"$candidates"
fi

if [ -z "$new_version" ]; then
  echo "update.sh: no release has a .deb for ${REQUIRED_SYSTEMS[*]}" >&2
  exit 1
fi

emit "old-version=$old_version"
emit "version=$new_version"
emit "changelog=https://github.com/$REPO/releases/tag/v$new_version"

if [ "$old_version" = "$new_version" ]; then
  echo "update.sh: already on $new_version"
  emit "updated=false"
  exit 0
fi

echo "update.sh: $old_version -> $new_version"
if $dry_run; then
  emit "updated=true"
  echo "update.sh: --dry-run, not writing $sources_file"
  exit 0
fi

assets=$(assets_for "$new_version")

# Prefetch each architecture that exists for this version. Missing arches are
# dropped from sources.json rather than guessed, so meta.platforms stays honest.
platforms_json="{}"
for system in "${SYSTEMS[@]}"; do
  arch="${ARCHES[$system]}"
  url="https://github.com/$REPO/releases/download/v$new_version/tabby-$new_version-linux-$arch.deb"

  if ! has_deb "$assets" "$new_version" "$arch"; then
    echo "update.sh: no $arch build for $new_version, skipping $system" >&2
    continue
  fi

  echo "update.sh: prefetching $system ($arch)..."
  hash=$(nix store prefetch-file --json --hash-type sha256 "$url" | jq -r '.hash')
  echo "update.sh:   $hash"

  platforms_json=$(
    jq --arg sys "$system" --arg arch "$arch" --arg hash "$hash" \
      '.[$sys] = { arch: $arch, hash: $hash }' <<<"$platforms_json"
  )
done

jq --arg version "$new_version" --argjson platforms "$platforms_json" \
  '.version = $version | .platforms = $platforms' \
  "$sources_file" >"$sources_file.tmp"
mv "$sources_file.tmp" "$sources_file"

emit "updated=true"
emit "systems=$(jq -r '.platforms | keys | join(",")' "$sources_file")"
echo "update.sh: wrote $sources_file"
