#!/usr/bin/env bash
set -Eeuo pipefail
if grep -qx "setting=on" "$LAB_ROOT/toggle.conf" 2> /dev/null; then exit 0; fi
echo "toggle: setting is not on"
exit 10
