#!/usr/bin/env bash
# Backup diário: pg_dump -> gpg (AES256, senha em backup.pass) -> bucket GCS.
# Uso, na pasta do deploy: ./backup.sh <bucket>
#
# Envia pela API JSON do GCS com o token da conta de serviço da VM, criando o objeto só se ele
# não existir (ifGenerationMatch=0). Assim a VM precisa apenas de roles/storage.objectCreator:
# não lê, não sobrescreve e não apaga backups. A retenção fica na regra de ciclo de vida do bucket.
#
# Restaurar (num Postgres 17 com pgvector):
#   gpg --batch --passphrase-file backup.pass -d <arquivo>.dump.gpg > sf.dump
#   pg_restore --no-owner -d <url do banco vazio> sf.dump
set -euo pipefail

BUCKET=${1:?uso: backup.sh <bucket>}
cd "$(dirname "$0")"
[ -s backup.pass ] || { echo "backup: falta o arquivo backup.pass" >&2; exit 1; }

name="simplefinance-$(date -u +%Y%m%dT%H%M%SZ).dump.gpg"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

docker compose -f docker-compose.vps.yml exec -T postgres pg_dump -Fc -U simplefinance simplefinance \
  | gpg --batch --yes --symmetric --cipher-algo AES256 --passphrase-file backup.pass -o "$tmp"

token=$(curl -sf -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token \
  | sed -E 's/.*"access_token":"([^"]+)".*/\1/')

curl -sf -o /dev/null -X POST --data-binary @"$tmp" \
  -H "Authorization: Bearer $token" -H "Content-Type: application/octet-stream" \
  "https://storage.googleapis.com/upload/storage/v1/b/$BUCKET/o?uploadType=media&ifGenerationMatch=0&name=simplefinance/$name"

echo "backup: $(date -u +%FT%TZ) gs://$BUCKET/simplefinance/$name ($(stat -c %s "$tmp") bytes)"
