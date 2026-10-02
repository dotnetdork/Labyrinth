#!/usr/bin/env bash
set -Eeuo pipefail
if [[ -e "$LAB_ROOT/FAIL_VERIFY" ]]; then echo "toggle: verify forced to fail"; exit 30; fi
grep -qx "setting=on" "$LAB_ROOT/toggle.conf" || exit 30
