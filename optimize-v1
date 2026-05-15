#!/bin/bash
# ============================================================
#  SMART CPU AUTO-REBALANCER — CentOS 7 | Dell R630
#  2x Xeon E5-2690 v3 | 48 Logical CPUs (24c x2 HT)
#
#  Strategy:
#  1. Sample per-CPU utilization
#  2. Identify overloaded CPUs (> HIGH_THRESH %)
#  3. Identify underloaded CPUs (< LOW_THRESH %)
#  4. Migrate heavy processes from hot → cold CPUs via taskset
#  5. Loop every INTERVAL seconds as a daemon
#
#  Usage:
#    ./cpu_autobalance.sh            # run once (manual)
#    ./cpu_autobalance.sh --daemon   # run as daemon loop
#    ./cpu_autobalance.sh --install  # install as systemd service
#    ./cpu_autobalance.sh --status   # show current CPU balance
# ============================================================

# ── Tunable Parameters ─────────────────────────────────────
HIGH_THRESH=75       # CPU% above this = overloaded
LOW_THRESH=30        # CPU% below this = underloaded
INTERVAL=10          # seconds between rebalance cycles
MAX_MOVES=8          # max process migrations per cycle
MIN_CPU_PCT=5        # ignore processes using less than this %
SAMPLE_SEC=2         # mpstat sample duration
LOG_FILE="/var/log/cpu_autobalance.log"
PID_FILE="/var/run/cpu_autobalance.pid"
MAX_LOG_MB=50        # rotate log after 50MB

# ── Process Blacklist (never touch these) ──────────────────
# Kernel threads, critical system processes
BLACKLIST="kthreadd|migration|kworker|kdevtmpfs|netns|khungtaskd|\
oom_reaper|writeback|kcompactd|kblockd|scsi_eh|irq/|xfs-|jbd2|\
systemd|sshd|auditd|rsyslogd|tuned|irqbalance|dbus|polkitd|\
NetworkManager|chronyd|crond|agetty|bash|cpu_autobalance"

# ── Colors ─────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
MAGENTA='\033[0;35m'

log_msg() {
    local level=$1; shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    echo "$msg" >> "$LOG_FILE"
    case $level in
        INFO)  echo -e "${GREEN}[INFO]${NC}  $*" ;;
        WARN)  echo -e "${YELLOW}[WARN]${NC}  $*" ;;
        ERROR) echo -e "${RED}[ERR]${NC}   $*" ;;
        MOVE)  echo -e "${CYAN}[MOVE]${NC}  $*" ;;
        STAT)  echo -e "${BLUE}[STAT]${NC}  $*" ;;
    esac
}

rotate_log() {
    if [[ -f "$LOG_FILE" ]]; then
        local size_mb
        size_mb=$(du -sm "$LOG_FILE" 2>/dev/null | awk '{print $1}')
        if [[ "${size_mb:-0}" -gt "$MAX_LOG_MB" ]]; then
            mv "$LOG_FILE" "${LOG_FILE}.1"
            log_msg INFO "Log rotated (was ${size_mb}MB)"
        fi
    fi
}

# ─────────────────────────────────────────────
# 1. DEPENDENCY CHECK
# ─────────────────────────────────────────────
check_deps() {
    local ok=1
    for cmd in mpstat taskset awk ps grep; do
        command -v "$cmd" &>/dev/null || { log_msg ERROR "Missing: $cmd"; ok=0; }
    done
    [[ $ok -eq 0 ]] && { log_msg ERROR "Install: yum install sysstat util-linux -y"; exit 1; }
    [[ $EUID -ne 0 ]] && { log_msg ERROR "Must run as root"; exit 1; }
}

