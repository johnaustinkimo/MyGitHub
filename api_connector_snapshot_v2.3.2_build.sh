#!/bin/bash
set -euo pipefail

SRC=${1:-api_connector_snapshot_v2.3.2.c}
OUT=${2:-api_connector_snapshot_v2.3.2}
CC=${CC:-gcc}

if ! command -v "$CC" >/dev/null 2>&1; then
    echo "ERROR: compiler not found: $CC" >&2
    exit 1
fi

for hdr in sqlite3.h openssl/ssl.h jansson.h; do
    if ! printf '#include <%s>\nint main(void){return 0;}\n' "$hdr" | \
         "$CC" -x c - -c -o /tmp/epv_hdr_test.$$ >/dev/null 2>&1; then
        rm -f /tmp/epv_hdr_test.$$
        echo "ERROR: required development header missing: $hdr" >&2
        echo "RHEL install hint: yum/dnf install gcc openssl-devel sqlite-devel jansson-devel" >&2
        exit 1
    fi
    rm -f /tmp/epv_hdr_test.$$
done

GLIBC_VERSION=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}' || true)
OPENSSL_VERSION=$(openssl version 2>/dev/null | head -1 || true)
GCC_VERSION=$($CC --version 2>/dev/null | head -1 || true)

FORTIFY_LEVEL=2
if [[ -n "${GLIBC_VERSION:-}" ]]; then
    GLIBC_MAJOR=${GLIBC_VERSION%%.*}
    REST=${GLIBC_VERSION#*.}
    GLIBC_MINOR=${REST%%.*}
    if [[ "$GLIBC_MAJOR" -gt 2 ]] || \
       { [[ "$GLIBC_MAJOR" -eq 2 ]] && [[ "$GLIBC_MINOR" -ge 34 ]]; }; then
        FORTIFY_LEVEL=3
    fi
fi

TMPBASE=/tmp/epv_cc_probe.$$
trap 'rm -f "${TMPBASE}"*' EXIT

cc_supports_flag() {
    local flag=$1
    printf 'int main(void){return 0;}\n' | \
        "$CC" -std=gnu11 -Werror "$flag" -x c - -c -o "${TMPBASE}.o" \
        >/dev/null 2>&1
}

CFLAGS=(
    -std=gnu11
    -O2
    -pipe
    -Wall
    -Wextra
    -Wshadow
    -Wformat=2
    -Wconversion
    "-D_FORTIFY_SOURCE=${FORTIFY_LEVEL}"
    -fPIE
    -pthread
)

for flag in -Wformat-security -Wnull-dereference -Wimplicit-fallthrough; do
    if cc_supports_flag "$flag"; then
        CFLAGS+=("$flag")
    fi
done

if cc_supports_flag -fstack-protector-strong; then
    CFLAGS+=(-fstack-protector-strong)
elif cc_supports_flag -fstack-protector-all; then
    CFLAGS+=(-fstack-protector-all)
else
    CFLAGS+=(-fstack-protector)
fi

LDFLAGS=(
    -pie
    -pthread
    -Wl,-z,relro
    -Wl,-z,now
    -Wl,-z,noexecstack
)
LIBS=(-lsqlite3 -lssl -lcrypto -ljansson -lrt)

# Some architectures/toolchains require libatomic for C11 atomic operations.
if ! printf '#include <stdatomic.h>\nint main(void){atomic_llong x=0; return (int)atomic_fetch_add(&x,1);}\n' | \
     "$CC" -std=gnu11 -x c - -o "${TMPBASE}.atomic" >/dev/null 2>&1; then
    if printf '#include <stdatomic.h>\nint main(void){atomic_llong x=0; return (int)atomic_fetch_add(&x,1);}\n' | \
       "$CC" -std=gnu11 -x c - -o "${TMPBASE}.atomic" -latomic >/dev/null 2>&1; then
        LIBS+=(-latomic)
    else
        echo "ERROR: compiler/runtime does not provide required C11 atomic support" >&2
        exit 1
    fi
fi

echo "EPV connector portable build"
echo "  source          : $SRC"
echo "  output          : $OUT"
echo "  compiler        : ${GCC_VERSION:-unknown}"
echo "  glibc           : ${GLIBC_VERSION:-unknown}"
echo "  OpenSSL         : ${OPENSSL_VERSION:-unknown}"
echo "  FORTIFY_SOURCE  : $FORTIFY_LEVEL"
echo "  stack protector : $(printf '%s\n' "${CFLAGS[@]}" | grep '^-fstack-protector' | tail -1)"

"$CC" "${CFLAGS[@]}" "$SRC" -o "$OUT" "${LDFLAGS[@]}" "${LIBS[@]}"
chmod 0755 "$OUT"

echo "Build OK: $OUT"
if command -v file >/dev/null 2>&1; then file "$OUT"; fi
