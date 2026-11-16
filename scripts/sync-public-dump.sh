#!/usr/bin/env bash
# Copies the files of the public dump (the scripts, the SQL and the page
# template) from a checkout of philomena-public-dump into the philomena
# chart. They are maintained there, together with the Docker Compose
# deployment's copy; change them there, then run this and raise the chart
# version.
#
# Usage: scripts/sync-public-dump.sh [checkout]   (default: ../philomena-public-dump)
set -euo pipefail
cd "$(dirname "$0")/.."

source=${1:-../philomena-public-dump}
files=(public-dump.sh public-dump.sql public-dump-upload.sh index.html.tmpl)

for file in "${files[@]}"; do
  [ -f "$source/$file" ] || {
    echo "$source/$file does not exist" >&2
    exit 1
  }
done

for file in "${files[@]}"; do
  cp "$source/$file" "charts/philomena/files/$file"
done

git status --short charts/philomena/files
