# Changelog

All notable changes to Shaken. Versions follow [Semantic Versioning](https://semver.org).

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
