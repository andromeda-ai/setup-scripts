#!/bin/bash

# Parse command line arguments
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
            echo "  -v, --verbose    Enable verbose output"
            echo "  -o, --output     Append variables to specified file (without export commands)"
            echo "  -h, --help       Show this help message"
            exit 0
            ;;
        *)
            echo "Usage: $0 [-v|--verbose] [-o|--output FILE]"
            echo "  -v, --verbose    Enable verbose output"
            echo "  -o, --output     Append variables to specified file (without export commands)"
            echo "  -h, --help       Show this help message"
            exit 1
            ;;
    esac
done

# Function to print verbose messages
verbose_echo() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo "$@"
    fi
}

# Function to check and install iproute2 if not installed
check_and_install_iproute2() {
    verbose_echo "Checking for iproute2..."
    
    # Check if ip command exists (part of iproute2)
    if command -v ip &> /dev/null; then
        verbose_echo "iproute2 is already installed (ip command found)"
        return 0
    fi
    
    verbose_echo "iproute2 not found, attempting to install..."
    
    # Detect package manager and install iproute2
    if command -v apt-get &> /dev/null; then
        verbose_echo "Detected apt package manager (Debian/Ubuntu)"
        if sudo apt-get update -qq && sudo apt-get install -y -qq iproute2; then
            verbose_echo "Successfully installed iproute2"
            return 0
        else
            echo "ERROR: Failed to install iproute2" >&2
            return 1
        fi
    elif command -v yum &> /dev/null; then
        verbose_echo "Detected yum package manager (RHEL/CentOS)"
        if sudo yum install -y -q iproute; then
            verbose_echo "Successfully installed iproute2"
            return 0
        else
            echo "ERROR: Failed to install iproute2" >&2
            return 1
        fi
    elif command -v dnf &> /dev/null; then
        verbose_echo "Detected dnf package manager (Fedora/RHEL 8+)"
        if sudo dnf install -y -q iproute; then
            verbose_echo "Successfully installed iproute2"
            return 0
        else
            echo "ERROR: Failed to install iproute2" >&2
            return 1
        fi
    elif command -v pacman &> /dev/null; then
        verbose_echo "Detected pacman package manager (Arch Linux)"
        if sudo pacman -S --noconfirm --quiet iproute2; then
            verbose_echo "Successfully installed iproute2"
            return 0
        else
            echo "ERROR: Failed to install iproute2" >&2
            return 1
        fi
    elif command -v zypper &> /dev/null; then
        verbose_echo "Detected zypper package manager (openSUSE)"
        if sudo zypper install -y -q iproute2; then
            verbose_echo "Successfully installed iproute2"
            return 0
        else
            echo "ERROR: Failed to install iproute2" >&2
            return 1
        fi
    else
        echo "ERROR: Could not detect package manager. Please install iproute2 manually." >&2
        echo "  On Debian/Ubuntu: sudo apt-get install iproute2" >&2
        echo "  On RHEL/CentOS: sudo yum install iproute" >&2
        echo "  On Fedora: sudo dnf install iproute" >&2
        echo "  On Arch: sudo pacman -S iproute2" >&2
        echo "  On openSUSE: sudo zypper install iproute2" >&2
        return 1
    fi
}

