#!/bin/bash

# Usage: sudo ./free_ips.sh <subnet> <count> [--pool]
# Example (contiguous IPs): sudo ./free_ips.sh 192.168.1.0/24 4 --pool
# Example (any random IPs): sudo ./free_ips.sh 192.168.1.0/24 4

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: sudo $0 <subnet> <count> [--pool]"
  exit 1
fi

SUBNET=$1
DESIRED_COUNT=$2
POOL_FLAG=false

if [[ $# -eq 3 && $3 == "--pool" ]]; then
  POOL_FLAG=true
fi

# Extract the base IP and subnet mask
IFS='/' read -r base_ip subnet_mask <<< "$SUBNET"

# Convert an IP to a decimal number
ip_to_decimal() {
  local IFS=.
  read -r a b c d <<< "$1"
  echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

# Convert a decimal number back to an IP
decimal_to_ip() {
  local ip=$1
  echo "$(( (ip >> 24) & 255 )).$(( (ip >> 16) & 255 )).$(( (ip >> 8) & 255 )).$(( ip & 255 ))"
}

# Calculate the number of IPs in the subnet
num_ips=$(( 2 ** (32 - subnet_mask) ))

# Calculate the network address (the first IP in the range) and the broadcast address (the last IP)
network_address_decimal=$(( $(ip_to_decimal "$base_ip") & ((2 ** subnet_mask - 1) << (32 - subnet_mask)) ))
broadcast_address_decimal=$(( network_address_decimal + num_ips - 1 ))

network_address=$(decimal_to_ip "$network_address_decimal")
broadcast_address=$(decimal_to_ip "$broadcast_address_decimal")

# Get the list of "down" IPs using nmap and store them in an array, excluding network and broadcast addresses
mapfile -t ips < <(nmap -v -sn -n "$SUBNET" -oG - | awk '/Status: Down/{print $2}' | grep -v -e "$network_address" -e "$broadcast_address")

if [[ ${#ips[@]} -lt $DESIRED_COUNT ]]; then
  echo "Not enough down IPs found to satisfy the requested count."
  exit 1
fi

# Function to find the smallest CIDR block that covers a range of IPs
range_to_cidr() {
  local start_ip_decimal=$1
  local desired_count=$2

  # Calculate the smallest CIDR block that can cover the range
  local mask=32
  local total_ips=1

  while (( total_ips < desired_count )); do
    ((mask--))
    total_ips=$((2 ** (32 - mask)))
  done

  # Exclude network and broadcast addresses in the CIDR range
  local first_ip_decimal=$start_ip_decimal
  local last_ip_decimal=$((start_ip_decimal + total_ips - 1))

  # Ensure the range doesn't include network or broadcast addresses
  if (( first_ip_decimal <= network_address_decimal )); then
    first_ip_decimal=$((network_address_decimal + 1))
  fi

  if (( last_ip_decimal >= broadcast_address_decimal )); then
    last_ip_decimal=$((broadcast_address_decimal - 1))
  fi

  echo "$(decimal_to_ip "$first_ip_decimal")/$mask"
}

# If the pool flag is set, look for contiguous IPs and output in CIDR format
if $POOL_FLAG; then
  for ((i=0; i <= ${#ips[@]} - DESIRED_COUNT; i++)); do
    start_ip="${ips[i]}"
    end_ip="${ips[i + DESIRED_COUNT - 1]}"

    # Ensure that the IPs are contiguous
    contiguous=true
    for ((j=0; j < DESIRED_COUNT - 1; j++)); do
      current_ip=$(ip_to_decimal "${ips[i + j]}")
      next_ip=$(ip_to_decimal "${ips[i + j + 1]}")
      if (( next_ip != current_ip + 1 )); then
        contiguous=false
        break
      fi
    done

    if $contiguous; then
      start_ip_decimal=$(ip_to_decimal "$start_ip")
      echo "Found contiguous down IP range in CIDR format:"
      cidr_range=$(range_to_cidr "$start_ip_decimal" "$DESIRED_COUNT")
      echo "$cidr_range"
      exit 0
    fi
  done
  echo "No contiguous down IPs found with the desired count of $DESIRED_COUNT."
  exit 1
else
  # Output random down IPs, excluding network and broadcast addresses
  for ((i=0; i < DESIRED_COUNT; i++)); do
    echo "${ips[i]}"
  done
  exit 0
fi

