#!/usr/bin/env bash
# =============================================================================
# build-imagemagick-filc.sh
#
# Build a memory-safe ImageMagick 7 for x86_64 Linux with Fil-C
# (https://fil-c.org, https://github.com/pizlonator/fil-c) and package it as a
# relocatable tarball you can copy to any x86_64 Linux server.
#
# Strategy
#   * Fil-C "pizfix" binary release (musl-based, no root needed). Its clang
#     driver is build/bin/filcc (C) / fil++ (C++). Fil-C's libc (musl),
#     runtime (libpizlo) and GC live in pizfix/.
#   * EVERY piece of C code linked into the program must be Fil-C compiled, so
#     all image libraries are built from source with filcc too.
#   * Everything is linked STATICALLY (Fil-C turns -static into -static-pie).
#     The result is one self-contained `magick` binary: no dynamic loader,
#     no shared libraries, no dependency on the server's glibc.
#   * ImageMagick's XML config (policy.xml, delegates.xml, ...) ships in the
#     bundle's etc/ImageMagick-7 and is located through MAGICK_CONFIGURE_PATH,
#     which the bin/magick wrapper sets.  (--enable-zero-configuration is NOT
#     used: it compiles the config in and silently ignores policy.xml, which
#     you want to be able to tighten on a server.)
#
# Enabled formats/delegates : zlib, PNG, JPEG (libjpeg-turbo, no SIMD), WebP,
#                             TIFF, LCMS2 (ICC colour management) + all of
#                             ImageMagick's built-in coders (GIF, BMP, PNM,
#                             TGA, ICO, MIFF, PSD, ...).
# Disabled                  : OpenMP, OpenCL, X11 (display/animate/import),
#                             loadable modules, Magick++ (C++ API), Perl,
#                             FreeType/fontconfig (no text rendering),
#                             bzip2, lzma, zstd, JXL, HEIC/AVIF, OpenJPEG,
#                             OpenEXR, RAW, SVG/rsvg, XML, Ghostscript lib,
#                             DjVu, FFTW, LQR, Pango, WMF, JBIG, libdeflate.
#                             (PDF/PS still work if `gs` is installed on the
#                             server, via the external delegate.)
#
# Usage:
#   ./build-imagemagick-filc.sh
#
# Environment overrides (all optional):
#   WORK_DIR       build area                (default: ./work)
#   OUT_DIR        where the tarball goes    (default: ./dist)
#   JOBS           parallel make jobs        (default: nproc)
#   FILC_VERSION   Fil-C release             (default: 0.686)
#   FILC_SHA256    sha256 of the Fil-C tarball ("skip" to not verify;
#                  automatically skipped if FILC_VERSION is overridden and
#                  FILC_SHA256 is not set)
#   IM_VERSION     ImageMagick tag           (default: 7.1.2-32)
#   IM_SHA256      sha256 of the IM tarball (same rules as FILC_SHA256)
#   *_VERSION / *_SHA256 for ZLIB, PNG, JPEG, WEBP, TIFF, LCMS similarly.
#   CFLAGS_OPT     optimisation flags        (default: "-O2")
#   SKIP_FILC_SETUP=1  reuse an already extracted+setup Fil-C in WORK_DIR
#   FORCE_DEPS=1   rebuild deps even if their stamp files exist (re-runs
#                  otherwise skip already-built deps; ImageMagick is always
#                  rebuilt)
#
# Host requirements (Debian/Ubuntu names): curl ca-certificates xz-utils tar
#   make cmake pkg-config patchelf file linux-libc-dev (Fil-C's setup.sh
#   symlinks /usr/include/{linux,asm,asm-generic}).  A host gcc is NOT used
#   for target code, but cmake/configure want `make` & friends.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/work}"
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/dist}"
JOBS="${JOBS:-$(nproc)}"
CFLAGS_OPT="${CFLAGS_OPT:--O2}"

