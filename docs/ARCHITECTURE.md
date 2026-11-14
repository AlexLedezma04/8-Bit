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

## Tests

- `zig build test` runs unit tests and the integration tests in `tests/`.
- Every SDL-free folder has a `root.zig` that imports all of its files.
  `src/tests.zig` imports only these roots. A new file only needs one line
  in its folder's `root.zig`; a new integration test needs one line in
  `tests/root.zig`.
- `ui/root.zig` imports only the SDL-free files (`theme`, `layout`).
- The test build has no SDL, so a test that reaches SDL code fails to build.
  Keep testable logic out of `platform/`, `panels/` and `widgets/`.