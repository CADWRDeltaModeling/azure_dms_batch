#!/bin/bash
export APP_INSIGHTS_INSTRUMENTATION_KEY="48148b53-57d1-45d9-b682-fae92a74e526"
export APP_INSIGHTS_APP_ID="c97cfe6e-a29c-4801-88cd-56b7fe64204d" # Application Insights :"schism-app-insights"
export BATCH_INSIGHTS_DOWNLOAD_URL="https://github.com/Azure/batch-insights/releases/download/v1.3.0/batch-insights"
wget  -O - https://raw.githubusercontent.com/Azure/batch-insights/master/scripts/run-linux.sh | bash