# ---- pinned versions --------------------------------------------------------
# pin <NAME> <default-version> <default-sha256>: if the caller overrides the
# version but not the hash, verification is skipped (with a warning).
pin() {
  local n=$1 v=$2 h=$3 vv="${1}_VERSION" hv="${1}_SHA256"
  if [[ -n "${!vv:-}" && "${!vv}" != "$v" && -z "${!hv:-}" ]]; then
    printf -v "$hv" '%s' skip
  fi
  printf -v "$vv" '%s' "${!vv:-$v}"
  printf -v "$hv" '%s' "${!hv:-$h}"
}
pin FILC 0.686     60bfbe8ee63d7e462394aa8d5e44fee675de892bcf800d9cc80d86378cad6b07
pin IM   7.1.2-32  940e349f0ef394e658fd57400b83d1d7a81b954f6e7bdbfbfad31b2718c10add
pin ZLIB 1.3.2     bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16
pin PNG  1.6.59    d80dd2a38a37f803cb9b6ac7b14bd6e74ddc3b654780a8380bdf93523fdb4389
pin JPEG 3.2.0     6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e
pin WEBP 1.6.0     e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564
pin TIFF 4.7.2     4996f0c4f93094719b1ca5c6279b20e588773ba8a247533e486416fb662ddb88
pin LCMS 2.19.1    bfc54f7bab59fbc921012014a8032e4cba4abd46db47d46b76416a8c0b2815c8

FILC_URL="https://github.com/pizlonator/fil-c/releases/download/v${FILC_VERSION}/filc-${FILC_VERSION}-linux-x86_64.tar.xz"
# GitHub tag archive; ImageMagick's repo ships a generated ./configure.
IM_URL="https://github.com/ImageMagick/ImageMagick/archive/refs/tags/${IM_VERSION}.tar.gz"
ZLIB_URL="https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz"
PNG_URL="https://download.sourceforge.net/libpng/libpng-${PNG_VERSION}.tar.xz"
JPEG_URL="https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/${JPEG_VERSION}/libjpeg-turbo-${JPEG_VERSION}.tar.gz"
WEBP_URL="https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-${WEBP_VERSION}.tar.gz"
TIFF_URL="https://download.osgeo.org/libtiff/tiff-${TIFF_VERSION}.tar.xz"
LCMS_URL="https://github.com/mm2/Little-CMS/releases/download/lcms${LCMS_VERSION}/lcms2-${LCMS_VERSION}.tar.gz"

# ---- layout -------------------------------------------------------------------
DL_DIR="$WORK_DIR/downloads"
SRC_DIR="$WORK_DIR/src"
FILC_DIR="$WORK_DIR/filc-${FILC_VERSION}-linux-x86_64"
DEPS="$WORK_DIR/deps"                 # Fil-C compiled static deps prefix
IM_PREFIX="/opt/imagemagick-filc"     # nominal prefix (bundle is relocatable)
IM_DESTDIR="$WORK_DIR/im-destdir"
BUNDLE_NAME="imagemagick-${IM_VERSION}-filc-${FILC_VERSION}-linux-x86_64"
BUNDLE="$WORK_DIR/$BUNDLE_NAME"
LOG_DIR="$WORK_DIR/logs"
mkdir -p "$DL_DIR" "$SRC_DIR" "$DEPS" "$LOG_DIR" "$OUT_DIR"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
# run <logname> <cmd...>: run a command, tee'ing output into logs/<logname>.log
run()  { local l="$LOG_DIR/$1.log"; shift; echo "+ $*" >>"$l"; "$@" >>"$l" 2>&1 || { tail -n 60 "$l" >&2; die "failed ($l)"; }; }

[[ "$(uname -m)" == x86_64 ]] || die "this script targets x86_64 Linux hosts"
for t in curl tar xz make cmake pkg-config patchelf sha256sum; do
  command -v "$t" >/dev/null || die "missing host tool: $t (apt-get install curl xz-utils make cmake pkg-config patchelf coreutils)"
done
[[ -d /usr/include/linux ]] || die "missing kernel headers (/usr/include/linux): apt-get install linux-libc-dev"

