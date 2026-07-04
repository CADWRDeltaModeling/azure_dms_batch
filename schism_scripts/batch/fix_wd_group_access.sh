#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./fix_wd_group_access.sh /mnt/batch/tasks/workitems/<job>/job-1/<task>
#   ./fix_wd_group_access.sh /mnt/batch/tasks/workitems/<job>/job-1/<task>/wd

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
  echo "Usage: $0 <task-dir-or-wd-dir>"
  exit 1
fi

GROUP="_azbatchgrp"
USER_TO_ADD="batch-explorer-user"

# Accept either task dir or wd dir
if [[ "$(basename "$TARGET")" == "wd" ]]; then
  WD_PATH="$TARGET"
else
  WD_PATH="$TARGET/wd"
fi

if [[ ! -d "$WD_PATH" ]]; then
  echo "Error: wd directory not found: $WD_PATH"
  exit 1
fi

echo "Ensuring user is in group $GROUP..."
sudo usermod -aG "$GROUP" "$USER_TO_ADD"

echo "Setting group ownership on wd tree..."
sudo chown -R :"$GROUP" "$WD_PATH"

echo "Granting group read/write/traverse permissions..."
sudo chmod -R g+rwX "$WD_PATH"

echo "Ensuring new files inherit group ($GROUP)..."
sudo find "$WD_PATH" -type d -exec chmod g+s {} +

echo "Done. Verifying access as $USER_TO_ADD..."
sudo -u "$USER_TO_ADD" ls -ld "$WD_PATH"

echo "If this is a new group assignment, re-login may be required for active shells."
