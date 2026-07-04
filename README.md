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

the right apis, used properly:

- **[`FileManager.evictUbiquitousItem(at:)`](https://developer.apple.com/documentation/foundation/filemanager/evictubiquitousitem(at:))** — the only eviction api that works from a non-extension process. [`NSFileProviderManager(for: domain)`](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager) returns nil when called from a process that isn't the file provider extension itself (verified on macos 26.5.1), so `evictItem(identifier:)` is not available to us
- **leaf-first package eviction** — for packages like `.fcpbundle`, evicts individual child files before the package root, avoiding the atomic `EBUSY` failure that occurs when any child has an open file descriptor. apple's [`evictItem` documentation](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/evictitem(identifier:completionhandler:)) confirms: "if a non-evictable child is encountered, eviction will stop immediately"
- **`SF_DATALESS` verification** — uses [`lstat(2)`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/lstat.2.html) to check the apfs `SF_DATALESS` flag (`0x40000000`) post-eviction. a truly dataless file has `st_blocks == 0` (zero allocated disk blocks) while `st_size > 0` (nonzero logical size)

### layer 3: active defense (watch + re-evict)

detects and reverses rematerialization within seconds:

- **[`NSMetadataQuery`](https://developer.apple.com/documentation/foundation/nsmetadataquery) watcher** — scoped to `NSMetadataQueryUbiquitousDocumentsScope`, monitors `ubiquitousItemDownloadingStatus` changes. when an evicted item transitions from `.notDownloaded` to `.current` or `.downloaded`, it immediately re-evicts
- **exponential backoff** — starts at 1s delay, doubles up to 60s max, resets when stable for 5 minutes. prevents fighting `fileproviderd` in a tight cpu-burning loop

### layer 4: system mitigation

aggressive last-resort measures:

- **[`pauseSync(forUbiquitousItem:)`](https://developer.apple.com/documentation/foundation/filemanager/pausesyncforubiquitousitem(at:))** on individual leaf files inside packages (can't pause on package directories — apple explicitly restricts this to non-package items)
- the watcher handles re-eviction as the primary defense

## what it doesn't do

- it cannot stop cloudkit push notifications from your iphone (server-side, no user toggle)
- it cannot disable the trial system's speculative download namespace (`COREOS_FPFS_SPECULATIVE_DOWNLOADS`)
- it cannot stop finder from holding background enumerators on the icloud root
- it cannot set [`NSFileProviderContentPolicy.downloadLazily`](https://developer.apple.com/documentation/fileprovider/nsfileprovideritem/contentpolicy) on items (read-only from outside the file provider extension)

what it _can_ do: eliminate the spotlight trigger, eliminate the quicklook trigger, make the guard's own reads non-materializing, and reverse rematerialization within seconds instead of minutes. the net effect is dramatically less local disk usage and fewer cpu-burning download/evict cycles.

## installation

### from source

```bash
git clone https://github.com/rexliu/icloud-guard.git
cd icloud-guard
./scripts/build-app.sh --release --install
open ~/Applications/ICloudGuard.app
```

### requirements

- macos 14+ (sonoma or later — required for `@Environment(\.openSettings)`)
- swift 5.10+ (xcode 15+)
- icloud drive enabled
- "optimize mac storage" turned on in system settings → apple id → icloud

### config

the app reads a toml config at `~/.icloud-guard/config.toml`. if it doesn't exist, defaults are used. no json anywhere.

```toml
[suppression]
spotlight = true
quicklook = true
materialize_dataless = false

[eviction]
batch_limit = 500
panic_limit = 2000

[watcher]
backoff_max_seconds = 60
pollution_check_interval_seconds = 300

[scope]
path = "~/Library/Mobile Documents/com~apple~CloudDocs"

[policy]
target_local_gib = 30
trim_local_gib = 35
warn_free_gib = 80
remediate_free_gib = 50
panic_free_gib = 25
cooldown_minutes = 30
growth_trigger_gib = 20
growth_window_minutes = 10
```

all app files live under `~/.icloud-guard/` — config, logs, future state. nothing in `~/Library/Application Support/` or `~/Library/Logs/`.

### gh releases

tip and beta releases are available in this repo. tip releases are built from every tip commit that lands on main that passes CI, builds and gets packaged successfully. beta releases are more polished, sporadic, when i think it's good enough for a certain standard with respect to goals i set for myself on this tool. you can find them in releases in this gh repo.

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

the cli wrapper is installed automatically when you run `./scripts/build-app.sh --install`:

```bash
~/bin/icloud-guard --help
```

add `~/bin` to your `PATH` if it's not already there.

### subcommands

```bash
icloud-guard status          # show icloud drive status
icloud-guard evict           # evict materialized files
icloud-guard evict --dry-run # preview what would be evicted
icloud-guard panic-evict     # evict everything up to panic limit
icloud-guard config show     # print current config.toml
icloud-guard --version       # print version
icloud-guard --help          # show help
```

### socket

the cli communicates with the running app via a unix domain socket at `~/.icloud-guard/guard.sock`, authenticated with a random token at `~/.icloud-guard/guard.token` (mode 0600). if the socket is unavailable, the cli falls back to in-process execution.

## notifications

icloud guard sends local notifications for:

- eviction completion (file count + reclaimed bytes)
- rematerialization detected (file path)
- pollution threshold crossing (>70%)

notifications appear even when the app is in the foreground. authorize them in system settings → notifications → icloud guard if prompted.
## acknowledgments

- [howard oakley (eclectic light)](https://eclecticlight.co/) — for documenting the sonoma fileprovider eviction regression and the `com.apple.fileprovider.pinned` xattr mechanism
- [icanhasjonas/icloud-tools](https://github.com/icanhasjonas/icloud-tools) — the cleanest swift cli reference for post-sonoma eviction
- [steipete/trimmy](https://github.com/steipete/Trimmy) — the canonical spm menu bar app packaging pattern
- [ryan cabeen](https://cabeen.io/blog/posts/2026-01-15-icloud-is-not-a-folder.html) — for documenting the phantom file problem and bird daemon internals

## license

mit
