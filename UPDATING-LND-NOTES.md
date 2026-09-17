# Updating LND - Practical Notes (supplement)

Supplements the **"Updating LND version in BTCPay Server"** section in the repo README.
That section lists the high-level steps; this file captures the non-obvious details
and gotchas that actually make a release go green. Replace `X.Y.Z` with the new version
(e.g. `0.21.3`) throughout.

---

## 0. TL;DR checklist

- [ ] `btcpayserver/lnd`: branch `lnd/vX.Y.Z-beta` off the upstream `vX.Y.Z-beta` tag
- [ ] Cherry-pick the single consolidated **`Adding BtcPayServer related files and resources`** commit
- [ ] Fix versions in the 3 Dockerfiles (Go base image, Loop) - **see gotchas below**
- [ ] Local test build (amd64 + at least one arm) and smoke-test the binaries
- [ ] Tag **`basedon-vX.Y.Z-beta`** and push it - **the tag is the release trigger, not the branch**
- [ ] Watch GitHub Actions `publish` run -> confirm `btcpayserver/lnd:vX.Y.Z-beta` multiarch image on Docker Hub
- [ ] Downstream PRs: BTCPayServer.Lightning -> btcpayserver -> btcpayserver-docker
- [ ] Update `master` (merge to preserve refs + `Update README.md` versions list)

---

## 1. The overlay is now ONE consolidated commit

`Adding BtcPayServer related files and resources` now already includes everything that
used to be separate follow-ups: the `kvdb_sqlite` build tag, the Go base-image bump, and
the Loop bump. So for a new version you only cherry-pick **that one commit** onto the new
upstream tag, then adjust version numbers. (10 files, ~590 insertions.)

