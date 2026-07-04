# iCloud Guard

yeah well, this was initially just a script in my [nix-darwin](https://github.com/nix-darwin/nix-darwin) repo where each `nix-darwin switch` builds a simple swift binary that [launchd](https://en.wikipedia.org/wiki/Launchd) manages to reactively prune icloud storage when it goes berserk and trying to fill your mac so you upgrade.

a deep investigation of the root cause surfaced that apple has this speculative download enabled in a private framework on macos and on icloud infra server-side they do a [CloudKit](https://developer.apple.com/documentation/cloudkit) push every single time even just a single thing, doesnt matter if it's just metadata, changes, on any one of your devices connected under your icloud account, so it triggers a rematerialization attempt and downstream speculative downloading on macos tries to fetch the update and rematerialize a local copy, that's why sometimes you go to bed and you wake up and you see your mac becomes extremely sluggish and you find out you only have 10gb free disk space on your 512gb macbook.

the actual mechanism, traced from system logs, goes like this:

1. your iphone (or any device) changes a file in icloud — even just metadata
2. apple's [cloudkit](https://developer.apple.com/documentation/cloudkit) sends a push notification to your mac — the logs show `sync down (push triggered)` → `ckfetchrecordzonechangesoperation`
3. the [`bird`](https://eclecticlight.co/2023/11/21/icloud-drive-in-sonoma-fileprovider-and-eviction/) daemon (the icloud sync engine) processes the push and sees `itemchangedremotely`
4. [`fileproviderd`](https://developer.apple.com/documentation/fileprovider) schedules a `fetch-content` job with `why:materialization|itemchangedremotely` — this is the speculative download
5. the file is rematerialized on disk, even though literally nobody asked for it

this speculative download behavior is controlled by apple's [trial (a/b testing) system](https://developer.apple.com/documentation/technotes/tn3150-getting-ready-for-data-less-files) under a namespace called `coreos_fpfs_speculative_downloads` — meaning apple can turn it on or off per user from their servers, without any macos update, and without your consent or knowledge. there is no user-facing toggle for this. you can't turn it off in system settings. you can't turn it off with a defaults write command. it just is.

it also doesnt help that both [spotlight](https://support.apple.com/guide/mac-help/spotlight-mchlp1008/mac) indexing service and [finder](https://en.wikipedia.org/wiki/Finder_(software)) app both run an eager enumerator on icloud root on mac so nothing regarding icloud, on your mac, ever truly rests even if you barely even touch it. the `fileproviderctl dump` output shows spotlight holding an active enumerator on `icloud/root` and finder holding enumerators on the file system and trash — both of which can trigger materialization of [dataless files](https://developer.apple.com/documentation/technotes/tn3150-getting-ready-for-data-less-files) (evicted files that exist as apfs stubs with the `sf_dataless` flag, `0x40000000`).

there are threads of multiple people on forums with the same problem:

- [apple developer forums](https://developer.apple.com/forums/thread/817068) — `evictubiquitousitem` returning `ebusy` on packages
- [eclectic light (howard oakley)](https://eclecticlight.co/2023/11/21/icloud-drive-in-sonoma-fileprovider-and-eviction/) — documenting the sonoma fileprovider eviction regression and quicklook re-materialization bug
- [apple support communities](https://discussions.apple.com/thread/254698327) — `fileproviderd` eating 95%+ cpu permanently
- [creative cow forums](https://community.creativecow.net/) — fcp editors documenting `.fcpbundle` corruption and redownload in icloud drive

and even official discussions with an apple engineer acknowledging the issue but commented that they will not fix it. for whatever reason. fine.

so i built this fix.

## what it does

icloud guard is a macos menu bar app that runs four layers of defense against icloud's rematerialization problem:

### layer 1: download suppression (proactive)

stops the triggers before they happen:

- **spotlight suppression** — drops a `.metadata_never_index` marker in the icloud drive root so spotlight stops indexing the [fileprovider working set](https://developer.apple.com/documentation/fileprovider/nsfileprovideritem), which prevents metadata reads from triggering materialization of dataless files
- **quicklook cache clearing** — runs `qlmanage -r cache` before eviction to prevent quicklook thumbnail generation from immediately re-materializing evicted packages (this is the [known bug](https://eclecticlight.co/2023/11/21/icloud-drive-in-sonoma-fileprovider-and-eviction/) where "no sooner is the file evicted, but as its quicklook thumbnail has to be displayed in the finder, it's immediately materialised for that purpose")
- **non-materializing i/o policy** — sets [`setiopolicynp`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/setiopolicy_np.3.html) on the guard process itself so its own metadata reads don't trigger downloads, equivalent to the [`materializedatalessfiles: false`](https://www.manpagez.com/man/5/launchd.plist/) launchd key

### layer 2: correct eviction

the right apis, used properly:

- **[`filemanager.evictubiquitousitem(at:)`](https://developer.apple.com/documentation/foundation/filemanager/evictubiquitousitem(at:))** — the only eviction api that works from a non-extension process ([`nsfileprovidermanager.evictitem(identifier:)`](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/evictitem(identifier:completionhandler:)) returns nil for non-extension processes, verified on macos 26.5)
- **leaf-first package eviction** — for packages like `.fcpbundle`, evicts individual child files before the package root, avoiding the atomic `ebusy` failure that occurs when any child has an open file descriptor
- **`sf_dataless` verification** — uses [`lstat`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/lstat.2.html) to verify the apfs `sf_dataless` flag (`0x40000000`) is set post-eviction, confirming the file is truly dataless

### layer 3: active defense (watch + re-evict)

detects and reverses rematerialization within seconds:

- **[`nsmetadataquery`](https://developer.apple.com/documentation/foundation/nsmetadataquery) watcher** — scoped to `nsmetadataqueryubiquitousdocumentsscope`, monitors `ubiquitousitemdownloadingstatus` changes. when an evicted item transitions from `.notdownloaded` to `.current` or `.downloaded`, it immediately re-evicts
- **exponential backoff** — starts at 1s delay, doubles up to 60s max, resets when stable for 5 minutes. prevents fighting `fileproviderd` in a tight cpu-burning loop

### layer 4: system mitigation

aggressive last-resort measures:

- **[`pausesyncforubiquitousitem`](https://developer.apple.com/documentation/foundation/filemanager/pausesyncforubiquitousitem(at:))** on individual leaf files inside packages (can't pause on package root — apple restriction)
- the watcher handles re-eviction as the primary defense

## what it doesn't do

- it cannot stop cloudkit push notifications from your iphone (server-side, no user toggle)
- it cannot disable `fileproviderd`'s speculative download trial system (`coreos_fpfs_speculative_downloads`)
- it cannot stop finder from holding background enumerators on the icloud root
- it cannot set `nsfileprovidercontentpolicy.downloadlazily` on items (read-only from outside the extension)

what it *can* do: eliminate the spotlight trigger, eliminate the quicklook trigger, make the guard's own reads non-materializing, and reverse rematerialization within seconds instead of minutes. the net effect is dramatically less local disk usage and fewer cpu-burning download/evict cycles.

## installation

### from source

```bash
git clone https://github.com/rexliu/icloud-guard.git
cd icloud-guard
./scripts/build-app.sh --release --install
open ~/Applications/ICloudGuard.app
```

### requirements

- macos 13+ (ventura or later)
- swift 5.10+ (xcode 15+)
- icloud drive enabled
- "optimize mac storage" turned on in system settings → apple id → icloud

### config

the app reads a toml config at `~/Library/Application Support/ICloudGuard/config.toml`. if it doesn't exist, defaults are used. no json anywhere.

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
```

## the menu bar

the dropdown shows:

- **icloud pollution gauge** — a bar showing the ratio of materialized vs dataless files in your icloud drive. 0% = everything evicted (clean). 100% = everything downloaded (polluted). this is the metric that matters, not local disk space.
- **defense status** — compact badges showing whether suppression and the watcher are active, plus a running count of re-evictions performed
- **evict now** — evict all materialized icloud files (up to batch limit)
- **panic evict** — evict everything up to the panic limit (2000 files by default)
- **settings** — or press cmd+, when the popover is open

## ci/cd

- **`main` branch** — build + test on every push
- **`v*` tags** — auto-create a github release with the `.app` bundle
- **`tip` branch** — every passing commit auto-replaces the tip prerelease
- **`beta` branch** — date+build-time versioned prereleases (e.g. `2026.704.50312` for july 4th, 5:03:12 am)

## acknowledgments

- [howard oakley (eclectic light)](https://eclecticlight.co/) — for documenting the sonoma fileprovider eviction regression and the `com.apple.fileprovider.pinned` xattr mechanism
- [icanhasjonas/icloud-tools](https://github.com/icanhasjonas/icloud-tools) — the cleanest swift cli reference for post-sonoma eviction
- [steipete/trimmy](https://github.com/steipete/Trimmy) — the canonical spm menu bar app packaging pattern
- [ryan cabeen](https://cabeen.io/blog/posts/2026-01-15-icloud-is-not-a-folder.html) — for documenting the phantom file problem and bird daemon internals

## license

mit
