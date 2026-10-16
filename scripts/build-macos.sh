#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v brew >/dev/null || { echo "Install Homebrew first." >&2; exit 1; }
command -v pkg-config >/dev/null || { echo "Run: brew install pkg-config libusb libxml2" >&2; exit 1; }
export PKG_CONFIG_PATH="$(brew --prefix libxml2)/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
pkg-config --exists libusb-1.0 libxml-2.0
make clean
make -j"$(sysctl -n hw.ncpu)" CPPFLAGS="-I$(brew --prefix)/include ${CPPFLAGS:-}"
file ./dpcmd
./dpcmd --list > /tmp/dediprog-chip-list.txt
echo "Built dpcmd; keep ChipInfoDb.dedicfg beside it."
