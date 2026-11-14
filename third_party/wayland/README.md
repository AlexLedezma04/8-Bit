# Wayland headers and protocol code

What SDL's Wayland backend needs to compile, so Linux builds work on any
machine (also when cross-compiling from Windows) with no extra tools.
Nothing here is linked: SDL loads the Wayland libraries at run time.

- `include/`: headers copied from Debian 13 packages (licenses in `licenses/`, MIT style).
- `generated/`: protocol code made from `third_party/SDL3-3.4.20/wayland-protocols`
  with wayland-scanner 1.23.1. Each protocol's license is in its XML file.

| Package          | Version |
|------------------|---------|
| libwayland-dev   | 1.23.1  |
| libxkbcommon-dev | 1.7.0   |
| libdecor-0-dev   | 0.2.2   |

To regenerate after updating SDL:

```sh
for x in third_party/SDL3-3.4.20/wayland-protocols/*.xml; do
    n=$(basename "$x" .xml)
    wayland-scanner client-header "$x" "third_party/wayland/generated/$n-client-protocol.h"
    wayland-scanner private-code  "$x" "third_party/wayland/generated/$n-protocol.c"
done
```
