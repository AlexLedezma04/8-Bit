# Architecture

```
src/
  main.zig        wires platform + editor + ui
  platform/       OS/SDL boundary: window, renderer, input, clipboard, fs, pty
  core/           text model: buffer, cursor, edit, undo, search, utf8
  syntax/         highlighting engine; language data lives in assets/grammars
  git/            VCS integration via the git CLI
  terminal/       VT parser + screen grid; pty comes from platform/
  editor/         app state, commands, keymap, config
  ui/
    theme.zig     colours; theme files live in assets/themes
    layout.zig    workbench docks: sidebar, editor area, bottom panel, status bar
    widgets/      reusable controls (prompt, lists, tabs, ...)
    panels/       one view per feature (editor_view, file_tree, git, terminal)
  font/           bitmap font
assets/
  themes/         theme data files
  grammars/       one grammar file per language
tests/            integration tests (unit tests stay next to the code)
tools/            small build helpers (size_check: `zig build size`)
third_party/      vendored C dependencies (SDL3)
```

## Dependency rules

- `platform/` is the only place that touches SDL or OS-specific APIs.
- `core/`, `syntax/`, `git/`, `terminal/` are SDL-free and unit-testable.
  They may depend on `core/`, never on `editor/` or `ui/`.
- `editor/` owns state and depends on the feature modules.
- `ui/` renders `editor/` state through `platform/renderer.zig`.

## Text model (`core/`)

- `buffer.zig` stores the text as a **gap buffer**: one array with an empty
  gap at the edit position, so typing is cheap. It is the simplest structure
  that is fast for normal editing. Move to a piece table only if the gap
  buffer is measured to be too slow.
- The buffer keeps the start of every line and updates it on each edit.
  Only `\n` ends a line, so LF and CRLF files both work.
- `edit.zig` has `Document`: a buffer, one cursor and the undo history. Every
  text change goes through `Document.apply`, which returns the changed range.
- `undo.zig` only stores changes; `Document` replays them through `apply`.
- One character is one codepoint and one cell. A bad byte is one character.

## Tests

- `zig build test` runs unit tests and the integration tests in `tests/`.
- Every SDL-free folder has a `root.zig` that imports all of its files.
  `src/tests.zig` imports only these roots. A new file only needs one line
  in its folder's `root.zig`; a new integration test needs one line in
  `tests/root.zig`.
- `ui/root.zig` imports only the SDL-free files (`theme`, `layout`).
- The test build has no SDL, so a test that reaches SDL code fails to build.
  Keep testable logic out of `platform/`, `panels/` and `widgets/`.