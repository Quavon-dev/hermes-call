#!/usr/bin/env bash
# Creates a fresh repository with one commit from the current HEAD (tracked files only), for
# publishing without this repository's development history. It never pushes.
#
#   tools/export_public.sh ../hermes-call-public
#   cd ../hermes-call-public && git remote add origin git@github.com:quavon-dev/hermes-call.git && git push -u origin main
set -euo pipefail

target=${1:?usage: tools/export_public.sh <new-directory>}
root=$(git rev-parse --show-toplevel)
[[ ! -e $target ]] || { echo "refusing: $target exists" >&2; exit 1; }
[[ -z $(git -C "$root" status --porcelain) ]] || { echo "refusing: commit or stash your changes first" >&2; exit 1; }

mkdir -p "$target"
git -C "$root" archive --format=tar HEAD | tar -x -C "$target"

# Last safety net: nothing private or film-derived may leave (see CONTRIBUTING.md).
# Case-sensitive: device UDIDs (old 00008140-… and any new-style 8-16 hex id), the owner's LAN
# host, container id and device names, home directories, private e-mail addresses.
private='00008140-|\b[0-9A-F]{8}-[0-9A-F]{16}\b|192\.168\.0\.177|LXC 121|pct exec 121|iPhone von|/Users/[a-z]+'
private+='|[A-Za-z0-9._%+-]+@quavon\.de'
# Case-insensitive: personal names and handles, film and franchise names.
names='leopold|jarvis|ultron|marvel|stark industries'
found=0
grep -rInE "$private" "$target" --exclude=export_public.sh && found=1
grep -rIniE "$names" "$target" --exclude=export_public.sh && found=1
if [[ $found -eq 1 ]]; then
  echo "refusing: private or film-derived text found above" >&2
  rm -rf "$target"
  exit 1
fi

cd "$target"
git init -q -b main
git add -A
git commit -q -m "Initial public release"
echo "created $target ($(git ls-files | wc -l | tr -d ' ') files, one commit); review it, then add the remote and push"
