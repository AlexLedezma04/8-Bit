<p align="center">
  <img src="assets/icons/8bit-logo-with-name-light-mode.png#gh-light-mode-only" alt="8-Bit" width="320">
  <img src="assets/icons/8bit-logo-with-name-dark-mode.png#gh-dark-mode-only" alt="8-Bit" width="320">
</p>

<p align="center">The true minimal text editor. One executable under 2 MiB, no runtime, no plugins to install.</p>

## What it does

- **Editing**: gap-buffer text model, multi-step undo and redo, find and
  replace (match case, whole word), go to line, go to matching bracket,
  comment toggling, word wrap, zoom.
- **Panes and tabs**: split right or down, move between panes, many files open.
- **Syntax highlighting**: 96 languages (full list below), each one a small
  data file. Add your own without touching the code.
- **Git built in**: status, commit and amend, change markers in the gutter,
  next and previous change, peek and revert a change, blame, file history.
  Uses your `git` program; everything else works without it.
- **Terminal built in**: a real pty terminal inside the window, with
  scrollback, wide characters and the symbols terminal programs draw.
- **File tree** for the open folder.
- **Themes**: dark and light included, or write your own.
- **Windows and Linux**, x86_64 and ARM64, X11 and Wayland.

## Supported languages

96 languages. A file is matched by its extension or name, and by its first line (`#!`) for scripts.
To add another, see [docs/GRAMMARS.md](docs/GRAMMARS.md).

