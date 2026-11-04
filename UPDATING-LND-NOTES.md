# Updating LND in BTCPay Server

This is the release procedure for `btcpayserver/lnd`. Use the full upstream
version, including `-beta` and any `.rcN`, throughout. The sequence is source
and local build -> published-image verification and startup tests -> library
and core integration PRs -> Docker deployment PR -> authorized master update.
Publishing, merging and changing a live server are separate actions; stay within
the operator's request.

For Core Lightning, use its [update skill](https://github.com/btcpayserver/lightning/blob/btcpaymaster/.agents/skills/update-btcpay-cln/SKILL.md).
CLN rewrites `btcpaymaster` linearly; LND uses version branches and a consolidated
BTCPay overlay. The downstream integration gates are shared, but LND's wallet
and macaroon startup tests are LND-specific.

## 1. Prepare the version branch and overlay

Fetch and verify the selected upstream `lightningnetwork/lnd` tag's peeled SHA
and release notes. Start `lnd/v<version>` there in a clean worktree. Compare the
previous upstream tag with the last shipped `basedon-*` tag to identify the
**complete current BTCPay overlay**, including subsequent fixes. Do not replay
an old list of commit IDs: publishing, ARM packaging and startup fixes have
already been folded into newer overlays.

Apply that reviewed diff as one `Adding BtcPayServer related files and resources`
commit. Preserve the upstream README on version branches. Carry forward the
three `linux*.Dockerfile` files, startup scripts, regression suite, publish/test
workflows, build tags and `-fresh-btcpay` commit suffix. Preserve the latest
release guide too, including documentation updates on master since the previous
tag. Review conflicts and the resulting upstream-to-branch diff; do not silently
copy unrelated upstream changes into the overlay.

## 2. Match the Go toolchain

Inspect `go.mod` and upstream's Makefile `GO_VERSION`. All three builder images
must satisfy the module's Go requirement; matching upstream's toolchain is the
usual choice. Confirm those image tags exist. `GOTOOLCHAIN=local` prevents an
older builder from downloading the required toolchain automatically.

Use the appropriate Alpine amd64 and Debian ARM variants. Check all Dockerfiles
after applying the overlay even when Git reports no conflict.

## 3. Preserve ARM packaging

The ARM builder stages use `--platform=$BUILDPLATFORM` and Go cross-compilation.
Keep the supported Debian builder/runtime variants (currently Bookworm) and
`qemu-user-static qemu-user binfmt-support`; the removed `qemu` metapackage is
not needed. Preserve the matching static QEMU binary copied into each runtime.
Do not restore the obsolete Bullseye images from an old overlay.

## 4. Keep bundled versions and build tags consistent

Keep Loop at its previous version unless deliberately updating it. If changing
Loop, verify the upstream release and LND compatibility, update its source tag
in all three Dockerfiles, check `loop --version`, and update master's version
entry when that master update is authorized. Preserve `kvdb_sqlite` and the
existing RPC build tags in every `make install` command.

## 5. Build before publishing

Build and smoke-test amd64 locally:

```bash
docker build --pull -t local-lnd:test -f linuxamd64.Dockerfile .
docker run --rm --network none --entrypoint lnd local-lnd:test --version
docker run --rm --network none --entrypoint loop local-lnd:test --version
```

Check version and source identity, not just successful startup. Exercise an ARM
build on a suitable native/emulated builder when available; do not install
host-wide binfmt handlers on a shared machine as an incidental release step.
The publication workflow must still build all three platforms successfully.

## 6. Publish, verify and run startup tests on the new image

The [publish workflow](.github/workflows/publish.yml) runs on `basedon-*` tag
pushes, not version-branch pushes. Its image tag is the Git tag without
`basedon-`. First publication is `basedon-v<version>` with **no `-1`**; additional
BTCPay revisions use `-1`, `-2`, etc.

Push the reviewed branch, verify its remote SHA, and create an annotated tag at
that exact tip after checking both remote Git refs and Docker Hub for collisions.
Publishing needs the repository's Docker Hub credentials. Watch the matching
run and verify its source SHA. Retry infrastructure failures on the same source;
changed source requires a new revision. Never move a published tag or reuse an
image version for different contents. A canceled run may have published partial
artifacts, so inspect the registry before recovery.

The workflow builds amd64, arm32v7 and arm64v8 tags, then assembles the index.
Before the first downstream PR:

1. Require successful publication and an index containing `linux/amd64`,
   `linux/arm/v7` and `linux/arm64`. Record the index and platform digests.
2. Pull each platform and check its actual `/bin/lnd` binary: architecture,
   version, and embedded Git commit identity against the selected tag/build,
   including BTCPay's `-fresh-btcpay` suffix. Execute the native-platform binary;
   distinguish static ARM inspection from execution. RC and final binaries can
   print the same version; check the source identity, and Loop if it changed.
3. Run the complete [startup suite](btcpay/test-startup-tests.sh) against the
   **new published image**. The script's `IMAGE` assignment currently selects
   an older release and overrides an environment variable of the same name.
   A normal green workflow can therefore test the scripts against an old binary.
   Create a temporary branch from the release source, change only that assignment
   to the exact new tag, and dispatch [BTCPay startup tests](.github/workflows/btcpay-tests.yml)
   on that branch. Require every matrix group to pass, verify the pulled image
   in logs, save the commit/run evidence, then delete only the temporary branch.

The suite mounts the checkout's startup scripts into disposable regtest
containers. Keep those scripts identical to the release source; the suite does
not replace checking the scripts packaged in the image. `--list` enumerates
scenarios (currently 37 across seven CI groups); keep the workflow's lists in
sync with it. Coverage includes password/marker combinations, fresh wallets,
interrupted changes, historical newlines, funded channels and expected failures.
If no run appears, check the workflow's enabled state and trigger configuration.

## 7. Downstream repos - exact files

Read each repository's current agent instructions and workflows. Open test-image
PRs only after publication verification and new-image startup tests pass. Keep
any RC/test/revision suffix in every image reference and identify test candidates
as such in the PRs.

| Repository | Compose files | LND services |
| --- | --- | --- |
| `BTCPayServer.Lightning` | `tests/docker-compose.yml` | both LND services |
| `btcpayserver` | `BTCPayServer.Tests/docker-compose.yml`, `docker-compose.altcoins.yml`, `docker-compose.mutinynet.yml`, `docker-compose.testnet.yml` | `merchant_lnd`, `customer_lnd` in each |

Open the library PR, then the core PR linking it and the published image.
Require both integration jobs to pass on their **current PR heads**, inspect
logs for the intended image and executed LND tests, and record commit, tag/digest
and run links. Core CI uses the altcoins Compose file for regtest; updating the
other files does not exercise their separate environments. Follow core's test
instructions, including `PLAYWRIGHT_HEADLESS=true` locally. Investigate failures
before advancing; old-image green CI does not validate the new release.

After both suites pass, update
`docker-compose-generator/docker-fragments/bitcoin-lnd.yml` in
`btcpayserver-docker`. Its [AGENTS.md](https://github.com/btcpayserver/btcpayserver-docker/blob/master/AGENTS.md)
is authoritative for regenerating `contrib/build-all-images.sh` and
`docs/supported-images.md`; do not manually replace versions in generated files.
Follow that repository's PR skill, open a draft, and link both test PRs. Its
[CI](https://github.com/btcpayserver/btcpayserver-docker/blob/master/.github/workflows/ci.yml)
includes generator, documentation and installation checks. The destructive
installation script belongs on disposable CI runners, not a development host.

Validate an appropriate LND-backed upgrade, including wallet auto-unlock,
identity/channel preservation, connectivity and invoice/payment flows. State
what was actually exercised: no channels means payments were not tested.
Use disposable infrastructure unless the operator authorized an existing server
update. CI and a version command do not establish a live deployment's safety.
Ask release maintainers to review; merge only when authorized.

## 8. Updating `master` on btcpayserver/lnd

When authorized, preserve version history while updating master's release tree.
Start from current remote master and record its SHA. Preserve master's BTCPay
README/version list, this guide and current repository instructions before
changing the tree. Version branches carry the upstream README.

Record skipped version branches with `git merge -s ours --no-ff` as needed.
For the selected newest version, make a merge commit whose release source tree
matches that version (`git merge -s ours --no-ff --no-commit`, then
`git read-tree -u --reset <version-branch>`). Restore the current master-only
documentation and add the new README version entry as a separate commit.
Review the final tree and ancestry against both parents before pushing; do not
restore an obsolete guide from the release tag or force-rewrite master.

Each README version entry links the **amd64 platform digest**, not the index:

```text
 - [<version>](https://hub.docker.com/layers/btcpayserver/lnd/v<version>/images/sha256-<AMD64_DIGEST>?context=repo)
    - Includes <LOOP_VERSION> Loop
```

Obtain the digest from the published index or Docker Hub's `images[]` entry for
amd64. The README link, image provenance and version branch must agree.

## Startup invariants to preserve

These are release-review checks; the authoritative behavior is in
[docker-initunlocklnd.sh](docker-initunlocklnd.sh),
[docker-entrypoint.sh](docker-entrypoint.sh) and the regression suite.

- Fresh/default-password wallets receive a random per-instance password stored
  in `walletunlock.json`. Custom passwords remain unchanged unless a pending
  replacement exists. Default includes empty, null, missing and historical
  `hellorockstar` forms, including the supported newline variant.
- Save a replacement in `walletunlock.json.newpassword` **before** changing it.
  On interrupted changes, try the saved replacement first, then stored password;
  only a wrong-wallet-password response permits another candidate. Preserve both
  files on failure: wallet encryption may already have changed.
- `changepassword` also unlocks. Combine a requested native macaroon-root rotation
  with the password change while locked; do not delete the macaroon database.
  A successful change/init may return an `admin_macaroon`, not just `{}`.
- Record `.macaroon-rotated-<ID>` only after success and saving the confirmed
  password. A completed ID skips rotation; fresh initialization records its ID
  without causing rotation on the next startup.
- Rotation invalidates old tokens. LND regenerates its standard macaroon files;
  copied/custom credentials need re-pairing/reissue. Unknown passwords, missing
  files or inconsistent stores require recovery, not a false completion marker.
  Legacy wallets without an unlock file must refuse a new rotation request,
  while no-request or already-completed-marker startup remains supported.

The suite checks token revocation/preservation, identities, funded channels and
backup points. It does not replace operator backups or prove every upgrade path.
