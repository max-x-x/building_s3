#!/bin/sh
set -eu

ROOT_USER="$(cat /run/secrets/minio_root_user)"
ROOT_PASS="$(cat /run/secrets/minio_root_password)"
APP_KEY="$(cat /run/secrets/app_access_key)"
APP_SECRET="$(cat /run/secrets/app_secret_key)"

ALIAS="local"
ENDPOINT="http://minio:${MINIO_S3_PORT}"

echo "Waiting MinIO at ${ENDPOINT}..."
for i in $(seq 1 90); do
  if wget -qO- "${ENDPOINT}/minio/health/ready" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

mc alias set "${ALIAS}" "${ENDPOINT}" "${ROOT_USER}" "${ROOT_PASS}" >/dev/null

# Бакеты
IFS=',' read -r -a BUCKETS <<< "${MINIO_BUCKETS}"
for B in "${BUCKETS[@]}"; do
  B_TRIM="$(echo "$B" | xargs)"
  [ -z "${B_TRIM}" ] && continue
  echo "Ensuring bucket: ${B_TRIM}"
  mc mb --ignore-existing "${ALIAS}/${B_TRIM}" || true
  mc version enable "${ALIAS}/${B_TRIM}" || true
  mc ilm import "${ALIAS}/${B_TRIM}" "/init/ilm-30d.json" || true
done

# Политика RW для app-пользователя только на перечисленные бакеты
# Сборка JSON policy на лету
POLICY_JSON="$(mktemp)"
{
  echo '{ "Version":"2012-10-17", "Statement": ['
  SEP=""
  for B in "${BUCKETS[@]}"; do
    B_TRIM="$(echo "$B" | xargs)"
    [ -z "${B_TRIM}" ] && continue
    [ -n "$SEP" ] && echo ','
    echo "  {\"Effect\":\"Allow\",\"Action\":[\"s3:ListBucket\",\"s3:GetBucketLocation\"],\"Resource\":[\"arn:aws:s3:::${B_TRIM}\"]},"
    echo "  {\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:PutObject\",\"s3:DeleteObject\",\"s3:AbortMultipartUpload\",\"s3:ListMultipartUploadParts\"],\"Resource\":[\"arn:aws:s3:::${B_TRIM}/*\"]}"
    SEP=","
  done
  echo '] }'
} > "$POLICY_JSON"

# Создание/обновление policy и пользователя
mc admin policy create "${ALIAS}" app-buckets-rw "$POLICY_JSON" 2>/dev/null || \
mc admin policy update "${ALIAS}" app-buckets-rw "$POLICY_JSON"

# Создать/сбросить пользователя с заданными ключами
if mc admin user info "${ALIAS}" "${APP_KEY}" >/dev/null 2>&1; then
  mc admin user disable "${ALIAS}" "${APP_KEY}" || true
  mc admin user remove "${ALIAS}" "${APP_KEY}" || true
fi
mc admin user add "${ALIAS}" "${APP_KEY}" "${APP_SECRET}"
mc admin policy attach "${ALIAS}" app-buckets-rw --user "${APP_KEY}"
mc admin user enable "${ALIAS}" "${APP_KEY}"

echo "App user ready with RW to buckets: ${MINIO_BUCKETS}"
echo "Init done."
