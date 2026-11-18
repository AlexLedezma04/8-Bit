# Third-party software

8-Bit itself is MIT licensed (see `LICENSE`). It includes the following
software, all under licenses that allow this use. Each one keeps its own
license text in the folder named below.

| Component | Used for | License | Where |
|---|---|---|---|
| SDL 3.4.20 | window, input, clipboard, dialogs (compiled into the exe) | zlib | `third_party/SDL3-3.4.20/LICENSE.txt` |
| stb_truetype 1.28 | reading the built-in fonts | MIT or public domain | `third_party/stb/stb_truetype.h` (end of file) |
| JetBrains Mono | code font | SIL OFL 1.1 | `assets/fonts/OFL-JetBrainsMono.txt` |
| Inter | interface font | SIL OFL 1.1 | `assets/fonts/OFL-Inter.txt` |
| Wayland and X11 headers | building SDL on Linux (headers only, not linked in) | MIT-style | `third_party/wayland/licenses`, `third_party/X11/licenses` |

The fonts are cut to the characters the app draws. The OFL permits this and
permits embedding in software, as long as the license text travels with them.
