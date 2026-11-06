# Gallery

Wheels and command packs listed in *Settings › Gallery*.

## Add yours

1. Make the wheel in *Settings › Wheel*, then *Share › Export This Wheel…*.
2. Put the `.shakenwheel` file in [`wheels/`](wheels).
3. Add an entry to [`index.json`](index.json):

```json
{
  "id": "my-wheel",
  "name": "My wheel",
  "description": "One sentence on what it's for.",
  "author": "your GitHub name",
  "url": "https://shaken.noxhsxrk.com/gallery/wheels/my-wheel.shakenwheel",
  "icon": "star"
}
```

4. Open a pull request.

Command packs go in `packs` with the https URL of their Git repository.

## What gets accepted

- Wheels that are useful to more people than just you. Avoid personal paths like `/Users/you/...`.
- Scripts kept short and readable. Every script, Shortcut, snippet and key press is shown to the
  user before a wheel is imported, and pack scripts are shown before their first run.
- Nothing that downloads and runs other code, sends data anywhere, or deletes files.
