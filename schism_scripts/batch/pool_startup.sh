#!/bin/env bash
# This script is run on the pool nodes when they are created.
# Especially needed for custom images, where installs are permanent but these settings are not.
cd /opt/schism_scripts/batch
source ./enable_sudo_for_batch.sh
source ./make_root_ssh_passwordless.sh
source ./appinsights_start.sh