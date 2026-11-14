# X11 headers

Only the X11 headers SDL's X11 backend includes, so Linux builds work on any
machine (also when cross-compiling from Windows) without X11 dev packages.
No X11 code is compiled or linked: SDL loads the X11 libraries at run time.

Copied from Debian 13 packages (licenses in `licenses/`, MIT/X11 style):

| Package        | Version  |
|----------------|----------|
| libx11-dev     | 1.8.12   |
| libxcursor-dev | 1.2.3    |
| libxext-dev    | 1.3.4    |
| libxfixes-dev  | 6.0.0    |
| libxi-dev      | 1.8.2    |
| libxrandr-dev  | 1.5.4    |
| libxrender-dev | 0.9.12   |
| x11proto-dev   | 2024.1   |
