#!/bin/bash

# Network Health Monitor for Fedora
# Logs connectivity issues with system state and network environment

LOG_DIR="$HOME/.local/share/network-monitor"
CHECK_INTERVAL=2  # seconds between checks
TARGET_SERVERS=("8.8.8.8" "1.1.1.1" "google.com")
MAX_LOG_SIZE=10485760  # 10MB max log size

# Create log directory
mkdir -p "$LOG_DIR"

# Function to get current timestamp in ISO format
get_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

LOG_FILE="$LOG_DIR/network_health_$(get_timestamp).json"

# Function to get WiFi interface info
get_wifi_info() {
    local iface=$(nmcli -t -f DEVICE,TYPE dev | grep ":wifi$" | cut -d: -f1)

    if [ -z "$iface" ]; then
        echo '{"error": "No WiFi interface found"}'
        return
    fi

    # Get current connection details
    local current_ssid=$(nmcli -g GENERAL.SSID device show "$iface" 2>/dev/null)
    local signal=$(nmcli -g WIFI,SIGNAL device show "$iface" 2>/dev/null)
    local freq=$(nmcli -g WIFI.FREQ device show "$iface" 2>/dev/null)
    local channel=$(nmcli -g WIFI.CHANNEL device show "$iface" 2>/dev/null)
    local mode=$(nmcli -g WIFI.MODE device show "$iface" 2>/dev/null)
    local security=$(nmcli -g WIFI.SECURITY device show "$iface" 2>/dev/null)

    # Get all nearby networks
    local scan_result=$(nmcli -t -f SSID,SIGNAL,FREQ,SECURITY,MODE dev wifi list 2>/dev/null | head -20)

    cat <<EOF
{
  "interface": "$iface",
  "current_ssid": "$current_ssid",
  "signal_strength": "$signal",
  "frequency": "$freq",
  "channel": "$channel",
  "mode": "$mode",
  "security": "$security",
  "nearby_networks": [$(echo "$scan_result" | awk -F: '{printf "{\"ssid\":\"%s\",\"signal\":%s,\"freq\":"%s",\"security\":\"%s\",\"mode\":\"%s\"},", $1, $2, $3, $4, $5}' | sed 's/,$//')]
}
EOF
}

# Function to get system resource usage
get_system_stats() {
    local cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
    local mem_total=$(free -m | awk '/Mem:/ {print $2}')
    local mem_used=$(free -m | awk '/Mem:/ {print $3}')
    local mem_percent=$((mem_used * 100 / mem_total))

    # Get GPU info if available
    local gpu_info="null"
    if command -v nvidia-smi &>/dev/null; then
        gpu_info=$(nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader,nounits 2>/dev/null | tr '\n' ',')
        gpu_info="[${gpu_info%,}]"
    elif command -vradeontop &>/dev/null; then
        gpu_info="amd_gpu_data"
    fi

    # Get temperature (try multiple methods)
    local temp="null"
    if command -v sensors &>/dev/null; then
        temp=$(sensors | grep -E "Package id 0|Core 0|Tctl" | head -1 | awk '{print $NF}' | tr -d '+°C')
    fi

    cat <<EOF
{
  "cpu_usage_percent": ${cpu_usage:-0},
  "memory": {
    "total_mb": $mem_total,
    "used_mb": $mem_used,
    "percent": $mem_percent
  },
  "gpu_utilization": $gpu_info,
  "temperature_celsius": ${temp:-null}
}
EOF
}

# Function to get running processes
get_process_snapshot() {
    # Get top 10 CPU consuming processes
    local top_procs=$(ps aux --sort=-%cpu | head -11 | tail -10 | awk '{printf "{\"pid\":%s,\"user\":\"%s\",\"cpu\":%s,\"mem\":%s,\"cmd\":\"%s\"},", $2, $1, $3, $4, $11}' | sed 's/,$//')

    # Get network-related processes
    local net_procs=$(ss -tulpn 2>/dev/null | grep -v "^Netid" | awk '{printf "{\"proto\":\"%s\",\"local\":\"%s\",\"remote\":\"%s\",\"pid\":\"%s\"},", $1, $4, $5, $7}' | sed 's/,$//' | head -20)

    cat <<EOF
{
  "top_cpu_processes": [$top_procs],
  "network_processes": [$net_procs]
}
EOF
}

# Function to test connectivity
test_connectivity() {
    local server=$1
    local timeout=2

    # Try ping first
    if ping -c 1 -W $timeout "$server" &>/dev/null; then
        echo "online"
        return
    fi

    # Try DNS resolution if it's a hostname
    if [[ "$server" != *[0-9]* ]]; then
        if nslookup "$server" &>/dev/null; then
            echo "dns_ok_ping_fail"
            return
        fi
    fi

    echo "offline"
}

# Function to rotate log file if too large
rotate_log() {
    if [ -f "$LOG_FILE" ] && [ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null) -gt $MAX_LOG_SIZE ]; then
        mv "$LOG_FILE" "${LOG_FILE}.$(date +%Y%m%d_%H%M%S).bak"
        gzip "${LOG_FILE}.$(date +%Y%m%d_%H%M%S).bak" 2>/dev/null || true
    fi
}

# Main monitoring loop
echo "Starting network health monitor..."
echo "Logging to: $LOG_FILE"
echo "Press Ctrl+C to stop"

# Initialize log file with array start
if [ ! -f "$LOG_FILE" ]; then
    echo "[" > "$LOG_FILE"
fi

while true; do
    timestamp=$(get_timestamp)
    connectivity_status="all_online"
    failed_servers=()

    # Test all target servers
    for server in "${TARGET_SERVERS[@]}"; do
        status=$(test_connectivity "$server")
        if [ "$status" != "online" ]; then
            connectivity_status="partial"
            if [ "$status" = "offline" ]; then
                connectivity_status="offline"
                failed_servers+=("$server")
            fi
        fi
    done

    # Only log when there's an issue
    if [ "$connectivity_status" != "all_online" ]; then
        wifi_info=$(get_wifi_info)
        system_stats=$(get_system_stats)
        process_snapshot=$(get_process_snapshot)

        # Create log entry
        log_entry=$(cat <<EOF
{
  "timestamp": "$timestamp",
  "connectivity_status": "$connectivity_status",
  "failed_servers": [$(printf '"%s",' "${failed_servers[@]}" | sed 's/,$//')],
  "wifi_environment": $wifi_info,
  "system_resources": $system_stats,
  "running_processes": $process_snapshot
}
EOF
)

        # Add comma if not first entry
        if [ -s "$LOG_FILE" ] && [ "$(tail -c 2 "$LOG_FILE")" != "[" ]; then
            echo "," >> "$LOG_FILE"
        fi

        echo "$log_entry" >> "$LOG_FILE"

        # Rotate log if needed
        rotate_log

        echo "[$timestamp] Network issue detected! Status: $connectivity_status"
        echo "Failed servers: ${failed_servers[*]}"
        echo "Log entry added to $LOG_FILE"
    fi

    sleep $CHECK_INTERVAL
done