# Function to append environment variables to file (without export commands)
append_env_variables() {
    local output_file="$1"
    
    verbose_echo "Appending environment variables to: $output_file"
    
    {
        if [[ "$VERBOSE" == "true" ]]; then
            echo "# NCCL and UCX Environment Variables"
            echo "# Generated on $(date)"
            echo "# Only actual InfiniBand devices are included"
            echo ""
        fi
        
        # NCCL Configuration
        if [[ ! -z "$DETECTED_IB_DEVICES" ]]; then
            if [[ "$VERBOSE" == "true" ]]; then
                echo "# InfiniBand devices for NCCL (verified as IB link layer)"
            fi
            echo "NCCL_IB_HCA=$DETECTED_IB_DEVICES"
            echo "NCCL_IB_DISABLE=0"
            echo "NCCL_IB_TIMEOUT=23"
            echo "NCCL_IB_RETRY_CNT=7"
        else
            if [[ "$VERBOSE" == "true" ]]; then
                echo "# No active InfiniBand devices found, disabling IB"
            fi
            echo "NCCL_IB_DISABLE=1"
        fi
        
        if [[ ! -z "$DETECTED_ETH_INTERFACES" ]]; then
            if [[ "$VERBOSE" == "true" ]]; then
                echo "# Ethernet fallback for NCCL"
            fi
            echo "NCCL_SOCKET_IFNAME=$(echo $DETECTED_ETH_INTERFACES | cut -d',' -f1)"
        fi
        
        if [[ "$VERBOSE" == "true" ]]; then
            echo "# NCCL Debug settings"
        fi
        echo "NCCL_DEBUG=INFO"
        echo "NCCL_DEBUG_SUBSYS=ALL"
        
        # UCX Configuration
        if [[ ! -z "$DETECTED_IB_DEVICES_WITH_PORTS" ]]; then
            if [[ "$VERBOSE" == "true" ]]; then
                echo "# UCX InfiniBand devices (with port specification)"
            fi
            
            # Use only InfiniBand devices for UCX when available
            echo "UCX_NET_DEVICES=$DETECTED_IB_DEVICES_WITH_PORTS"
        else
            if [[ "$VERBOSE" == "true" ]]; then
                echo "# No InfiniBand devices for UCX, using Ethernet only"
            fi
            if [[ ! -z "$DETECTED_ETH_INTERFACES" ]]; then
                echo "UCX_NET_DEVICES=$(echo $DETECTED_ETH_INTERFACES | cut -d',' -f1)"
            fi
        fi
        
    } >> "$output_file"
    
    verbose_echo "Environment variables successfully appended to: $output_file"
}

