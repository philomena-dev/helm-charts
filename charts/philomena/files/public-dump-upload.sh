#!/bin/sh
# Publishes what public-dump.sh wrote to an S3 bucket.
#
# Runs in the rclone image. The bucket is the rclone remote "dest", which is
# configured through the environment (RCLONE_CONFIG_DEST_TYPE=s3,
# RCLONE_CONFIG_DEST_ENDPOINT, RCLONE_CONFIG_DEST_ACCESS_KEY_ID, ...).
#
# Usage: public-dump-upload.sh [directory]   (default: /scratch/out)
#
# Settings, read from the environment:
#
#   S3_BUCKET   bucket to upload to (required)
#   S3_PATH     key prefix inside the bucket (the root of the bucket)
#   RETENTION   age from which dumps are deleted from the bucket, as rclone
#               writes it: 7d, 4w, ... (nothing is deleted)

set -eu

: "${S3_BUCKET:?S3_BUCKET must be set}"

# The remote is configured through the environment alone.
export RCLONE_CONFIG=/dev/null

out=${1:-/scratch/out}
dest="dest:$S3_BUCKET${S3_PATH:+/$S3_PATH}"

if [ ! -f "$out/latest.json" ]; then
  echo "There is no dump in $out" >&2
  exit 1
fi

echo "Uploading to $dest..."
# The dump goes first. latest.json and the page replace the ones of the
# previous dump the moment they arrive, and name a file that has to be there.
rclone copy -v --include '*.pgdump' "$out" "$dest"
rclone copy -v --exclude '*.pgdump' "$out" "$dest"

if [ -n "${RETENTION:-}" ]; then
  echo "Deleting dumps older than $RETENTION..."
  rclone delete -v --min-age "$RETENTION" --include '*.pgdump' "$dest"
fi

echo "Done."
