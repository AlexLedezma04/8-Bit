#!/bin/sed -f
# Swap words and drop empty lines.
s/foo/bar/g
/^$/d
y/abc/xyz/