# fetch <url> <file> <sha256|skip>
fetch() {
  local url=$1 out="$DL_DIR/$2" sum=$3
  if [[ ! -s "$out" ]]; then
    log "Downloading $2"
    curl -fL --retry 3 -o "$out.part" "$url" && mv "$out.part" "$out"
  fi
  if [[ "$sum" == skip ]]; then
    echo "WARNING: not verifying $2 (sha256 $(sha256sum "$out" | cut -d' ' -f1))"
  else
    echo "$sum  $out" | sha256sum -c --quiet - || die "checksum mismatch for $2"
  fi
}
# unpack <file> <dirname>: fresh extraction into $SRC_DIR/<dirname>
unpack() { rm -rf "$SRC_DIR/$2"; tar -xf "$DL_DIR/$1" -C "$SRC_DIR"; [[ -d "$SRC_DIR/$2" ]] || die "unexpected layout in $1"; }

# Stamp files let a re-run skip dependencies that are already built with the
# same version, Fil-C version and flags (FORCE_DEPS=1 rebuilds them all).
stamp() { echo "$DEPS/.stamp-$1-$2-filc${FILC_VERSION}-$(echo "$CFLAGS_OPT" | tr -c 'A-Za-z0-9\n' _)"; }
need_build() { [[ "${FORCE_DEPS:-0}" == 1 || ! -f "$(stamp "$1" "$2")" ]] || { log "$1 $2 (already built, skipping)"; return 1; }; }
mark_built() { touch "$(stamp "$1" "$2")"; }

# ---- 1. Fil-C ---------------------------------------------------------------
fetch "$FILC_URL" "filc-${FILC_VERSION}-linux-x86_64.tar.xz" "$FILC_SHA256"
if [[ "${SKIP_FILC_SETUP:-0}" != 1 || ! -x "$FILC_DIR/build/bin/filcc" ]]; then
  log "Installing Fil-C $FILC_VERSION into $FILC_DIR"
  rm -rf "$FILC_DIR"
  tar -xf "$DL_DIR/filc-${FILC_VERSION}-linux-x86_64.tar.xz" -C "$WORK_DIR"
  # setup.sh patches rpaths/interpreter to absolute paths of this directory and
  # links the host's kernel UAPI headers into pizfix/os-include.
  (cd "$FILC_DIR" && run filc-setup ./setup.sh)
fi
export CC="$FILC_DIR/build/bin/filcc"
export CXX="$FILC_DIR/build/bin/fil++"
export AR=ar RANLIB=ranlib
"$CC" --version | head -n1

# Isolate from host libraries: pkg-config must only see Fil-C built deps.
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig:$DEPS/share/pkgconfig"
unset PKG_CONFIG_PATH || true
export CFLAGS="$CFLAGS_OPT"
export CXXFLAGS="$CFLAGS_OPT"
export CPPFLAGS="-I$DEPS/include"
export LDFLAGS="-L$DEPS/lib"

# Sanity: Fil-C works and actually catches an out-of-bounds write.
log "Smoke-testing Fil-C"
cat >"$WORK_DIR/oob.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) { volatile char *p = malloc(16); p[15 + argc] = 1; /* 1 past the end */ printf("NOT CAUGHT %d\n", p[0]); return 0; }
C
"$CC" -O2 -static -o "$WORK_DIR/oob" "$WORK_DIR/oob.c"
# (run via sh -c so the expected SIGTRAP is not reported noisily by bash)
if sh -c '"$1" >"$2" 2>&1; exit $?' _ "$WORK_DIR/oob" "$LOG_DIR/oob.log" 2>/dev/null; then die "Fil-C did not catch OOB write?!"; fi
echo "Fil-C caught the OOB write as expected:"; grep -m3 -i "panic\|safety" "$LOG_DIR/oob.log" || head -n 5 "$LOG_DIR/oob.log"

