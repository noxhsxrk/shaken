# Shaken

Shake mid-drag, pick a command, drag the result onward.

> **ไทย:** Shaken คือแอปแถบเมนูบน macOS ลากไฟล์แล้วสะบัดเมาส์ วงคำสั่งจะเปิดขึ้นใต้เคอร์เซอร์
> ปล่อยไฟล์ลงช่องที่ต้องการ แล้วผลลัพธ์จะโผล่เป็นชิปให้ลากต่อเข้าแอปถัดไปได้ทันที ย้อนได้ทุกครั้ง
> และเขียนคำสั่งเองได้ด้วยสคริปต์สั้น ๆ แจกฟรี โอเพนซอร์สด้วย MIT

**Main demo:** drag a HEIC photo toward a web form that only takes JPG → shake → drop on
*Convert to JPG* → a chip with the new file appears under the pointer → drag it into the form.

- **Drag onward.** Results become a chip you drag straight into Finder, Safari, Chrome, Slack or Mail.
- **Always undoable.** Esc stops a running job and cleans up; the ↩ button moves results to the Trash
  (never the originals, and not if you edited the result afterwards).
- **Drag anything.** Files, folders, file promises (Photos, Mail, Safari images), links and text.
- **Write your own commands.** A folder with an `action.toml` and a short script gets the chip,
  cancel, undo and error messages for free.

Requires macOS 13 or later. No special permissions (no Accessibility, no sandbox).

## Install

Download the DMG from Releases, drag Shaken to Applications, open it. A hand icon appears in the menu bar.

Build from source (needs Xcode installed, but you never have to open it):

```sh
scripts/build-app.sh          # → build/Shaken.app (universal, ad-hoc signed)
scripts/test.sh               # run the test suite
scripts/make-dmg.sh           # → build/Shaken-<version>.dmg
```

To ship a DMG that opens without a Gatekeeper warning you need an Apple Developer ID:

```sh
xcrun notarytool store-credentials shaken-notary --apple-id you@example.com --team-id TEAMID
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=shaken-notary \
  VERSION=0.1.0 scripts/make-dmg.sh
```

## Using it

| Do this | to |
|---|---|
| Shake while dragging | open the wheel under the pointer |
| Move out of the wheel | close it at once — the drag carries on as normal |
| Rest on a ••• slot | open its submenu; rest on the centre to go back |
| Drop on a slot | run it; a chip shows progress, then the result |
| Esc | cancel a running job, or close the wheel/chip |
| Drag the chip | take the result(s) into the next app |
| ↩ on the chip | move the results to the Trash |
| ⌃⌥Space, menu bar, or ⌥ + shake | open the wheel without dragging (commands act on the clipboard) |

A bare shake without dragging never opens the wheel, because macOS uses that gesture to enlarge the pointer.

### The wheel

Six fixed slots, so your hand learns where things are. Each slot can be:

- **Suggested command** (default) — filled with whatever fits what you're dragging
- **App** — open dropped files or links in it
- **Website** — `{query}` is replaced with the dragged text or link
- **Folder** — copy dropped files into it (undoable)
- **Command** — always this one command
- **Submenu** — up to six more slots, one level deep
- **Empty**

Arrange them in *Settings → Wheel* (drag one slot onto another to swap). *Settings → Commands*
reorders or hides suggested commands per kind of item. *Settings → Gesture* sets sensitivity,
an optional key to hold, apps to ignore and the keyboard shortcut.

### Built-in commands

| Dragged | Suggested slots |
|---|---|
| One HEIC or PNG | Convert to JPG · Shrink below size limit · Remove metadata · Open in Preview · Copy name |
| One JPG | Shrink below size limit · Remove metadata · Make PDF · Open in Preview · Copy name |
| One PDF | Split pages · Open in Preview · Copy name |
| Several items or a folder | Compress to ZIP · Merge into PDF (images/PDFs only) · Copy name |
| A link | Open link · Copy link · Make QR code |
| Text | Save as .txt · Copy text |

### Where results go

- Next to the original, under a free name (`photo.jpg`, `photo 2.jpg`, …). Nothing is ever overwritten.
- If there is no source folder (file promises, links, text) or items come from different folders: `~/Downloads`.
- Work happens in a temporary folder; files are moved into place only when everything succeeded,
  and the temporary folder is removed on error or cancel. You never get half a result.

## Writing a command

One folder = one command. Put it in `~/Library/Application Support/Shaken/Actions/`
(*Settings → Commands → Open Commands Folder*), then press *Reload*.

```toml
# ~/Library/Application Support/Shaken/Actions/web-ready/action.toml
name = "Web ready"
name_th = "เตรียมขึ้นเว็บ"       # optional, per language: name_<code>
icon = "globe"                    # any SF Symbol
accepts = ["public.image"]        # UTIs, or shaken.link / shaken.text / shaken.any
requires = ["cwebp"]              # missing tools show an install hint instead of running
run = "./web-ready.sh"
```

The script gets the dragged files as arguments and writes its results into `$SHAKEN_OUTPUT`.
Exit code ≠ 0 means failure, and whatever it printed to stderr is shown to the user.

