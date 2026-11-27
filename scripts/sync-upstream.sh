#!/usr/bin/env bash
# Sync flake.nix version, source hash, frontend.bun.lock and frontend outputHash from the latest NixRTR/nebula-commander tag.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
repo=NixRTR/nebula-commander
tag=$(git ls-remote --tags --refs "https://github.com/$repo.git" 'v*' | awk -F/ '{print $3}' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n1)
version=${tag#v}
current=$(grep -oE '^\s*version = "[^"]+"' flake.nix | head -n1 | sed -E 's/.*"([^"]+)"/\1/')
[ "$current" != "$version" ] || { echo "already at $version"; exit 0; }
fake="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
src_hash=$(nix store prefetch-file --json --unpack "https://github.com/$repo/archive/refs/tags/$tag.tar.gz" | jq -r .hash)
curl -fsSL "https://raw.githubusercontent.com/$repo/$tag/frontend/package.json" -o "$tmp/package.json"
(cd "$tmp" && nix shell nixpkgs#bun -c bun install --lockfile-only)
cp "$tmp/bun.lock" frontend.bun.lock
sed -i "s|version = \"$current\";|version = \"$version\";|" flake.nix
SRC_HASH=$src_hash perl -0pi -e 's/(rev = "v\$\{version\}";\s*hash = ")[^"]+(")/$1$ENV{SRC_HASH}$2/' flake.nix
sed -i -E "s|(outputHash = \")[^\"]+(\";)|\1$fake\2|" flake.nix
log=$(mktemp)
if nix build .#frontend --no-link --accept-flake-config >"$log" 2>&1; then :; else
  deps_hash=$(grep -oE 'got:\s+sha256-[A-Za-z0-9+/=]+' "$log" | head -n1 | grep -oE 'sha256-[A-Za-z0-9+/=]+')
  [ -n "$deps_hash" ] || { cat "$log" >&2; echo "could not derive outputHash" >&2; exit 1; }
  sed -i -E "s|(outputHash = \")[^\"]+(\";)|\1$deps_hash\2|" flake.nix
fi
rm -f "$log"
nix build .#default .#frontend --no-link --accept-flake-config
echo "synced nebula-commander $version"
