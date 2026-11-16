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
  editor/         app state: files, panes and tabs, commands, keymap, view,
                  decoration, config
  ui/
    canvas.zig    what the UI draws on; the renderer implements it
    panel.zig     the interface every panel follows
    workbench.zig the whole window: places panels, routes input, focus
    theme.zig     the color struct; theme files live in assets/themes
    layout.zig    where the parts of the window are; all sizes come from the cell
    widgets/      reusable controls (list, tabs, prompt)
    panels/       one view per feature (editor_view, file_tree, messages, status_bar, ...)
  font/           bitmap font
assets/           built-in ZON files, embedded in the exe (assets.zig lists them)
  settings.zon    default settings
  keymap.zon      user key bindings (empty: the defaults are in keymap.zig)
  themes/         theme data files
  grammars/       one grammar file per language (docs/GRAMMARS.md)
tests/            integration tests (unit tests stay next to the code)
tools/            small build helpers (size_check: `zig build size`,
                  embed_dir: embeds every grammar file)
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
- `ui/` renders `editor/` state on a `Canvas` (`ui/canvas.zig`), which
  `platform/renderer.zig` implements. So `ui/` has no SDL and is tested.

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

- `font/spleen.zig` holds the glyph bits of the 8x16 Spleen font (ASCII,
  Latin-1, box drawing, blocks; a missing character is a small box). `font/bitmap_font.zig` turns them into
  atlas pixels and places the glyphs of a line. Both are SDL-free.
- `platform/renderer.zig` uploads the atlas once and draws all text through
  `drawText`, in batches, tinted with the text color.
- Color values live only in theme files; `ui/theme.zig` defines the struct.
- The main loop sleeps until an event comes, handles all waiting events, and
  draws one frame only if something changed.

## The editor (`editor/`, `ui/`, `main.zig`)

- **Input.** `platform/input.zig` turns SDL events into the plain events of
  `platform/event.zig`, and `main.zig` hands them to `ui/workbench.zig`. A
  key goes to the prompt if it is open, else to the focused panel, else it
  is looked up in the `editor/keymap.zig` table and becomes a `Command`.
- **Panels.** The sidebar (file tree), the editor area and the bottom panel
  (messages) follow `ui/panel.zig`: `title`, `draw(rect)` and `handle(event)`.
  One area has focus; a click gives focus. The workbench draws and routes
  without knowing what a panel is.
- **Files, panes and tabs.** `Editor.files` holds the open files
  (`editor/file.zig`: document, path, time on disk). The editor area is a
  tree of splits (`editor/panes.zig`) whose leaves are panes of tabs. A tab
  is one view of a file with its own cursor and scroll. The active tab uses
  the document's cursor; the other tabs register theirs with
  `Document.follow`, and `apply` moves them on every change.
- **Changes on disk.** When the window gets focus, `Editor.checkDisk` reloads
  files that changed, or asks first when they have unsaved changes.
- **Commands.** `editor/commands.zig` lists every action and runs it with
  `run(editor, command)`. Keys, mouse and dialogs all end up there. A new
  action is one enum value and one case; its tag name is its text name.
- **View.** `editor/view.zig` knows what is on screen: scroll position, line
  wrap, which text position is under a cell. It works in cells and only
  measures lines near the screen, so file size does not matter.
  `ui/panels/editor_view.zig` only draws what the view says is visible.
- **Decorations.** The current line, selection, search matches, git markers,
  diff lines and blame are entries in `Tab.decorations` (`editor/decoration.zig`).
  Features add entries; only the editor view draws them.
- **Background work.** A thread hands a result to the main loop with
  `Mailbox.post` (`platform/mailbox.zig`), which wakes the event wait. The
  main thread takes the item and `Editor.receive` frees it. Dialogs, find
  in project and git use it.
- **Prompts.** A command that needs typed text returns `Request.prompt`;
  the workbench opens the prompt and sends the text back to the editor.
- **Files.** `platform/fs.zig` reads whole files and saves through a
  temporary file and a rename. The buffer keeps the bytes as they are, so
  line endings and the final newline survive a save.
- **Questions.** The flag for unsaved changes comes from the undo history
  (`History.isModified`). Quit and closing a tab ask Save / Don't save /
  Cancel with an `ask` request; the answer comes back to `Editor.answer`.
- **Messages.** Everything reports through `Editor.notify`; the status bar
  shows the message for a few seconds and the messages panel keeps it.
- **Sizes.** `ui/layout.zig` derives every size from the cell size, which is
  the 8x16 font times the zoom (1x to 4x).