# Function to detect actual InfiniBand devices (not Ethernet)
detect_ib_devices() {
    verbose_echo "=== Detecting True InfiniBand Devices ==="
    
    local ib_devices=""
    local ib_devices_with_ports=""
    
    if command -v ibstat &> /dev/null; then
        verbose_echo "Scanning devices with ibstat..."
        
        # Get list of all devices
        local all_devices=$(ibstat -l 2>/dev/null)
        
        for device in $all_devices; do
            verbose_echo "Checking device: $device"
            
            # Get detailed info for this device
            local device_info=$(ibstat $device 2>/dev/null)
            
            # Check if this device has InfiniBand link layer
            local link_layer=$(echo "$device_info" | grep "Link layer:" | awk '{print $3}')
            local state=$(echo "$device_info" | grep "State:" | awk '{print $2}')
            local ports=$(echo "$device_info" | grep "Number of ports:" | awk '{print $4}')
            
            verbose_echo "  - Link layer: $link_layer"
            verbose_echo "  - State: $state"
            verbose_echo "  - Ports: $ports"
            
            if [[ "$link_layer" == "InfiniBand" ]]; then
                verbose_echo "  ✓ This is an InfiniBand device"
                
                if [[ "$state" == "Active" ]]; then
                    verbose_echo "  ✓ Device is active"
                    
                    # Add device to our list
                    if [[ -z "$ib_devices" ]]; then
                        ib_devices="$device"
                    else
                        ib_devices="$ib_devices,$device"
                    fi
                    
                    # For UCX, add with port specification
                    for ((port=1; port<=ports; port++)); do
                        if [[ -z "$ib_devices_with_ports" ]]; then
                            ib_devices_with_ports="$device:$port"
                        else
                            ib_devices_with_ports="$ib_devices_with_ports,$device:$port"
                        fi
                    done
                else
                    verbose_echo "  ✗ Device is not active (State: $state)"
                fi
            else
                verbose_echo "  ✗ Not an InfiniBand device (Link layer: $link_layer)"
            fi
            verbose_echo ""
        done
    else
        verbose_echo "ibstat not available, trying alternative detection..."
        
        # Alternative method using /sys filesystem
        if [ -d "/sys/class/infiniband" ]; then
            for device in /sys/class/infiniband/*; do
                device_name=$(basename $device)
                verbose_echo "Found potential IB device: $device_name"
                
                # Check if device has active ports
                if [ -d "$device/ports" ]; then
                    for port_dir in $device/ports/*; do
                        if [ -f "$port_dir/state" ]; then
                            port_state=$(cat $port_dir/state)
                            port_num=$(basename $port_dir)
                            
                            if [[ "$port_state" == "4: ACTIVE" ]]; then
                                verbose_echo "  ✓ Port $port_num is active"
                                
                                if [[ -z "$ib_devices" ]]; then
                                    ib_devices="$device_name"
                                else
                                    ib_devices="$ib_devices,$device_name"
                                fi
                                
                                if [[ -z "$ib_devices_with_ports" ]]; then
                                    ib_devices_with_ports="$device_name:$port_num"
                                else
                                    ib_devices_with_ports="$ib_devices_with_ports,$device_name:$port_num"
                                fi
                            fi
                        fi
                    done
                fi
            done
        fi
    fi
    
    # Export results for use by other functions
    export DETECTED_IB_DEVICES="$ib_devices"
    export DETECTED_IB_DEVICES_WITH_PORTS="$ib_devices_with_ports"
    
    verbose_echo "=== Detection Results ==="
    verbose_echo "InfiniBand devices found: $ib_devices"
    verbose_echo "With port specification: $ib_devices_with_ports"
}

# Function to detect network interfaces (Ethernet only)
detect_ethernet_interfaces() {
    verbose_echo -e "\n=== Detecting Ethernet Interfaces ==="
    
    local eth_interfaces=""
    
    # Get interfaces that are up and not loopback/docker/virtual
    for interface in $(ip link show | grep -E "^[0-9]+:" | awk '{print $2}' | sed 's/://' | grep -v -E "^(lo|docker|ib|veth|br-)" | grep -v "@"); do
        # Additional validation: check if interface exists and is accessible
        if ip link show "$interface" &> /dev/null; then
            # Check if interface has an IP address and is up
            local ip_info=$(ip addr show $interface 2>/dev/null | grep "inet ")
            local state=$(ip link show $interface | grep -o "state [A-Z]*" | awk '{print $2}')
            
            # Also exclude interfaces that look like container interfaces
            if [[ "$state" == "UP" && ! -z "$ip_info" && ! "$interface" =~ "@" ]]; then
                verbose_echo "Found active Ethernet interface: $interface"
                
                if [[ -z "$eth_interfaces" ]]; then
                    eth_interfaces="$interface"
                else
                    eth_interfaces="$eth_interfaces,$interface"
                fi
            else
                verbose_echo "Skipping interface $interface (state: $state, has_ip: $([[ ! -z "$ip_info" ]] && echo "yes" || echo "no"))"
            fi
        else
            verbose_echo "Skipping non-existent interface: $interface"
        fi
    done
    
    export DETECTED_ETH_INTERFACES="$eth_interfaces"
    verbose_echo "Ethernet interfaces found: $eth_interfaces"
}

# Function to generate environment variables
generate_env_variables() {
    verbose_echo -e "\n=== Generating Environment Variables ==="
    
    if [[ "$VERBOSE" == "true" ]]; then
        echo "# NCCL and UCX Environment Variables"
        echo "# Generated on $(date)"
        echo "# Only actual InfiniBand devices are included"
        echo ""
        
        # NCCL Configuration
        echo "# === NCCL Configuration ==="
    fi
    
    if [[ ! -z "$DETECTED_IB_DEVICES" ]]; then
        if [[ "$VERBOSE" == "true" ]]; then
            echo "# InfiniBand devices for NCCL (verified as IB link layer)"
        fi
        echo "export NCCL_IB_HCA=$DETECTED_IB_DEVICES"
        echo "export NCCL_IB_DISABLE=0"
        echo "export NCCL_IB_TIMEOUT=23"
        echo "export NCCL_IB_RETRY_CNT=7"
    else
        if [[ "$VERBOSE" == "true" ]]; then
            echo "# No active InfiniBand devices found, disabling IB"
        fi
        echo "export NCCL_IB_DISABLE=1"
    fi
    
    if [[ ! -z "$DETECTED_ETH_INTERFACES" ]]; then
        if [[ "$VERBOSE" == "true" ]]; then
            echo ""
            echo "# Ethernet fallback for NCCL"
        fi
        echo "export NCCL_SOCKET_IFNAME=$(echo $DETECTED_ETH_INTERFACES | cut -d',' -f1)"
    fi
    
    if [[ "$VERBOSE" == "true" ]]; then
        echo ""
        echo "# NCCL Debug settings"
    fi
    echo "export NCCL_DEBUG=INFO"
    echo "export NCCL_DEBUG_SUBSYS=ALL"
    
    # UCX Configuration
    if [[ "$VERBOSE" == "true" ]]; then
        echo ""
        echo "# === UCX Configuration ==="
    fi
    
    if [[ ! -z "$DETECTED_IB_DEVICES_WITH_PORTS" ]]; then
        if [[ "$VERBOSE" == "true" ]]; then
            echo "# UCX InfiniBand devices (with port specification)"
        fi
        
        # Use only InfiniBand devices for UCX when available
        echo "export UCX_NET_DEVICES=$DETECTED_IB_DEVICES_WITH_PORTS"
    else
        if [[ "$VERBOSE" == "true" ]]; then
            echo "# No InfiniBand devices for UCX, using Ethernet only"
        fi
        if [[ ! -z "$DETECTED_ETH_INTERFACES" ]]; then
            echo "export UCX_NET_DEVICES=$(echo $DETECTED_ETH_INTERFACES | cut -d',' -f1)"
        fi
    fi
    
    if [[ "$VERBOSE" == "true" ]]; then
        echo ""
        echo "# === Verification Commands ==="
        echo "# To verify NCCL: NCCL_DEBUG=INFO python your_script.py"
        echo "# To verify UCX: UCX_LOG_LEVEL=info mpirun your_application"
    fi
}

# Main function
main() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo "Improved InfiniBand Detection Script"
        echo "===================================="
        echo "This script properly filters for actual InfiniBand adapters"
        echo ""
    fi
    
    # Check and install iproute2 if not installed
    if ! check_and_install_iproute2; then
        echo "ERROR: iproute2 is required but could not be installed. Exiting." >&2
        exit 1
    fi
    
    detect_ib_devices
    detect_ethernet_interfaces
    
    # Check if output file is specified
    if [[ ! -z "$OUTPUT_FILE" ]]; then
        # Append to file mode
        append_env_variables "$OUTPUT_FILE"
        
        if [[ "$VERBOSE" == "true" ]]; then
            echo -e "\n=== Summary ==="
            echo "InfiniBand devices: ${DETECTED_IB_DEVICES:-'None found'}"
            echo "Ethernet devices: ${DETECTED_ETH_INTERFACES:-'None found'}"
            echo "Variables appended to: $OUTPUT_FILE"
        fi
    else
        # Standard output mode
        generate_env_variables
        
        if [[ "$VERBOSE" == "true" ]]; then
            echo -e "\n=== Summary ==="
            echo "InfiniBand devices: ${DETECTED_IB_DEVICES:-'None found'}"
            echo "Ethernet devices: ${DETECTED_ETH_INTERFACES:-'None found'}"
        fi
    fi
    
    # Show warnings in verbose mode
    if [[ "$VERBOSE" == "true" && -z "$DETECTED_IB_DEVICES" ]]; then
        echo ""
        echo "⚠️  WARNING: No active InfiniBand devices detected!"
        echo "   This could mean:"
        echo "   1. No IB hardware is installed"
        echo "   2. IB drivers are not loaded"
        echo "   3. Devices are configured for Ethernet mode"
        echo "   4. Ports are not connected/active"
    fi
}

# Run the script
main
