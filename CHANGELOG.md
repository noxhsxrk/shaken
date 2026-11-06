# Changelog

All notable changes to Shaken. Versions follow [Semantic Versioning](https://semver.org).

## 0.1.0 - 2026-11-06

First release.

### Shake while dragging
- Shake the mouse while dragging a file, folder, photo, link or text, and a six-slot wheel opens under the pointer. Drop on a slot to run it, then drag the result chip straight into the next app. Esc cancels, and undo moves results to the Trash.
- Built-in commands: convert to JPG, PNG, HEIC, AVIF or WebP; shrink below a size limit; resize; rotate; remove metadata; remove background (macOS 14+); extract text or copy text from an image; make, merge, split and compress PDFs; ZIP; rename in bulk with patterns (`{n}`, `{name}`, `{date}`, `{ext}`…); compress video; extract audio; download a link; copy path, name or checksum; QR code; and more.
- Quick Look from the result chip. Shake while dragging the chip or a shelf item to chain another command.
- The shelf: drop on the wheel's centre to park items for later.

### A launcher without dragging
- Open the wheel with a keyboard shortcut you record (⌃⌥Space by default), from the menu bar, or with ⌥ + shake.
- Slots hold apps, files, folders, websites, Apple Shortcuts, shell scripts, AppleScript, text snippets, keyboard shortcuts, system controls, workflows of up to 12 steps, and an app switcher with your most recent apps (with optional window previews).
- Extra wheels and per-app wheels. Flip between them with ⌘← / ⌘→ or a two-finger swipe, and the whole wheel turns like a dial.
- Keyboard control: arrows, Return, and 1–6 to pick a slot.

### Set it up your way
- *Settings → Commands* shows the wheel for each kind of item: click a slot, then pick its command. Or right-click a slot on the open wheel to change it there.
- Glass that follows your Mac's accent color, Shaken blue or any color, with a tint slider.
- A gallery of shared wheels (Media, Screenshots, Web search, System, Photo tools, File tools), `.shakenwheel` import and export, your own commands with `action.toml`, and command packs from Git, with every script shown and approved by SHA-256 before it runs.
- A welcome window, VoiceOver support, and Reduce Motion, Reduce Transparency and Increase Contrast support.
- Updates from shaken.noxhsxrk.com: *Help › Check for Updates* installs the new version in place after checking its SHA-256.
