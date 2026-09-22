#!/usr/bin/env bash
# ==============================================================================
# ser.ops Daily Verification & Multi-Channel Escalation Loop
# ==============================================================================
set -euo pipefail

ENV_FILE="/etc/ser_ops/.env"
if [ -f "$ENV_FILE" ]; then
    set -o allexport
    source "$ENV_FILE"
    set +o allexport
fi

LOG_FILE="/var/log/ser_ops/daily_loop.log"
mkdir -p /var/log/ser_ops /var/log/ser_ops/vulnerability_reports
exec > >(tee -a "$LOG_FILE") 2>&1

echo "======================================================================"
echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Starting ser.ops Daily Loop..."
echo "======================================================================"

# ------------------------------------------------------------------------------
# Function: Dispatch Webhook Alert (Slack & Reech)
# ------------------------------------------------------------------------------
dispatch_webhook_alert() {
    local severity="$1"
    local title="$2"
    local message="$3"

    echo "[$severity] Dispatching webhook alert: $title"

    local payload
    payload=$(cat <<EOF
{
  "text": "*[$severity Alert - ser.ops]* $title\n$message",
  "severity": "$severity",
  "title": "$title",
  "description": "$message",
  "timestamp": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
}
EOF
)

    if [ -n "${SLACK_WEBHOOK_URL:-}" ] && [ "$SLACK_WEBHOOK_URL" != "https://hooks.slack.com/services/YOUR/WEBHOOK/HERE" ]; then
        curl -s -X POST -H 'Content-Type: application/json' --data "$payload" "$SLACK_WEBHOOK_URL" || true
    fi

    if [ -n "${REECH_WEBHOOK_URL:-}" ] && [ "$REECH_WEBHOOK_URL" != "https://api.reech.online/v1/notifications/webhook_endpoint" ]; then
        curl -s -X POST -H 'Content-Type: application/json' --data "$payload" "$REECH_WEBHOOK_URL" || true
    fi
}

# ------------------------------------------------------------------------------
# STEP 1: Configuration & Security Verifier (BLA-37)
# ------------------------------------------------------------------------------
echo "--> Running STEP 1: Configuration & Port Security Verifier..."

# 1a. Database Port Interface Binding Audit
EXPOSED_DBS=$(ss -tuln | awk '/:(5432|3306) / && !/127\.0\.0\.1/ && !/10\./' || true)
if [ -n "$EXPOSED_DBS" ]; then
    TITLE="CRITICAL: Database ports exposed on non-internal interface!"
    MSG="The following DB bindings are public:\n$EXPOSED_DBS"
    dispatch_webhook_alert "CRITICAL" "$TITLE" "$MSG"
else
    echo "[OK] All database ports (5432 / 3306) bound to internal interfaces."
fi

# 1b. Insecure Configuration / World-Readable Secret Scanner
INSECURE_ENVS=$(find /etc /home -maxdepth 3 \( -name "*.env" -o -name "*.conf" \) -type f -perm /0044 2>/dev/null || true)
if [ -n "$INSECURE_ENVS" ]; then
    TITLE="WARNING: World-readable secret files detected"
    MSG="Check permissions on files:\n$INSECURE_ENVS"
    dispatch_webhook_alert "WARNING" "$TITLE" "$MSG"
else
    echo "[OK] No world-readable secret configuration files found."
fi

# 1c. Defensive Vulnerability Report Ingestion
REPORT_DIR="/var/log/ser_ops/vulnerability_reports"
if [ -d "$REPORT_DIR" ]; then
    mapfile -t REPORTS < <(find "$REPORT_DIR" -maxdepth 1 -name "*.json" -type f 2>/dev/null)
    process_reports_recursive() {
        if [ "$#" -eq 0 ]; then return; fi
        report="$1"
        shift
        echo "Processing vulnerability report: $report"
        HIGH_CVES=$(awk '/"cvss":\s*([7-9]\.[0-9]|10\.0)/' "$report" || true)
        if [ -n "$HIGH_CVES" ]; then
            dispatch_webhook_alert "HIGH" "High/Critical CVE Detected in Report" "Report $report returned CVSS >= 7.0 findings."
        fi
        process_reports_recursive "$@"
    }
    process_reports_recursive "${REPORTS[@]}"
fi

