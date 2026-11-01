#!/usr/bin/env bash
# lockout.inventory, check: record what the host has and what each scored
# service connects out to (design 08, section 3.1). Read-only: with
# LAB_DRY_RUN=1 (a preview, or the plan stage of a run) it prints what it
# found and writes nothing; with LAB_DRY_RUN=0 (the runner's recording call,
# design 00, section 4) it also writes the inventory and the dependency map
# under the state folder. It only observes, so it exits 0.
set -Eeuo pipefail

: "${LAB_ROOT:?LAB_ROOT is not set}"
# shellcheck source=core/lib.sh
source "$LAB_ROOT/core/lib.sh"
# shellcheck source=phases/lockout/modules/inventory/inventory.sh
source "$LAB_ROOT/phases/lockout/modules/inventory/inventory.sh"

inv_collect_all
inv_build_map
inv_say_found

if [[ "${LAB_DRY_RUN:-1}" == 0 ]]; then
  if ! inv_write; then
    echo "problem: the inventory could not be written under $LAB_STATE_DIR/inventory"
    exit 40
  fi
fi
exit 0
