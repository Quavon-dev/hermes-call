# Proxmox VE helper script (community-scripts format)

`ct/hermes-call-relay.sh`, `install/hermes-call-relay-install.sh` and
`json/hermes-call-relay.json` follow the community-scripts/ProxmoxVED layout and
`build.func` framework: unprivileged Debian 13 LXC, 1 core, 512 MB RAM, 4 GB disk,
`update_script` via `check_for_gh_release`.

## Signed releases

The helper does **not** use `fetch_and_deploy_gh_release`: it downloads
`hermes-call.tar.gz`, `SHA256SUMS(.sig)` and, from 0.7 on, `MANIFEST(.sig)` from the latest
release, checks the signature against the pinned `RELEASE_SIGNER` key (`ssh-keygen -Y verify`)
and the checksum, and only then unpacks and runs anything as root. Without a pinned key it
refuses to install. On `update` it also refuses a release older than the installed version
(rollback protection; `HC_ALLOW_DOWNGRADE=1` in front of the command forces it).

Key handling, building, signing and publishing a release: [docs/releasing.md](../docs/releasing.md).

## One command

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Quavon-dev/hermes-call/main/proxmox-helper/ct/hermes-call-relay.sh)"
```

`ct/hermes-call-relay.sh` sets `COMMUNITY_SCRIPTS_URL` to this folder, so the community-scripts
framework (`community-scripts/core`) fetches `install/hermes-call-relay-install.sh` from this
repository. It asks for the relay's domain on the host, before the container is created (the
install script inside the container has no terminal); empty = public IP with a self-signed
certificate. Unattended: `var_relay_address=relay.example.com` before the command.

## Status

- **Needs a signed GitHub release** marked *latest* (`tools/release.sh`, see above); iOS releases
  (`ios-v*`) are never marked latest.
- **Not yet eligible upstream:** ProxmoxVED requires 600+ stars, 6+ months age,
  active maintenance and release tarballs.

## Run from a local checkout (on the Proxmox host, as root)

`COMMUNITY_SCRIPTS_ROOT` makes the framework load `ct/` and `install/` from this
folder instead of the upstream repository:

```bash
COMMUNITY_SCRIPTS_ROOT=/root/hermes-call/proxmox-helper bash /root/hermes-call/proxmox-helper/ct/hermes-call-relay.sh
```

Unattended: `var_relay_address=relay.example.com` before the command.

## Deviations from upstream rules (to state in the PR)

1. **Application setup is delegated to `relay/install.sh`.** The relay's
   security configuration (coturn deny lists, sandboxed units, secret ownership,
   firewall) is maintained and container-tested in one place; duplicating it in
   the install script would let the two drift apart.
2. **No `uv`.** The relay has no PyPI dependencies at runtime: it uses the
   distribution's `python3-aiohttp`, `python3-httpx`, `python3-cryptography`,
   `libsodium23`, which receive Debian security updates via unattended-upgrades.
3. **No APNs key in the helper.** Pushes go through the Hermes Call push gateway by default
   (docs/push-gateway.md). An own key (own app builds only) is added after install
   (`pct push` + `install.sh --apns-key`) so it never travels through environment variables or
   the website form.
