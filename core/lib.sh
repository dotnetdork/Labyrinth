# shellcheck shell=bash
# core/lib.sh: loads the Labyrinth core library on Linux. The runner and
# every module entry point load it the same way (docs/Conventions.md section 3):
#
#   source "$LAB_ROOT/core/lib.sh"
#
# Loading it only defines functions and empty variables; it changes nothing.

if [[ -z "${LAB_CORE_LOADED:-}" ]]; then
  LAB_CORE_LOADED=1
  # shellcheck source=core/config/config.sh
  source "${LAB_ROOT:?LAB_ROOT is not set}/core/config/config.sh"
  # shellcheck source=core/log/log.sh
  source "$LAB_ROOT/core/log/log.sh"
  # shellcheck source=core/manifest/manifest.sh
  source "$LAB_ROOT/core/manifest/manifest.sh"
  # shellcheck source=core/safety/safety.sh
  source "$LAB_ROOT/core/safety/safety.sh"
  # shellcheck source=core/safety/system.sh
  source "$LAB_ROOT/core/safety/system.sh"
  # shellcheck source=core/approval/approval.sh
  source "$LAB_ROOT/core/approval/approval.sh"
  # shellcheck source=core/quarantine/quarantine.sh
  source "$LAB_ROOT/core/quarantine/quarantine.sh"
  # shellcheck source=core/secret/secret.sh
  source "$LAB_ROOT/core/secret/secret.sh"
  # shellcheck source=core/platform/platform.sh
  source "$LAB_ROOT/core/platform/platform.sh"
  # shellcheck source=core/probe/probe.sh
  source "$LAB_ROOT/core/probe/probe.sh"
fi
