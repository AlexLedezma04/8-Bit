# Architecture

```
src/
  main.zig        wires platform + editor + ui
  platform/       OS/SDL boundary: window, renderer, input, clipboard, dialog, pty
                  SDL-free: event (input types), mailbox, fs
  core/           text model: buffer, cursor, edit, undo, newline, search, utf8
  syntax/         highlighting engine; language data lives in assets/grammars
  git/            VCS integration via the git CLI
  terminal/       VT parser + screen grid; pty comes from platform/
  editor/         app state, commands, keymap, view, decoration, config
  ui/
    theme.zig     the color struct; theme files live in assets/themes
    layout.zig    where the parts of the window are; all sizes come from the cell
    widgets/      reusable controls (prompt, lists, tabs, ...)
    panels/       one view per feature (editor_view, status_bar, file_tree, git, terminal)
  font/           bitmap font
assets/           built-in ZON files, embedded in the exe (assets.zig lists them)
  settings.zon    default settings
  keymap.zon      user key bindings (empty: the defaults are in keymap.zig)
  themes/         theme data files
  grammars/       one grammar file per language
tests/            integration tests (unit tests stay next to the code)
tools/            small build helpers (size_check: `zig build size`)
third_party/      vendored C dependencies (SDL3)
```

## Dependency rules

- `platform/` is the only place that touches SDL or OS-specific APIs.
  `event.zig`, `mailbox.zig` and `fs.zig` there are SDL-free and tested.
- `core/`, `syntax/`, `git/`, `terminal/` are SDL-free and unit-testable.
  They may depend on `core/`, never on `editor/` or `ui/`.
- `editor/` owns state and depends on the feature modules. It never calls
  SDL: what only the platform can do (clipboard, dialogs, quit) is returned
  as a `Request`, and `main.zig` carries it out.
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

## Drawing text

- `font/font8x8.zig` holds the glyph bits (ASCII, Latin-1, box drawing; a
  missing character is a small box). `font/bitmap_font.zig` turns them into
  atlas pixels and places the glyphs of a line. Both are SDL-free.
- `platform/renderer.zig` uploads the atlas once and draws all text through
  `drawText`, in batches, tinted with the text color.
- Color values live only in theme files; `ui/theme.zig` defines the struct.
- The main loop sleeps until an event comes, handles all waiting events, and
  draws one frame only if something changed.

## The editor (`editor/`, `ui/`, `main.zig`)

- **Input.** `platform/input.zig` turns SDL events into the plain events of
  `platform/event.zig`. A key press is looked up in the `editor/keymap.zig`
  table and becomes a `Command`; typed text goes to `Editor.typeText`.
- **Commands.** `editor/commands.zig` lists every action and runs it with
  `run(editor, command)`. Keys, mouse and dialogs all end up there. A new
  action is one enum value and one case; its tag name is its text name.
- **View.** `editor/view.zig` knows what is on screen: scroll position, line
  wrap, which text position is under a cell. It works in cells and only
  measures lines near the screen, so file size does not matter.
  `ui/panels/editor_view.zig` only draws what the view says is visible.
- **Decorations.** Selection, and later search matches, git markers and
  blame, are entries in `Editor.decorations` (`editor/decoration.zig`).
  Features add entries; only the editor view draws them.
- **Background work.** A thread hands a result to the main loop with
  `Mailbox.post` (`platform/mailbox.zig`), which wakes the event wait. The
  main thread takes the item and `Editor.receive` frees it. Dialogs use it.
- **Files.** `platform/fs.zig` reads whole files and saves through a
  temporary file and a rename. The buffer keeps the bytes as they are, so
  line endings and the final newline survive a save.
- **Unsaved changes.** The flag comes from the undo history
  (`History.isModified`). Quit and open ask Save / Don't save / Cancel.
- **Messages.** Everything reports through `Editor.notify`; the status bar
  shows the message for a few seconds.
- **Sizes.** `ui/layout.zig` derives every size from the cell size, which is
  the 8x8 font times the zoom (1x to 8x).

## Config (`editor/config.zig`)

- **One loader.** `Loader.load(T, name, base)` reads `name.zon` from the
  user config folder (`platform/fs.zig` `configDir`), else the built-in file
  from `assets/`, and parses it with `std.zon` over `base`: fields the file
  leaves out keep their value. A bad file is reported with `notify` and its
  line, and `base` is kept. `builtin(T, name)` parses a built-in file, which
  must set every field. Feature modules get parsed values, never files.
- A type with `fromZon` is written as that function's argument, so a theme
  color is a hex number.
- **Settings.** `Editor.reloadConfig` loads `settings.zon` and `keymap.zon`
  into one arena and applies them. It runs at start and whenever a file in
  the config folder is saved. `open_settings` opens the user's file, made
  from the built-in one the first time.
- **Themes.** `ui/theme.zig` `load` fills the chosen theme over the built-in
  dark theme. `next_theme` cycles built-in and user themes and writes the
  name into `settings.zon` with `setField`, which keeps the rest of the file.
  The UI loads the theme again when `Editor.config_version` changes.
- **Keys.** `keymap.zon` is a list of `.{ .key = "ctrl+shift+k", .command = "..." }`.
  `keymap.withUser` puts these before the defaults, so they win.

## Tests

- `zig build test` runs unit tests and the integration tests in `tests/`.
- Every SDL-free folder has a `root.zig` that imports all of its files.
  `src/tests.zig` imports only these roots. A new file only needs one line
  in its folder's `root.zig`; a new integration test needs one line in
  `tests/root.zig`.
- `ui/root.zig` and `platform/root.zig` import only their SDL-free files.
- The test build has no SDL, so a test that reaches SDL code fails to build.
  Keep testable logic out of the SDL files of `platform/`, and out of
  `panels/` and `widgets/`.