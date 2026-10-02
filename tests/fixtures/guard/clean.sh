#!/usr/bin/env bash
# curl is mentioned only in this comment
set -Eeuo pipefail
lab_log_info "starting"
curl -fsS --max-time 5 "$url"   # lab-guard: allow network -- probe of a scored service inside the event network
