#!/bin/bash

# Smart NCCL/UCX Environment Detection Script
#
# Intelligently detects network topology and generates optimal NCCL/UCX settings.
# Handles mixed RoCE/IB environments by comparing link speeds to determine
# which devices should be used for inter-node communication.
#
# Key behavior:
# - If both RoCE and IB are present, compares max speeds
# - If RoCE is faster (e.g., 400G RoCE vs 100G NVSwitch IB), excludes IB devices
# - This is critical for B200 nodes where NVSwitch IB (100G) should not be used for inter-node
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/.../nccl_env_smart_detect.sh | bash -s -- -o /etc/environment

VERBOSE=false
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [-v|--verbose] [-o|--output FILE]"
            echo ""
            echo "Detects network topology and generates NCCL/UCX environment variables."
            echo "Handles mixed RoCE/IB environments by preferring higher bandwidth links."
            echo ""
            echo "Options:"
            echo "  -v, --verbose    Enable verbose output"
            echo "  -o, --output     Append variables to specified file (without export)"
            echo "  -h, --help       Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Use -h for help" >&2
            exit 1
            ;;
    esac
done

log() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo "[INFO] $*" >&2
    fi
}

warn() {
    echo "[WARN] $*" >&2
}

parse_rate_gbps() {
    local rate_str="$1"
    echo "$rate_str" | grep -oE "^[0-9]+" || echo "0"
}

