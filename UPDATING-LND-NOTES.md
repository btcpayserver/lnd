# Updating LND - Practical Notes (supplement)

Supplements the **"Updating LND version in BTCPay Server"** section in the repo README.
That section lists the 5 high-level steps; this file captures the non-obvious details
and gotchas that actually make a release go green. Replace `X.Y.Z` with the new version
(e.g. `0.21.1`) throughout.

---

## 0. TL;DR checklist

- [ ] `btcpayserver/lnd`: branch `lnd/vX.Y.Z-beta` off the upstream `vX.Y.Z-beta` tag
- [ ] Cherry-pick the single consolidated **`Adding BtcPayServer related files and resources`** commit
- [ ] Fix versions in the 3 Dockerfiles (Go base image, Loop) - **see gotchas below**
- [ ] Local test build (amd64 + at least one arm) and smoke-test the binaries
- [ ] Tag **`basedon-vX.Y.Z-beta`** and push it - **the tag is the release trigger, not the branch**
- [ ] Watch CircleCI -> confirm `btcpayserver/lnd:vX.Y.Z-beta` multiarch image on Docker Hub
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
# arm64 (register emulation first)
docker run --privileged --rm tonistiigi/binfmt --install arm64,arm
docker build --pull -t local-lnd:test-arm64 -f linuxarm64v8.Dockerfile .
# smoke test - versions must match what you set
docker run --rm --entrypoint lnd  local-lnd:test --version   # lnd  X.Y.Z-beta ...-fresh-btcpay
docker run --rm --entrypoint loop local-lnd:test --version   # loop A.B.C-beta
```

## 6. The tag is the release - the branch push does nothing

CircleCI only fires on tags matching `/basedon-.+/` (see `.circleci/config.yml`); it strips
the 8-char `basedon-` prefix to form the Docker tag. So pushing the **branch** builds nothing;
you must push the **tag**:
```bash
git tag -a basedon-vX.Y.Z-beta -m "BtcPayServer LND vX.Y.Z-beta (Loop vA.B.C-beta, Go <ver>)" <branch-tip>
git push origin basedon-vX.Y.Z-beta
```
Docker tag ends up as `vX.Y.Z-beta` (no suffix). A `-N` suffix (e.g. `v0.19.3-beta-1`) is only
used when re-cutting an image for the same upstream version.

Monitor (public, no auth) or just use the CircleCI web UI:
```
https://circleci.com/api/v2/project/gh/btcpayserver/lnd/pipeline
https://circleci.com/api/v2/pipeline/<id>/workflow
https://circleci.com/api/v2/workflow/<id>/job
```
Confirm the published multiarch image (amd64 + arm/v7 + arm64):
```
https://hub.docker.com/v2/repositories/btcpayserver/lnd/tags/vX.Y.Z-beta
```
A tag force-move (re-point + `git push -f`) does re-trigger a fresh pipeline.

## 7. Downstream repos - exact files

**BTCPayServer.Lightning** (branch `feat/lnd-X.Y.Z`, PR title `Bumping LND to X.Y.Z-beta`)
- `tests/docker-compose.yml` - 2 lnd service `image:` lines
- Merge once `build_and_test` is green (its integration tests actually run the image).

**btcpayserver** (branch `feat/lnd-vX.Y.Z-beta`)
- 4 files, 8 refs total (`merchant_lnd` + `customer_lnd` in each):
  `BTCPayServer.Tests/docker-compose.yml`, `docker-compose.altcoins.yml`,
  `docker-compose.mutinynet.yml`, `docker-compose.testnet.yml`

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

## 10. Wallet password handling in `docker-initunlocklnd.sh`

Since v0.21.3 (btcpayserver/lnd#13) there is no shared `hellorockstar` default:
- **New wallets** get a random per-instance password, written to `walletunlock.json`
  next to `wallet.db` - the same file BTCPay's seed-backup view reads.
- **Existing wallets** whose unlock file still says `hellorockstar` (or empty) are
  migrated on startup: `changepassword` on the still-**locked** wallet rotates +
  unlocks in one call, and only then is the file rewritten. The `hellorockstar\n`
  line-feed variant falls through to a second `changepassword` attempt.

Gotchas that bit during implementation:
- **WalletUnlocker dies on unlock.** `changepassword` only exists while the wallet is
  locked; after a successful `unlockwallet` the service is gone and any rotate call
  fails with "wallet already unlocked". Migration must run INSTEAD of unlock.
- **Success is not always `{}`.** With macaroons enabled, `initwallet` and
  `changepassword` return `{"admin_macaroon":"..."}`. Checking success by exact `== {}`
  silently misdetects these as failures (and can strand the wallet if you retry with a
  "wrong current password" instinct). Match `{}` OR `*admin_macaroon*`.
- `unlockwallet` success IS `{}` - the pre-0.21.3 script treated anything without
  "invalid" as failure, so every restart logged "Wallet unlocking failed" and exited
  before the Loop-start section. Fixed in #13.
- Test setups need `no-rest-tls=1` in `LND_EXTRA_ARGS` or the script's HTTP calls get 400s.

## 11. Safety reference: macaroon rotation (`LND_MACAROON_ROTATION_ID`)

Deleting `macaroons.db` + the `*.macaroon` files forces lnd to mint a new root key and
re-bake macaroons on unlock. It **cannot** cause fund loss (funds = seed / `wallet.db` /
channel state, none of which are touched) - the only consequence is that API clients
(mobile, RTL, custom-baked macaroons) must **re-pair**. The BTCPayServer<->LND link recovers
automatically because it reads the regenerated macaroon from the shared volume. True across
all upgrade-from versions (0.18.0+); macaroon paths have been stable.
