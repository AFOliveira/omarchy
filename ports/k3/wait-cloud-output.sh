#!/bin/bash
set -euo pipefail

for (( attempt = 0; attempt < 60; attempt++ )); do
  if hyprctl monitors -j 2>/dev/null | jq -e '.[] | select(.name == "K3-CLOUD" and .disabled == false)' >/dev/null; then
    exit 0
  fi
  sleep 1
done
echo "The K3 cloud output did not become ready." >&2
exit 1
