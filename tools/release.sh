#!/usr/bin/env bash
# Builds a signed release: dist/hermes-call.tar.gz, SHA256SUMS and SHA256SUMS.sig.
#
#   tools/release.sh v0.6.0 ~/.ssh/hermes-call-release
#
# The signing key is an SSH key kept offline (ssh-keygen -t ed25519 -f ~/.ssh/hermes-call-release);
# its public key is pinned in proxmox-helper/install/hermes-call-relay-install.sh (RELEASE_SIGNER).
# Upload the three files in dist/ to the GitHub release of that tag.
set -Eeuo pipefail

tag=${1:?usage: release.sh <tag> <ssh signing key>}
key=${2:?usage: release.sh <tag> <ssh signing key>}
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "tag must look like v1.2.3" >&2; exit 2; }
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
git rev-parse -q --verify "refs/tags/$tag" >/dev/null || { echo "tag $tag does not exist" >&2; exit 2; }
[[ -z $(git status --porcelain --untracked-files=no) ]] || { echo "working tree is not clean" >&2; exit 2; }

rm -rf dist && mkdir dist
git archive --format=tar.gz --prefix=hermes-call/ -o dist/hermes-call.tar.gz "$tag"
(cd dist && if command -v sha256sum >/dev/null; then sha256sum hermes-call.tar.gz; else shasum -a 256 hermes-call.tar.gz; fi >SHA256SUMS)
ssh-keygen -Y sign -q -f "$key" -n hermes-call-release dist/SHA256SUMS
echo "dist/ ready for $tag:"
ls -l dist
