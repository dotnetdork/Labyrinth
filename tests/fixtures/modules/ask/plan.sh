#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=/dev/null
source "$LAB_ROOT/core/lib.sh"
# Each item's state is its own id, so its fingerprint is fixed.
lab_item item-a sample "$(printf 'item-a' | lab_item_fingerprint)" 'first sample item'
lab_item item-b sample "$(printf 'item-b' | lab_item_fingerprint)" 'second sample item'
lab_item item-c other "$(printf 'item-c' | lab_item_fingerprint)" 'an item of another category'
exit 10
