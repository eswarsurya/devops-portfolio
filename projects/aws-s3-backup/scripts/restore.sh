#!/usr/bin/env bash
#
# restore.sh - download a backup from S3, verify its checksum, and extract it.
#
# Usage:
#   BUCKET=my-backups KEY=myhost/www-20261012T020000Z.tar.gz DEST=/tmp/restore ./restore.sh
#   BUCKET=my-backups PREFIX=myhost DEST=/tmp/restore ./restore.sh   # latest backup
#
set -Eeuo pipefail

BUCKET="${BUCKET:?BUCKET is required}"
DEST="${DEST:?DEST is required}"
KEY="${KEY:-}"
PREFIX="${PREFIX:-}"

if [[ -z "$KEY" ]]; then
  [[ -n "$PREFIX" ]] || { echo "set KEY or PREFIX" >&2; exit 1; }
  # Newest .tar.gz under the prefix
  KEY="$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$PREFIX/" \
          --query "reverse(sort_by(Contents[?ends_with(Key, '.tar.gz')], &LastModified))[0].Key" \
          --output text)"
  [[ "$KEY" != "None" && -n "$KEY" ]] || { echo "no backups found under $PREFIX/" >&2; exit 1; }
fi

mkdir -p "$DEST"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

name="$(basename "$KEY")"
echo "downloading s3://$BUCKET/$KEY"
aws s3 cp "s3://$BUCKET/$KEY" "$tmp/$name" --only-show-errors
aws s3 cp "s3://$BUCKET/$KEY.sha256" "$tmp/$name.sha256" --only-show-errors

echo "verifying checksum"
(cd "$tmp" && sha256sum -c "$name.sha256")

tar -xzf "$tmp/$name" -C "$DEST"
echo "restored into $DEST"