CMAKE_COMMON=(
  -G "Unix Makefiles"
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX"
  -DCMAKE_C_FLAGS_RELEASE="$CFLAGS_OPT"
  -DCMAKE_INSTALL_PREFIX="$DEPS" -DCMAKE_INSTALL_LIBDIR=lib
  -DCMAKE_PREFIX_PATH="$DEPS"
  -DCMAKE_FIND_ROOT_PATH="$DEPS"
  -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
  -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  -DBUILD_SHARED_LIBS=OFF
)

# ---- 2. zlib ------------------------------------------------------------------
if need_build zlib "$ZLIB_VERSION"; then
log "zlib $ZLIB_VERSION"
fetch "$ZLIB_URL" "zlib-${ZLIB_VERSION}.tar.gz" "$ZLIB_SHA256"
unpack "zlib-${ZLIB_VERSION}.tar.gz" "zlib-${ZLIB_VERSION}"
( cd "$SRC_DIR/zlib-${ZLIB_VERSION}"
  run zlib ./configure --static --prefix="$DEPS"
  run zlib make -j"$JOBS" libz.a
  run zlib make install )
mark_built zlib "$ZLIB_VERSION"; fi

# ---- 3. libpng ----------------------------------------------------------------
if need_build libpng "$PNG_VERSION"; then
log "libpng $PNG_VERSION"
fetch "$PNG_URL" "libpng-${PNG_VERSION}.tar.xz" "$PNG_SHA256"
unpack "libpng-${PNG_VERSION}.tar.xz" "libpng-${PNG_VERSION}"
( cd "$SRC_DIR/libpng-${PNG_VERSION}"
  run libpng ./configure --prefix="$DEPS" --disable-shared --enable-static --with-pic \
        --disable-tools --enable-hardware-optimizations=no
  run libpng make -j"$JOBS"
  run libpng make install )
mark_built libpng "$PNG_VERSION"; fi

# ---- 4. libjpeg-turbo ---------------------------------------------------------
# WITH_SIMD=0: its SIMD code is hand-written NASM assembly that cannot be
# linked into a Fil-C program (only Fil-C compiled code may be linked).
if need_build libjpeg-turbo "$JPEG_VERSION"; then
log "libjpeg-turbo $JPEG_VERSION"
fetch "$JPEG_URL" "libjpeg-turbo-${JPEG_VERSION}.tar.gz" "$JPEG_SHA256"
unpack "libjpeg-turbo-${JPEG_VERSION}.tar.gz" "libjpeg-turbo-${JPEG_VERSION}"
( cd "$SRC_DIR/libjpeg-turbo-${JPEG_VERSION}"
  run libjpeg cmake -S . -B build "${CMAKE_COMMON[@]}" \
        -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_SIMD=OFF -DWITH_TURBOJPEG=OFF \
        -DWITH_TOOLS=OFF -DWITH_TESTS=OFF
  run libjpeg cmake --build build -j"$JOBS"
  run libjpeg cmake --install build )
mark_built libjpeg-turbo "$JPEG_VERSION"; fi

# ---- 5. libwebp ---------------------------------------------------------------
# SSE2/SSE4.1 intrinsics are fine under Fil-C (they're compiler builtins).
if need_build libwebp "$WEBP_VERSION"; then
log "libwebp $WEBP_VERSION"
fetch "$WEBP_URL" "libwebp-${WEBP_VERSION}.tar.gz" "$WEBP_SHA256"
unpack "libwebp-${WEBP_VERSION}.tar.gz" "libwebp-${WEBP_VERSION}"
( cd "$SRC_DIR/libwebp-${WEBP_VERSION}"
  run libwebp cmake -S . -B build "${CMAKE_COMMON[@]}" \
        -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
        -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
        -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF \
        -DWEBP_BUILD_LIBWEBPMUX=ON -DWEBP_USE_THREAD=ON
  run libwebp cmake --build build -j"$JOBS"
  run libwebp cmake --install build )
mark_built libwebp "$WEBP_VERSION"; fi

