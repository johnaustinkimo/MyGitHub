#!/bin/bash
set -euo pipefail

SRC=${1:-epv_api_cli_v2.3.1_rhel7.c}
OUT=${2:-epv_api_cli_v2.3.1_rhel7}
CC=${CC:-gcc}

if ! command -v "$CC" >/dev/null 2>&1; then
    echo "ERROR: compiler not found: $CC" >&2
    exit 1
fi

# Determine glibc version. RHEL7 (glibc 2.17) supports FORTIFY level 2,
# while newer glibc releases can support level 3.
GLIBC_VERSION=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}' || true)
FORTIFY_LEVEL=2
if [ -n "${GLIBC_VERSION:-}" ]; then
    GLIBC_MAJOR=${GLIBC_VERSION%%.*}
    _rest=${GLIBC_VERSION#*.}
    GLIBC_MINOR=${_rest%%.*}
    if [ "$GLIBC_MAJOR" -gt 2 ] || { [ "$GLIBC_MAJOR" -eq 2 ] && [ "$GLIBC_MINOR" -ge 34 ]; }; then
        FORTIFY_LEVEL=3
    fi
fi

# Probe compiler support so this one script works with GCC 4.8.x on RHEL7
# as well as newer GCC versions on RHEL8/9/10.
supports_cc_flag() {
    local flag=$1
    printf 'int main(void){return 0;}\n' | "$CC" -x c - -c -o /dev/null "$flag" >/dev/null 2>&1
}

CFLAGS=(
    -std=gnu11 -O2 -pipe
    -Wall -Wextra -Wshadow -Wconversion -Wformat=2
    "-D_FORTIFY_SOURCE=${FORTIFY_LEVEL}"
    -fPIE
)

for flag in \
    -Wnull-dereference \
    -Wimplicit-fallthrough \
    -fstack-protector-strong; do
    if supports_cc_flag "$flag"; then
        CFLAGS+=("$flag")
    fi
done

# RHEL7/OpenSSL is normally 1.0.2; modern RHEL uses newer OpenSSL.
OPENSSL_VERSION=$(openssl version 2>/dev/null | awk '{print $2}' || true)
GCC_VERSION=$($CC --version 2>/dev/null | head -1 || true)

echo "Building:       $SRC -> $OUT"
echo "Compiler:       ${GCC_VERSION:-unknown}"
echo "glibc:          ${GLIBC_VERSION:-unknown}"
echo "OpenSSL:        ${OPENSSL_VERSION:-unknown}"
echo "FORTIFY_SOURCE: $FORTIFY_LEVEL"
echo "CFLAGS:         ${CFLAGS[*]}"

"$CC" "${CFLAGS[@]}" \
    "$SRC" -o "$OUT" \
    -pie -Wl,-z,relro,-z,now -Wl,-z,noexecstack \
    -lssl -lcrypto

echo "Build OK: $OUT"
