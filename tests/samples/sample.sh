#!/bin/bash
# A script.
set -e

name="${1:-world}"
for f in *.txt; do
    echo "file: $f" 'raw $x'
done

if [ -z "$name" ]; then exit 1; fi
