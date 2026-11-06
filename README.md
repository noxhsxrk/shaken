# Shaken

Shake mid-drag, pick a command, drag the result onward.

Shaken is a free, open-source menu-bar app for macOS. While you drag something (a photo, a PDF,
a link, some text), give the mouse a quick shake. A six-slot wheel opens under the pointer.
Drop on a slot and Shaken runs it: it converts the file, opens it in an app, copies it to a folder,
runs a Shortcut or a script. The result appears as a small chip that you can drag straight into
the next app.

Without dragging anything, the same wheel works as a launcher. Press a key and you get your apps,
snippets, keyboard shortcuts, system controls and workflows, all one flick away.

<p align="center">
  <img src="docs/images/wheel-drag.png" width="340" alt="The wheel opened over a dragged photo, with Shrink below size limit highlighted">
</p>

- **Drag onward.** Results land in a chip under the pointer. Drag it into Finder, Safari, Chrome,
  Slack or Mail.
- **Always undoable.** Esc stops a running job and cleans up. The undo button moves results to
  the Trash. It never touches the originals, and leaves a result alone if you edited it afterwards.
- **Drag anything.** Files, folders, file promises (Photos, Mail, Safari images), links and text.
- **More than conversions.** Slots can hold apps, folders, websites, Apple Shortcuts, shell
  scripts, AppleScript, text snippets, key presses, system controls, multi-step workflows and an
  app switcher.
- **A wheel per app.** Safari can get one wheel and Figma another. Flip between wheels with ⌘← and ⌘→.
- **Write your own commands.** A folder with an `action.toml` and a short script gets the chip,
  cancel, undo and error messages for free. Share them as Git packs, and share whole wheels as files.

Requires macOS 13 or later. Free, MIT licensed.

---

## Contents