detect_devices() {
    local ib_devices=()
    local roce_devices=()
    local ib_speeds=()
    local roce_speeds=()
    local max_ib_speed=0
    local max_roce_speed=0

    if [[ ! -d /sys/class/infiniband ]]; then
        warn "No InfiniBand/RoCE devices found (/sys/class/infiniband missing)"
        echo "NCCL_IB_DISABLE=1"
        return
    fi

    log "=== Scanning RDMA devices ==="

    for device_path in /sys/class/infiniband/mlx5_*; do
        [[ -d "$device_path" ]] || continue
        local device=$(basename "$device_path")
        local port_path="$device_path/ports/1"

        local link_layer="unknown"
        local rate_gbps=0
        local state="unknown"

        if [[ -f "$port_path/link_layer" ]]; then
            link_layer=$(cat "$port_path/link_layer" 2>/dev/null || echo "unknown")
        fi

        if [[ -f "$port_path/state" ]]; then
            state=$(cat "$port_path/state" 2>/dev/null | awk '{print $2}' || echo "unknown")
        fi

        if [[ -f "$port_path/rate" ]]; then
            local rate_str=$(cat "$port_path/rate" 2>/dev/null || echo "0")
            rate_gbps=$(parse_rate_gbps "$rate_str")
        fi

        log "  $device: link_layer=$link_layer, rate=${rate_gbps}G, state=$state"

        [[ "$state" != "ACTIVE" ]] && continue

        if [[ "$link_layer" == "InfiniBand" ]]; then
            ib_devices+=("$device")
            ib_speeds+=("$rate_gbps")
            [[ "$rate_gbps" -gt "$max_ib_speed" ]] && max_ib_speed="$rate_gbps"
        elif [[ "$link_layer" == "Ethernet" ]]; then
            roce_devices+=("$device")
            roce_speeds+=("$rate_gbps")
            [[ "$rate_gbps" -gt "$max_roce_speed" ]] && max_roce_speed="$rate_gbps"
        fi
    done

    log ""
    log "=== Detection Summary ==="
    log "IB devices: ${ib_devices[*]:-none} (max: ${max_ib_speed}G)"
    log "RoCE devices: ${roce_devices[*]:-none} (max: ${max_roce_speed}G)"

    local use_devices=()
    local use_roce=false

    if [[ ${#roce_devices[@]} -gt 0 && ${#ib_devices[@]} -gt 0 ]]; then
        log ""
        log "=== Mixed RoCE/IB Environment Detected ==="

        if [[ "$max_roce_speed" -gt "$max_ib_speed" ]]; then
            log "RoCE faster than IB (${max_roce_speed}G > ${max_ib_speed}G)"
            log "Using only fastest RoCE devices (${max_roce_speed}G)"
            for i in "${!roce_devices[@]}"; do
                if [[ "${roce_speeds[$i]}" -eq "$max_roce_speed" ]]; then
                    use_devices+=("${roce_devices[$i]}")
                fi
            done
            use_roce=true
        else
            log "IB faster or equal to RoCE (${max_ib_speed}G >= ${max_roce_speed}G)"
            log "Using only fastest IB devices (${max_ib_speed}G)"
            for i in "${!ib_devices[@]}"; do
                if [[ "${ib_speeds[$i]}" -eq "$max_ib_speed" ]]; then
                    use_devices+=("${ib_devices[$i]}")
                fi
            done
        fi
    elif [[ ${#ib_devices[@]} -gt 0 ]]; then
        log "IB-only environment, using fastest (${max_ib_speed}G)"
        for i in "${!ib_devices[@]}"; do
            if [[ "${ib_speeds[$i]}" -eq "$max_ib_speed" ]]; then
                use_devices+=("${ib_devices[$i]}")
            fi
        done
    elif [[ ${#roce_devices[@]} -gt 0 ]]; then
        log "RoCE-only environment, using fastest (${max_roce_speed}G)"
        for i in "${!roce_devices[@]}"; do
            if [[ "${roce_speeds[$i]}" -eq "$max_roce_speed" ]]; then
                use_devices+=("${roce_devices[$i]}")
            fi
        done
        use_roce=true
    else
        warn "No active RDMA devices found"
        echo "NCCL_IB_DISABLE=1"
        return
    fi

    log ""
    log "=== Generated Configuration ==="
    log "Using devices: ${use_devices[*]}"

    if [[ ${#use_devices[@]} -gt 0 ]]; then
        local use_str=$(IFS=,; echo "${use_devices[*]}")
        echo "NCCL_IB_HCA=${use_str}"
        log "NCCL_IB_HCA=${use_str}"
    fi

    echo "NCCL_IB_DISABLE=0"
    echo "NCCL_IB_TIMEOUT=23"
    echo "NCCL_IB_RETRY_CNT=7"
    echo "NCCL_IB_PCI_RELAXED_ORDERING=1"

    if [[ "$use_roce" == "true" ]]; then
        echo "UCX_TLS=tcp,self"
        echo "UCX_VFS_ENABLE=no"
        echo "SHARP_COLL_ENABLE_PCI_RELAXED_ORDERING=1"
    fi

    local default_iface=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -n1)
    if [[ -n "$default_iface" ]]; then
        echo "NCCL_SOCKET_IFNAME=${default_iface}"
    fi
}

main() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo "Smart NCCL/UCX Environment Detection Script" >&2
        echo "============================================" >&2
        echo "" >&2
    fi

    local vars=$(detect_devices)

    if [[ -n "$OUTPUT_FILE" ]]; then
        log ""
        log "Writing to: $OUTPUT_FILE"

        if [[ "$VERBOSE" == "true" ]]; then
            {
                echo ""
                echo "# NCCL/UCX Environment Variables (Smart Detection)"
                echo "# Generated on $(date)"
                echo "# Script: https://github.com/andromeda-ai/setup-scripts/nccl_env_smart_detect.sh"
                echo ""
            } >> "$OUTPUT_FILE"
        fi

        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            echo "$line" >> "$OUTPUT_FILE"
        done <<< "$vars"

        log "Done"
    else
        if [[ "$VERBOSE" == "true" ]]; then
            echo ""
            echo "# NCCL/UCX Environment Variables (Smart Detection)"
            echo "# Generated on $(date)"
            echo ""
        fi

        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            echo "export $line"
        done <<< "$vars"
    fi
}

main
