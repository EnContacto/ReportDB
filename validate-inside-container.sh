#!/bin/bash

set -e

echo "[$(date)] Starting SQL Server validation inside container..."

echo "[$(date)] Waiting for SQL Server to be ready..."
for i in {1..60}; do
    if /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -C -Q "SELECT 1" &>/dev/null; then
        echo "[$(date)] SQL Server is ready!"
        break
    fi
    sleep 2
done

# Initialize results JSON
RESULTS_FILE="/results/validation.json"
cat > $RESULTS_FILE << 'EOF'
{
    "start_time": "TIMESTAMP",
    "databases": {},
    "resources": {
        "cpu_samples": [],
        "memory_samples": [],
        "io_samples": []
    }
}
EOF

# Function to get resource usage
get_resource_usage() {
    local cpu=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 2>/dev/null || echo "0")
    local mem=$(free | grep Mem | awk '{printf("%.1f", $3/$2 * 100.0)}' 2>/dev/null || echo "0")
    echo "{\"cpu\": $cpu, \"memory\": $mem, \"timestamp\": \"$(date -Iseconds)\"}"
}

# Function to restore and validate a backup
validate_backup() {
    local backup_type=$1
    local backup_file=$2
    local db_name=$3
    local temp_db="${db_name}_Temp"
    
    echo "[$(date)] Validating $backup_type backup: $backup_file"
    
    local start_time=$(date +%s.%N)
    local status="FAILED"
    local error_msg=""
    local restore_time=0
    local checkdb_time=0
    
    # Get resource usage before
    local resources_before=$(get_resource_usage)
    
    # Restore backup
    case $backup_type in
        "FULL")
            if /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -C \
                -Q "RESTORE DATABASE [$temp_db] FROM DISK = '$backup_file' WITH NORECOVERY, REPLACE" 2>&1; then
                status="OK"
            else
                error_msg="RESTORE FULL failed"
            fi
            ;;
        "DIFF")
            if /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -C \
                -Q "RESTORE DATABASE [$temp_db] FROM DISK = '$backup_file' WITH NORECOVERY" 2>&1; then
                status="OK"
            else
                error_msg="RESTORE DIFF failed"
            fi
            ;;
        "LOG")
            if /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -C \
                -Q "RESTORE DATABASE [$temp_db] FROM DISK = '$backup_file' WITH RECOVERY" 2>&1; then
                status="OK"
                
                # Run CHECKDB
                local checkdb_start=$(date +%s.%N)
                if /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -C \
                    -Q "DBCC CHECKDB([$temp_db]) WITH NO_INFOMSGS" 2>&1; then
                    local checkdb_end=$(date +%s.%N)
                    checkdb_time=$(echo "$checkdb_end - $checkdb_start" | bc)
                else
                    error_msg="CHECKDB failed"
                fi
            else
                error_msg="RESTORE LOG failed"
            fi
            ;;
    esac
    
    local end_time=$(date +%s.%N)
    restore_time=$(echo "$end_time - $start_time" | bc)
    
    # Get resource usage after
    local resources_after=$(get_resource_usage)
    
    # Get LSN information
    local lsn_info=$(/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -C \
        -h -1 -W -Q "SELECT FirstLSN, LastLSN, CheckpointLSN FROM msdb.dbo.backupset WHERE database_name = '$db_name' AND type = '$(echo $backup_type | cut -c1)' ORDER BY backup_finish_date DESC" 2>/dev/null | head -1 || echo "")
    
    # Output JSON for this validation
    cat << EOFJ
{
    "backup_type": "$backup_type",
    "file": "$(basename $backup_file)",
    "status": "$status",
    "restore_time_seconds": $restore_time,
    "checkdb_time_seconds": $checkdb_time,
    "error": "$error_msg",
    "lsn_info": "$lsn_info",
    "resources_before": $resources_before,
    "resources_after": $resources_after
}
EOFJ
}

# Main validation logic
echo "[$(date)] Starting backup validation..."

# Find and validate backups
for backup_type in FULL DIFF LOG; do
    backup_dir="/backups/$(echo $backup_type | tr '[:upper:]' '[:lower:]')"
    
    if [ -d "$backup_dir" ]; then
        # Find latest backup file
        latest_backup=$(find "$backup_dir" -name "*.bak" -o -name "*.trn" 2>/dev/null | head -1)
        
        if [ -n "$latest_backup" ]; then
            echo "[$(date)] Found $backup_type backup: $latest_backup"
            
            # Extract database name from filename (assumes format: *_DBNAME_*.bak)
            db_name=$(basename "$latest_backup" | sed 's/.*_\([A-Za-z0-9_]*\)_.*/\1/' | head -1)
            
            if [ -n "$db_name" ]; then
                result=$(validate_backup "$backup_type" "$latest_backup" "$db_name")
                echo "[$(date)] Validation result: $result"
                
                # Append to results file
                echo "$result" >> /results/${backup_type}_result.json
            fi
        fi
    fi
done

echo "[$(date)] Validation complete. Results saved to /results/"