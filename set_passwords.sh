#!/bin/sh
# 03_set_passwords.sh — runs as part of postgres docker-entrypoint-initdb.d on FIRST init.
#
# Replaces PLACEHOLDER_* passwords created by init.sql (line ~28-40) with real values
# from container env vars. Mounted to /docker-entrypoint-initdb.d/03_set_passwords.sh
# via docker-compose.yaml (axiom_db service volumes).
#
# Required container env vars (declared in docker-compose.yaml axiom_db service):
#   DB_PASSWORD_AXIOM       -> axiom_user
#   DB_PASSWORD_CRYPTOBOT   -> cryptobot_user
#   DB_PASSWORD_N8N         -> n8n_user
#   DB_PASSWORD_OBSERVER    -> readonly_observer
#   DB_PASSWORD_PARAMSYNC   -> parameter_sync_user
#
# Security:
#   - SET log_statement = 'none' suppresses postgres logging of ALTER USER stmts
#   - Heredoc keeps SQL out of process args / shell history
#   - Script aborts (exit 1) if any required env var is empty
#
# Note: aru_admin (POSTGRES_USER) password is set at bootstrap by postgres image
# from POSTGRES_PASSWORD env — does NOT need post-init ALTER.

set -e

echo "[set_passwords] Replacing PLACEHOLDER passwords with real values..."

# Verify required env vars are set (length-only check, no leak)
for V in DB_PASSWORD_AXIOM DB_PASSWORD_CRYPTOBOT DB_PASSWORD_N8N DB_PASSWORD_OBSERVER DB_PASSWORD_PARAMSYNC DB_PASSWORD_PGBOUNCER_AUTH; do
  eval "VAL=\$$V"
  if [ -z "$VAL" ]; then
    echo "[set_passwords] FATAL: $V not set in container env" >&2
    exit 1
  fi
  echo "[set_passwords]   $V present (len ${#VAL})"
done

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "postgres" <<EOSQL
SET log_statement = 'none';
SET log_min_duration_statement = -1;
ALTER USER axiom_user PASSWORD '$DB_PASSWORD_AXIOM';
ALTER USER cryptobot_user PASSWORD '$DB_PASSWORD_CRYPTOBOT';
ALTER USER n8n_user PASSWORD '$DB_PASSWORD_N8N';
ALTER USER readonly_observer PASSWORD '$DB_PASSWORD_OBSERVER';
ALTER USER parameter_sync_user PASSWORD '$DB_PASSWORD_PARAMSYNC';
ALTER USER pgbouncer_auth PASSWORD '$DB_PASSWORD_PGBOUNCER_AUTH';
RESET log_statement;
RESET log_min_duration_statement;
EOSQL

echo "[set_passwords] Done — 5 non-admin users updated."