| Language | Extensions and file names |
|---|---|
| ActionScript | `.as` |
| Ada | `.adb`, `.ads`, `.ada` |
| ALGOL | `.alg`, `.a68`, `.algol` |
| APL | `.apl`, `.aplf`, `.apln`, `.aplc`, `.dyalog` |
| AppleScript | `.applescript` |
| Assembly | `.asm`, `.s`, `.nasm`, `.inc` |
| AutoHotkey | `.ahk`, `.ahk2` |
| BASIC | `.bas`, `.vb`, `.vbs`, `.vba`, `.frm`, `.bi` |
| Batch | `.bat`, `.cmd` |
| C | `.c`, `.h` |
| C# | `.cs`, `.csx` |
| C++ | `.cpp`, `.cc`, `.cxx`, `.c++`, `.hpp`, `.hh`, `.hxx`, `.h++`, `.ipp`, `.inl` |
| Cadence | `.cdc` |
| Cairo | `.cairo` |
| Carbon | `.carbon` |
| Clarity | `.clar` |
| Clojure | `.clj`, `.cljs`, `.cljc`, `.edn`, `.bb` |
| CMake | `.cmake`, `CMakeLists.txt` |
| COBOL | `.cob`, `.cbl`, `.cpy`, `.cobol` |
| CoffeeScript | `.coffee`, `.litcoffee`, `Cakefile` |
| Common Lisp | `.lisp`, `.lsp`, `.cl`, `.asd`, `.ros` |
| CSS | `.css`, `.scss`, `.less` |
| CUDA | `.cu`, `.cuh` |
| Cypher | `.cypher`, `.cyp`, `.cql` |
| D | `.d`, `.di` |
| Dart | `.dart` |
| Datalog | `.dl`, `.dlog`, `.datalog` |
| Diff | `.diff`, `.patch` |
| Dockerfile | `.dockerfile`, `.containerfile`, `Dockerfile`, `Containerfile` |
| Elixir | `.ex`, `.exs`, `mix.lock` |
| Elm | `.elm` |
| Emacs Lisp | `.el`, `.emacs`, `_emacs`, `.spacemacs` |
| Erlang | `.erl`, `.hrl`, `.escript`, `rebar.config` |
| F# | `.fs`, `.fsi`, `.fsx`, `.fsscript` |
| Fish | `.fish` |
| Forth | `.fth`, `.4th`, `.forth`, `.frt`, `.fs` |
| Fortran | `.f`, `.f90`, `.f95`, `.f03`, `.f08`, `.f77`, `.for`, `.ftn` |
| Git Commit | `COMMIT_EDITMSG`, `MERGE_MSG`, `TAG_EDITMSG`, `SQUASH_MSG` |
| GLSL | `.glsl`, `.vert`, `.frag`, `.geom`, `.comp`, `.tesc`, `.tese` |
| Go | `.go`, `go.mod`, `go.work` |
| GraphQL | `.graphql`, `.gql`, `.graphqls` |
| Groovy | `.groovy`, `.gvy`, `.gradle`, `Jenkinsfile` |
| Haskell | `.hs`, `.lhs` |
| Haxe | `.hx`, `.hxml` |
| HTML | `.html`, `.htm`, `.xhtml` |
| INI | `.ini`, `.cfg`, `.conf`, `.properties`, `.desktop`, `.editorconfig`, `.gitconfig`, `.npmrc` |
| Java | `.java` |
| JavaScript | `.js`, `.mjs`, `.cjs`, `.jsx` |
| JSON | `.json`, `.jsonc`, `.json5`, `.geojson`, `.webmanifest`, `.babelrc`, `.eslintrc`, `.prettierrc` |
| Julia | `.jl` |
| Kotlin | `.kt`, `.kts` |
| Logo | `.logo`, `.lgo`, `.lg` |
| Lua | `.lua` |
| Makefile | `.mk`, `.mak`, `Makefile`, `makefile`, `GNUmakefile` |
| Markdown | `.md`, `.markdown`, `.mdown`, `.mkd` |
| MATLAB | `.m` |
| Mercury | `.m` |
| Modula-2 | `.mod`, `.def`, `.mi`, `.m2`, `.ob`, `.ob2`, `.obn` |
| Move | `.move` |
| MQL | `.mq4`, `.mq5`, `.mqh` |
| Nim | `.nim`, `.nims`, `.nimble` |
| Objective-C | `.m`, `.mm` |
| OCaml | `.ml`, `.mli`, `.mll`, `.mly` |
| Odin | `.odin` |
| Pascal | `.pas`, `.pp`, `.dpr`, `.lpr`, `.dpk` |
| Perl | `.pl`, `.pm`, `.t`, `.pod`, `.psgi` |
| PHP | `.php`, `.phtml` |
| PL/I | `.pli`, `.pl1`, `.plinc` |
| PowerShell | `.ps1`, `.psm1`, `.psd1` |
| Prolog | `.pl`, `.pro`, `.prolog` |
| Python | `.py`, `.pyw`, `.pyi` |
| R | `.r`, `.rmd`, `.Rprofile` |
| ReScript | `.res`, `.resi` |
| RPG | `.rpg`, `.rpgle`, `.sqlrpgle`, `.rpgleinc` |
| Ruby | `.rb`, `.rake`, `.gemspec`, `.ru`, `Rakefile`, `Gemfile` |
| Rust | `.rs` |
| Scala | `.scala`, `.sc`, `.sbt` |
| Sed | `.sed` |
| Shell | `.sh`, `.bash`, `.zsh`, `.ksh`, `.bashrc`, `.bash_profile`, `.zshrc`, `.profile`, `.bash_aliases` |
| Solidity | `.sol` |
| SPARQL | `.sparql`, `.rq` |
| SQL | `.sql` |
| Swift | `.swift` |
| Tcl | `.tcl`, `.tk`, `.itcl`, `.tm` |
| TOML | `.toml`, `Cargo.lock` |
| TypeScript | `.ts`, `.tsx`, `.mts`, `.cts` |
| V | `.v`, `.vsh`, `.vv` |
| Verilog | `.v`, `.vh`, `.sv`, `.svh` |
| VHDL | `.vhd`, `.vhdl` |
| Vyper | `.vy`, `.vyi` |
| WebAssembly | `.wat`, `.wast` |
| WGSL | `.wgsl` |
| XML | `.xml`, `.xsd`, `.xsl`, `.xslt`, `.svg`, `.plist`, `.csproj`, `.vcxproj`, `.props`, `.targets`, `.xaml`, `.rss`, `.atom` |
| YAML | `.yaml`, `.yml` |
| Zig | `.zig` |
| ZON | `.zon` |

## Keys

### Files and app

