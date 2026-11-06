# Changelog

All notable changes to Shaken. Versions follow [Semantic Versioning](https://semver.org).

## 0.3.2 - 2026-11-06

### Added
- **Pick commands on the wheel.** *Settings → Commands* now shows the wheel itself: click a slot, then the command it shows. Picking one that's on another slot swaps the two, and nothing else moves.
- **Right-click a slot** on the wheel (opened with your shortcut, the menu bar or the shelf) to change its command right there.
- **Glass color** in *Settings → General*: your Mac's accent color (the default), Shaken blue or any color, with a tint slider and a preview. Text on the selected slot turns dark on light accents.

### Changed
- Switching wheels turns the whole wheel, glass and gaps included, not just what's drawn on it.
- JPGs share the commands list with other images. A JPG order you set before moves over.
- *Running apps* and the app switcher put apps you used before Shaken started in order too, by how close to the front their windows are.
- The Commands tab opens on the kind of item you dragged last.

### Fixed
- Long command names on the wheel wrap to two lines instead of being cut off next to the slot number.
- Commands with Shaken's own icons showed no icon in the Commands list.

## 0.3.1 - 2026-11-06

### Changed
- New tagline: "A little shake. A lot less work." It shows in the README and the installer window.

## 0.3.0 - 2026-11-06

### Added
- **Extract text** and **Copy text from image**: reads the words in photos, screenshots and scanned PDFs.
- **Remove background**: cuts the subject out onto a transparent PNG (macOS 14+).
- **Rotate right** and **Rotate left**, **Convert to PNG** and **Convert to HEIC**.
- **Compress video** to a 720p MP4, and **Extract audio** to M4A.
- **Download file**: drag a link and get the file it points to.
- **Copy path** and **Copy checksum** (SHA-256) for any file.
- **Rename in bulk** with patterns: `{n}`, `{n:3}`, `{name}`, `{date}`, `{date:yyyyMMdd}`, `{ext}`, with buttons for each and a live preview. Taken numbers are skipped.
- **Quick Look** from the result chip: the eye button or a double-click. Video and audio play, and get a play mark on the chip.
- Window previews in the app switcher now work on macOS 13 too.
- Two gallery wheels: **Photo tools** and **File tools**.

### Changed
- The gallery loads from shaken.noxhsxrk.com, so it works for everyone.

## 0.2.2 - 2026-11-06

### Changed
- Switching wheels turns the ring of slots like a dial, around a centre that stays still, instead of moving the whole window. It runs on Core Animation, follows a two-finger swipe, and springs back if you let go early.

## 0.2.1 - 2026-11-06

### Added
- Switching wheels slides: the wheel follows a two-finger swipe, slides on to the next wheel, or springs back if you let go early. ⌘← / ⌘→ slide too. Reduce Motion switches instantly.
- Check for Updates installs the new version in place and relaunches, after checking the download against the release's SHA-256. The daily check asks before installing.

### Changed
- Updates come from shaken.noxhsxrk.com, which also has a new download page where you can pick any version and read its notes.

## 0.2.0 - 2026-11-06

### Added
- New look from the Shaken asset kit: app icon, menu bar icon, 16 command glyphs, and a periwinkle and navy palette across the wheel, chip, shelf tray, Settings and welcome window. The wheel follows the kit's geometry.
- Record any keyboard shortcut to open the wheel, and give each blank wheel its own shortcut.
- Settings › Gallery: shared wheels (Media, Screenshots, Web search, System) and command packs.
- Optional window previews in the app switcher (Screen Recording, macOS 14+).
- Visual workflow editor: cards you drag to reorder, a play button per step, Run All.
- Commands: Convert to AVIF, Convert to WebP, Resize to 1920 px / 1080 px / 50%, Compress PDF, Rename in bulk (with undo).
- Shortcut output and files scripts write to `$SHAKEN_OUTPUT` appear in the chip.
- Shake while dragging the chip or a shelf tile to chain another command.
- Designed installer window.
- Glass wheel: rounded tile corners, translucent gradient surfaces with a light edge, a gradient on the selected slot, and slot numbers shown in click mode. Follows Reduce Transparency and Increase Contrast.
- The shelf is a horizontal strip with thumbnails and names side by side, and the wheel leaves room for it below.

### Fixed
- Choosing App, File or Keyboard shortcut for a slot no longer snaps back to Empty before it's filled in.

## 0.1.1 - 2026-11-06

### Added
- Welcome window on first launch: how to shake, the keyboard, permissions, and a sample photo to try. Reopen it from *Help › Show Welcome*.
- Update check against GitHub Releases, once a day (can be turned off), plus *Help › Check for Updates*.
- *Help › Copy Diagnostics* and *Report a Problem*, which copy version, setup and recent errors for a bug report.
- VoiceOver support for the wheel: each slot is a button with its name.
- Reduce Motion skips the fade-in, and Increase Contrast gives the wheel stronger edges.
- Blank wheels you can name and reorder, in addition to per-app wheels.

### Changed
- Bundle identifier is now `com.noxhsxrk.shaken`. Settings are kept. Re-enable *Open at login* and Accessibility once.
- The wheel preview in Settings is drawn like the real wheel.
- Logging goes to the unified log (Console.app, subsystem `com.noxhsxrk.shaken`).

### Removed
- Unused translation files.

## 0.1.0 - 2026-11-06

First release.

- Shake while dragging to open a six-slot wheel, drop on a slot to run it, then drag the result chip into the next app. Esc cancels; undo moves results to the Trash.
- Built-in commands for images, PDFs, folders, links and text.
- The shelf: drop on the wheel's centre to park items for later.
- A launcher without dragging (⌃⌥Space): apps, files, folders, websites, Apple Shortcuts, shell scripts, AppleScript, text snippets, keyboard shortcuts, system controls, workflows, and an app switcher.
- Per-app wheels, keyboard control, two-finger swipe between wheels.
- Share wheels as `.shakenwheel` files.
- Your own commands with `action.toml`, and command packs from Git with SHA-256 approval.