## Search

- `core/search.zig` is the one matcher: plain text, match case, whole word.
  It reads the two halves of the gap buffer, so nothing is copied.
- `editor/find.zig` keeps the needle, the options and the matches of the
  active file. While the find or replace prompt is open, the matches are
  found again after every change and drawn as decorations.
- `editor/project_search.zig` walks the open folder on a thread and posts
  the hits of each file. A new search drops the late hits of the old one.

## Syntax (`syntax/`)

- `grammar.zig` is the shape of a grammar file (see `docs/GRAMMARS.md`) and
  the rule set made from it, with a sorted word list for keyword lookup.
- `syntax.zig` turns a line into styled spans. Each line has a one-byte
  start state (normal, inside a block comment, inside a multiline string).
  A `Highlighter` per file finds states only down to the lines asked for;
  `Document.apply` notes the first changed line and the states from there
  are found again when needed. It also finds matching brackets, skipping
  strings and comments.
- `language.zig` picks a grammar by file name, extension, then shebang.
  Grammars that share an extension (`.m`, `.pl`, `.v`, `.fs`) are told
  apart by hints found in the first 1 KB of the file.
- Grammars load with the settings into the config arena. `tools/embed_dir.zig`
  embeds every file of `assets/grammars/` at build time.
- The editor view draws each run of one style in its theme color.

## Git (`git/`, `editor/git.zig`, `editor/tracking.zig`)

- `git/repo.zig` finds the repository (walks up to `.git`) and runs the git
  CLI. Every git feature goes through `repo.run`. The program comes from the
  `git` setting; when it is missing, git features hide and one message says why.
- `git/status.zig`, `git/log.zig` know the commands and read their output:
  `status --porcelain=v1 -z`, `log`, `branch`, `blame --porcelain`.
- `git/diff.zig` is the one line diff (Myers, at most 1000 edits, else one
  hunk) and the unified diff made from it. Gutter markers and diff views use it.
- `editor/git.zig` runs each git command as a `Job` on a thread of its own;
  the job comes back through the mailbox to `Git.receive`. It keeps the
  status, the history (200 commits a page) and the branches. Each status also
  reads the hash of HEAD, so a commit made in a terminal is noticed too.
- `editor/tracking.zig` is what git knows about one open file: its text at
  HEAD (fetched once), the gutter markers, and blame. `Editor.tick` asks for
  what is missing and makes markers again once the text has rested for
  300 ms. Files over 50,000 lines get no markers.
- A diff view and the commit message are files with a `role`: a diff view is
  read-only (`Document.read_only`) with its lines as `File.marks`; the commit
  message is committed with Ctrl+Enter and is never "modified".
- The sidebar has the file tree and the git panel; each dock switches its
  panels with the tabs widget.

## Terminal (`terminal/`, `platform/pty.zig`, `editor/terminals.zig`)

- `platform/pty.zig` starts the shell in a pseudo-terminal: `/dev/ptmx` and
  fork with plain system calls on Linux, ConPTY on Windows, one API picked
  at compile time. It needs no libc and no SDL, so tests run a real shell.
  A thread reads the output and hands it to a callback. The shell gets every
  signal back at its default, even ones the editor ignores.
- `terminal/vt.zig` is the parser, after the classic DEC state machine. Its
  state carries over between reads, so split UTF-8 and split sequences work.
  OSC and DCS strings are read and dropped.
- `terminal/grid.zig` is the screen: cells, cursor, scroll region, alternate
  screen and the scrollback, a ring of lines without their blank ends.
  Resizing cuts or pads lines and never reflows.
- `terminal/keys.zig` turns keys into bytes; typed text comes from text events.
- `terminal/terminal.zig` has `Session`: it maps parser actions to the grid
  and answers status queries. It gets the shell as a `Port` (write, resize),
  so its tests use a fake one.
- `editor/terminals.zig` owns the terminals. The pty thread posts output
  through the mailbox with the terminal's id; output of a closed one is dropped.
- `ui/panels/terminal.zig` draws each run of one color with `drawText`. The
  16 colors come from the theme's `terminal` colors; 256 and true colors
  are computed. Keys go to the shell, except a few window commands.

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
- `platform/root.zig` imports only its SDL-free files.
- The test build has no SDL, so a test that reaches SDL code fails to build.
  Keep testable logic out of the SDL files of `platform/`.
- `tests/session.zig` drives the whole window with events and checks what
  is drawn with `canvas.Recorder`, in a real folder that is a git repository.
  Terminals in tests run `/bin/sh` (`cmd.exe` on Windows).