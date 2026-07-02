#!/bin/zsh
# Build the app, stage the zip, deploy the download site to Cloudflare.
set -euo pipefail
cd "$(dirname "$0")"

source ~/.config/cloudflare/credentials

../app/build.sh
cp ../app/build/ContextLayer-*.zip public/

npx --yes wrangler@latest deploy