| Keys | Action |
|---|---|
| `Ctrl+N` | New file |
| `Ctrl+O` | Open file |
| `Ctrl+Shift+O` | Open folder |
| `Ctrl+Shift+W` | Close folder |
| `Ctrl+S` | Save |
| `Ctrl+Shift+S` | Save as |
| `Ctrl+,` | Open settings |
| `Alt+Shift+T` | Next theme |
| `Ctrl+Q` | Quit |

### Tabs, panes and panels

| Keys | Action |
|---|---|
| `Ctrl+W` | Close tab |
| `Ctrl+Tab` | Next tab |
| `Ctrl+Shift+Tab` | Previous tab |
| `Ctrl+\` or `Alt+Shift+Right` | Split right |
| `Ctrl+Shift+\` or `Alt+Shift+Down` | Split down |
| `F6` | Next pane |
| `Shift+F6` | Previous pane |
| `Alt+1` | Focus the sidebar |
| `Esc` | Focus the editor |
| `Ctrl+Shift+E` | Show the file tree |
| `Ctrl+Shift+G` | Show the git panel |

### Moving the cursor (add Shift to select)

| Keys | Action |
|---|---|
| `Arrows` | Move by character or line |
| `Home` / `End` | Start / end of line |
| `Page Up` / `Page Down` | Move by page |
| `Ctrl+Left` / `Ctrl+Right` | Previous / next word |
| `Ctrl+Home` / `Ctrl+End` | Start / end of file |
| `Ctrl+A` | Select all |
| `Ctrl+G` | Go to line |
| `Ctrl+Shift+M` | Go to matching bracket |

### Editing

| Keys | Action |
|---|---|
| `Enter` or `Shift+Enter` | New line |
| `Tab` / `Shift+Tab` | Indent / outdent |
| `Backspace` / `Delete` | Delete left / right |
| `Ctrl+Backspace` / `Ctrl+Delete` | Delete word left / right |
| `Ctrl+Z` | Undo |
| `Ctrl+Y` or `Ctrl+Shift+Z` | Redo |
| `Ctrl+C` / `Ctrl+X` / `Ctrl+V` | Copy / cut / paste |
| `Ctrl+/` or `Ctrl+Shift+7` | Toggle comment |
| `Alt+L` | Pick the language |

### View

| Keys | Action |
|---|---|
| `Alt+Z` | Toggle word wrap |
| `Ctrl+=` or `Ctrl++` | Zoom in |
| `Ctrl+-` | Zoom out |
| `Ctrl+0` | Reset zoom |

### Find and replace

| Keys | Action |
|---|---|
| `Ctrl+F` | Find |
| `F3` / `Shift+F3` | Next / previous match |
| `Ctrl+H` | Replace |
| `Alt+A` | Replace all |
| `Alt+C` | Toggle match case |
| `Alt+W` | Toggle whole word |

### Git

| Keys | Action |
|---|---|
| `Ctrl+Enter` | Commit |
| `Ctrl+Shift+Enter` | Amend the last commit |
| `Alt+D` | Show changes |
| `F7` / `Shift+F7` | Next / previous change |
| `Ctrl+Alt+D` | Peek at a change |
| `Ctrl+Alt+Z` | Revert a change |
| `Alt+B` | Toggle blame |
| `Alt+H` | File history |

### Terminal

| Keys | Action |
|---|---|
| `Ctrl+`` or `Alt+T` or `Alt+F12` | Show or hide the terminal |
| `Ctrl+Shift+`` or `Alt+Shift+F12` | New terminal |

All of these can be changed in `keymap.zon` (see below).

## Configuration

8-Bit reads its files from `~/.config/8-bit` on Linux (or `$XDG_CONFIG_HOME/8-bit`)
and `%APPDATA%\8-bit` on Windows. Press Ctrl+, to open the settings.

| File or folder | What it does |
|---|---|
| `settings.zon` | Tabs, wrap, zoom, theme, line numbers, git and shell |
| `keymap.zon` | Your key bindings, added to the defaults |
| `themes/` | Your themes (copy `assets/themes/dark.zon` to start) |
| `grammars/` | Your languages, see [docs/GRAMMARS.md](docs/GRAMMARS.md) |

A key binding looks like this:

```zon
.{
    .{ .key = "ctrl+shift+k", .command = "toggle_comment" },
}
```

## License

[MIT](LICENSE)