# ─────────────────────────────────────────────
# 2. GET TOTAL CPU COUNT & NUMA INFO
# ─────────────────────────────────────────────
get_topology() {
    TOTAL_CPUS=$(nproc --all)
    CPU_MAX=$((TOTAL_CPUS - 1))
    ALL_CPUS=$(seq 0 "$CPU_MAX" | tr '\n' ',' | sed 's/,$//')

    # Build NUMA socket maps
    SOCKET0_CPUS=(); SOCKET1_CPUS=()
    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*/topology; do
        [[ -d "$cpu_dir" ]] || continue
        cpu_id=$(echo "$cpu_dir" | grep -oP 'cpu\K[0-9]+')
        socket=$(cat "$cpu_dir/physical_package_id" 2>/dev/null || echo "0")
        [[ "$socket" == "0" ]] && SOCKET0_CPUS+=("$cpu_id")
        [[ "$socket" == "1" ]] && SOCKET1_CPUS+=("$cpu_id")
    done

    S0_MASK=$(IFS=,; echo "${SOCKET0_CPUS[*]}")
    S1_MASK=$(IFS=,; echo "${SOCKET1_CPUS[*]}")

    # Sort numerically (fix alphabetical ordering: cpu0,cpu10,cpu11 → cpu0,cpu1,cpu2...)
    IFS=$'\n' SOCKET0_CPUS=($(printf '%s\n' "${SOCKET0_CPUS[@]}" | sort -n))
    IFS=$'\n' SOCKET1_CPUS=($(printf '%s\n' "${SOCKET1_CPUS[@]}" | sort -n))
    unset IFS
}

# ─────────────────────────────────────────────
# 3. SAMPLE PER-CPU UTILIZATION
# ─────────────────────────────────────────────
declare -A CPU_USAGE  # global: CPU_USAGE[cpu_id]=busy%

sample_cpu_usage() {
    CPU_USAGE=()
    while IFS= read -r line; do
        cpu=$(echo "$line" | awk '{print $2}')
        idle=$(echo "$line" | awk '{print $NF}')
        busy=$(awk "BEGIN{printf \"%.1f\", 100 - $idle}")
        CPU_USAGE["$cpu"]="$busy"
    done < <(mpstat -P ALL "$SAMPLE_SEC" 1 2>/dev/null | \
             awk '/^Average/ && $2 != "CPU" && $2 != "all" {print}')
}

# ─────────────────────────────────────────────
# 4. CLASSIFY CPUs INTO HOT / COLD / NORMAL
# ─────────────────────────────────────────────
classify_cpus() {
    HOT_CPUS=(); COLD_CPUS=(); NORMAL_CPUS=()
    for cpu in "${!CPU_USAGE[@]}"; do
        usage="${CPU_USAGE[$cpu]}"
        result=$(awk "BEGIN{
            if ($usage >= $HIGH_THRESH) print \"HOT\"
            else if ($usage <= $LOW_THRESH) print \"COLD\"
            else print \"NORMAL\"
        }")
        case $result in
            HOT)    HOT_CPUS+=("$cpu")    ;;
            COLD)   COLD_CPUS+=("$cpu")   ;;
            NORMAL) NORMAL_CPUS+=("$cpu") ;;
        esac
    done

    # Sort HOT by usage descending, COLD by usage ascending
    IFS=$'\n'
    HOT_CPUS=($(for c in "${HOT_CPUS[@]}"; do echo "${CPU_USAGE[$c]} $c"; done | \
                sort -rn | awk '{print $2}'))
    COLD_CPUS=($(for c in "${COLD_CPUS[@]}"; do echo "${CPU_USAGE[$c]} $c"; done | \
                sort -n | awk '{print $2}'))
    unset IFS
}

# ─────────────────────────────────────────────
# 5. GET PROCESSES ON A SPECIFIC CPU
#    Returns: PID PPID CPU% COMM lines
# ─────────────────────────────────────────────
get_procs_on_cpu() {
    local target_cpu=$1
    # ps shows 'psr' = processor last ran on
    ps -eo pid,ppid,psr,pcpu,comm --no-headers 2>/dev/null | \
        awk -v cpu="$target_cpu" -v min="$MIN_CPU_PCT" -v bl="$BLACKLIST" '
        $3 == cpu && $4+0 >= min {
            if ($5 !~ bl) print $1, $2, $3, $4, $5
        }' | sort -k4 -rn
}

# ─────────────────────────────────────────────
# 6. GET CURRENT AFFINITY OF A PROCESS
# ─────────────────────────────────────────────
get_affinity() {
    local pid=$1
    taskset -cp "$pid" 2>/dev/null | awk -F': ' '{print $2}'
}

