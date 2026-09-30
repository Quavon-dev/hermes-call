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
if grep -rInE "00008140-|192\.168\.0\.177|iPhone von|Leopold|/Users/[a-z]+|Jarvis|Ultron|Marvel" "$target" \
    --exclude=export_public.sh; then
  echo "refusing: private or film-derived text found above" >&2
  rm -rf "$target"
  exit 1
fi

cd "$target"
git init -q -b main
git add -A
git commit -q -m "Initial public release"
echo "created $target ($(git ls-files | wc -l | tr -d ' ') files, one commit); review it, then add the remote and push"