# ------------------------------------------------------------------------------
# STEP 2: Backup Pipeline Health Verification
# ------------------------------------------------------------------------------
echo "--> Running STEP 2: Backup Pipeline Verification..."
if [ -f "/tmp/db-backup.log" ]; then
    FAILED_BACKUPS=$(awk 'BEGIN{IGNORECASE=1} /FAILED/' /tmp/db-backup.log || true)
    if [ -n "$FAILED_BACKUPS" ]; then
        dispatch_webhook_alert "ERROR" "Nightly Backup Job Failure Detected" "$FAILED_BACKUPS"
    else
        echo "[OK] All nightly database backups completed successfully."
    fi
fi

# ------------------------------------------------------------------------------
# STEP 3: Fleet Capacity Watch (locator.prime-quality.online)
# ------------------------------------------------------------------------------
# unit8 hit 100% disk and unit4 72% before anyone noticed - the locator already
# collects disk/mem/cpu per node, so this reads that instead of SSHing around.
# Set LOCATOR_AI_KEY in /etc/ser_ops/.env (X-Locator-AI-Key header value).
echo "--> Running STEP 3: Fleet Capacity Watch..."

LOCATOR_URL="${LOCATOR_URL:-https://locator.prime-quality.online}"
DISK_WARN="${DISK_WARN:-80}"
DISK_CRIT="${DISK_CRIT:-93}"
MEM_WARN="${MEM_WARN:-85}"

if [ -n "${LOCATOR_AI_KEY:-}" ]; then
    # --compressed required: Traefik's compress middleware answers in brotli/gzip.
    NODES_JSON=$(curl -sf --compressed --max-time 20 -H "X-Locator-AI-Key: ${LOCATOR_AI_KEY}" "${LOCATOR_URL}/api/nodes" || true)
    if [ -n "$NODES_JSON" ]; then
        CAPACITY_REPORT=$(printf '%s' "$NODES_JSON" | python3 -c "
import json, sys
nodes = json.load(sys.stdin)
warn_disk, crit_disk, warn_mem = $DISK_WARN, $DISK_CRIT, $MEM_WARN
lines = []
for nid, n in sorted(nodes.items()):
    if not isinstance(n, dict):
        continue
    st = n.get('status', 'UNKNOWN')
    if st != 'ONLINE':
        lines.append(('WARN', f'{nid} is {st}'))
        continue
    disk, mem = n.get('disk_percent'), n.get('mem_percent')
    if disk is not None and disk >= crit_disk:
        lines.append(('CRIT', f'{nid} disk {disk:.0f}%'))
    elif disk is not None and disk >= warn_disk:
        lines.append(('WARN', f'{nid} disk {disk:.0f}%'))
    if mem is not None and mem >= warn_mem:
        lines.append(('WARN', f'{nid} mem {mem:.0f}%'))
for sev, line in lines:
    print(f'{sev}|{line}')
" || true)
        if [ -n "$CAPACITY_REPORT" ]; then
            while IFS='|' read -r sev line; do
                [ "$sev" = "CRIT" ] && S="CRITICAL" || S="WARNING"
                dispatch_webhook_alert "$S" "Fleet capacity: $line" "Node $line - investigate before the balancer or an OOM does it for you."
            done <<< "$CAPACITY_REPORT"
        else
            echo "[OK] All nodes online, disk < ${DISK_WARN}%, mem < ${MEM_WARN}%."
        fi
    else
        echo "[WARN] Locator API unreachable - fleet capacity check skipped."
    fi
else
    echo "[WARN] LOCATOR_AI_KEY not set in $ENV_FILE - fleet capacity check skipped."
fi

# ------------------------------------------------------------------------------
# STEP 4: Config File Vault (config_files DB on comms-db)
# ------------------------------------------------------------------------------
# Copies config files from every reachable unit into config_files.files so a
# dead unit no longer takes its bind-mounted configs (homeserver.yaml, .env,
# postfix-accounts.cf, ...) with it. unit8 proved the need on 2026-09-17.
echo "--> Running STEP 4: Config File Vault..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS_SCRIPT="${CONFIG_BACKUP_SCRIPT:-/usr/local/bin/backup-configs.sh}"
[ -f "$CONFIGS_SCRIPT" ] || CONFIGS_SCRIPT="$SCRIPT_DIR/../scripts/backup-configs.sh"
if [ -x "$CONFIGS_SCRIPT" ] || [ -f "$CONFIGS_SCRIPT" ]; then
    bash "$CONFIGS_SCRIPT" || dispatch_webhook_alert "WARNING" "Config vault run failed" "backup-configs.sh exited non-zero; check /var/log/ser_ops/daily_loop.log"
else
    echo "[WARN] $CONFIGS_SCRIPT not found - config vault skipped."
fi

echo "======================================================================"
echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] ser.ops Daily Loop Finished."
echo "======================================================================"