# ---- 6. libtiff (with zlib + jpeg only) --------------------------------------
if need_build libtiff "$TIFF_VERSION"; then
log "libtiff $TIFF_VERSION"
fetch "$TIFF_URL" "tiff-${TIFF_VERSION}.tar.xz" "$TIFF_SHA256"
unpack "tiff-${TIFF_VERSION}.tar.xz" "tiff-${TIFF_VERSION}"
( cd "$SRC_DIR/tiff-${TIFF_VERSION}"
  run libtiff cmake -S . -B build2 "${CMAKE_COMMON[@]}" \
        -Dtiff-tools=OFF -Dtiff-tests=OFF -Dtiff-contrib=OFF -Dtiff-docs=OFF -Dtiff-opengl=OFF \
        -Dzlib=ON -Djpeg=ON -Dpixarlog=ON -Dold-jpeg=ON \
        -Dlibdeflate=OFF -Djbig=OFF -Dlerc=OFF -Dlzma=OFF -Dzstd=OFF -Dwebp=OFF -Dcxx=OFF
  run libtiff cmake --build build2 -j"$JOBS"
  run libtiff cmake --install build2 )
mark_built libtiff "$TIFF_VERSION"; fi

# ---- 7. Little-CMS 2 ------------------------------------------------------------
if need_build lcms2 "$LCMS_VERSION"; then
log "lcms2 $LCMS_VERSION"
fetch "$LCMS_URL" "lcms2-${LCMS_VERSION}.tar.gz" "$LCMS_SHA256"
unpack "lcms2-${LCMS_VERSION}.tar.gz" "lcms2-${LCMS_VERSION}"
( cd "$SRC_DIR/lcms2-${LCMS_VERSION}"
  run lcms2 ./configure --prefix="$DEPS" --disable-shared --enable-static --with-pic \
        --without-jpeg --without-tiff
  run lcms2 make -j"$JOBS" -C src
  run lcms2 make -C src install
  run lcms2 make -C include install
  install -Dm644 lcms2.pc "$DEPS/lib/pkgconfig/lcms2.pc" )
mark_built lcms2 "$LCMS_VERSION"; fi

# ---- 8. ImageMagick -----------------------------------------------------------
log "ImageMagick $IM_VERSION"
fetch "$IM_URL" "ImageMagick-${IM_VERSION}.tar.gz" "$IM_SHA256"
unpack "ImageMagick-${IM_VERSION}.tar.gz" "ImageMagick-${IM_VERSION}"
( cd "$SRC_DIR/ImageMagick-${IM_VERSION}"
  # configure's link tests use -static so they match the final link.
  # PKG_CONFIG="pkg-config --static": static archives need the Requires.private
  # / Libs.private chain (e.g. libwebp -> libsharpyuv, libtiff -> libjpeg/libz).
  run imagemagick ./configure PKG_CONFIG="pkg-config --static" \
        --prefix="$IM_PREFIX" \
        --disable-shared --enable-static --without-modules \
        --disable-openmp --disable-opencl --without-x \
        --without-magick-plus-plus --without-perl --disable-docs \
        --with-utilities \
        --with-zlib --with-png --with-jpeg --with-webp --with-tiff --with-lcms \
        --without-bzlib --without-lzma --without-zstd --without-zip \
        --without-freetype --without-fontconfig --without-raqm --without-pango \
        --without-jxl --without-heic --without-openjp2 --without-openexr \
        --without-raw --without-rsvg --without-xml --without-djvu --without-fftw \
        --without-gslib --without-gvc --without-lqr --without-wmf --without-jbig \
        --without-dps --without-fpx --without-flif --without-uhdr --without-dmr \
        --without-autotrace --without-jemalloc --without-tcmalloc \
        LDFLAGS="$LDFLAGS -static"
  # libtool swallows plain -static for programs; -all-static reaches the linker.
  run imagemagick make -j"$JOBS" LDFLAGS="$LDFLAGS -all-static"
  rm -rf "$IM_DESTDIR"
  run imagemagick make install DESTDIR="$IM_DESTDIR" LDFLAGS="$LDFLAGS -all-static" )
