yeah well, this was initially just a script in my nix-darwin repo where each nix-darwin switch builds a simple swift binary that launchd manages to reactively prune icloud storage when it goes berserk and trying to fill your mac so you upgrade.

a deep investigation of the root cause surfaced that apple has this speculative download enabled in a private framework on macos and on icloud infra server-side they do a CloudKit push every single time even just a single thing, doesnt matter if it's just metadata, changes, on any one of your devices connected under your icloud account, so it triggers a rematerialization attempt and downstream speculative downloading on macos tries to fetch the update and rematerialize a local copy, that's why sometimes you go to bed and you wake up and you see your mac becomes extremely sluggish and you find out you only have 10gb free disk space on your 512gb macbook.

it also doesnt help that both spotlight indexing service and finder app both run an eager enumerator on icloud root on mac so nothing regarding icloud, on your mac, ever truly rests even if you barely even touch it.

there are threads of multiple people on forums with the same problem and even official discussions with an apple engineer acknowledging the issue but commented that they will not fix it. for whatever reason. fine.

so i built this fix.
