# Release checklist (real hardware)

The PRD's release criteria. Numbers are defaults to revisit after issues #1–#3.
Automated (✅ in `scripts/test.sh`, plus `scripts/smoke.sh`, which drives the real app through
drop → chip → undo, the shelf, right-click, switching wheels, glass color and Settings) vs. by hand (☐).
Run `SHAKEN_NETWORK_TESTS=1 scripts/test.sh` once before a release to include the download test.

| Area | Criterion | How |
|---|---|---|
| Gesture | 20 shakes per device open the wheel ≥ 18 times without extra keys; 10 min of normal use never opens it | ☐ by hand, mouse and trackpad. Record misses with *Record Gesture Traces* and add them to `Fixtures/` · ✅ trace replay |
| Mis-open | Moving out of the wheel closes it at once; dropping on the original target still works, file intact | ☐ |
| Demo speed | 5 MB HEIC on M1: drop → chip ready ≤ 1 s | ☐ (✅ small HEIC < 1 s in tests) |
| Drag onward | Chip drags into Finder, Safari, Chrome, Slack, Mail | ☐ each app |
| Cancel | Esc stops within 1 s, no partial files | ✅ `cancelStopsWithinASecondAndCleansUp` · ☐ by hand on a big ZIP |
| Undo | Results in Trash, originals intact, refused after edit | ✅ `UndoTests` · ☐ button |
| Drag sources | Files, folders, web images, links, text show matching commands before release | ✅ resolver · ☐ Finder, Safari, Chrome, Photos, Mail |
| Own commands | ≤ 5-line script gets chip, cancel, undo, error text | ✅ `ScriptActionTests` · ☐ in the app |
| Packs | No code runs before approval; 1 byte changed → asks again | ✅ `PackTests` · ☐ dialog |
| Resources | < 1 % average CPU while not dragging | ☐ Activity Monitor, 5 min idle |
| Errors | Damaged image, unwritable folder, name clash: clear message, originals intact, nothing partial left | ✅ `damagedImage…`, `unwritableFolder…`, `neverOverwrites` |
| Install | Opens on a fresh macOS account without Gatekeeper warning, no Xcode | ☐ needs Developer ID + `NOTARY_PROFILE` |
| Shelf | Drop on centre → on shelf; ⌃⌥Space shows tray; tile drags into Finder/Safari/Slack and leaves the shelf; clicking ZIP zips the shelf | ✅ `ShelfTests` · ☐ by hand |
| Every command | Each built-in command runs on a real file and gives a valid result | ✅ `EveryCommandTests`, `ClipboardCommandTests` and the suites above · ☐ Open in Preview, Open link |
| Right-click | Menu names the kind, picking swaps only that slot, choice is saved | ✅ `scripts/smoke.sh` · ☐ menu and Esc by hand |
| Switching wheels | Whole wheel turns; nothing left behind | ✅ `scripts/smoke.sh` · ☐ look by hand |

## Releasing

In order. Repos sit side by side: `shaken`, `shaken-site`, `homebrew-nox`.

1. `scripts/test.sh` (once with `SHAKEN_NETWORK_TESTS=1`) and `scripts/smoke.sh`: all pass.
2. Bump `VERSION` in `scripts/build-app.sh`, add the `CHANGELOG.md` entry, commit `chore: release X.Y.Z`.
3. `scripts/make-dmg.sh` (with `SIGN_IDENTITY` and `NOTARY_PROFILE` once there's a Developer ID).
4. Push, tag `vX.Y.Z`, and `gh release create vX.Y.Z build/Shaken-X.Y.Z.dmg` with the notes ending in
   `SHA-256: <hash>`. The site and the updater read the checksum from that line.
5. **Homebrew:** `scripts/bump-cask.sh`, then `git -C ../homebrew-nox push`. It sets `version` and
   `sha256` in `Casks/shaken.rb` and refuses if the DMG on the release isn't the one you built.
6. **Site:** in `shaken-site`, `scripts/sync-releases.sh`. Delete any DMG it lists as
   "Not in any release", update version text in `public/index.html` if it names one, commit, then
   `npx wrangler deploy`.
7. If `docs/images` changed, `scripts/make-readme-gif.sh` for the GIFs.
