#!/bin/sh
# NotchDeck on Linux.
#
# Two things the desktop needs help with:
#   * Wayland does not let a client place its own windows, and the notch has to
#     sit on a screen edge — so it runs as an X11 client under XWayland.
#   * A shell started from a snap (VS Code, for one) exports that snap's library
#     paths, and they break a binary built against the system glibc.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bin=${NOTCHDECK_BIN:-$root/target/release/notchdeck}
[ -x "$bin" ] || bin=$root/target/debug/notchdeck

if [ ! -x "$bin" ]; then
  echo "No binary yet. Build one first:  cargo build --release -p notchdeck" >&2
  exit 1
fi

exec env -u LD_LIBRARY_PATH -u GTK_PATH -u GIO_MODULE_DIR -u GSETTINGS_SCHEMA_DIR \
         -u LOCPATH -u GDK_PIXBUF_MODULE_FILE -u GDK_PIXBUF_MODULEDIR \
         GDK_BACKEND=x11 \
    "$bin" "$@"
