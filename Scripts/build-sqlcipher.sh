#!/bin/zsh
# Build the pinned database library with Apple's crypto. Nothing from Homebrew ships or links.
set -euo pipefail
cd ${0:A:h}/..
ROOT="$PWD/.build-release-deps"
VERSION=4.19.0
SHA256=7075f96cbabe45b4ecfc2e6b1745a625f856f695b0827a5506ce9ed85b906aa0
ARCHIVE="$ROOT/sqlcipher-$VERSION.tar.gz"
SOURCE="$ROOT/sqlcipher-$VERSION"
PREFIX="$ROOT/prefix"
mkdir -p "$ROOT" "$PREFIX/lib/pkgconfig" "$PREFIX/include/sqlcipher"
if [[ ! -f "$ARCHIVE" ]]; then
    curl -fL --retry 2 "https://github.com/sqlcipher/sqlcipher/archive/refs/tags/v$VERSION.tar.gz" -o "$ARCHIVE"
fi
print "$SHA256  $ARCHIVE" | shasum -a 256 -c -
if [[ ! -d "$SOURCE" ]]; then tar -xzf "$ARCHIVE" -C "$ROOT"; fi
STAMP="sqlcipher-$VERSION-commoncrypto-arm64-macos26-v1"
if [[ ! -f "$PREFIX/stamp" || "$(cat "$PREFIX/stamp")" != "$STAMP" || ! -f "$PREFIX/lib/libsqlcipher.a" ]]; then
    mkdir -p "$ROOT/amalgamation"
    (
        cd "$ROOT/amalgamation"
        "$SOURCE/configure" --disable-tcl --with-tempstore=yes
        make sqlite3.c
        xcrun clang -arch arm64 -mmacosx-version-min=26.0 -O2 -DNDEBUG \
            -DSQLCIPHER_CRYPTO_CC -DSQLITE_HAS_CODEC -DSQLITE_TEMP_STORE=2 -DSQLITE_THREADSAFE=1 \
            -DSQLITE_EXTRA_INIT=sqlcipher_extra_init -DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown \
            -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_COLUMN_METADATA -DSQLITE_OMIT_LOAD_EXTENSION \
            -c sqlite3.c -o sqlcipher.o
        xcrun libtool -static sqlcipher.o -o "$PREFIX/lib/libsqlcipher.a"
        cp sqlite3.h "$PREFIX/include/sqlcipher/"
    )
    print "$STAMP" > "$PREFIX/stamp"
fi
cat > "$PREFIX/lib/pkgconfig/sqlcipher.pc" <<EOF
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include/sqlcipher
Name: SQLCipher
Description: SQLCipher with Apple CommonCrypto, statically linked
Version: $VERSION
Libs: -L\${libdir} -lsqlcipher -framework Security
Cflags: -I\${includedir} -DSQLITE_HAS_CODEC
EOF
print "Built pinned SQLCipher in $PREFIX"
