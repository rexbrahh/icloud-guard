# iCloud Guard

yeah well, this was initially just a script in my [nix-darwin](https://github.com/nix-darwin/nix-darwin) repo where each `nix-darwin switch` builds a simple swift binary that [launchd](https://en.wikipedia.org/wiki/Launchd) manages to reactively prune icloud storage by removing local copies (not deleting the actual files/folders upstream) when it goes berserk and trying to fill your mac so you upgrade. kinda like playing whackamole.

a deep investigation of the root cause surfaced that apple has this speculative download enabled in a private framework on macos and on icloud infra server-side they do a [CloudKit](https://developer.apple.com/documentation/cloudkit) push every single time even just a single thing, doesnt matter if it's just metadata, changes, on any one of your devices connected under your icloud account, so it triggers a rematerialization attempt and downstream speculative downloading on macos tries to fetch the update and rematerialize a local copy, that's why sometimes you go to bed and you wake up and you see your mac becomes extremely sluggish and you find out you only have 10gb free disk space on your 512gb macbook.

the actual mechanism, traced from system logs (`log show --predicate 'process == "bird"' --last 1h --info`), goes like this:

1. your iphone (or any device) changes a file in icloud — even just metadata
2. apple's [cloudkit](https://developer.apple.com/documentation/cloudkit) sends a push notification to your mac — the logs show `Sync down (push triggered)` → `CKFetchRecordZoneChangesOperation`
3. the [`bird`](https://eclecticlight.co/2023/11/21/icloud-drive-in-sonoma-fileprovider-and-eviction/) daemon (the icloud sync engine at `/System/Library/PrivateFrameworks/iCloudDriveCore.framework/`) processes the push and sees `itemChangedRemotely`
4. [`fileproviderd`](https://developer.apple.com/documentation/fileprovider) (the file provider daemon) schedules a `fetch-content` job with `why:materialization|itemChangedRemotely` — this is the speculative download
5. the file is rematerialized on disk, even though literally nobody asked for it

this speculative download behavior is controlled by apple's [trial (a/b testing) system](https://developer.apple.com/documentation/technotes/tn3150-getting-ready-for-data-less-files) under a namespace called `COREOS_FPFS_SPECULATIVE_DOWNLOADS` — the logs show `Namespace COREOS_FPFS_SPECULATIVE_DOWNLOADS does not provide a factor with name "speculativeDownloadSetCompressedAge"` — meaning apple can turn it on or off per user from their servers, without any macos update, and without your consent or knowledge. there is no user-facing toggle for this. you can't turn it off in system settings. you can't turn it off with a `defaults write` command. it just is.

it also doesnt help that both [spotlight](https://support.apple.com/guide/mac-help/spotlight-mchlp1008/mac) indexing service and [finder](https://en.wikipedia.org/wiki/Finder_(software)) app both run an eager enumerator on icloud root on mac so nothing regarding icloud, on your mac, ever truly rests even if you barely even touch it. the `fileproviderctl dump` output shows spotlight process holding an active enumerator on `icloud/root` and finder process holding enumerators on the file system and trash — both of which can trigger materialization of [dataless files](https://developer.apple.com/documentation/technotes/tn3150-getting-ready-for-data-less-files) (evicted files that exist as apfs stubs with the `SF_DATALESS` flag, `0x40000000`, zero allocated blocks but nonzero logical size).

there are threads of multiple people on forums with the same problem:

- [apple developer forums](https://developer.apple.com/forums/thread/817068) — `evictUbiquitousItem` returning `EBUSY` on packages
- [eclectic light (howard oakley)](https://eclecticlight.co/2023/11/21/icloud-drive-in-sonoma-fileprovider-and-eviction/) — documenting the sonoma fileprovider eviction regression and quicklook re-materialization bug
- [apple support communities](https://discussions.apple.com/thread/254698327) — `fileproviderd` eating 95%+ cpu permanently
- [ryan cabeen's blog](https://cabeen.io/blog/posts/2026-01-15-icloud-is-not-a-folder.html) — documenting the phantom file problem where `bird` tries to sync deleted files

and even official discussions with an apple engineer acknowledging the issue but commented that they will not fix it. for whatever reason. fine.

so i built this fix.

## what it does

icloud guard is a macos menu bar app that runs four layers of defense against icloud's rematerialization problem:

### layer 1: download suppression (proactive)

stops the triggers before they happen:

- **spotlight suppression** — drops a `.metadata_never_index` marker in the icloud drive root so spotlight stops indexing the [fileprovider working set](https://developer.apple.com/documentation/fileprovider/nsfileprovideritem), which prevents metadata reads from triggering materialization of dataless files
- **quicklook cache clearing** — runs `qlmanage -r cache` before eviction to prevent quicklook thumbnail generation from immediately re-materializing evicted packages (this is the [known bug](https://eclecticlight.co/2023/11/21/icloud-drive-in-sonoma-fileprovider-and-eviction/) where "no sooner is the file evicted, but as its quicklook thumbnail has to be displayed in the finder, it's immediately materialised for that purpose")
- **non-materializing i/o policy** — sets [`setiopolicy_np`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/setiopolicy_np.3.html) on the guard process itself so its own metadata reads don't trigger downloads, equivalent to the [`MaterializeDatalessFiles: false`](https://www.manpagez.com/man/5/launchd.plist/) launchd key

### layer 2: correct eviction

the right apis, used properly (all verified on macos 26):

- **[`FileManager.evictUbiquitousItem(at:)`](https://developer.apple.com/documentation/foundation/filemanager/evictubiquitousitem(at:))** — the only eviction api that works from a non-extension process. [`NSFileProviderManager(for: domain)`](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager) returns nil when called from a process that isn't the file provider extension itself (verified on macos 26.5.1), so `evictItem(identifier:)` is not available to us
- **package-root eviction** — on macos 26, packages (`.app`, `.fcpbundle`, …) are single items to `fileproviderd`: evicting package *contents* fails with `NSFileNoSuchFileError` ("doesn't exist") and even apple's own `brctl evict` crashes on package children. so packages are detected (`NSWorkspace.isFilePackage`, cached per extension) and evicted as one unit at the root. before eviction, a bounded native process inspection checks for open package contents. the default `protect_busy_packages = true` setting blocks eviction when a package is busy or inspection is unavailable. the result reports privacy-bounded process names so you can close the relevant app and retry
- **`SF_DATALESS` residency detection** — the legacy `ubiquitousItemDownloadingStatus` url resource keys return nil for every file on macos 26 (verified: 150/150 materialized files), so eligibility is computed from [`lstat(2)`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/lstat.2.html): a file is evictable when it's a regular file without the apfs `SF_DATALESS` flag (`0x40000000`) and has `st_blocks > 0`. every eviction is re-verified the same way, so "reclaimed bytes" is measured, never assumed
- **bulk scanning** — the full drive is scanned with `getattrlistbulk(2)` (one syscall per directory batch) plus targeted `lstat` on materialized files only. a ~425k-file icloud drive scans in ~13 seconds instead of the several minutes that per-file `URL.resourceValues` xpc round trips took

### layer 3: active defense (watchlist + re-evict)

detects and reverses rematerialization within seconds:

- **watchlist watcher** — every evicted path is recorded in `~/.icloud-guard/watchlist.json` and polled with `lstat(2)` every few seconds (microseconds per path, no spotlight dependency — so it works while spotlight suppression is active, and it doesn't rely on the download-status attributes that are broken on macos 26). a path that becomes resident again is re-evicted immediately
- **exponential backoff + fighting detection** — re-eviction backoff doubles per rematerialization (up to a configurable max, default 60s). files that keep bouncing back past the fight threshold are flagged as "fighting" in the ui instead of burning cpu in an infinite war with `fileproviderd`; files that stay dataless graduate out of the watchlist after a stable period

in practice this matters: in testing, icloud re-downloaded ~7 gb of freshly evicted packages within ~10 minutes. the watchlist plus the policy loop is what turns a one-time cleanup into a held line.

### layer 4: policy-driven trimming (always on, in the app)

the menu bar app itself runs the policy engine — no launchd job required:

- **auto-trim** — every scan interval (default 300s) the drive's real footprint is measured; when it exceeds the trim trigger (default 8 gib), the largest/oldest files and packages are evicted until the footprint is back at the target (default 5 gib). free-space floors (warn/remediate/panic) and a growth-rate trigger act as additional tripwires, with a cooldown between runs
- **cli parity** — `icloud-guard status|evict|panic-evict` talks to the running app over an authenticated unix socket (streaming progress), and falls back to the exact same engine in-process when the app isn't running

## what it doesn't do

- it cannot stop cloudkit push notifications from your iphone (server-side, no user toggle)
- it cannot disable the trial system's speculative download namespace (`COREOS_FPFS_SPECULATIVE_DOWNLOADS`)
- it cannot stop finder from holding background enumerators on the icloud root
- it cannot set [`NSFileProviderContentPolicy.downloadLazily`](https://developer.apple.com/documentation/fileprovider/nsfileprovideritem/contentpolicy) on items (read-only from outside the file provider extension)

what it _can_ do: eliminate the spotlight trigger, eliminate the quicklook trigger, make the guard's own reads non-materializing, and reverse rematerialization within seconds instead of minutes. the net effect is dramatically less local disk usage and fewer cpu-burning download/evict cycles.

## installation

### requirements

- macos 15+ (sequoia or later)
- icloud drive enabled
- "optimize mac storage" turned on in system settings → apple id → icloud

swift 5.10+ / xcode 15+ is only needed when building from source.

### homebrew cask (recommended)

the easiest install path is the dedicated tap:

```bash
brew tap rexbrahh/tap
brew install --cask icloud-guard
open /Applications/ICloudGuard.app
```

the cask installs the notarized app bundle into `/Applications`.

to upgrade later:

```bash
brew update
brew upgrade --cask icloud-guard
```

to uninstall the app but keep your config/logs:

```bash
brew uninstall --cask icloud-guard
```

to uninstall the app and remove icloud guard's local state:

```bash
brew uninstall --cask --zap icloud-guard
```

the zap step removes `~/.icloud-guard`.

### github release zip

download the latest notarized beta from:

```text
https://github.com/rexbrahh/icloud-guard/releases
```

then:

1. unzip `ICloudGuard-beta-<version>.zip`
2. drag `ICloudGuard.app` into `/Applications`
3. open `/Applications/ICloudGuard.app`

if macos says the app is damaged, you are almost certainly using an old pre-notarization build. download `0.4.4` or newer.

### from source

```bash
git clone https://github.com/rexbrahh/icloud-guard.git
cd icloud-guard
./scripts/build-app.sh --release --install
open ~/Applications/ICloudGuard.app
```

source installs copy the app to `~/Applications/ICloudGuard.app` and install a convenience cli wrapper at `~/bin/icloud-guard`.

### config

The app reads TOML configuration from `~/.icloud-guard/config.toml`. If the file does not exist, the app uses the defaults. Runtime receipts, state, and the watchlist use private JSON files in the same directory.

```toml
[suppression]
spotlight = true
quicklook = true
materialize_dataless = false

[eviction]
batch_limit = 500
panic_limit = 2000
protect_busy_packages = true

[watcher]
backoff_max_seconds = 60
pollution_check_interval_seconds = 300
watchlist_poll_seconds = 10
watchlist_max_entries = 5000
verified_retention_hours = 168
pending_verification_grace_seconds = 30
pending_retry_limit = 10
max_fights = 10

[scope]
path = "~/Library/Mobile Documents/com~apple~CloudDocs"
protected_paths = []
keep_downloaded_paths = []
# each value uses "mode:relative/path"; modes are protect, evict-first, evict-last
folder_policies = []

[policy]
target_local_gib = 5
trim_local_gib = 8
warn_free_gib = 80
remediate_free_gib = 50
panic_free_gib = 25
cooldown_minutes = 30
growth_trigger_gib = 20
growth_window_minutes = 10

[energy]
enabled = true
defer_on_low_power_mode = true
defer_on_serious_thermal_state = true
defer_on_battery_power = true

[notifications]
eviction_completed = true
partial_failure = true
fighting_files = true
restore_completed = true
keep_downloaded = true
actions_enabled = true

[updates]
# disabled until a trusted update origin and key are configured
enabled = false
channel = "stable"
feed_url = ""
key_id = ""
public_key_x963_base64 = ""
team_id = ""
```

`keep_downloaded_paths` accepts safe scope-relative prefixes or globs. The guard excludes these paths from eviction and periodically requests local materialization. This rule is separate from `protected_paths` and never weakens protection.

Energy policy can defer only scheduled nonpanic mutation. Manual eviction, panic eviction, and full reconciliation never defer. Missing native power or thermal signals fail open. Status and receipts identify each deferral and its cause.

Folder policies use the most-specific matching path. `protect` excludes the folder from every eviction path. `evict-first` and `evict-last` change stable candidate ordering.

#### multiple scopes

The legacy `[scope]`, `[watcher]`, `[policy]`, and `[eviction]` sections remain the default single-scope configuration. Existing installations keep their current paths and storage files.

For explicit multi-scope mode, add `[scopes]` with 1 to 64 canonical version-2 definitions. Each definition has its own stable ID, display name, and automatic scheduling switch. It also has independent path protections, watcher settings, policy, and eviction limits. This one-scope example includes every required canonical field:

```toml
[scopes]
definitions = ["{\"automatic_enabled\":true,\"eviction\":{\"batchLimit\":500,\"panicLimit\":2000,\"protectBusyPackages\":true},\"id\":\"personal\",\"name\":\"Personal\",\"policy\":{\"cooldownMinutes\":30,\"growthTriggerGiB\":20,\"growthWindowMinutes\":10,\"panicFreeGiB\":25,\"remediateFreeGiB\":50,\"targetLocalGiB\":5,\"trimLocalGiB\":8,\"warnFreeGiB\":80},\"scope\":{\"folderPolicies\":[],\"keepDownloadedPaths\":[],\"path\":\"/Users/example/Library/Mobile Documents/com~apple~CloudDocs\",\"protectedPaths\":[]},\"version\":2,\"watcher\":{\"backoffMaxSeconds\":60,\"maxFights\":10,\"pendingRetryLimit\":10,\"pendingVerificationGraceSeconds\":30,\"pollutionCheckIntervalSeconds\":300,\"verifiedRetentionHours\":168,\"watchlistMaxEntries\":5000,\"watchlistPollSeconds\":10}}"]
```

Replace the example with an absolute, non-symbolic-link path. Definitions use sorted compact JSON inside a TOML string. The parser rejects non-canonical text, unknown fields, unsafe IDs, duplicate names, path aliases, symbolic-link components, and overlapping scopes. Let iCloud Guard save an edited definition before copying it to other systems. Do not reformat the JSON by hand.

Explicit scopes store state, watchlist, history, recovery, logs, mutation locks, and browser data under `~/.icloud-guard/scopes/<id>/`. Selected-scope diagnostics and support bundles read only that scope's effective configuration and isolated storage. Configuration-level suppression, notifications, energy policy, update trust, IPC credentials, and the automatic panic lease remain global. Each automatic scope runs independently. The global disk-panic lease permits only one simultaneous automatic panic run.

Use the app scope selector to view or change one scope. Run `icloud-guard scope list` to list IDs without revealing paths. Commands that act on one scope accept `--scope <id-or-name>`. This includes `icloud-guard doctor --scope <id-or-name>` and `icloud-guard support-bundle <output.zip> --scope <id-or-name>`.

An ID must match exactly. A display name uses Unicode case- and diacritic-folded matching. Configuration validation rejects ambiguous folded names. In explicit multi-scope mode, omit the selector only when exactly one scope exists. Multiple scopes without a selector fail with `scope-required`. Legacy single-scope commands remain unchanged.

Legacy verified evictions also write `~/.icloud-guard/recovery.json` with mode `0600`. Explicit scopes use their isolated recovery path. This bounded journal stores scope-relative paths, item type, run ID, and device/inode identity. It does not store file contents or rely on receipt hashes as restore authority. Restore revalidates the scope, ancestors, item type, and identity immediately before it calls `startDownloadingUbiquitousItem`.

all app files live under `~/.icloud-guard/` — config, logs, future state. nothing in `~/Library/Application Support/` or `~/Library/Logs/`.

### gh releases

tip and beta releases are available in this repo. tip releases are built from every tip commit that lands on main that passes CI, builds and gets packaged successfully. beta releases are more polished, sporadic, when i think it's good enough for a certain standard with respect to goals i set for myself on this tool. you can find them in releases in this gh repo.

beta releases are developer id signed, hardened-runtime enabled, notarized, and stapled before the zip is uploaded. the release zip is what the homebrew cask points at.

tip archives are ad hoc signed and do not authenticate their source publisher. To check only the archive and manifest's internal integrity, get the tag and commit independently. Then acknowledge that boundary explicitly:

```bash
expected_tag="tip-<12-character-commit-prefix>"
git fetch --tags origin
expected_commit=$(git rev-parse "$expected_tag^{commit}")
./scripts/verify-release.sh \
  --expected-tag "$expected_tag" \
  --expected-commit "$expected_commit" \
  --allow-unauthenticated-tip \
  ICloudGuard-tip-<version>-<commit-prefix>.zip.json \
  ICloudGuard-tip-<version>-<commit-prefix>.zip
```

This mode reports `Internal consistency verified; publisher and source provenance not authenticated`. An independently delivered SHA-256 can replace `--allow-unauthenticated-tip` with `--expected-sha256 <digest>`. That mode reports artifact integrity against the digest, but it still does not authenticate source provenance.

### updating

By default, the built-in updater does nothing. Configure its trust key and update origin to enable it. The updater supports authenticated `stable` and `beta` feeds. It does not support `tip` because tip archives do not have authenticated publisher provenance.

`icloud-guard update check` downloads and authenticates metadata only. `icloud-guard update download` is an explicit second action. It downloads one candidate into a private temporary directory. It checks the signature, size, SHA-256, and archive structure. It also checks the Developer ID Team ID, notarization ticket, staple, bundle identity, version, and executable identity. It then prints manual replacement instructions. The app and CLI never install or replace an app.

The feed URL, artifact URL, redirects, and final response must use one HTTPS origin. The scheme, host, and port must match. GitHub release downloads redirect to a different asset host. Therefore, a GitHub release URL is not a valid live update origin. Host `feed-v1.json` and its zip without cross-origin redirects. For an origin such as `https://updates.example/icloud-guard`, use these paths:

```text
https://updates.example/icloud-guard/stable/feed-v1.json
https://updates.example/icloud-guard/stable/ICloudGuard-<version>.zip
https://updates.example/icloud-guard/beta/feed-v1.json
https://updates.example/icloud-guard/beta/ICloudGuard-beta-<version>.zip
```

The updater caches successful metadata checks for up to 15 minutes and never past feed expiry. Cache and backoff timers use monotonic system uptime. A backward wall-clock change clears the cache and fails closed. A candidate becomes invalid when wall-clock time passes its signed expiry. Failed operations use exponential backoff from 30 seconds to one hour.

The updater stores rollback and equivocation state in a private `0600` schema-v1 file. The file has a 256 KiB limit and uses the signing-key ID and channel as its key. It records the highest feed generation, the canonical generation fingerprint, and the full release fingerprint for each version. The updater rejects an older generation or conflicting content at one generation. It also rejects changed metadata or artifact identity for a previously observed version. These checks persist across process restarts.

A private advisory lock covers read, validation, merge, and atomic replacement. This lock prevents a stale process from regressing the state. State advances only after complete feed and selected-channel validation. Corrupt, replaced, non-canonical, or otherwise unsafe continuity storage fails closed.

Cancellation stops the network request or native verifier and removes incomplete private files. Native verification runs fixed absolute system tools only. On cancellation, it sends `TERM` and escalates to `KILL` after 500 ms. The updater must reap the child within one second. Pipe reads have time and size limits.

A successful download is a private manual handoff. The updater never installs it. Discard the handoff when it is no longer needed.

At startup, the updater examines at most 64 entries and removes at most 16 stale update directories. A directory must be at least 24 hours old. It must have the expected name, owner, mode, and contents. Cleanup skips symbolic links, replacements, unowned paths, and unexpected entries.

The app shows a **Discard verified download** button. A discard failure preserves the handoff and reports that you can retry. Before a new check, the app discards the existing handoff. It follows the same rule when update-trust configuration changes. Cleanup failure aborts the new action.

On quit, the app cancels and awaits active update work, then discards the handoff. It declines termination if that cleanup fails. Retired asynchronous work cannot overwrite a newer update status or handoff.

homebrew users:

```bash
brew update
brew upgrade --cask icloud-guard
```

manual zip users, including built-in updater handoffs:

1. Quit iCloud Guard from the menu bar.
2. Open the verified release archive.
3. Replace `/Applications/ICloudGuard.app` manually.
4. Open the new app and confirm its version.

source users:

```bash
cd icloud-guard
git pull
./scripts/build-app.sh --release --install
open ~/Applications/ICloudGuard.app
```

### uninstalling

quit icloud guard first from the menu bar.

homebrew:

```bash
brew uninstall --cask icloud-guard
```

manual install:

```bash
rm -rf /Applications/ICloudGuard.app
```

source install:

```bash
rm -rf ~/Applications/ICloudGuard.app
rm -f ~/bin/icloud-guard
```

remove all local config, logs, socket files, tokens, and state:

```bash
rm -rf ~/.icloud-guard
```

do not run that last command if you want to preserve policy settings, protected paths, or historical logs.

### maintenance and troubleshooting

common paths:

```text
~/.icloud-guard/config.toml       # editable config
~/.icloud-guard/icloud-guard.log  # app/service log
~/.icloud-guard/evictions.log     # eviction history
~/.icloud-guard/history.json      # bounded, versioned run receipts
~/.icloud-guard/watchlist.json    # rematerialization defense state
~/.icloud-guard/guard.sock        # cli socket
~/.icloud-guard/guard.token       # cli auth token, mode 0600
~/.icloud-guard/icloud-guard.pid  # gui pid marker
~/.icloud-guard/run.lock          # run lock
```

use these when debugging:

```bash
/Applications/ICloudGuard.app/Contents/MacOS/ICloudGuard status
/Applications/ICloudGuard.app/Contents/MacOS/ICloudGuard evict --dry-run
/Applications/ICloudGuard.app/Contents/MacOS/ICloudGuard config show
tail -f ~/.icloud-guard/icloud-guard.log
tail -f ~/.icloud-guard/evictions.log
```

if you built from source with `./scripts/build-app.sh --install`, you can use `~/bin/icloud-guard` instead of the full `/Applications/...` path.

if the cli cannot reach the menu bar app, it falls back to running the engine in-process. if you suspect stale ipc state:

```bash
rm -f ~/.icloud-guard/guard.sock ~/.icloud-guard/icloud-guard.pid ~/.icloud-guard/run.lock
open /Applications/ICloudGuard.app
```

if the app appears to do nothing, check:

- icloud drive is enabled
- optimize mac storage is enabled
- the configured scope points at `~/Library/Mobile Documents/com~apple~CloudDocs`
- protected paths do not cover everything you expect to evict
- `trim_local_gib` is greater than `target_local_gib`; invalid values are normalized, but clear thresholds are easier to reason about

if memory or cpu looks suspicious:

```bash
pgrep -afil 'ICloudGuard|icloud-guard'
ps -axo pid,pcpu,rss,etime,command | grep -i ICloudGuard
vmmap -summary <pid> | grep -E 'Physical footprint|MALLOC|TOTAL'
```

### maintainer release checklist

1. Set `ICloudGuardProduct.version` in `Sources/ICloudGuardCore/ProductInfo.swift`.
2. Test and commit the version change before creating a tag:

```bash
./scripts/test-release.sh
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
git add Sources/ICloudGuardCore/ProductInfo.swift
git commit -m "Release $(./scripts/version.sh)"
test -z "$(git status --porcelain=v1 --untracked-files=all)"
```

3. Create the tag on the committed version source. Then validate that exact tag and commit:

```bash
version=$(./scripts/version.sh)
git tag -a "beta-$version" -m "Beta $version"
test "$(git rev-parse HEAD)" = "$(git rev-parse "beta-$version^{commit}")"
NOTARY_KEYCHAIN_PROFILE=<preconfigured-profile> \
APPLE_TEAM_ID=<expected-10-character-team-id> \
CODESIGN_IDENTITY="Developer ID Application: ..." \
./scripts/release-gate.sh --check --channel beta --tag "beta-$version"
git push origin main
git push origin "beta-$version"
```

Configure a notarization profile before a local release. Hosted workflows create an isolated profile from protected App Store Connect Team API-key secrets. The issuer UUID is required; Individual API keys are not supported. The workflows delete the private key and keychain after the job. The release script accepts a keychain profile and optional keychain path. It never puts the private key contents or an app-specific password in a process argument.

To enable authenticated update-feed output, create a separate P-256 feed-signing key. Do not reuse a Developer ID or notarization key:

```bash
./scripts/update-feed.sh keygen \
  --private-key update-feed-private.pem \
  --public-key update-feed-public-x963-base64.txt
base64 < update-feed-private.pem | tr -d '\n'
```

Store the base64 PEM as the `UPDATE_FEED_PRIVATE_KEY_PEM_BASE64` GitHub Actions secret. Set these repository variables: `UPDATE_FEED_ENABLED=true`, `UPDATE_FEED_ORIGIN`, `UPDATE_FEED_KEY_ID`, and `UPDATE_FEED_PUBLIC_KEY_X963_BASE64`. Use the same public key, key ID, Team ID, channel, and exact channel feed URL in `[updates]`. The stable and beta workflows fail when an enabled value is absent or inconsistent.

External/manual deployment boundary: the workflow copies `feed-v1.json` into the GitHub release as an auditable output. That copy is not the live feed. GitHub publication does not update `UPDATE_FEED_ORIGIN`. The release operator must deploy the signed feed and its exact zip together without cross-origin redirects.

The feed expires after seven days. Refresh, verify, and redeploy it before expiry, even when no new app release exists. Create the refresh from the verified schema-2 release manifest. The producer refuses to overwrite output. Use a new staging directory for each refresh. Run `scripts/update-feed.sh verify` with the configured public key before each deployment.

```bash
version=$(./scripts/version.sh)
artifact="ICloudGuard-$version.zip"
manifest="$artifact.json"
staging_dir=$(mktemp -d "${TMPDIR:-/private/tmp}/icloud-guard-feed.XXXXXX")
generated_at=$(date +%s)
expires_at=$((generated_at + 604800))
./scripts/update-feed.sh create \
  --manifest "$manifest" \
  --artifact "$artifact" \
  --update-origin "$UPDATE_FEED_ORIGIN" \
  --channel stable \
  --team-id "$APPLE_TEAM_ID" \
  --key-id "$UPDATE_FEED_KEY_ID" \
  --private-key update-feed-private.pem \
  --generated-at "$generated_at" \
  --expires-at "$expires_at" \
  --output "$staging_dir/feed-v1.json"
./scripts/update-feed.sh verify \
  --feed "$staging_dir/feed-v1.json" \
  --update-origin "$UPDATE_FEED_ORIGIN" \
  --channel stable \
  --team-id "$APPLE_TEAM_ID" \
  --key-id "$UPDATE_FEED_KEY_ID" \
  --public-key-x963-base64 "$UPDATE_FEED_PUBLIC_KEY_X963_BASE64" \
  --checked-at "$generated_at"
```

Rotate keys in stages. First distribute the new public key and key ID to clients. Then sign feeds with the new private key. Keep the prior origin and feed available until clients have moved. The single-key envelope has no fallback to an unknown key.

4. Wait for the beta release workflow. The workflow must run mandatory shell analysis and strict tests before it imports signing credentials. It must then build, sign, notarize, staple, archive, checksum, and verify the app before publication.
5. Download all three release files: the zip, `.sha256`, and `.json` manifest. Get the expected commit from the pushed tag, not from the downloaded manifest. Verify the checksum and app without executing its binary:

```bash
expected_tag="beta-<version>"
git fetch --tags origin
expected_commit=$(git rev-parse "$expected_tag^{commit}")
shasum -a 256 -c ICloudGuard-beta-<version>.zip.sha256
./scripts/verify-release.sh \
  --expected-tag "$expected_tag" \
  --expected-commit "$expected_commit" \
  --expected-team-id <expected-10-character-team-id> \
  ICloudGuard-beta-<version>.zip.json \
  ICloudGuard-beta-<version>.zip
unzip ICloudGuard-beta-<version>.zip
codesign --verify --deep --strict --verbose=2 ICloudGuard.app
codesign --check-notarization --verbose=4 ICloudGuard.app
codesign -dv --verbose=4 ICloudGuard.app 2>&1 | grep -E 'Authority|TeamIdentifier|Notarization'
```

6. update the tap repo:

```bash
cd ~/homebrew-tap
shasum -a 256 ~/Downloads/ICloudGuard-beta-<version>.zip
$EDITOR Casks/icloud-guard.rb
brew install --cask --dry-run rexbrahh/tap/icloud-guard
git add Casks/icloud-guard.rb
git commit -m "Update iCloud Guard to <version>"
git push
```

homebrew users will then get the update with `brew update && brew upgrade --cask icloud-guard`.

## the menu bar

the dropdown shows:

- **icloud pollution gauge** — a bar showing the ratio of materialized vs dataless files in your icloud drive. 0% = everything evicted (clean). 100% = everything downloaded (polluted). this is the metric that matters, not local disk space. the check uses `lstat` (no content reads, no materialization triggers)
- **defense status** — compact badges showing whether suppression and the watcher are active, plus a running count of re-evictions performed
- **evict now** — evict all materialized icloud files (up to batch limit, default 500)
- **panic evict** — evict everything up to the panic limit (default 2000 files)
- **settings** — or press cmd+, when the popover is open
- **pause/resume** — temporarily stop the watcher, pollution checks, and network-triggered auto-eviction. suppression stays active. click pause to disable the evict buttons, click resume to restart

## cli

icloud guard comes with a full cli that talks to the running menu bar app via a unix domain socket at `~/.icloud-guard/guard.sock`. if the app isn't running, the cli falls back to running the eviction engine in-process.

### installation

the app binary doubles as the cli. homebrew and manual installs can call it directly:

```bash
/Applications/ICloudGuard.app/Contents/MacOS/ICloudGuard --help
```

the `icloud-guard` convenience wrapper is installed automatically when you run `./scripts/build-app.sh --install`:

```bash
~/bin/icloud-guard --help
```

add `~/bin` to your `PATH` if it's not already there.

### subcommands

examples below use the `icloud-guard` wrapper. for homebrew or manual installs, replace `icloud-guard` with `/Applications/ICloudGuard.app/Contents/MacOS/ICloudGuard`.

```bash
icloud-guard status          # show icloud drive status
icloud-guard evict           # evict materialized files
icloud-guard evict --dry-run # preview what would be evicted
icloud-guard panic-evict     # evict everything up to panic limit
icloud-guard reclaim 5GiB    # reclaim an explicit byte goal
icloud-guard explain         # explain the current dry-run plan
icloud-guard doctor          # run read-only diagnostics
icloud-guard doctor --scope work
icloud-guard history list    # list durable run receipts
icloud-guard history show RUN_ID
icloud-guard history export history.csv
icloud-guard watchlist       # inspect pending and fighting files
icloud-guard scope browse    # inspect bounded read-only scope metadata
icloud-guard scope browse --reveal-paths --limit 1000
icloud-guard restore-last    # request local restoration of the last verified run
icloud-guard keep-downloaded # enforce configured keep-downloaded rules
icloud-guard support-bundle support.zip
icloud-guard support-bundle support.zip --scope work
icloud-guard config show     # print current config.toml
icloud-guard doctor --json   # emit one versioned JSON document
icloud-guard update check    # authenticate metadata only
icloud-guard update download # verify one archive; never install it
icloud-guard --version       # print version
icloud-guard --help          # show help
```

### socket

the cli communicates with the running app via a unix domain socket at `~/.icloud-guard/guard.sock`, authenticated with a random token at `~/.icloud-guard/guard.token` (mode 0600). if the socket is unavailable, the cli falls back to in-process execution.

Put `--json` before or after the subcommand. The CLI writes one JSON document to standard output and writes diagnostics to standard error. Every JSON result uses the same outer fields: `schema`, `request_id`, `command`, optional `run_id`, `exit_code`, `status`, optional typed `payload`, and optional typed `error`.

Exit codes follow `sysexits` where applicable: usage `64`, malformed data `65`, unavailable service `69`, I/O or persistence failure `74`, temporary contention `75`, invalid configuration `78`, and cancellation `130`. A partial goal or pending run returns `1`. The `doctor` command returns `78` when a required check fails or is unavailable. Warning-only doctor results return `0`.

On the first successful app start, the menu shows a diagnostics-review banner. Open Settings > Operations, review the read-only checks, and acknowledge the review. The app does not force the review again for the same doctor schema.

## notifications

icloud guard can send local notifications for:

- eviction completion (file count + reclaimed bytes)
- partial failures and pollution thresholds
- fighting or rematerialized files
- restore and keep-downloaded results

Each category has a typed setting. Notification actions can pause the guard or request the last-run restore. The app validates the same mutation lock, scope, type, and identity rules for notification actions as it does for app and CLI actions.

Notifications appear even when the app is in the foreground. Authorize them in System Settings → Notifications → iCloud Guard if prompted.

## acknowledgments

- [howard oakley (eclectic light)](https://eclecticlight.co/) — for documenting the sonoma fileprovider eviction regression and the `com.apple.fileprovider.pinned` xattr mechanism
- [icanhasjonas/icloud-tools](https://github.com/icanhasjonas/icloud-tools) — the cleanest swift cli reference for post-sonoma eviction
- [steipete/trimmy](https://github.com/steipete/Trimmy) — the canonical spm menu bar app packaging pattern
- [ryan cabeen](https://cabeen.io/blog/posts/2026-01-15-icloud-is-not-a-folder.html) — for documenting the phantom file problem and bird daemon internals

## license

mit
