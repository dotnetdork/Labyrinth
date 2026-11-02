#!/usr/bin/env bash
# Test fixture: what the recorder reports when its check wants a change.
set -Eeuo pipefail
echo "recorder: would write the marker"
exit 10
