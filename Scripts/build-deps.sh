#!/bin/bash
# Build the C/C++ dependencies openvpn3 needs, as static universal libraries.
#
# openvpn3 itself is a header library compiled into the tunnel extension; these
# are the four things it links against (ThirdParty/README.md). Homebrew cannot
# supply them: it installs one architecture, and its dylibs live at paths that
# do not exist on a user's Mac.
#
#   Scripts/build-deps.sh            build whatever is missing
#   Scripts/build-deps.sh --clean    start over
#
# Output: ThirdParty/out/{include,lib}. Sources are fetched as pinned tarballs
# and verified by SHA-256 before anything is extracted.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TP="$ROOT/ThirdParty"
SRC="$TP/src"; BUILD="$TP/build"; OUT="$TP/out"
ARCHS="arm64 x86_64"
MIN_MACOS="14.0"
JOBS="$(sysctl -n hw.ncpu)"

ASIO_VERSION=1.24.0
LZ4_VERSION=1.10.0
FMT_VERSION=12.2.0
OPENSSL_VERSION=3.6.4

if [ "${1:-}" = "--clean" ]; then rm -rf "$BUILD" "$OUT"; fi
mkdir -p "$SRC" "$BUILD" "$OUT/include" "$OUT/lib"

# ── fetch ────────────────────────────────────────────────────────────────────
fetch() { # name url sha256
  local file="$SRC/$1"
  if [ ! -f "$file" ]; then
    echo "── fetching $1"
    curl -sSL --fail -o "$file.part" "$2" && mv "$file.part" "$file"
  fi
  local got; got="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  if [ "$got" != "$3" ]; then
    echo "SHA-256 mismatch for $1" >&2
    echo "  expected $3" >&2; echo "  got      $got" >&2
    rm -f "$file"; exit 1
  fi
}
extract() { # tarball destdir
  rm -rf "$2"; mkdir -p "$2"; tar -xzf "$SRC/$1" -C "$2" --strip-components=1
}
done_stamp() { [ -f "$OUT/.stamp-$1" ]; }
stamp() { touch "$OUT/.stamp-$1"; }

fetch "asio-$ASIO_VERSION.tar.gz" \
  "https://github.com/chriskohlhoff/asio/archive/refs/tags/asio-${ASIO_VERSION//./-}.tar.gz" \
  cbcaaba0f66722787b1a7c33afe1befb3a012b5af3ad7da7ff0f6b8c9b7a8a5b
fetch "lz4-$LZ4_VERSION.tar.gz" \
  "https://github.com/lz4/lz4/archive/refs/tags/v$LZ4_VERSION.tar.gz" \
  537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b
fetch "fmt-$FMT_VERSION.tar.gz" \
  "https://github.com/fmtlib/fmt/archive/refs/tags/$FMT_VERSION.tar.gz" \
  8b852bb5aa6e7d8564f9e81394055395dd1d1936d38dfd3a17792a02bebd7af0
fetch "openssl-$OPENSSL_VERSION.tar.gz" \
  "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
  9bffaa1ad1e07b354c21bd3324ec02fa15579f45a7d0494b3e74bc449b7333ef

ARCH_FLAGS=""; for a in $ARCHS; do ARCH_FLAGS="$ARCH_FLAGS -arch $a"; done
COMMON_CFLAGS="$ARCH_FLAGS -mmacosx-version-min=$MIN_MACOS -O2"

