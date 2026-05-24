# Plan DR / Backups Adaki Municipal

Objetivo: garantizar continuidad servicio público y retención legal audit log.

## Componentes a proteger

| Componente | Volumen | RPO | RTO | Retención |
|---|---|---|---|---|
| Postgres (datos transaccionales) | ~ | 1h | 4h | 30 días rolling |
| ActiveStorage media (audios/imágenes/docs) | ~ | 24h | 24h | 7 años (admin pública) |
| Audit log (`adaki_audit_log_entries`) | bajo | 0 (sincronía) | 1h | permanente, archivado legal |
| Sidekiq Redis (volátil) | — | — | — | regenerable |

## Estrategia

### 1. Postgres
- `pg_dump` diario 03:00 UTC vía `bin/adaki-backup.sh`
- Destino: S3 / Coolify backups
- Encriptación at-rest (AES256)
- WAL archiving para PITR (opcional fase 2)

### 2. Media (ActiveStorage)
- Bucket S3 con versioning + lifecycle 7 años
- Sync diario verificado por `Adaki::MediaIntegritySweepJob`

### 3. Audit chain
- Export semanal a fichero JSONL firmado (SHA256 del último `hash_chain`)
- Almacenado off-site (S3 bucket separado, write-once Object Lock)
- Verificación `Adaki::AuditLogEntry.verify_chain!(account)` antes de cada export

## Restauración

```bash
# 1. Restore Postgres
pg_restore -d chatwoot_production < backup.dump

# 2. Verificar integridad audit chain post-restore
bundle exec rails runner 'Account.find_each { |a| Adaki::AuditLogEntry.verify_chain!(a) }'

# 3. Re-encolar Sidekiq jobs críticos
bundle exec rails runner 'Adaki::WhatsappTierMonitorJob.perform_later'
```

## Retirada de servicio (municipio)

Si un Account se da de baja:

1. Exportar audit a fichero legal (`rake adaki:audit:export[ACCOUNT_ID]`)
2. Adjuntar fichero a expediente municipal
3. Solo entonces destruir Account (requiere borrar entradas audit primero, ver ADAKI_MUNICIPAL.md)

## Pruebas

- Restore drill trimestral en entorno staging
- Verificación cadena audit post-restore obligatoria
- Log resultado en wiki interno
