#!/usr/bin/env bash
set -Eeuo pipefail
if [[ -e "$LAB_ROOT/FAIL_VERIFY" ]]; then echo "keeper: verify forced to fail"; exit 30; fi
grep -qx "setting=on" "$LAB_ROOT/keeper.conf" || exit 30