# ── asio (header-only, patched) ──────────────────────────────────────────────
# openvpn3 requires its own patched asio: the first patch adds Apple NAT64
# support, and core code calls hooks the others add. The patch set lives in
# the openvpn3 submodule and belongs to the pinned release.
if ! done_stamp "asio-$ASIO_VERSION"; then
  echo "── asio $ASIO_VERSION + $(ls "$TP"/openvpn3/deps/asio/patches/*.patch | wc -l | tr -d ' ') patches"
  extract "asio-$ASIO_VERSION.tar.gz" "$BUILD/asio"
  for p in "$TP"/openvpn3/deps/asio/patches/*.patch; do
    patch -d "$BUILD/asio" -p1 -s < "$p" || { echo "patch failed: $p" >&2; exit 1; }
  done
  rm -rf "$OUT/include/asio" "$OUT/include/asio.hpp"
  cp -R "$BUILD/asio/asio/include/asio" "$BUILD/asio/asio/include/asio.hpp" "$OUT/include/"
  grep -q NAT64 "$OUT/include/asio/detail/impl/socket_ops.ipp" || { echo "patched asio lacks NAT64 support" >&2; exit 1; }
  stamp "asio-$ASIO_VERSION"
fi

# ── lz4 ──────────────────────────────────────────────────────────────────────
if ! done_stamp "lz4-$LZ4_VERSION"; then
  echo "── lz4 $LZ4_VERSION"
  extract "lz4-$LZ4_VERSION.tar.gz" "$BUILD/lz4"
  # ranlib warns that a fat archive cannot be edited with ar; the linker is fine with it.
  make -s -C "$BUILD/lz4/lib" -j"$JOBS" liblz4.a CFLAGS="$COMMON_CFLAGS" >/dev/null 2> >(grep -v 'will be fat' >&2)
  cp "$BUILD/lz4/lib/liblz4.a" "$OUT/lib/"
  cp "$BUILD/lz4/lib/lz4.h" "$BUILD/lz4/lib/lz4hc.h" "$BUILD/lz4/lib/lz4frame.h" "$OUT/include/"
  stamp "lz4-$LZ4_VERSION"
fi

# ── fmt ──────────────────────────────────────────────────────────────────────
if ! done_stamp "fmt-$FMT_VERSION"; then
  echo "── fmt $FMT_VERSION"
  extract "fmt-$FMT_VERSION.tar.gz" "$BUILD/fmt"
  cmake -S "$BUILD/fmt" -B "$BUILD/fmt/build" -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_OSX_ARCHITECTURES="${ARCHS// /;}" -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
    -DFMT_TEST=OFF -DFMT_DOC=OFF -DFMT_INSTALL=ON \
    -DCMAKE_INSTALL_PREFIX="$OUT" -DCMAKE_INSTALL_LIBDIR=lib >/dev/null
  cmake --build "$BUILD/fmt/build" -j"$JOBS" >/dev/null
  cmake --install "$BUILD/fmt/build" >/dev/null
  stamp "fmt-$FMT_VERSION"
fi

# ── OpenSSL ──────────────────────────────────────────────────────────────────
# OpenSSL builds one architecture at a time; the slices are joined with lipo.
if ! done_stamp "openssl-$OPENSSL_VERSION"; then
  for arch in $ARCHS; do
    echo "── OpenSSL $OPENSSL_VERSION ($arch)"
    dir="$BUILD/openssl-$arch"
    extract "openssl-$OPENSSL_VERSION.tar.gz" "$dir"
    # OpenSSL 3.6's install script prints DEBUG lines and perl warnings on
    # stderr that are not errors; real errors still come through.
    ( cd "$dir" && ./Configure "darwin64-$arch-cc" \
        no-shared no-tests no-apps no-docs \
        -mmacosx-version-min="$MIN_MACOS" \
        --prefix="$dir/prefix" --libdir=lib >/dev/null \
      && make -s -j"$JOBS" >/dev/null \
      && make -s install_dev >/dev/null ) \
      2> >(grep -v -e '^DEBUG:' -e 'mkinstallvars.pl' -e '^No value given' -e '^LIBDIR = $' -e '^libdir = $' >&2)
  done
  first="$(echo $ARCHS | cut -d' ' -f1)"
  for other in $ARCHS; do
    diff -rq "$BUILD/openssl-$first/prefix/include" "$BUILD/openssl-$other/prefix/include" >/dev/null \
      || { echo "OpenSSL headers differ between $first and $other; a universal header set is not possible as built" >&2; exit 1; }
  done
  rm -rf "$OUT/include/openssl"; cp -R "$BUILD/openssl-$first/prefix/include/openssl" "$OUT/include/"
  for lib in libssl.a libcrypto.a; do
    slices=(); for arch in $ARCHS; do slices+=("$BUILD/openssl-$arch/prefix/lib/$lib"); done
    lipo -create "${slices[@]}" -output "$OUT/lib/$lib"
  done
  stamp "openssl-$OPENSSL_VERSION"
fi

# ── verify ───────────────────────────────────────────────────────────────────
echo "── result"
for lib in "$OUT"/lib/*.a; do
  info="$(lipo -info "$lib" | sed 's/.*are: //; s/.*is architecture: //')"
  for a in $ARCHS; do
    grep -qw "$a" <<<"$info" || { echo "$(basename "$lib") lacks $a: $info" >&2; exit 1; }
  done
  printf '  %-14s %s\n' "$(basename "$lib")" "$info"
done
if grep -rl /opt/homebrew "$OUT/lib" "$OUT/include" >/dev/null 2>&1; then
  echo "a Homebrew path leaked into the output" >&2; exit 1
fi
echo "  headers: $(ls "$OUT/include" | tr '\n' ' ')"
echo "Done: $OUT"
