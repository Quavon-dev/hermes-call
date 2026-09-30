#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Builds a release of the relay and the bridge from a tag (runbook: docs/releasing.md).
#
#   tools/release.sh v0.7.0 ~/.ssh/hermes-call-release    build and sign (owner, offline key)
#   tools/release.sh v0.7.0                               build only (the v* tag workflow in CI)
#   tools/release.sh --sign dist ~/.ssh/hermes-call-release
#                                                         sign a build downloaded from the draft
#                                                         release, after rebuilding it here and
#                                                         checking that the content is identical
#
# dist/ then holds:
#   hermes-call.tar.gz          git archive of the tag, plus hermes-call/RELEASE (version, tag, commit)
#   SHA256SUMS (+ .sig)         checksum of the tarball, signed in namespace hermes-call-release
#                               (what installers up to 0.6.x verify)
#   MANIFEST (+ .sig)           name, version, tag, commit and tarball checksum, signed in namespace
#                               hermes-call-manifest; newer installers refuse a MANIFEST whose version
#                               is lower than the installed one (rollback protection)
#
# The signing key is an SSH ed25519 key kept offline; its public key is RELEASE_SIGNER in
# proxmox-helper/ct/hermes-call-relay.sh, proxmox-helper/install/hermes-call-relay-install.sh and
# bridge/get.sh.
set -Eeuo pipefail

SUMS_NAMESPACE=hermes-call-release
MANIFEST_NAMESPACE=hermes-call-manifest
TARBALL=hermes-call.tar.gz

die() { printf 'release.sh: %s\n' "$*" >&2; exit 2; }
usage() { die "usage: release.sh <tag> [<ssh signing key>] | release.sh --sign <dist dir> <ssh signing key>"; }

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
sha256_stdin() { sha256 - | cut -d' ' -f1; }

check_tag() {
  [[ $1 =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "tag must look like v1.2.3 (got '$1')"
  git -C "$root" rev-parse -q --verify "refs/tags/$1^{commit}" >/dev/null || die "tag $1 does not exist"
}

# The version the installers see must be the tag's: relay/hermescall_relay/version.py (relay VERSION
# file, /healthz) and bridge/pyproject.toml.
check_versions() {
  local tag=$1 want=${1#v} relay bridge
  relay=$(git -C "$root" show "$tag:relay/hermescall_relay/version.py" | sed -n 's/^VERSION = "\(.*\)"$/\1/p')
  bridge=$(git -C "$root" show "$tag:bridge/pyproject.toml" | sed -n 's/^version = "\(.*\)"$/\1/p' | head -1)
  [[ $relay == "$want" ]] || die "$tag: relay/hermescall_relay/version.py says '$relay', not $want"
  [[ $bridge == "$want" ]] || die "$tag: bridge/pyproject.toml says '$bridge', not $want"
}

# Deterministic for a given tag: RELEASE has no time stamp, and git gives every entry the commit time.
release_file() {
  local tag=$1 commit
  commit=$(git -C "$root" rev-parse "$tag^{commit}")
  printf 'version=%s\ntag=%s\ncommit=%s\n' "${tag#v}" "$tag" "$commit"
}

archive_tar() {
  local tag=$1
  git -C "$root" archive --format=tar --prefix=hermes-call/ \
    --add-virtual-file="hermes-call/RELEASE:$(release_file "$tag")"$'\n' "$tag"
}

write_manifest() {
  local tag=$1 dir=$2 commit created digest
  commit=$(git -C "$root" rev-parse "$tag^{commit}")
  created=$(git -C "$root" log -1 --format=%cI "$tag^{commit}")
  digest=$(sha256_stdin <"$dir/$TARBALL")
  {
    echo "format=1"
    echo "name=hermes-call"
    echo "version=${tag#v}"
    echo "tag=$tag"
    echo "commit=$commit"
    echo "created=$created"
    echo "tarball=$TARBALL"
    echo "sha256=$digest"
  } >"$dir/MANIFEST"
}

sign() {
  local dir=$1 key=$2
  [[ -r $key ]] || die "signing key $key is not readable"
  rm -f "$dir/SHA256SUMS.sig" "$dir/MANIFEST.sig"
  ssh-keygen -Y sign -q -f "$key" -n "$SUMS_NAMESPACE" "$dir/SHA256SUMS"
  ssh-keygen -Y sign -q -f "$key" -n "$MANIFEST_NAMESPACE" "$dir/MANIFEST"
}

build() {
  local tag=$1 key=${2:-}
  check_tag "$tag"
  check_versions "$tag"
  [[ -z $(git -C "$root" status --porcelain --untracked-files=no) ]] || die "working tree is not clean"
  local dist=$root/dist
  rm -rf "$dist" && mkdir "$dist"
  archive_tar "$tag" | gzip -9n >"$dist/$TARBALL"
  (cd "$dist" && sha256 "$TARBALL" >SHA256SUMS)
  write_manifest "$tag" "$dist"
  if [[ -n $key ]]; then
    sign "$dist" "$key"
    echo "dist/ ready and signed for $tag:"
  else
    echo "dist/ built for $tag, NOT signed (sign with: tools/release.sh --sign dist <key>):"
  fi
  ls -l "$dist"
}

# Signs a build made elsewhere (the draft release from CI) after checking, from this checkout, that
# the tarball holds exactly the tag's content and that SHA256SUMS and MANIFEST describe that tarball.
sign_existing() {
  local dir=$1 key=$2 tag want got
  [[ -f $dir/$TARBALL && -f $dir/SHA256SUMS && -f $dir/MANIFEST ]] || die "$dir needs $TARBALL, SHA256SUMS and MANIFEST"
  tag=$(sed -n 's/^tag=//p' "$dir/MANIFEST")
  check_tag "$tag"
  check_versions "$tag"
  [[ $(sed -n 's/^commit=//p' "$dir/MANIFEST") == "$(git -C "$root" rev-parse "$tag^{commit}")" ]] ||
    die "MANIFEST commit is not the commit of $tag here"
  want=$(archive_tar "$tag" | sha256_stdin)
  got=$(gzip -dc "$dir/$TARBALL" | sha256_stdin)
  [[ $want == "$got" ]] || die "$TARBALL does not contain exactly $tag (tar $got, expected $want)"
  (cd "$dir" && sha256 -c --quiet SHA256SUMS) || die "SHA256SUMS does not match $TARBALL"
  [[ $(sed -n 's/^sha256=//p' "$dir/MANIFEST") == "$(sha256_stdin <"$dir/$TARBALL")" ]] ||
    die "MANIFEST checksum does not match $TARBALL"
  sign "$dir" "$key"
  echo "signed $tag in $dir: upload SHA256SUMS.sig and MANIFEST.sig to the draft release"
}

case ${1:-} in
  --sign) [[ $# -eq 3 ]] || usage; sign_existing "$2" "$3" ;;
  "" | -h | --help) usage ;;
  *) [[ $# -le 2 ]] || usage; build "$1" "${2:-}" ;;
esac