# ─────────────────────────────────────────────
# 7. MOVE PROCESS TO TARGET CPU(s)
# ─────────────────────────────────────────────
move_process() {
    local pid=$1
    local target_cpu_list=$2   # e.g. "4,5,6,7"
    local comm=$3
    local old_affinity

    old_affinity=$(get_affinity "$pid")
    [[ -z "$old_affinity" ]] && return 1

    # Skip if process already has broad affinity (all CPUs) — let scheduler handle it
    local current_cpu_count
    current_cpu_count=$(taskset -cp "$pid" 2>/dev/null | awk -F': ' '{print $2}' | \
                        tr ',' '\n' | grep -c '[0-9]' || echo 0)

    if taskset -cp "$target_cpu_list" "$pid" &>/dev/null; then
        log_msg MOVE "PID $pid ($comm) | affinity: [$old_affinity] → [$target_cpu_list]"
        return 0
    else
        log_msg WARN "Failed to move PID $pid ($comm)"
        return 1
    fi
}

# ─────────────────────────────────────────────
# 8. CORE REBALANCE LOGIC
# ─────────────────────────────────────────────
do_rebalance() {
    local cycle=$1
    local moves=0

    sample_cpu_usage
    classify_cpus

    local hot_count=${#HOT_CPUS[@]}
    local cold_count=${#COLD_CPUS[@]}

    log_msg STAT "Cycle $cycle | HOT CPUs: $hot_count | COLD CPUs: $cold_count | Total: $TOTAL_CPUS"

    # Print current socket averages
    local s0_total=0 s0_n=0 s1_total=0 s1_n=0
    for cpu in "${SOCKET0_CPUS[@]}"; do
        u="${CPU_USAGE[$cpu]:-0}"
        s0_total=$(awk "BEGIN{print $s0_total + $u}")
        s0_n=$((s0_n+1))
    done
    for cpu in "${SOCKET1_CPUS[@]}"; do
        u="${CPU_USAGE[$cpu]:-0}"
        s1_total=$(awk "BEGIN{print $s1_total + $u}")
        s1_n=$((s1_n+1))
    done
    local s0_avg s1_avg
    s0_avg=$(awk "BEGIN{printf \"%.1f\", ($s0_n>0 ? $s0_total/$s0_n : 0)}")
    s1_avg=$(awk "BEGIN{printf \"%.1f\", ($s1_n>0 ? $s1_total/$s1_n : 0)}")
    log_msg STAT "Socket 0 avg: ${s0_avg}% | Socket 1 avg: ${s1_avg}%"

    # Nothing to do if no hot or no cold CPUs
    if [[ $hot_count -eq 0 ]]; then
        log_msg INFO "All CPUs within threshold — no rebalancing needed"
        return 0
    fi
    if [[ $cold_count -eq 0 ]]; then
        log_msg WARN "Hot CPUs detected but no cold CPUs to migrate to — system fully loaded"
        return 0
    fi

    # Build a pool of cold CPUs to spread work to
    # Use ALL cold CPUs as a spread mask (better than pinning to 1)
    local cold_mask
    cold_mask=$(IFS=,; echo "${COLD_CPUS[*]}")

    # Also build a "normal+cold" mask for broader spread
    local balanced_mask
    balanced_mask=$(printf '%s\n' "${COLD_CPUS[@]}" "${NORMAL_CPUS[@]}" | \
                    sort -n | tr '\n' ',' | sed 's/,$//')
    [[ -z "$balanced_mask" ]] && balanced_mask="$cold_mask"

    # Process each hot CPU
    for hot_cpu in "${HOT_CPUS[@]}"; do
        [[ $moves -ge $MAX_MOVES ]] && break

        local hot_usage="${CPU_USAGE[$hot_cpu]}"
        log_msg STAT "  HOT cpu$hot_cpu @ ${hot_usage}% — scanning processes..."

        # Get heaviest processes on this CPU
        while IFS= read -r proc_line; do
            [[ $moves -ge $MAX_MOVES ]] && break
            [[ -z "$proc_line" ]] && continue

            local pid ppid psr pcpu comm
            read -r pid ppid psr pcpu comm <<< "$proc_line"

            # Skip kernel threads (PPID=0 or 2 = kthreadd)
            [[ "$ppid" -eq 0 || "$ppid" -eq 2 ]] && continue

            # Skip blacklisted names
            echo "$comm" | grep -qE "$BLACKLIST" && continue

            # Skip if PID no longer exists
            kill -0 "$pid" 2>/dev/null || continue

            # Decide target: spread across cold+normal, prefer same socket if possible
            local target_mask="$balanced_mask"

            # If hot CPU is on socket 0, prefer to spread to cold CPUs on socket 1
            local in_s0=0
            for c in "${SOCKET0_CPUS[@]}"; do
                [[ "$c" == "$hot_cpu" ]] && in_s0=1 && break
            done

            if [[ $in_s0 -eq 1 ]]; then
                # Prefer socket 1 cold CPUs
                local s1_cold=()
                for c in "${COLD_CPUS[@]}"; do
                    for s1c in "${SOCKET1_CPUS[@]}"; do
                        [[ "$c" == "$s1c" ]] && s1_cold+=("$c")
                    done
                done
                [[ ${#s1_cold[@]} -gt 0 ]] && target_mask=$(IFS=,; echo "${s1_cold[*]}")
            else
                # Prefer socket 0 cold CPUs
                local s0_cold=()
                for c in "${COLD_CPUS[@]}"; do
                    for s0c in "${SOCKET0_CPUS[@]}"; do
                        [[ "$c" == "$s0c" ]] && s0_cold+=("$c")
                    done
                done
                [[ ${#s0_cold[@]} -gt 0 ]] && target_mask=$(IFS=,; echo "${s0_cold[*]}")
            fi

            if move_process "$pid" "$target_mask" "$comm"; then
                moves=$((moves + 1))
                log_msg MOVE "  → Moved $comm (PID:$pid, ${pcpu}%) cpu$hot_cpu → [$target_mask]"
            fi

        done < <(get_procs_on_cpu "$hot_cpu")
    done

    log_msg INFO "Cycle $cycle complete — $moves migrations performed"
    echo "---" >> "$LOG_FILE"
}

# ─────────────────────────────────────────────
# 9. IRQBALANCE RECONFIGURE
# ─────────────────────────────────────────────
setup_irqbalance() {
    log_msg INFO "Reconfiguring irqbalance..."

    cat > /etc/sysconfig/irqbalance << 'EOF'
IRQBALANCE_ONESHOT=no
IRQBALANCE_ARGS="--powerthresh=0 --deepestcache=2"
EOF

    if systemctl is-active irqbalance &>/dev/null; then
        systemctl restart irqbalance
        log_msg INFO "irqbalance restarted"
    else
        systemctl enable --now irqbalance
        log_msg INFO "irqbalance enabled and started"
    fi
}

# ─────────────────────────────────────────────
# 10. KERNEL SCHEDULER TUNING
# ─────────────────────────────────────────────
apply_kernel_tuning() {
    log_msg INFO "Applying scheduler kernel parameters..."

    sysctl -w kernel.numa_balancing=1              >> "$LOG_FILE" 2>&1
    sysctl -w kernel.sched_migration_cost_ns=250000 >> "$LOG_FILE" 2>&1
    sysctl -w kernel.sched_min_granularity_ns=10000000 >> "$LOG_FILE" 2>&1
    sysctl -w kernel.sched_wakeup_granularity_ns=15000000 >> "$LOG_FILE" 2>&1

    # Persist across reboots
    cat > /etc/sysctl.d/99-cpu-autobalance.conf << 'EOF'
kernel.numa_balancing = 1
kernel.sched_migration_cost_ns = 250000
kernel.sched_min_granularity_ns = 10000000
kernel.sched_wakeup_granularity_ns = 15000000
EOF

    log_msg INFO "Kernel tuning applied and persisted"
}

# ─────────────────────────────────────────────
# 11. OPEN AFFINITY FOR BOTTLENECKED PROCS
#     (BattleServer / AIProxyServer etc)
#     Open their affinity to ALL CPUs so kernel
#     can freely schedule them anywhere
# ─────────────────────────────────────────────
open_affinity_all() {
    log_msg INFO "Opening CPU affinity for all user processes to full CPU set..."

    local count=0
    while IFS= read -r line; do
        local pid comm ppid
        pid=$(echo "$line"  | awk '{print $1}')
        ppid=$(echo "$line" | awk '{print $2}')
        comm=$(echo "$line" | awk '{print $3}')

        # Skip kernel threads
        [[ "$ppid" -eq 0 || "$ppid" -eq 2 ]] && continue
        echo "$comm" | grep -qE "$BLACKLIST" && continue
        kill -0 "$pid" 2>/dev/null || continue

        if taskset -p 0xffffffffffff "$pid" &>/dev/null; then
            count=$((count+1))
        fi
    done < <(ps -eo pid,ppid,comm --no-headers 2>/dev/null)

    log_msg INFO "Opened affinity for $count processes → all CPUs"
}

# ─────────────────────────────────────────────
# 12. STATUS DISPLAY
# ─────────────────────────────────────────────
show_status() {
    echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  CPU BALANCE STATUS — $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${NC}\n"

    echo -e "  ${BOLD}Load Average:${NC} $(uptime | awk -F'load average:' '{print $2}')"
    echo -e "  ${BOLD}Total CPUs  :${NC} $(nproc --all)"
    echo ""

    get_topology
    sample_cpu_usage
    classify_cpus

    echo -e "  ${BOLD}Per-CPU Utilization:${NC}"
    echo ""

    local s0_total=0 s0_n=0 s1_total=0 s1_n=0

    printf "  %-32s %-32s\n" \
        "── Socket 0 (Node 0) ─────────────" \
        "── Socket 1 (Node 1) ─────────────"

    local MAX_LEN
    MAX_LEN=$(( ${#SOCKET0_CPUS[@]} > ${#SOCKET1_CPUS[@]} ? \
                ${#SOCKET0_CPUS[@]} : ${#SOCKET1_CPUS[@]} ))

    for ((idx=0; idx<MAX_LEN; idx++)); do
        S0_CPU="${SOCKET0_CPUS[$idx]:-}"
        S1_CPU="${SOCKET1_CPUS[$idx]:-}"

        format_cpu_bar() {
            local cpuid=$1 socket=$2
            local usage="${CPU_USAGE[$cpuid]:-0}"
            local usage_i
            usage_i=$(printf "%.0f" "$usage")
            local bar_len=$((usage_i * 14 / 100))
            local bar=""
            for ((b=0; b<bar_len; b++)); do bar+="█"; done
            for ((b=bar_len; b<14; b++)); do bar+="░"; done

            local C
            [[ $usage_i -ge 75 ]] && C=$RED || \
            [[ $usage_i -ge 50 ]] && C=$YELLOW || C=$GREEN
            [[ $socket -eq 1 ]] && { [[ $usage_i -ge 75 ]] && C=$RED || \
            [[ $usage_i -ge 50 ]] && C=$YELLOW || C=$BLUE; }

            printf "${C}  cpu%-3s %5.1f%% %s${NC}" "$cpuid" "$usage" "$bar"
        }

        S0_STR=""
        S1_STR=""
        [[ -n "$S0_CPU" ]] && S0_STR=$(format_cpu_bar "$S0_CPU" 0)
        [[ -n "$S1_CPU" ]] && S1_STR=$(format_cpu_bar "$S1_CPU" 1)
        echo -e "$S0_STR    $S1_STR"

        # Accumulate socket totals
        [[ -n "$S0_CPU" ]] && {
            u="${CPU_USAGE[$S0_CPU]:-0}"
            s0_total=$(awk "BEGIN{print $s0_total + $u}"); s0_n=$((s0_n+1)); }
        [[ -n "$S1_CPU" ]] && {
            u="${CPU_USAGE[$S1_CPU]:-0}"
            s1_total=$(awk "BEGIN{print $s1_total + $u}"); s1_n=$((s1_n+1)); }
    done

    local s0_avg s1_avg delta
    s0_avg=$(awk "BEGIN{printf \"%.1f\", ($s0_n>0 ? $s0_total/$s0_n : 0)}")
    s1_avg=$(awk "BEGIN{printf \"%.1f\", ($s1_n>0 ? $s1_total/$s1_n : 0)}")
    delta=$(awk "BEGIN{d=$s0_avg-$s1_avg; if(d<0)d=-d; printf \"%.1f\",d}")

    echo ""
    printf "  ${BOLD}Socket 0 avg: ${GREEN}%s%%${NC}   Socket 1 avg: ${BLUE}%s%%${NC}   Delta: " \
           "$s0_avg" "$s1_avg"
    if awk "BEGIN{exit ($delta > 15)}"; then
        printf "${GREEN}%s%% ✔ BALANCED${NC}\n" "$delta"
    else
        printf "${RED}%s%% ✘ IMBALANCED${NC}\n" "$delta"
    fi

    echo ""
    echo -e "  ${BOLD}Top CPU consumers:${NC}"
    ps -eo pid,pcpu,psr,comm --no-headers --sort=-pcpu 2>/dev/null | \
        awk '$2 >= 5 {printf "    PID:%-7s %6.1f%%  cpu%-3s  %s\n", $1, $2, $3, $4}' | \
        head -20
    echo ""
}

# ─────────────────────────────────────────────
# 13. INSTALL AS SYSTEMD SERVICE
# ─────────────────────────────────────────────
install_service() {
    local script_path
    script_path=$(realpath "$0")
    local service_file="/etc/systemd/system/cpu-autobalance.service"

    cat > "$service_file" << EOF
[Unit]
Description=CPU Auto-Rebalancer — Dell R630 CentOS 7
After=network.target irqbalance.service
Wants=irqbalance.service

[Service]
Type=simple
ExecStart=/bin/bash $script_path --daemon
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=cpu-autobalance

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable cpu-autobalance
    systemctl start  cpu-autobalance
    log_msg INFO "Service installed and started: cpu-autobalance"
    log_msg INFO "Check status : systemctl status cpu-autobalance"
    log_msg INFO "View logs    : journalctl -u cpu-autobalance -f"
    log_msg INFO "Live log     : tail -f $LOG_FILE"
}

# ─────────────────────────────────────────────
# 14. MAIN ENTRY POINT
# ─────────────────────────────────────────────
main() {
    local mode="${1:---once}"

    case "$mode" in

    # ── STATUS ONLY ─────────────────────────
    --status)
        get_topology
        show_status
        exit 0
        ;;

    # ── INSTALL SYSTEMD SERVICE ─────────────
    --install)
        check_deps
        get_topology
        setup_irqbalance
        apply_kernel_tuning
        open_affinity_all
        install_service
        exit 0
        ;;

    # ── DAEMON LOOP ─────────────────────────
    --daemon)
        check_deps
        get_topology

        echo $$ > "$PID_FILE"
        trap "rm -f $PID_FILE; exit 0" SIGTERM SIGINT

        log_msg INFO "=========================================="
        log_msg INFO "CPU Auto-Rebalancer STARTED (PID: $$)"
        log_msg INFO "Total CPUs: $TOTAL_CPUS | Interval: ${INTERVAL}s"
        log_msg INFO "Thresholds: HIGH=${HIGH_THRESH}% LOW=${LOW_THRESH}%"
        log_msg INFO "=========================================="

        # Initial setup on daemon start
        setup_irqbalance
        apply_kernel_tuning
        open_affinity_all

        CYCLE=0
        while true; do
            CYCLE=$((CYCLE + 1))
            rotate_log
            do_rebalance "$CYCLE"
            sleep "$INTERVAL"
        done
        ;;

    # ── SINGLE RUN ──────────────────────────
    --once|*)
        check_deps
        get_topology

        echo -e "${BOLD}${CYAN}"
        echo "  ╔══════════════════════════════════════════════════╗"
        echo "  ║   CPU AUTO-REBALANCER — Single Run Mode          ║"
        echo "  ║   2x E5-2690 v3 | CentOS 7          ║"
        echo "  ╚══════════════════════════════════════════════════╝"
        echo -e "${NC}"

        show_status
        setup_irqbalance
        apply_kernel_tuning
        open_affinity_all

        log_msg INFO "Running rebalance cycle..."
        do_rebalance 1

        echo ""
        log_msg INFO "Done. Re-run status check:"
        show_status

        echo ""
        echo -e "  ${BOLD}Next steps:${NC}"
        echo -e "  → Run as daemon : ${CYAN}./cpu_autobalance.sh --daemon${NC}"
        echo -e "  → Install svc   : ${CYAN}./cpu_autobalance.sh --install${NC}"
        echo -e "  → Live status   : ${CYAN}./cpu_autobalance.sh --status${NC}"
        echo -e "  → Watch log     : ${CYAN}tail -f $LOG_FILE${NC}"
        ;;
    esac
}

main "$@"
