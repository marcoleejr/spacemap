# Contributing to SpaceMap

Small, focused PRs are easiest to review. One change per PR.

## Ground rules

- The app never deletes files: Move to Trash only, always confirmed.
- The scanner never follows symlinks and never crosses volume boundaries.
- No networking, no analytics, no secrets in the repo.
- All user-visible strings go through `Sources/SpaceMap/Resources/Localizable.xcstrings`
  (edit via `scripts/strings.py`, never by hand-editing generated files):
  `python3 scripts/strings.py generate`, then add the missing translations for
  all six locales (`en`, `es`, `pt`, `fr`, `de`, `ja`).
- Keep the visual world original: no borrowed palettes, marks, or layouts.
  After UI changes, capture a real screenshot and compare against the previous
  one before calling it done.

## Checks

```sh
swift build
swift test          # must stay green (includes catalog coverage)
scripts/build-app.sh
```

## Screenshots

Real captures only (never mockups): find the app window with
`CGWindowListCopyWindowInfo` in a Swift snippet, then
`screencapture -x -o -l <window-id> docs/screens/<name>.png`.
