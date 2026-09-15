#!/bin/bash
set -euo pipefail

SRC="${1:-epv_api_cli_v2.3.3_rhel7.c}"
OUT="${2:-epv_api_cli_v2.3.3_rhel7}"
CC="${CC:-gcc}"

if [ ! -r "$SRC" ]; then
    echo "ERROR: source not readable: $SRC" >&2
    exit 1
fi
if ! command -v "$CC" >/dev/null 2>&1; then
    echo "ERROR: compiler not found: $CC" >&2
    exit 1
fi

GLIBC_VERSION="$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}' || true)"
OPENSSL_VERSION="$(openssl version 2>/dev/null || true)"
GCC_VERSION="$($CC --version 2>/dev/null | head -1 || true)"

FORTIFY=2
if [ -n "$GLIBC_VERSION" ]; then
    GLIBC_MAJOR="${GLIBC_VERSION%%.*}"
    rest="${GLIBC_VERSION#*.}"
    GLIBC_MINOR="${rest%%.*}"
    case "$GLIBC_MAJOR:$GLIBC_MINOR" in
        ''|*[!0-9:]* ) ;;
        * )
            if [ "$GLIBC_MAJOR" -gt 2 ] || { [ "$GLIBC_MAJOR" -eq 2 ] && [ "$GLIBC_MINOR" -ge 34 ]; }; then
                FORTIFY=3
            fi
            ;;
    esac
fi

TMPDIR_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/epv-build.XXXXXX")"
trap 'rm -rf "$TMPDIR_BUILD"' EXIT
cat > "$TMPDIR_BUILD/probe.c" <<'EOF'
int main(void) { return 0; }
EOF

supports_compile_flag() {
    "$CC" -Werror "$1" -c "$TMPDIR_BUILD/probe.c" -o "$TMPDIR_BUILD/probe.o" >/dev/null 2>&1
}

supports_link_flag() {
    "$CC" "$TMPDIR_BUILD/probe.c" "$1" -o "$TMPDIR_BUILD/probe" >/dev/null 2>&1
}

CFLAGS=(
    -std=gnu11
    -O2
    -pipe
    -Wall
    -Wextra
    -Wformat=2
    -Wformat-security
    -Werror=implicit-function-declaration
    -D_FORTIFY_SOURCE="$FORTIFY"
    -fPIE
)

for flag in \
    -Wpedantic \
    -Wshadow \
    -Wconversion \
    -Wsign-conversion \
    -Wnull-dereference \
    -Wimplicit-fallthrough; do
    if supports_compile_flag "$flag"; then
        CFLAGS+=("$flag")
    fi
done

STACK_PROTECTOR="-fstack-protector"
if supports_compile_flag -fstack-protector-strong; then
    STACK_PROTECTOR="-fstack-protector-strong"
elif supports_compile_flag -fstack-protector-all; then
    STACK_PROTECTOR="-fstack-protector-all"
fi
CFLAGS+=("$STACK_PROTECTOR")

LDFLAGS=(-pie)
for flag in -Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack; do
    if supports_link_flag "$flag"; then
        LDFLAGS+=("$flag")
    fi
done

LIBS=(-lssl -lcrypto)

echo "EPV API client portable build"
echo "  source          : $SRC"
echo "  output          : $OUT"
echo "  compiler        : ${GCC_VERSION:-unknown}"
echo "  glibc           : ${GLIBC_VERSION:-unknown}"
echo "  OpenSSL         : ${OPENSSL_VERSION:-unknown}"
echo "  FORTIFY_SOURCE  : $FORTIFY"
echo "  stack protector : $STACK_PROTECTOR"

echo "Compiling..."
"$CC" "${CFLAGS[@]}" "$SRC" -o "$OUT" "${LDFLAGS[@]}" "${LIBS[@]}"

if command -v file >/dev/null 2>&1; then
    file "$OUT"
fi
if command -v ldd >/dev/null 2>&1; then
    echo "Dynamic dependencies:"
    ldd "$OUT" || true
fi

echo "Build OK: $OUT"
