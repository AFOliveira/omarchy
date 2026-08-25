echo "Repair machine browser policy ownership and quarantine untrusted policies"

policy_helper=/usr/bin/omarchy-browser-policy

if [[ ! -x $policy_helper ]]; then
  echo "Browser policy repair helper is unavailable: $policy_helper" >&2
  omarchy-notification-send -u critical "Browser policy repair failed" \
    "The packaged browser policy helper is missing. Run omarchy-update again." 2>/dev/null || true
  exit 1
fi

repair_output=$(sudo "$policy_helper" repair) || {
  echo "Could not secure the machine browser policy directories." >&2
  omarchy-notification-send -u critical "Browser policy repair failed" \
    "A machine browser policy path was unsafe or could not be repaired. Run omarchy-update again." 2>/dev/null || true
  exit 1
}

if [[ -n $repair_output ]]; then
  printf '%s\n' "$repair_output"
  omarchy-notification-send -u critical "Browser policies quarantined" \
    "Policies created while machine policy directories were writable were disabled and quarantined. Review the update output for their locations." 2>/dev/null || true
fi

# The repair installs a neutral fixed-schema Chromium policy. Restore the
# current user's validated theme colour through the narrow passwordless helper.
omarchy-theme-set-browser || {
  echo "Browser policy directories were secured, but the current theme color could not be restored." >&2
  exit 1
}
