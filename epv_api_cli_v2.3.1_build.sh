#!/bin/bash
set -euo pipefail
SRC=${1:-epv_api_cli_v2.3.1.c}
OUT=${2:-epv_api_cli_v2.3.1}
exec gcc -std=gnu11 -O2 -pipe \
  -Wall -Wextra -Wshadow -Wconversion -Wformat=2 \
  -Wnull-dereference -Wimplicit-fallthrough \
  -fstack-protector-strong -D_FORTIFY_SOURCE=3 -fPIE \
  "$SRC" -o "$OUT" \
  -pie -Wl,-z,relro,-z,now -Wl,-z,noexecstack \
  -lssl -lcrypto
