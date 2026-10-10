#!/usr/bin/env bash
set -Eeuo pipefail
if grep -qx "setting=on" "$LAB_ROOT/keeper.conf" 2> /dev/null; then exit 0; fi
echo "keeper: setting is not on"
exit 10