sed -n '/Option *Value/,/^$/p;/Delegate Library Configuration/,/^$/p' "$LOG_DIR/imagemagick.log" | tail -n 60 || true

# ---- 9. Stage relocatable bundle ----------------------------------------------
log "Staging bundle $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE"/{bin,libexec,etc,share/licenses}
R="$IM_DESTDIR$IM_PREFIX"
REAL="$R/bin/magick"
file "$REAL" | grep -q 'static-pie linked\|statically linked' || die "magick is not statically linked: $(file "$REAL")"
cp "$REAL" "$BUNDLE/libexec/magick"
strip --strip-debug "$BUNDLE/libexec/magick"   # keep symbols for readable Fil-C panics
cp -r "$R/etc/ImageMagick-7" "$BUNDLE/etc/"
cp -r "$R/share/ImageMagick-7" "$BUNDLE/share/" 2>/dev/null || true
# Ready-made security policies (open/limited/secure/websafe): copy one over
# etc/ImageMagick-7/policy.xml to harden a server that handles untrusted files.
mkdir -p "$BUNDLE/share/ImageMagick-7/policy-examples"
cp "$SRC_DIR/ImageMagick-${IM_VERSION}"/config/policy-*.xml "$BUNDLE/share/ImageMagick-7/policy-examples/"

# Wrapper: points ImageMagick at the bundled (editable) config files and lets
# legacy names (convert, identify, ...) work via symlinks.
cat >"$BUNDLE/bin/magick" <<'W'
#!/bin/sh
# Wrapper for the Fil-C (memory-safe) static build of ImageMagick.
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
root=$(dirname -- "$here")
# Bundled config files (policy.xml etc.) are consulted before the compiled-in
# defaults; edit $root/etc/ImageMagick-7/policy.xml to restrict resources.
MAGICK_CONFIGURE_PATH="$root/etc/ImageMagick-7${MAGICK_CONFIGURE_PATH:+:$MAGICK_CONFIGURE_PATH}"
export MAGICK_CONFIGURE_PATH
name=$(basename -- "$0")
case "$name" in
  magick|magick-filc) exec "$root/libexec/magick" "$@" ;;
  *)                  exec "$root/libexec/magick" "$name" "$@" ;;
esac
W
chmod +x "$BUNDLE/bin/magick"
for t in animate compare composite conjure convert display identify import \
         magick-script mogrify montage stream; do
  case $t in animate|display|import) continue ;; esac   # X11-only tools
  ln -s magick "$BUNDLE/bin/$t"
done

# Licenses
cp "$SRC_DIR/ImageMagick-${IM_VERSION}/LICENSE" "$BUNDLE/share/licenses/ImageMagick-LICENSE"
cp "$SRC_DIR/zlib-${ZLIB_VERSION}/LICENSE" "$BUNDLE/share/licenses/zlib-LICENSE" 2>/dev/null || true
cp "$SRC_DIR/libpng-${PNG_VERSION}/LICENSE" "$BUNDLE/share/licenses/libpng-LICENSE"
cp "$SRC_DIR/libjpeg-turbo-${JPEG_VERSION}/LICENSE.md" "$BUNDLE/share/licenses/libjpeg-turbo-LICENSE.md"
cp "$SRC_DIR/libwebp-${WEBP_VERSION}/COPYING" "$BUNDLE/share/licenses/libwebp-COPYING"
cp "$SRC_DIR/tiff-${TIFF_VERSION}/LICENSE.md" "$BUNDLE/share/licenses/libtiff-LICENSE.md"
cp "$SRC_DIR/lcms2-${LCMS_VERSION}/LICENSE" "$BUNDLE/share/licenses/lcms2-LICENSE" 2>/dev/null || true
for f in PAS-LICENSE.txt MUSL-LICENSE.txt LLVM-LICENSE.txt; do
  cp "$FILC_DIR/$f" "$BUNDLE/share/licenses/filc-$f"
done

