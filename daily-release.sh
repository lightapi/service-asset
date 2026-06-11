#!/usr/bin/env bash
# daily-release.sh
# Master script to execute the daily release pipeline in the correct sequence.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================================="
echo "Starting Daily Release Pipeline"
echo "=========================================================="

echo ""
echo "Step 1/2: Updating assets (update-asset.sh)"
echo "----------------------------------------------------------"
"$SCRIPT_DIR/update-asset.sh"

echo ""
echo "Step 2/3: Releasing Docker images (release-docker-images.sh)"
echo "----------------------------------------------------------"
"$SCRIPT_DIR/release-docker-images.sh"

echo ""
echo "Step 3/3: Committing and pushing updates to GitHub"
echo "----------------------------------------------------------"
cd "$SCRIPT_DIR"
if [ -n "$(git status --porcelain)" ]; then
    git add -A
    git commit -m "Daily release update $(date -u '+%Y-%m-%d %H:%M UTC')"
    git push origin HEAD
    echo "Changes pushed to GitHub successfully."
else
    echo "No changes to commit."
fi

echo ""
echo "=========================================================="
echo "Daily Release Pipeline Completed Successfully!"
echo "=========================================================="
