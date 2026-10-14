#!/bin/sh
# Build Bochs 3.0 with the NE2000 and slirp networking into build/bochs, since
# Homebrew's Bochs has no network card. The tarball's SHA-256 is the one in
# Homebrew's formula, and so is the patch (keymap.cc wants <libgen.h> on macOS).
# Slirp needs the resolver library on macOS, which configure does not add.
set -e
cd "$(dirname "$0")/.."
V=3.0
SRC=build/bochs-src
mkdir -p downloads $SRC
T=downloads/bochs-$V.tar.gz
[ -f $T ] || curl -fsSL -o $T https://downloads.sourceforge.net/project/bochs/bochs/$V/bochs-$V.tar.gz
echo "cb6f542b51f35a2cc9206b2a980db5602b7cd1b7cf2e4ed4f116acd5507781aa  $T" | shasum -a 256 -c -
rm -rf $SRC/bochs-$V
tar xzf $T -C $SRC
cd $SRC/bochs-$V
patch -p1 <<'PATCH'
--- a/gui/keymap.cc
+++ b/gui/keymap.cc
@@ -30,6 +30,10 @@
 #include "gui.h"
 #include "keymap.h"

+#if defined(__APPLE__)
+#include <libgen.h>
+#endif
+
 // Table of bochs "BX_KEY_*" symbols
 // the table must be in BX_KEY_* order
 const char *bx_key_symbol[BX_KEY_NBKEYS] = {
PATCH
./configure --prefix="$PWD/../../bochs" --with-sdl2 --with-nogui --enable-ne2000 \
    --enable-pci --enable-cpu-level=6 --enable-fpu --disable-docbook LIBS=-lresolv > ../configure.log
make -j8 > ../make.log
make install > ../install.log
echo "built $(cd ../../bochs && pwd)/bin/bochs"