- [A short walkthrough](#a-short-walkthrough)
- [Install](#install)
- [Opening the wheel](#opening-the-wheel)
- [Controls](#controls)
- [What a slot can do](#what-a-slot-can-do)
- [The shelf](#the-shelf)
- [Wheels per app, and sharing wheels](#wheels-per-app-and-sharing-wheels)
- [Built-in commands](#built-in-commands)
- [Writing a command](#writing-a-command)
- [Command packs from Git](#command-packs-from-git)
- [Permissions](#permissions)
- [How it works](#how-it-works)
- [Development](#development)

---

## A short walkthrough

Five short scenes that show the whole idea, the way a demo video would.

### Scene 1: a HEIC photo, and a form that only takes JPG

1. In Finder, start dragging `IMG_0412.HEIC` toward the upload form in your browser.
2. Halfway there, shake the mouse left and right two or three times. The wheel opens under the pointer.
3. Keep holding the button and slide onto **Convert to JPG**. The slot lights up. Let go.
4. A chip appears where you dropped it, with a spinner while it works. Then it shows
   `IMG_0412.jpg` and the size change, for example 3.1 MB → 1.2 MB.
5. Press on the chip and drag it into the form. The original HEIC is untouched.

<p align="center">
  <img src="docs/images/chip-running.png" width="300" alt="The chip while a command runs">
</p>

Changed your mind? Press the undo button on the chip and the JPG goes to the Trash.
Opened the wheel by accident? Just move out of it. It closes at once and your drag carries on
as if nothing happened.

### Scene 2: park it on the shelf for later

1. You find three screenshots you'll need in a minute, but the place they're going isn't open yet.
2. Drag them, shake, and drop them on the **middle** of the wheel ("Put on shelf").
3. Later, press **⌃⌥Space** anywhere. The wheel opens with the shelf underneath.
4. Drag a tile, or **All 3**, into Slack. Each item leaves the shelf once it's delivered.

<p align="center">
  <img src="docs/images/wheel-shelf.png" width="300" alt="Dropping on the centre of the wheel puts items on the shelf">
  <img src="docs/images/shelf-tray.png" width="420" alt="The shelf tray under the wheel">
</p>

You can also click a slot while the shelf is up. Commands, apps, folders, Shortcuts and scripts
then act on everything on the shelf, for example to zip all of it at once.

### Scene 3: the wheel as a launcher

1. Press **⌃⌥Space** with nothing dragged. The wheel opens under the pointer.
2. Press **→** twice and **Return**, or press **3**, or just click. Calendar opens.
3. Other slots mute the sound, paste your email signature, press `⇧⌘4`, or run a backup script.

<p align="center">
  <img src="docs/images/wheel-click.png" width="340" alt="A wheel with an app, a system control, the app switcher, a script, a key press and a snippet. The centre shows the page name Safari and four dots.">
</p>

### Scene 4: a different wheel in every app

1. In *Settings → Wheel*, choose **Add App Wheel…** and pick Safari. Give it slots for
   *Reader mode* (keys `cmd+shift+r`), *Translate this page* (a Shortcut) and your bookmarks.
2. Back in Safari, press ⌃⌥Space. The Safari wheel opens instead of the main one.
3. Press **⌘←** or **⌘→**, or swipe sideways with two fingers, to flip to the main wheel, to your other app wheels, or to
   **Running apps**: a ring of the apps you used most recently. Arrow to one and press Return to switch.

The bottom of the centre shows which wheel you're on: its name, and one dot per wheel with the
current one highlighted.

### Scene 5: one slice, five steps

A **Workflow** slot runs up to twelve steps in order. A "Start work" slot might:

1. open Slack,
2. open the team board in the browser,
3. run the Shortcut that sets a Focus mode,
4. wait 1 second,
5. press `ctrl+opt+left` to snap the window into place.

Build it in *Settings → Wheel*, reorder steps with the arrows, and press **Run Now** to try it.

When something fails, the chip says what went wrong in plain words and stays until you close it:

<p align="center">
  <img src="docs/images/chip-error.png" width="420" alt="The chip showing an error">
</p>

---

## Install

Download the DMG from Releases, drag Shaken to Applications and open it. A hand icon appears in
the menu bar. There is no Dock icon. Opening Shaken again shows Settings.

To build from source you need Xcode installed, but you never have to open it:

```sh
./build.sh                    # build build/Shaken.app, quit the running copy, open the new one
./build.sh --no-open          # build only
scripts/test.sh               # run the test suite
scripts/make-dmg.sh           # build build/Shaken-<version>.dmg
```

To ship a DMG that opens without a Gatekeeper warning, you need an Apple Developer ID:

```sh
xcrun notarytool store-credentials shaken-notary --apple-id you@example.com --team-id TEAMID
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=shaken-notary \
  VERSION=0.1.0 scripts/make-dmg.sh
```

---

## Opening the wheel

| How | What the wheel works on |
|---|---|
| Shake while dragging | What you're dragging |
| ⌃⌥Space (changeable in *Settings → Gesture*) | The shelf if it has anything, otherwise the clipboard |
| ⌥ + shake, with no button pressed | Same as the shortcut |
| Menu bar → *Open Wheel* | Same as the shortcut |

A shake without dragging and without ⌥ never opens the wheel, because macOS uses that gesture to
make the pointer bigger. The shake only counts while an item is being dragged, so moving windows
and selecting text never trigger it.

## Controls

**While dragging**

| Do this | What happens |
|---|---|
| Drop on a slot | Run it. A chip shows progress, then the result. |
| Drop on the centre | Put the item on the shelf. |
| Rest on a slot marked ••• | Open its submenu. Rest on the centre to go back. |
| Move out of the wheel | Close it. The drag carries on normally. |

**With the wheel open, nothing dragged**

| Key | What it does |
|---|---|
| ← → (or ↑ ↓) | Move around the wheel |
| Return or Space | Pick the highlighted slot |
| 1 – 6 | Pick that slot at once (1 is the top, then clockwise) |
| Delete | Leave a submenu |
| ⌘← ⌘→ (or Tab, ⇧Tab) | Switch between the main wheel, app wheels and *Running apps* |
| Two-finger swipe sideways | The same, on a trackpad or Magic Mouse, with the pointer over the wheel |
| Esc | Close |

These keys belong to Shaken only while the wheel is open.

**The chip**

| Do this | What happens |
|---|---|
| Drag it | Take the result or results into another app |
| Undo button | Move the results to the Trash |
| Esc | Cancel a running job, or close the chip |

---

## What a slot can do

Six fixed slots, so your hand learns where things are. Change them in *Settings → Wheel*
(drag one slot onto another to swap).

| Slot | Click it | Drop on it |
|---|---|---|
| **Suggested command** (default) | Runs on the shelf or clipboard | Filled with whatever fits what you're dragging |
| **Command** | Same, always the same command | Same |
| **App** | Opens or switches to the app | Opens the files or link in it |
| **Folder** | Opens it in Finder | Copies the files into it (undoable) |
| **File** | Opens the file | — |
| **Website** | Opens the page | `{query}` in the address becomes the dragged text or link |
| **Apple Shortcut** | Runs the Shortcut | Runs it with the dragged items as input |
| **Shell script** | Runs the zsh code typed into the slot | Files are `$1`, `$2`…; text is in `$SHAKEN_TEXT` |
| **AppleScript** | Runs the script typed into the slot | Files are passed to `on run argv` |
| **Text snippet** | Pastes the text where you're typing* | — |
| **Keyboard shortcut** | Presses keys such as `cmd+shift+4` in the front app* | — |
| **System control** | Volume, mute, brightness*, play/pause*, next and previous track*, screenshot*, Mission Control, screen saver, dark mode, display off, lock screen*, sleep | — |
| **Workflow** | Runs up to 12 steps in order: apps, links, files, folders, Shortcuts, scripts, snippets, keys, system controls and waits | — |
| **App switcher** | Opens a ring of your six most recent apps | Rest on it, then drop on an app to open the files there |
| **Submenu** | Opens six more slots, one level deep | Rest on it to open |
| **Empty** | — | — |

\* Types into other apps, so it needs Accessibility permission. See [Permissions](#permissions).

Snippets restore your previous clipboard afterwards. Keys can be written as `cmd+shift+4`,
`ctrl+opt+t`, `f5` or `⌃⌥T`. Every slot has a **Run Now** button in Settings so you can try it.

*Settings → Commands* reorders or hides suggested commands for each kind of item.
*Settings → Gesture* sets shake sensitivity, an optional key to hold, apps to ignore and the
keyboard shortcut.

---

## The shelf

The shelf is a place to park things between apps.

- **To add:** drag, shake, drop on the centre of the wheel.
- **To use:** open the wheel without dragging. The shelf appears underneath. Drag a tile, or
  *All*, into another app; a delivered item leaves the shelf. Or click a slot to act on the
  whole shelf.
- **To remove:** the × on a tile, *Clear* in the tray, or *Clear Shelf* in the menu bar.

Files stay where they are. The shelf only remembers them, and forgets files that were moved or
deleted. Things that aren't files yet (file promises from Photos, images from Safari) are saved
under `~/Library/Application Support/Shaken/Shelf` and cleaned up on the next launch once nothing
points to them.

When the shelf is empty, the wheel works on the clipboard. Commands that would only copy the
clipboard back to itself are left out, and empty suggestion slots become shortcuts to Downloads
and Desktop.

---

## Wheels per app, and sharing wheels

**Per-app wheels.** In *Settings → Wheel*, **Add App Wheel…** gives an app its own six slots. It
replaces the main wheel when that app is in front and you open the wheel without dragging.
Drags always use the main wheel, so your hand never has to relearn it. Press ⌘← or ⌘→ to reach
the other wheels; the dots in the centre show where you are.

**Sharing.** *Settings → Wheel → Share* exports the wheel you're editing as a `.shakenwheel`
file. It can also import one from a file or an https link. Before anything is imported, Shaken
lists every script, Shortcut, snippet and key press in it, so you can see exactly what it would
do. A wheel made for one app offers to install as that app's wheel.

---

## Built-in commands

| Dragged | Suggested |
|---|---|
| One HEIC or PNG | Convert to JPG, Shrink below size limit, Remove metadata, Open in Preview, Copy name |
| One JPG | Shrink below size limit, Remove metadata, Make PDF, Open in Preview, Copy name |
| One PDF | Split pages, Open in Preview, Copy name |
| Several items or a folder | Compress to ZIP, Merge into PDF (images and PDFs only), Copy name |
| A link | Open link, Copy link, Make QR code |
| Text | Save as .txt, Copy text |

**Where results go**

- Next to the original, under a free name (`photo.jpg`, `photo 2.jpg`, …). Nothing is ever overwritten.
- If there is no source folder (file promises, links, text), or the items come from different
  folders, results go to `~/Downloads`.
- Work happens in a temporary folder. Files move into place only when every step succeeded, and
  the temporary folder is removed on error or cancel. You never get half a result.

---

## Writing a command

One folder is one command. Put it in `~/Library/Application Support/Shaken/Actions/`
(*Settings → Commands → Open Commands Folder*), then press *Reload*.

```toml
# ~/Library/Application Support/Shaken/Actions/web-ready/action.toml
name = "Web ready"
icon = "globe"                    # any SF Symbol
accepts = ["public.image"]        # UTIs, or shaken.link / shaken.text / shaken.any
requires = ["cwebp"]              # missing tools show an install hint instead of running
run = "./web-ready.sh"
```

The script gets the dragged files as arguments and writes its results into `$SHAKEN_OUTPUT`.
A non-zero exit code means it failed, and whatever it printed to stderr is shown in the chip.

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
| `min`, `max` | How many items. Default 1 to unlimited. |
| `requires` | Command-line tools that must exist. Homebrew paths are searched too. |
| `install` | Custom install hint. Default `brew install <tools>`. |
| `run` | `./script` inside the folder, or an inline shell command (`"$@"` are the inputs). |
| `steps` | Instead of `run`: a pipeline where each step's output is the next step's input. |

Environment: `SHAKEN_OUTPUT` (write results here), `SHAKEN_KIND` (`files`, `link` or `text`),
`SHAKEN_ACTION_DIR`, and `SHAKEN_TEXT` for text. For links and text the value is also `$1`.

Built-in steps you can chain: `convert:jpg|png|heic|tiff`, `resize:<px>`, `shrink[:<KB>]`,
`strip-metadata`, `to-pdf`, `merge-pdf`, `split-pdf`, `zip`, `qr`, `save-text`. These can only
be the last step: `open-with:<bundle id>`, `copy-names`, `copy-text`, `open-url`, `reveal`.

```toml
steps = ["resize:1920", "strip-metadata", "./to-webp.sh"]
```

The built-in commands are written in this same format (see `Sources/ShakenCore/ActionRegistry.swift`),
so your commands can do everything they can. Three examples ship in [`Examples/`](Examples) and
are copied into your commands folder on first launch.

For a quick one-off, a **Shell script** slot on the wheel is often enough: no folder, no manifest.
Use a command when you want the chip, undo and file placement.

---

## Command packs from Git

*Settings → Packs*: paste a Git URL and press *Install*. A pack is a repository whose sub-folders
(or root) contain `action.toml`.

- Installing only downloads files (`git clone` with hooks and submodules disabled). Nothing runs.
- Before a pack command's first run, Shaken shows every file in it and asks. It stores the SHA-256
  of each approved file. If a single byte changes, or a file is added, it asks again.
- Scripts run as you and can read and change any file you can. Shaken can move and undo only
  what a script writes into `$SHAKEN_OUTPUT`, and the approval dialog says so.
- *Remove* deletes the pack and its approvals.

Commands in your own Actions folder are yours and run without asking.

---

## Permissions

| Feature | Needs |
|---|---|
| Shaking a drag, the wheel, chip, shelf, commands, apps, folders, websites, Shortcuts, scripts | Nothing |
| Text snippets, keyboard shortcuts; brightness, media keys, screenshot and lock screen | Accessibility, asked the first time you use one |
| The *Dark mode* system control | Permission to control System Events, asked once |

Shaken watches the mouse with a standard event monitor and reads the drag only after you shake.
Global keys use Carbon `RegisterEventHotKey`, which needs no permission.

---

## How it works

```
Action registry ─┐
                 v
Gesture detector -> Drag reader -> Action resolver -> Wheel overlay -> Job runner -> Result chip
```

| Part | File | Notes |
|---|---|---|
| Gesture detector | `ShakenCore/ShakeDetector.swift` | Counts quick direction reversals per axis. Tested by replaying recorded pointer paths. |
| Drag reader | `Shaken/DragReader.swift` | Compares the drag pasteboard's `changeCount` at mouse-down and at the shake, so only real drags count. Receives file promises after the drop. |
| Action resolver | `ShakenCore/ActionResolver.swift` | Filters by type and count, applies per-kind order, lays out the wheel once per drag so slots never move. |
| Wheel overlay | `Shaken/Wheel.swift` | Non-activating `NSPanel` registered as a drop target. Other apps own the mouse during a drag, so it polls the button state. |
| Job runner | `ShakenCore/JobRunner.swift` | Runs Swift steps and scripts. Scripts get their own process group: cancel sends SIGTERM, then SIGKILL. |
| Result chip | `Shaken/Chip.swift` | A second panel that is an `NSDraggingSource` for the result files. |
| Shelf | `ShakenCore/Shelf.swift`, `Shaken/ShelfTray.swift` | Items kept by reference in a JSON file. |
| Slot actions | `ShakenCore/Shortcuts.swift`, `InlineScript.swift`, `KeyCombo.swift`, `SystemControl.swift`, `Shaken/Typing.swift` | Shortcuts through `/usr/bin/shortcuts`, scripts through zsh and `osascript`, keys through `CGEvent`. |
| Settings | `ShakenCore/Settings.swift`, `WheelPreset.swift` | Versioned `Codable` JSON with stable slot ids, validated on load, save and import. |
| Packs | `ShakenCore/PackManager.swift` | Clone, fingerprint, approve, update, remove. |

---

## Development

```sh
scripts/test.sh                                 # the test suite
SHAKEN_SNAPSHOT=/tmp/snap .build/debug/Shaken   # render the wheel, tray and chip to PNGs and exit
```

The tests cover the gesture detector, manifest parsing, the resolver, settings validation, every
built-in command, scripts, cancel, undo, packs, key combos and wheel presets. The README images
come from the snapshot mode.

**Gesture traces.** `Tests/ShakenCoreTests/Fixtures/*.json` are pointer paths replayed through
the detector at several sensitivities. The current files are synthetic (`scripts/gen-traces.py`).
To add real ones, choose *menu bar → Record Gesture Traces*, drag as usual, then copy the files
from *Show Traces Folder* into `Fixtures/`. They're picked up automatically.

**Status.** Built from PRD v0.2 (R1–R9). The shelf, the launcher slot kinds, per-app wheels and
wheel sharing were added on top of it. The wheel, chip and tray still need a hand test on a real
Mac. See [`docs/CHECKLIST.md`](docs/CHECKLIST.md).

## License

MIT
