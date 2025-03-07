#!/bin/bash

log_file="/var/log/check_speeds.log"

test_mode=false
if [[ "$1" == "--test" ]]; then
    test_mode=true
fi

if [[ $PPID -ne 1 && -z "$NOHUP_STARTED" && "$test_mode" == false ]]; then
    MAGENTA="\e[35m"
    YELLOW="\e[33m"
    RESET="\e[0m"
    echo -e "${MAGENTA}Start. Check logs with command:${RESET} ${YELLOW}tail -f $log_file${RESET}"
    NOHUP_STARTED=1 nohup "$0" "$@" > "$log_file" 2>&1 &
    exit
fi

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
MAGENTA="\e[35m"
CYAN="\e[36m"
BOLD="\e[1m"
RESET="\e[0m"

file_path="/incremental-snapshot.tar.bz2"
temp_dir="/tmp/speedtest"
mkdir -p "$temp_dir"
results_file="$temp_dir/speed_results.txt"
> "$results_file"
> "$log_file"

declare -A identity_map

if [[ "$test_mode" == true ]]; then
    identity_map=(
        ["127.0.0.1:8001"]="TestIdentity1"
        ["127.0.0.2:8002"]="TestIdentity2"
        ["127.0.0.3:8003"]="TestIdentity3"
    )
else
    while read -r line; do
        rpc_address=$(echo "$line" | awk -F'|' '{gsub(/ /,"",$6); print $6}')
        identity=$(echo "$line" | awk -F'|' '{gsub(/ /,"",$2); print $2}')
        if [[ "$rpc_address" != "none" && -n "$rpc_address" ]]; then
            identity_map["$rpc_address"]="$identity"
        fi
    done <<< "$(solana gossip -ut 2>/dev/null | tail -n +3)"
fi

if [ ${#identity_map[@]} -eq 0 ]; then
    echo -e "${RED}X Failed to get node list.${RESET}"
    exit 1
fi

total_nodes=${#identity_map[@]}
echo "Found $total_nodes nodes."
echo "Starting to check the servers..."

processed=0
for rpc_address in "${!identity_map[@]}"; do
    ((processed++))
    percent=$((processed * 100 / total_nodes))
    identity="${identity_map[$rpc_address]}"

    echo -e "${BOLD}[$percent%]${RESET} Checking $rpc_address - ${CYAN}$identity${RESET}..."

    if [[ "$test_mode" == true ]]; then
        speed=$(awk "BEGIN {printf \"%.2f\", (RANDOM%100+1)/10}")
        echo "$rpc_address - $identity - ${speed} MB/s" >> "$results_file"
        echo -e "$rpc_address: ${CYAN}$identity${RESET} - ${GREEN}${speed} MB/s${RESET}"
        continue
    fi

    ip="${rpc_address%%:*}"
    port="${rpc_address##*:}"
    url="http://$rpc_address$file_path"

    if ! timeout 5 bash -c ">/dev/tcp/$ip/$port" 2>/dev/null; then
        echo -e "$rpc_address - ${CYAN}$identity${RESET}: ${RED}Port unavailable${RESET}"
        continue
    fi

    raw_speed=$(timeout 40 wget -O /dev/null --timeout=20 --tries=1 --read-timeout=20 "$url" 2>&1 | grep -oP '[0-9.]+ [KM]B/s' | tail -1)

    if [ $? -eq 124 ]; then
        echo -e "$rpc_address - ${CYAN}$identity${RESET}: ${RED}Timed out (40 sec)${RESET}"
    elif [ -z "$raw_speed" ]; then
        echo -e "$rpc_address - ${CYAN}$identity${RESET}: ${RED}Connection error or timeout${RESET}"
    else
        speed_value=$(echo "$raw_speed" | awk '{print $1}')
        speed_unit=$(echo "$raw_speed" | awk '{print $2}')
        if [ "$speed_unit" == "KB/s" ]; then
            speed=$(awk "BEGIN {printf \"%.2f\", $speed_value/1024}")
        else
            speed=$(awk "BEGIN {printf \"%.2f\", $speed_value}")
        fi
        echo "$rpc_address - $identity - ${speed} MB/s" >> "$results_file"
        echo -e "$rpc_address: ${CYAN}$identity${RESET} - ${GREEN}${speed} MB/s${RESET}"
    fi
done

if [ ! -s "$results_file" ]; then
    echo -e "\n${RED}X No successful tests. Closing.${RESET}"
    exit 1
fi

echo -e "\n${YELLOW}${BOLD}Best servers:${RESET}"
echo -e "${YELLOW}"
sort -k5 -nr "$results_file" | head -10 | while read -r line; do
    rpc_address=$(echo "$line" | awk -F' - ' '{print $1}')
    identity=$(echo "$line" | awk -F' - ' '{print $2}')
    speed=$(echo "$line" | awk -F' - ' '{print $3}')
    echo -e "$rpc_address: ${CYAN}$identity${RESET} - ${GREEN}$speed${RESET}"
done

echo -e "${RESET}"
echo -e "\n${MAGENTA}Results in file ${YELLOW}$results_file${MAGENTA}\nPress CTRL+C for Exit.${RESET}"
