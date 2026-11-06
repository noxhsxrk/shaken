# Release checklist (real hardware)

The PRD's release criteria. Numbers are defaults to revisit after issues #1–#3.
Automated (✅ in `scripts/test.sh`) vs. by hand (☐).

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
