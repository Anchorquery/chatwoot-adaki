#!/usr/bin/env bash
# Adaki municipal backup — postgres dump + media verification.
# Run nightly via cron / Coolify scheduled task.
set -euo pipefail

: "${DATABASE_URL:?DATABASE_URL required}"
: "${BACKUP_DIR:=/var/backups/adaki}"
: "${RETENTION_DAYS:=30}"

TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
DUMP_FILE="${BACKUP_DIR}/pg-${TIMESTAMP}.dump"

mkdir -p "${BACKUP_DIR}"

echo "[adaki-backup] Dumping postgres -> ${DUMP_FILE}"
pg_dump --format=custom --compress=9 --no-owner --no-acl \
  --file="${DUMP_FILE}" "${DATABASE_URL}"

echo "[adaki-backup] Verifying dump"
pg_restore --list "${DUMP_FILE}" > /dev/null

if [[ -n "${BACKUP_S3_BUCKET:-}" ]]; then
  echo "[adaki-backup] Uploading to s3://${BACKUP_S3_BUCKET}/"
  aws s3 cp "${DUMP_FILE}" "s3://${BACKUP_S3_BUCKET}/pg/${TIMESTAMP}.dump" \
    --sse AES256
fi

echo "[adaki-backup] Pruning local dumps older than ${RETENTION_DAYS} days"
find "${BACKUP_DIR}" -name 'pg-*.dump' -mtime +"${RETENTION_DAYS}" -delete

echo "[adaki-backup] Done"
