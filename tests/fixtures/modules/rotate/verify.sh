#!/usr/bin/env bash
set -Eeuo pipefail
if grep -qx '[0-9a-f]\{64\}' "$LAB_ROOT/rotate.pw" 2> /dev/null; then exit 0; fi
exit 30
