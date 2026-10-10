#!/usr/bin/env bash
#
# Update the Cloudreve packages in this flake.
#
# Usage:
#   scripts/update.sh [VERSION] [bin|src|all]
#
# Without VERSION the latest GitHub release is used. The third argument
# defaults to "all". Requires: nix-update, curl, jq, awk, sed,
# nix-prefetch-url and nix-hash (all provided by `nix develop`).
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")/.."

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

repo="cloudreve/Cloudreve"
frontend_repo="cloudreve/frontend"

version="${1:-}"
target="${2:-all}"

gh_api() {
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" "$@"
  else
    curl -fsSL "$@"
  fi
}

if [[ -z "$version" ]]; then
  version="$(gh_api "https://api.github.com/repos/$repo/releases/latest" | jq -r .tag_name)"
fi
version="${version#v}"

echo "==> Updating Cloudreve packages to $version (target: $target)"

if [[ "$target" == "all" || "$target" == "bin" ]]; then
  # The release hashes are platform independent to compute: read them from the
  # published checksums.txt instead of prefetching each tarball (nix-update can
  # only prefetch the hash for the system it runs on).
  echo "==> cloudreve-bin"
  checksums="$tmpdir/checksums.txt"
  curl -fsSL "https://github.com/$repo/releases/download/$version/checksums.txt" > "$checksums"

  declare -A assets=(
    [x86_64-linux]=linux_amd64
    [aarch64-linux]=linux_arm64
    [x86_64-darwin]=darwin_amd64
    [aarch64-darwin]=darwin_arm64
  )

  sed -i -E "s/^(  version \? \")[^\"]*(\",)$/\1$version\2/" packages/cloudreve-bin.nix

  for platform in "${!assets[@]}"; do
    asset="cloudreve_${version}_${assets[$platform]}.tar.gz"
    hex="$(awk -v a="$asset" '$2 == a { print $1 }' "$checksums")"
    if [[ -z "$hex" ]]; then
      echo "error: no checksum for $asset in checksums.txt" >&2
      exit 1
    fi
    sri="$(nix-hash --to-sri --type sha256 "$hex")"
    sed -i "/^    $platform = {/,/^    };/ s#hash = \"[^\"]*\";#hash = \"$sri\";#" packages/cloudreve-bin.nix
    echo "  $platform -> $sri"
  done
fi

if [[ "$target" == "all" || "$target" == "src" ]]; then
  # The frontend is a git submodule pinned by the Cloudreve tag. nix-update does
  # not know about it, so resolve and patch the revision and its source hash
  # before letting nix-update handle the rest.
  frontend_rev="$(gh_api "https://api.github.com/repos/$repo/contents/assets?ref=$version" | jq -r .sha)"
  last_commit="$(gh_api "https://api.github.com/repos/$repo/commits/$version" | jq -r .sha)"
  last_commit="${last_commit:0:7}"

  echo "==> cloudreve (from source): frontend $frontend_rev, commit $last_commit"

  cloudreve_hash="$(nix-prefetch-url --unpack "https://github.com/$repo/archive/refs/tags/$version.tar.gz" | tail -n1)"
  cloudreve_sri="$(nix-hash --to-sri --type sha256 "$cloudreve_hash")"
  frontend_hash="$(nix-prefetch-url --unpack "https://github.com/$frontend_repo/archive/$frontend_rev.tar.gz" | tail -n1)"
  frontend_sri="$(nix-hash --to-sri --type sha256 "$frontend_hash")"

  file="packages/cloudreve.nix"

  sed -i -E "s/^(  version \? \")[^\"]*(\",)$/\1$version\2/" "$file"
  sed -i -E "s/^(  lastCommit \? \")[^\"]*(\",)$/\1$last_commit\2/" "$file"
  sed -i -E "s/^(  frontendRev \? \")[^\"]*(\",)$/\1$frontend_rev\2/" "$file"

  # Replace the hash that follows the given marker line (inside a fetchFromGitHub
  # block) without touching anything else in the file.
  patch_hash() {
    local marker="$1" sri="$2"
    awk -v marker="$marker" -v sri="$sri" '
      index($0, marker) { inblock = 1 }
      inblock && index($0, "hash = ") {
        sub(/hash = "[^"]*";/, "hash = \"" sri "\";")
        inblock = 0
      }
      { print }
    ' "$file" > "$file.tmp"
    mv "$file.tmp" "$file"
  }

  patch_hash 'repo = "Cloudreve";' "$cloudreve_sri"
  patch_hash 'repo = "frontend";' "$frontend_sri"

  # nix-update fills in buildGoModule's vendorHash and fetchYarnDeps' hash.
  nix-update cloudreve --flake --version=skip --system x86_64-linux
fi

echo "==> Done"
