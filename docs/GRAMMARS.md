# Grammars

A language is one ZON file in `assets/grammars/` (built in) or in the
`grammars` folder of the config folder (yours; a file with the same name
replaces the built-in one). No code changes and no regex: the build embeds
every file of `assets/grammars/` by itself, without spaces and comments.

## Example

```zon
.{
    .name = "Lua",
    .extensions = .{ "lua" },
    .shebangs = .{ "lua" },
    .line_comments = .{ "--" },
    .block_comment = .{ .start = "--[[", .end = "]]" },
    .strings = .{
        .{ .start = "[[", .end = "]]", .escape = false, .multiline = true },
        .{ .start = "\"" },
        .{ .start = "'" },
    },
    .keywords = .{ "and", "do", "else", "end", "for", "function", "if", "local", "return", "then" },
    .constants = .{ "true", "false", "nil" },
    .builtins = .{ "print", "pairs", "require" },
    .operators = "+-*/%^#=<>~:",
}
```

## Fields

Only `.name` is needed.

| Field | Meaning | Default |
|---|---|---|
| `name` | Shown in the status bar and the language picker (Alt+L). | |
| `extensions` | Without the dot. Case is ignored. | none |
| `file_names` | Whole names, like `Makefile` or `.bashrc`. Checked first. | none |
| `shebangs` | Programs after `#!` on the first line. `python` matches `python3`. Checked last. | none |
| `hints` | For grammars that share an extension: text near the start of a file (first 1 KB) that picks this one, like `@interface` for Objective-C `.m` files. The grammar without hints is picked when no hint is found. | none |
| `line_comments` | Each starts a comment to the end of the line. The first one is used by Ctrl+/. | none |
| `block_comment` | `.{ .start, .end }`. Can span lines. Used by Ctrl+/ when there is no line comment. | none |
| `strings` | Tried in order, so put `"""` before `"`. Each has `.start`, and maybe `.end` (else the same as start), `.escape = false` (no backslash escapes), `.multiline = true` (can span lines), `.style`. | none |
| `keywords`, `types`, `constants`, `builtins` | Words, each group with its own color. | none |
| `ignore_case` | Words match in any case (SQL, Batch). | `false` |
| `numbers` | A digit starts a number: `42`, `0xff`, `1.5e3`, `10px`. | `true` |
| `functions` | A word right before `(` gets the function color. | `true` |
| `key_before` | Characters that make the word before them a key, like `:` in YAML or `=` in TOML. | none |
| `operators` | Characters with the operator color. | none |
| `punctuation` | Characters with the punctuation color. | `"()[]{},;"` |
| `word_chars` | Characters that can be part of a word besides letters, digits and `_`, like `-` in CSS. | none |
| `prefixes` | `.{ .text, .style }`: a word that starts with this text, like `@import` or `$HOME`. | none |
| `line_starts` | `.{ .text, .style }`: a line that starts with this text gets that style, like `+` in a diff. | none |

Styles: `comment`, `keyword`, `type`, `constant`, `builtin`, `string`,
`number`, `function`, `operator`, `punctuation`, `text`. The theme's
`syntax` colors give each one a color.

## How it reads a line

At each position the first rule that fits wins: block comment, line comment,
string, prefix, number, word (a keyword group, else a function or key), then
an operator or punctuation character. Only block comments and multiline
strings carry over to the next line. A line is read up to 10,000 bytes.

## Adding a language

1. Add `assets/grammars/<name>.zon`.
2. If another grammar has the same extension, give one of them `hints`.
3. Add a small sample to `tests/samples/` that is found by its name,
   extension or shebang. `zig build test` checks that every grammar loads,
   has a sample, closes every string and comment it opens, and that no two
   grammars claim the same file name or an extension without hints.