```sh
#!/bin/sh
for f in "$@"; do
  cwebp -quiet -q 82 "$f" -o "$SHAKEN_OUTPUT/$(basename "${f%.*}").webp" || exit 1
done
```

| Key | Meaning |
|---|---|
| `name` | Required. Shown on the wheel. |
| `icon` | SF Symbol name. Default `bolt`. |
| `accepts` | Every dragged item must match one entry. Default: anything. |
| `single_accepts` | When exactly one item is dragged, match these instead (e.g. `["public.folder"]`). |
| `min`, `max` | How many items. Default 1 … unlimited. |
| `requires` | Command-line tools that must exist (Homebrew paths are searched too). |
| `install` | Custom install hint. Default `brew install <tools>`. |
| `run` | `./script` inside the folder, or an inline shell command (`"$@"` are the inputs). |
| `steps` | Instead of `run`: a pipeline; each step's output is the next step's input. |

Environment: `SHAKEN_OUTPUT` (write results here), `SHAKEN_KIND` (`files`, `link` or `text`),
`SHAKEN_ACTION_DIR`, and `SHAKEN_TEXT` for text. For links and text, the value is also `$1`.

Built-in steps you can chain: `convert:jpg|png|heic|tiff`, `resize:<px>`, `shrink[:<KB>]`,
`strip-metadata`, `to-pdf`, `merge-pdf`, `split-pdf`, `zip`, `qr`, `save-text`, and — as the last
step only — `open-with:<bundle id>`, `copy-names`, `copy-text`, `open-url`, `reveal`.

```toml
steps = ["resize:1920", "strip-metadata", "./to-webp.sh"]
```

The built-in commands are written in this exact format (see `Sources/ShakenCore/ActionRegistry.swift`),
so community commands can do everything they can. Three examples ship in [`Examples/`](Examples)
and are copied into your commands folder on first launch.

## Command packs from Git

*Settings → Packs*, paste a Git URL, *Install*. A pack is a repo whose sub-folders (or root) contain `action.toml`.

- Installing only downloads files (`git clone` with hooks and submodules disabled). Nothing runs.
- Before a pack command's first run, Shaken shows every file in it and asks. It stores the SHA-256
  of each file you approved; if a single byte changes (or a file is added), it asks again.
- Scripts run as you and can read and change any file you can. Shaken can move and undo only what
  a script writes into `$SHAKEN_OUTPUT`; the approval dialog says so.
- *Remove* deletes the pack and its approvals.

Commands in your own Actions folder are yours and run without asking.

## How it works

```
Action registry ─┐
                 ▼
Gesture detector → Drag reader → Action resolver → Wheel overlay → Job runner → Result chip
```

| Part | File | Notes |
|---|---|---|
| Gesture detector | `ShakenCore/ShakeDetector.swift` | Pure: counts quick direction reversals per axis. Tested by replaying traces. |
| Drag reader | `Shaken/DragReader.swift` | Remembers the drag pasteboard's `changeCount` at mouse-down; a shake opens the wheel only if it changed, so moving windows or selecting text never does. Reads file promises with `NSFilePromiseReceiver` and receives them after the drop. |
| Action resolver | `ShakenCore/ActionResolver.swift` | Filters by type and count, applies per-kind order/hidden, lays out the wheel once per drag. |
| Wheel overlay | `Shaken/Wheel.swift` | Non-activating `NSPanel` registered as a drop target. Other apps own the mouse during a drag, so it polls the button state and pointer distance. |
| Job runner | `ShakenCore/JobRunner.swift` | One runner for Swift steps and scripts. Scripts run in their own process group: cancel sends SIGTERM, then SIGKILL. |
| Result chip | `Shaken/Chip.swift` | Second `NSPanel`, an `NSDraggingSource` with the result file URLs. |
| Settings | `ShakenCore/Settings.swift` | Versioned `Codable` JSON with stable slot ids, validated on load and save. |
| Packs | `ShakenCore/PackManager.swift` | Clone, fingerprint, approve, update, remove. |

Global shortcuts use Carbon `RegisterEventHotKey`, and Esc is registered only while the wheel or chip
is on screen, so no Accessibility permission is needed.

### Gesture traces

`Tests/ShakenCoreTests/Fixtures/*.json` are pointer paths replayed through the detector at several
sensitivities. The current files are synthetic (`scripts/gen-traces.py`). To add real ones, pick
*menu bar → Record Gesture Traces → Shakes · mouse* (or trackpad / normal drags), drag as usual,
then copy the files from *Show Traces Folder* into `Fixtures/`; they're picked up automatically.

## Status

This is the first version from PRD v0.2 (R1–R9). Automated tests cover the gesture detector,
TOML/manifest parsing, the resolver, settings validation, every built-in command, scripts,
cancel, undo and packs. The wheel and the chip have to be tried by hand on a real Mac — see the
release checklist in [`docs/CHECKLIST.md`](docs/CHECKLIST.md).

Not in v1: Windows, many built-in formats, cloud, a shelf, video/Office conversion (call tools
you already have through a command instead), multi-level submenus, Apple Shortcuts, and a pack directory.

## License

MIT
