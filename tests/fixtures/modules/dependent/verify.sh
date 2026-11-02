#!/usr/bin/env bash
set -Eeuo pipefail
if [[ -e "$LAB_ROOT/FAIL_VERIFY" ]]; then echo "dependent: verify forced to fail"; exit 30; fi
grep -qx "setting=on" "$LAB_ROOT/dependent.conf" || exit 30
