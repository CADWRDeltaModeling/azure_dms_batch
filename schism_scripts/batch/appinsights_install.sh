#!/bin/bash
if [[ $1 == "" ]]; then
    app_insights_version="v1.3.0"
else 
    app_insights_version=$1
fi

export BATCH_INSIGHTS_DOWNLOAD_URL="https://github.com/Azure/batch-insights/releases/download/${app_insights_version}/batch-insights"
wget  -O - https://raw.githubusercontent.com/Azure/batch-insights/master/scripts/run-linux.sh | bash
