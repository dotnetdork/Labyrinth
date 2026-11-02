#!/usr/bin/env bash
# lockout.inventory, check: record what the host has and what each scored
# service connects out to (design 08, section 3.1). Read-only: with
# LAB_DRY_RUN=1 (a preview, or the plan stage of a run) it prints what it
# found and writes nothing; with LAB_DRY_RUN=0 (the runner's recording call,
# design 00, section 4) it also writes the dependency map and the inventory
# under the state folder. It only observes, so it exits 0.
#
# The listeners and connections are taken first and the dependency map is
# written before the slow kinds (packages, accounts, tasks) are collected, so
# the map the firewall needs exists even if the rest is cut short.
set -Eeuo pipefail

: "${LAB_ROOT:?LAB_ROOT is not set}"
# shellcheck source=core/lib.sh
source "$LAB_ROOT/core/lib.sh"
# shellcheck source=phases/lockout/modules/inventory/inventory.sh
source "$LAB_ROOT/phases/lockout/modules/inventory/inventory.sh"

run=0
if [[ "${LAB_DRY_RUN:-1}" == 0 ]]; then run=1; fi

inv_collect_sockets
inv_build_map
if (( run )) && ! inv_write_deps; then
  echo "problem: the dependency map could not be written under $LAB_STATE_DIR/inventory"
  exit 40
fi
inv_collect_rest
inv_say_found
if (( run )) && ! inv_write_inventory; then
  echo "problem: the inventory could not be written under $LAB_STATE_DIR/inventory"
  exit 40
fi
exit 0
