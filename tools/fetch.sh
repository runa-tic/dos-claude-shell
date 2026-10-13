#!/bin/sh
# Download FreeDOS 1.4 Lite and the two network packages, and check each one.
# The Lite image's SHA-256 is the one FreeDOS publishes in verify.txt; the two
# packages have no published hash that we found, so theirs were pinned at the
# first download (2026-10-13). A mismatch stops the build.
set -e
cd "$(dirname "$0")/.."
mkdir -p downloads
B=https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files
get() {
    [ -f "downloads/$1" ] || curl -fsSL -o "downloads/$1" "$2"
    echo "$3  downloads/$1" | shasum -a 256 -c -
}
get FD14-LiteUSB.zip "$B/distributions/1.4/FD14-LiteUSB.zip" 857dcd2ebf9d3d094320154db5fb5b830acba6fb98f981a95a0ca7ab3350338b
get crynwr.zip "$B/repositories/1.4/net/crynwr.zip" b5761639a1bf4ad4fa93bfa4643ca62ae46d08412c78d45ae1b5e10d91d0b9c8
get mtcp.zip "$B/repositories/1.4/net/mtcp.zip" 087ae50048004a8fd23f26f3e3a1bac7985107d1912e9244cf5ec0488432aedc
