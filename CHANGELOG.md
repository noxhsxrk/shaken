# Changelog

All notable changes to Shaken. Versions follow [Semantic Versioning](https://semver.org).

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
