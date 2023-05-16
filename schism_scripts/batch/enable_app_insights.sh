#!/bin/bash
export BATCH_INSIGHTS_DOWNLOAD_URL="https://github.com/Azure/batch-insights/releases/download/v1.3.0/batch-insights"
wget  -O - https://raw.githubusercontent.com/Azure/batch-insights/master/scripts/run-linux.sh | bash
