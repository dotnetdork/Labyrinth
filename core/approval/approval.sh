# shellcheck shell=bash
# core/approval/approval.sh: items for approval modules (docs/Conventions.md
# section 3.1, "Approval items"). Sourced through core/lib.sh.
#
# An approval module's plan prints one line per item it would change, with
# lab_item. Its apply changes an item only when lab_approved says a person
# approved it and it has not changed since the plan.

# lab_item_fingerprint: the fingerprint of the item state on standard input:
# the first 12 hex digits of its SHA-256.
lab_item_fingerprint() {
  local sum
  sum="$(sha256sum)" || return 40
  printf '%s\n' "${sum:0:12}"
}

# lab_item ID CATEGORY FINGERPRINT REASON: print one item line for the plan.
# Tabs and other control characters in REASON become spaces. Returns 40 when
# a field is malformed.
lab_item() {
  local id="$1" category="$2" fp="$3" reason="${4:-}"
  if [[ ! "$id" =~ ^[a-z0-9-]+$ || ! "$category" =~ ^[a-z0-9-]+$ || ! "$fp" =~ ^[0-9a-f]{12}$ ]]; then
    printf 'approval: malformed item: id %s, category %s, fingerprint %s\n' "$id" "$category" "$fp" >&2
    return 40
  fi
  reason="${reason//[[:cntrl:]]/ }"
  printf 'item\t%s\t%s\t%s\t%s\n' "$id" "$category" "$fp" "$reason"
}

# lab_approved ID FINGERPRINT: may apply change item ID, whose state has
# FINGERPRINT now? Returns 0 when a person approved it and it is unchanged
# since the plan, and 1 when it was not approved. Returns 2 when it was
# approved but has changed since: it is recorded as refused and must be left
# alone.
lab_approved() {
  local id="$1" fp="$2" entry
  local -a approved=()
  read -ra approved <<< "${LAB_APPROVED:-}"
  for entry in ${approved[@]+"${approved[@]}"}; do
    if [[ "${entry%@*}" != "$id" ]]; then continue; fi
    if [[ "${entry##*@}" == "$fp" ]]; then return 0; fi
    lab_manifest_record approval_refused "$id" '' "${entry##*@}" "changed since the plan; now $fp" || true
    lab_log_warn approval_refused "$id changed since the plan, so it was left alone" || true
    return 2
  done
  return 1
}