cat >"$BUNDLE/README.txt" <<TXT
ImageMagick ${IM_VERSION} built with Fil-C ${FILC_VERSION} (memory-safe C)
for x86_64 Linux.  Built $(date -u +%Y-%m-%dT%H:%MZ).

bin/magick        wrapper (use this; symlinks provide convert, identify, ...)
libexec/magick    the static-pie executable (no shared libs, no ELF interpreter)
etc/ImageMagick-7 config files (policy.xml etc.), read via MAGICK_CONFIGURE_PATH
share/ImageMagick-7/policy-examples  open/limited/secure/websafe policies; e.g.
                  cp share/ImageMagick-7/policy-examples/policy-websafe.xml \\
                     etc/ImageMagick-7/policy.xml

Formats via delegates: PNG, JPEG, WebP, TIFF, zlib, LCMS2 + built-in coders.
Not included: X11, OpenMP, OpenCL, modules, Magick++, fonts/FreeType (no text
rendering), bzip2/lzma/zstd, JXL, HEIC/AVIF, JPEG2000, EXR, RAW, SVG, XML.
PDF/PS/EPS need an external 'gs' on PATH.

Server requirements: x86_64 Linux, nothing else. The binary is static-pie
(no ELF interpreter, no NEEDED libraries, no glibc symbol versions), so the
server's libc/distro does not matter. /bin/sh is only needed for the wrapper;
libexec/magick also runs directly (then set MAGICK_CONFIGURE_PATH yourself). Memory-safety violations abort
the process with a "filc panic" message instead of being exploitable.
TXT

# ---- 10. Tarball ----------------------------------------------------------------
TARBALL="$OUT_DIR/$BUNDLE_NAME.tar.gz"
log "Creating $TARBALL"
tar -C "$WORK_DIR" -czf "$TARBALL" "$BUNDLE_NAME"
( cd "$OUT_DIR" && sha256sum "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256" )

# ---- 11. Verify ---------------------------------------------------------------
log "Verifying bundle from a fresh extraction with a clean environment"
T="$(mktemp -d)"
tar -xzf "$TARBALL" -C "$T"
B="$T/$BUNDLE_NAME"
env -i PATH=/usr/bin:/bin HOME="$T" "$B/bin/magick" -version
env -i PATH=/usr/bin:/bin HOME="$T" sh -c "
  set -e; cd '$T'
  '$B/bin/magick' -size 640x480 gradient:red-blue -swirl 90 test.png
  '$B/bin/magick' test.png -resize 50% -quality 85 test.jpg
  '$B/bin/magick' test.jpg test.webp
  '$B/bin/magick' test.webp -colorspace Gray test.tif
  '$B/bin/convert' test.tif -rotate 45 test2.png
  '$B/bin/identify' test.png test.jpg test.webp test.tif test2.png
  # policy.xml from the bundle must be honoured: forbid WEBP and expect failure
  cp '$B/etc/ImageMagick-7/policy.xml' policy.bak
  echo '<policymap><policy domain=\"coder\" rights=\"none\" pattern=\"WEBP\"/></policymap>' > '$B/etc/ImageMagick-7/policy.xml'
  if '$B/bin/magick' test.png blocked.webp 2>policy.err; then echo 'policy.xml NOT honoured' >&2; exit 1; fi
  echo \"policy.xml honoured: \$(head -n1 policy.err)\"
  cp policy.bak '$B/etc/ImageMagick-7/policy.xml'
"
echo "Dependencies of the executable (expect: static-pie, no INTERP, no NEEDED):"
file "$B/libexec/magick"
readelf -lW "$B/libexec/magick" | grep INTERP >/dev/null && die "unexpected ELF interpreter"
readelf -dW "$B/libexec/magick" | grep NEEDED && die "unexpected NEEDED entries"
echo "OK: no ELF interpreter, no shared library dependencies."
rm -rf "$T"
log "Done"
echo "Tarball: $TARBALL ($(du -h "$TARBALL" | cut -f1))"
