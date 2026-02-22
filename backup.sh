#!/bin/bash
set -euo pipefail

# ==============================
# CONFIGURATION
# ==============================
CONTAINER="sql_server_container"
DB_NAME="TestDB"
SA_USER="sa"
SA_PASSWORD="DockerSql@2026!"
CONTAINER_BACKUP_DIR="/var/backups"

LOCAL_BACKUP_DIR="/home/vagrant/backup/"
REMOTE_USER="sony"
REMOTE_HOST="10.70.34.200"
REMOTE_DIR="/home/sony/Music/"

RETENTION_DAYS=3
MIN_FREE_SPACE_GB=10
MAX_RETRIES=3           
RETRY_DELAY=60          
LOCK_FILE="/tmp/mssql_backup.lock"
LOG_FILE="/var/log/mssql_backup.log"

DATE=$(date +%F_%H-%M-%S)
BACKUP_FILE="${DB_NAME}_${DATE}.bak"

# ==============================
# LOGGING FUNCTION
# ==============================
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# ==============================
# LOCK PREVENTION
# ==============================
if [ -f "$LOCK_FILE" ]; then
    log "Error: Another backup process is running. Exiting."
    exit 1
fi

trap 'rm -f $LOCK_FILE' EXIT
touch "$LOCK_FILE"

# ==============================
# DISK SPACE CHECK
# ==============================
AVAILABLE=$(df -BG "$LOCAL_BACKUP_DIR" 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G' || echo 0)

if [ "$AVAILABLE" -lt "$MIN_FREE_SPACE_GB" ]; then
    log "Error: Not enough disk space. Available: ${AVAILABLE}GB, Required: ${MIN_FREE_SPACE_GB}GB"
    exit 1
fi

# ==============================
# START BACKUP INSIDE CONTAINER
# ==============================
log "Starting SQL Server backup for database: [$DB_NAME]..."


if ! docker exec "$CONTAINER" /opt/mssql-tools18/bin/sqlcmd \
-S localhost -U "$SA_USER" -P "$SA_PASSWORD" -C \
-Q "BACKUP DATABASE [$DB_NAME] TO DISK='${CONTAINER_BACKUP_DIR}/${BACKUP_FILE}' WITH COMPRESSION, INIT, STATS=10"; then
    log "Critical Error: SQL Backup failed inside container!"
    exit 1
fi

log "Backup completed inside container."

# ==============================
# COPY TO HOST & CLEANUP CONTAINER
# ==============================
mkdir -p "$LOCAL_BACKUP_DIR"

log "Copying backup file to Local Host..."
if docker cp "$CONTAINER:${CONTAINER_BACKUP_DIR}/${BACKUP_FILE}" "$LOCAL_BACKUP_DIR/"; then
    log "Copy successful. Removing temporary file from container..."
    docker exec "$CONTAINER" rm "${CONTAINER_BACKUP_DIR}/${BACKUP_FILE}"
else
    log "Error: Failed to copy backup from container!"
    exit 1
fi


# ==============================
# REMOTE SYNC WITH AUTO-RETRY & AUTO-CLEANUP
# ==============================
log "Starting remote transfer to ${REMOTE_HOST}..."

TRANSFER_SUCCESS=false
ATTEMPT=1

while [ $ATTEMPT -le $MAX_RETRIES ]; do
    log "Transfer attempt $ATTEMPT of $MAX_RETRIES..."
    

    if rsync -avz --progress --partial --append-verify \
    "$LOCAL_BACKUP_DIR/$BACKUP_FILE" \
    "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/"; then
        
        log "Remote transfer completed successfully."
        TRANSFER_SUCCESS=true
        

        log "Cleaning up local backup file to save space..."
        rm -f "$LOCAL_BACKUP_DIR/$BACKUP_FILE"
        # -------------------------------------------
        
        break
    else
        log "Warning: Transfer interrupted or failed. Retrying in $RETRY_DELAY seconds..."
        sleep "$RETRY_DELAY"
        ((ATTEMPT++))
    fi
done

if [ "$TRANSFER_SUCCESS" = false ]; then
    log "Critical Error: Remote transfer failed after $MAX_RETRIES attempts! Local file preserved for safety."
    exit 1
fi


# ==============================
# REMOTE RETENTION (Cleanup old files)
# ==============================
log "Cleaning remote backups older than $RETENTION_DAYS days..."
ssh "${REMOTE_USER}@${REMOTE_HOST}" \
"find ${REMOTE_DIR} -type f -name '*.bak' -mtime +${RETENTION_DAYS} -delete"

log "Full backup process finished successfully."