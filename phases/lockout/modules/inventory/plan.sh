#!/usr/bin/env bash
# lockout.inventory, plan: say what a run records and where. Read-only, and
# quick: it collects nothing (check does). The inventory only observes, so
# its check never asks for a change and the runner has no reason to call this
# in a run; it is here for the module contract (design 00, section 4).
set -Eeuo pipefail

: "${LAB_STATE_DIR:?LAB_STATE_DIR is not set}"
dir="$LAB_STATE_DIR/inventory"

echo "will do: write the inventory, one JSON line per item, to a new file in $dir"
echo "will do: add the outbound connections of each scored service to $dir/deps"
echo "why: the firewall's default deny must not cut off an address a scored service needs"
echo "risk: none; it only reads, and the map only ever grows"
exit 0