If a **feature PR** was merged onto the previous version branch (e.g. the macaroon-rotation
change in `docker-entrypoint.sh`, PR #11), carry it forward too - fold it into the overlay
commit so it isn't silently dropped in the next version.

**Cherry-pick order for the NEXT version (post-0.21.3).** The v0.21.2-era overlay still
ships `.circleci/config.yml`, so on top of the overlay you need the two v0.21.3 follow-ups
from `lnd/v0.21.3-beta`:
1. `14221cf95` - Switch image publishing from CircleCI to GitHub Actions (removes
   `.circleci/`, adds `.github/workflows/publish.yml`)
2. `abca9f952` - Pin arm builder stages to `BUILDPLATFORM` (arm cross-compile stays
   native-speed under buildx; without it buildx emulates the whole Go compile)
3. `391889da0` - Support file-based Bitcoin RPC password (PR #14, `RPCUSER_FILE` in
   `docker-entrypoint.sh`; shipped as image `v0.21.3-beta-1`)
Carry forward the current startup scripts and regression suite from PR #17 as well;
the older PR #13 password-migration implementation has been superseded. Preserve
`btcpay/test-startup-tests.sh` and `.github/workflows/btcpay-tests.yml`. For v0.21.4+,
fold these changes into the refreshed overlay rather than restoring older scripts.

## 2. Go base image must satisfy `go.mod` (this WILL bite)

Check the new version's requirement:
```bash
grep -E '^(go|toolchain) ' go.mod    # e.g. "go 1.25.10"
```
The `golang:` base image in the Dockerfiles must be **>= that Go version**. It is not
auto-handled: the official `golang` images pin `GOTOOLCHAIN=local`, so an older image
will **not** download the newer toolchain - the build hard-fails with
`go.mod requires go >= X (running go Y; GOTOOLCHAIN=local)`.

- `linuxamd64.Dockerfile`  -> `FROM golang:<ver>-alpine`
- `linuxarm32v7.Dockerfile` / `linuxarm64v8.Dockerfile` -> `FROM golang:<ver>-bookworm`

Safest: match upstream's own `GO_VERSION` in the `Makefile` for that tag. Cherry-picking the
overlay onto a tag where upstream bumped it may auto-merge instead of conflict - always
diff-check `Dockerfile`/`Makefile` after the cherry-pick.
(History: v0.21.1/0.21.2 upstream Go 1.26.3; v0.21.3 upstream Go 1.26.6, we follow suit.)

## 3. Arm builders: bullseye is dead, and `bookworm` dropped the `qemu` metapackage

Two linked traps that broke the v0.21.0 arm CI jobs:

1. **No `golang:<new>-bullseye` exists** (bullseye stopped at Go 1.24.x). Newer Go arm
   builders must use **`-bookworm`**.
2. **Debian bookworm removed the transitional `qemu` metapackage.** The arm apt line must be:
   ```dockerfile
   && apt-get install -qq --no-install-recommends qemu-user-static qemu-user binfmt-support
   ```
   i.e. **drop `qemu`** (kept it -> `E: Package 'qemu' has no installation candidate`).
   The build only needs `qemu-user-static` anyway - it provides `qemu-arm-static` /
   `qemu-aarch64-static`, which get `COPY`d into the final arm image. Full-system qemu was
   never used (the builder cross-compiles via `GOARCH`, no emulation).

## 4. Version knobs to bump in all 3 Dockerfiles

- **Loop** (bundled in the same image, built from source in each Dockerfile): bumping is
  *occasional/optional* - carry the previous version forward unless you deliberately update it.
  If you do: check latest at https://github.com/lightninglabs/loop/releases, sanity-check it's
  compatible with the new lnd version, then set the branch in **all 3** Dockerfiles:
  `RUN git clone --depth 1 --branch vA.B.C-beta https://github.com/lightninglabs/loop.git ...`
  Whenever you change it, also update the `loop --version` smoke test (Section 5) and the
  `- Includes <LOOP_VERSION> Loop` line in the master README (Section 8).
  (History: v0.19.1 -> Loop 0.29.0, v0.19.3 -> 0.31.2, v0.21.x -> 0.33.3.)
- **kvdb_sqlite**: keep it in `make install tags="... routerrpc watchtowerrpc kvdb_sqlite"`

## 5. Local test build before tagging

```bash
# amd64
docker build --pull -t local-lnd:test -f linuxamd64.Dockerfile .
# arm64 (register emulation first; the builder stage is pinned to BUILDPLATFORM
# since v0.21.3, so only the final-stage RUN steps run under QEMU - fast)
docker run --privileged --rm tonistiigi/binfmt --install arm64,arm
docker buildx build --platform linux/arm64 --pull -t local-lnd:test-arm64 -f linuxarm64v8.Dockerfile --load .
# smoke test - versions must match what you set
docker run --rm --entrypoint lnd  local-lnd:test --version   # lnd  X.Y.Z-beta ...-fresh-btcpay
docker run --rm --entrypoint loop local-lnd:test --version   # loop A.B.C-beta
```

Run the startup regression suite on a Linux Docker host with curl and jq:
```bash
bash btcpay/test-startup-tests.sh
bash btcpay/test-startup-tests.sh --list
# Or run one case:
bash btcpay/test-startup-tests.sh matrix-default-V1
```
The single file covers 37 cases, including password/marker combinations, fresh
wallets, interrupted password changes, historical newlines, funded channels and
explicit failures. It starts disposable regtest containers and cleans them up.
Its `IMAGE` variable selects the released LND binary; it mounts the checkout's two
startup scripts. This verifies the scripts but does not replace building and
checking the newly published image.

The `BTCPay startup tests` workflow runs the suite in seven groups on PRs and master
pushes. Keep its scenario lists aligned with `--list`. In this fork, inherited LND
workflows are disabled through repository settings; `publish` remains enabled.
If no run appears, check that repository Actions is enabled. Stop the old CircleCI
project separately: deleting its config does not disconnect that integration.

## 6. The tag is the release - the branch push does nothing

The `publish` GitHub Actions workflow only fires on tags matching `basedon-*` (see
`.github/workflows/publish.yml`, added in the v0.21.3 cycle when we moved off CircleCI);
it strips the `basedon-` prefix to form the Docker tag. So pushing the **branch** builds
nothing; you must push the **tag**:
```bash
git tag -a basedon-vX.Y.Z-beta -m "BtcPayServer LND vX.Y.Z-beta (Loop vA.B.C-beta, Go <ver>)" <branch-tip>
git push origin basedon-vX.Y.Z-beta
```
Docker tag ends up as `vX.Y.Z-beta` (no suffix). A `-N` suffix (e.g. `v0.19.3-beta-1`) is only
used when re-cutting an image for the same upstream version.

The workflow needs the `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` repo secrets (use a Docker Hub
access token, not the account password). The three per-arch buildx jobs push
`vX.Y.Z-beta-amd64` / `-arm32v7` / `-arm64v8`, then the `multiarch` job assembles the
manifest list with `docker buildx imagetools create` - platform annotations come from the
build metadata, no manual `manifest annotate` needed.

Monitor: the repo's Actions tab, or `gh run list -R btcpayserver/lnd` / `gh run watch`.
If a run failed for infrastructure reasons, rerun its failed jobs on the same commit
(`gh run rerun <id> --failed`). Use a new tag for changed source; do not move a published
release tag or reuse an image version for different contents.

Confirm the published multiarch image (amd64 + arm/v7 + arm64):
```
https://hub.docker.com/v2/repositories/btcpayserver/lnd/tags/vX.Y.Z-beta
```

## 7. Downstream repos - exact files

**BTCPayServer.Lightning** (branch `feat/lnd-X.Y.Z`, PR title `Bumping LND to X.Y.Z-beta`)
- `tests/docker-compose.yml` - 2 lnd service `image:` lines
- The `CI` workflow's `test` job runs Docker Compose integration tests against the image.

**btcpayserver** (branch `feat/lnd-vX.Y.Z-beta`)
- 4 files, 8 refs total (`merchant_lnd` + `customer_lnd` in each):
  `BTCPayServer.Tests/docker-compose.yml`, `docker-compose.altcoins.yml`,
  `docker-compose.mutinynet.yml`, `docker-compose.testnet.yml`
- Link the Lightning PR and the published image/tag in the PR description.

For a test image, keep the full suffix (for example `v0.21.3-beta-2-test-del`) in
every reference and identify it as a test candidate in both PRs. Open the PRs after
publication succeeds so their tests can pull the image. Opening test PRs does not
require merging them or updating the production Docker deployment.

**btcpayserver-docker** (branch `feat/lnd-vX.Y.Z-beta`, open as **draft**, tag @NicolasDorier + @Pavlenex)
- A single find/replace of the old tag `vOLD` -> `vX.Y.Z-beta` across 4 files does everything,
  because the `basedon-vOLD` URLs contain the tag as a substring:
  - `docker-compose-generator/docker-fragments/bitcoin-lnd.yml`  <- **this is the one that ships to users**
  - `contrib/build-all-images.sh`
  - `contrib/DockerFileBuildHelper/build-all.sh`
  - `README.md` (the `btcpayserver/lnd` components-table row)
- This repo has no CI on the PR; the release maintainers validate on their servers.

## 8. Updating `master` on btcpayserver/lnd

Goal: master's tree = the newest tagged version's tree, **references preserved**, and the
btcpayserver README (versions list) restored as a separate commit. The version branches carry
the **upstream lnd README**, so a plain merge would clobber master's README - that's why the
README is always its own follow-up commit.

```bash
git checkout master && git merge --ff-only origin/master

# preserve refs for any versions that were skipped on master (no tree change):
git merge -s ours --no-ff -m "Merge lnd/vA-beta into master (preserve references)" lnd/vA-beta
# ... repeat for each missing version ...

# make master's tree equal the newest version, still recording the merge (preserve ref):
git merge -s ours --no-ff --no-commit lnd/vX.Y.Z-beta
git read-tree -u --reset lnd/vX.Y.Z-beta
git commit -m "Merge lnd/vX.Y.Z-beta into master"

# restore btcpayserver README (with the new version entry) as its own commit:
#   edit README.md versions list, then:
git commit -m "Update README.md"
```

### README "Versions:" entry format
Each entry links the **amd64 image digest** (not the manifest-list digest):
```
 - [X.Y.Z-beta](https://hub.docker.com/layers/btcpayserver/lnd/vX.Y.Z-beta/images/sha256-<AMD64_DIGEST>?context=repo)
    - Includes <LOOP_VERSION> Loop
```
Get `<AMD64_DIGEST>` (hex, no `sha256:`) from the `images[]` entry with `architecture == amd64`:
```
https://hub.docker.com/v2/repositories/btcpayserver/lnd/tags/vX.Y.Z-beta
```

## 9. Sequencing notes

- If a feature PR targets the version branch (e.g. macaroon rotation), **merge it before**
  tagging so the first published image includes it - otherwise you need a `-1` re-tag.
- Rough order: build+publish image -> BTCPayServer.Lightning -> btcpayserver -> btcpayserver-docker
  -> master update. Each downstream step references the artifact from the previous one.
- A test candidate can tag an explicitly selected PR commit directly, without merging
  it. Keep that tag fixed even if a later documentation commit is added to the PR.
  Downstream test PRs can remain drafts while the candidate is reviewed.

## 10. Wallet password handling in `docker-initunlocklnd.sh`

The current scripts in PR #17 handle passwords as follows:
- **New wallets** get a random per-instance password, written to `walletunlock.json`
  next to `wallet.db` - the same file BTCPay's seed-backup view reads.
- **Default passwords** (`hellorockstar`, or an empty/null/missing password field)
  migrate to a random password. Save it in `walletunlock.json.newpassword` BEFORE
  `changepassword`: LND changes wallet encryption before updating the macaroon store.
  Only after success is the JSON password updated and the temporary file removed.
- **Pending changes** try the saved replacement first, then the stored password.
  Only LND's wrong-wallet-password response permits another candidate. If the saved
  password is `hellorockstar`, the historical `hellorockstar\n` variant is also tried.
- **Custom passwords** stay unchanged unless a pending replacement already exists.
  An ordinary startup just unlocks with the saved password.

Gotchas that bit during implementation:
- **ChangePassword also unlocks.** Password changes and native root rotation run
  while the wallet is locked, instead of first calling `unlockwallet`. A default
  password change and requested root rotation finish in the same startup.
- **Success is not always `{}`.** With macaroons enabled, `initwallet` and
  `changepassword` return `{"admin_macaroon":"..."}`. Checking success by exact `== {}`
  silently misdetects these as failures (and can strand the wallet if you retry with a
  "wrong current password" instinct). Match `{}` OR `*admin_macaroon*`.
- `unlockwallet` success IS `{}` - the pre-0.21.3 script treated anything without
  "invalid" as failure, so every restart logged "Wallet unlocking failed" and exited
  before the Loop-start section. Fixed in #13.
- Test setups need `no-rest-tls=1` in `LND_EXTRA_ARGS` or the script's HTTP calls get 400s.

## 11. Safety reference: macaroon rotation (`LND_MACAROON_ROTATION_ID`)

PR #17 uses LND's `changepassword` RPC with `new_macaroon_root_key=true`; the startup
scripts no longer delete the macaroon database. A custom wallet password is passed
unchanged, while a default/pending password change is combined with the rotation.

An existing `.macaroon-rotated-<ID>` marker skips rotation for that ID. On success,
the confirmed password is saved before the marker is created. A fresh wallet records
the requested ID after successful initialization, avoiding rotation on its next start.

Old tokens become invalid. LND recreates its admin, readonly and invoice macaroon
files; clients using copied tokens must re-pair, and custom macaroons must be reissued.
BTCPay uses the shared admin macaroon file. The regression suite checks token
revocation/preservation, node identity, funded channels and backup points; it does
not establish a live deployment's safety or replace its backups.

A requested rotation can fail on missing macaroon files or an inconsistent store.
These errors and unknown passwords require manual recovery. Preserve
`walletunlock.json` and any `.newpassword` file: failure can occur
after LND changes wallet encryption. An existing legacy wallet with no unlock file
is refused before LND starts if the requested rotation ID has no completion marker.
Legacy startup with no requested ID or a completed ID remains supported.

## 2026-09-16

### PR #17 test candidate: v0.21.3-beta-2-test-del

- Image: `btcpayserver/lnd:v0.21.3-beta-2-test-del`, **linux/amd64 only**.
- [Git tag](https://github.com/btcpayserver/lnd/tree/basedon-v0.21.3-beta-2-test-del):
  `basedon-v0.21.3-beta-2-test-del`, fixed at `df0ac2b3c1590fbda819a69754b6cb848e70c4e0`.
- Image index digest: `sha256:e749c9b16677ece57f31335ce79194b68e122d730f201155eff543c6d2db7181`.
- Draft downstream PRs: [Lightning #196](https://github.com/btcpayserver/BTCPayServer.Lightning/pull/196)
  and [BTCPayServer #7580](https://github.com/btcpayserver/btcpayserver/pull/7580).

The [normal publisher](https://github.com/btcpayserver/lnd/actions/runs/35178486562)
built amd64, but both ARM builds failed twice on Debian Bullseye package-download
404s. The [test manifest publisher](https://github.com/btcpayserver/lnd/actions/runs/35179868943)
copied the successful amd64 artifact by digest to the requested test tag, preserving
the exact source commit. Its one-time workflow is now disabled. No ARM image was
substituted and no existing tag was moved. ARM runtime packaging needs a separate
fix and a new source/tag before a normal multiarch release.
