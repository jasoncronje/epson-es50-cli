#!/bin/sh
# Builds SANE's epsonds backend with the long-paper patch into ~/.local/share/scan/sane.
# `scan --long` uses it to scan past 14" (the ES-50 takes up to 72"). Brew's SANE is untouched.
set -eu
PREFIX="${PREFIX:-$HOME/.local/share/scan/sane}"
HERE="$(cd "$(dirname "$0")" && pwd)"
brew install pkgconf libusb jpeg-turbo >/dev/null
brew fetch -s sane-backends >/dev/null
TARBALL="$(brew --cache -s sane-backends)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
tar -xzf "$TARBALL" -C "$WORK"
cd "$WORK"/sane-backends-*
patch -p1 < "$HERE/epsonds-long-paper.patch"
B=/opt/homebrew
PKG_CONFIG_PATH=$B/lib/pkgconfig CPPFLAGS="-I$B/include" LDFLAGS="-L$B/lib" \
  ./configure --prefix="$PREFIX" BACKENDS=epsonds --with-usb --without-gphoto2 --without-v4l \
  --without-avahi --without-snmp --disable-locking --disable-dependency-tracking >/dev/null
make -j4 >/dev/null
make install >/dev/null
echo "installed $PREFIX/bin/scanimage"
