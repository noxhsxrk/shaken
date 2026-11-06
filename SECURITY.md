# Security

Shaken runs code you choose: commands from your Actions folder, command packs from Git, and
shell or AppleScript typed into a slot. Those run as you and can read and change any file you
can. Shaken tries hard to make sure you only run what you've seen:

- Installing a pack only downloads it (`git clone` with hooks and submodules disabled). Nothing runs.
- Before a pack command's first run, every file in it is shown, and the SHA-256 of each file is
  stored when you approve. Any change, or a new file, asks again.
- Importing a shared wheel lists every script, Shortcut, snippet and key press in it first.
- Shaken has no network access of its own, except `git` for packs, downloading a wheel from a
  link you paste, and a daily check of shaken.noxhsxrk.com/releases.json for a new version (which you can turn off).
- Updates are only installed after the downloaded DMG matches the SHA-256 published with the release, and the app inside has Shaken's bundle identifier. The old copy goes to the Trash.

## Reporting a vulnerability

Please don't open a public issue. Use GitHub's private reporting instead:
**Security › Report a vulnerability** on https://github.com/noxhsxrk/shaken.

Include what you found, how to reproduce it, and the Shaken and macOS versions
(*Help › Copy Diagnostics* gathers them). You'll get a reply within a week.

Things that are in scope: approval being skipped or bypassed, a pack or shared wheel running code
without being shown, files outside a command's output being moved or deleted, and anything that
lets another app or website make Shaken run code.
