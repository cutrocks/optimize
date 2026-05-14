#!/bin/bash
# Omni CPU Balance Optimizer v2.5 - Dell R630 / CentOS 7
# Zero downtime - idempotent - no reboot required
# Usage: ./optimize.sh [NIC]   <- NIC optional, auto-detected if not given
# Log  : /var/log/omni-cpu-tune.log

set -uo pipefail

# -- SKIP FLAGS ------------------------------------------------
SKIP_NUMA=0          # set 1 if numactl unavailable

# -- CONFIG ----------------------------------------------------
LOG="/var/log/omni-cpu-tune.log"
SYSCTL_DROP="/etc/sysctl.d/99-omni-tuning.conf"
ERRORS=0
TS=$(date '+%Y-%m-%d %H:%M:%S')
SEP="============================================"

# -- HELPERS ---------------------------------------------------
p()    { echo "$*" | tee -a "$LOG"; }
ok()   { p "  [OK]   $*"; }
warn() { p "  [WARN] $*"; }
err()  { p "  [ERR]  $*"; ERRORS=$((ERRORS+1)); }
log()  { p "         $*"; }
skip() { p "  [SKIP] $*"; }
sep()  { p "$SEP"; }

sep
p "  [$TS] Omni CPU Balance Optimizer v2.5 - START"
p "  SKIP_NUMA = $SKIP_NUMA"
sep

# -- ROOT CHECK ------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    echo "[ERR] Run as root."
    exit 1
fi

# -- AUTO DETECT NIC -------------------------------------------
# Priority: 1) CLI argument  2) default route  3) fastest link up
sep
detect_nic() {
    local nic speed best_nic best_speed candidate s

    # Priority 1: command line argument
    if [ -n "${1:-}" ]; then
        if ip link show "$1" &>/dev/null; then
            echo "$1"
            return
        else
            p "  [WARN] Argument NIC '$1' not found - falling back to auto-detect"
        fi
    fi

    # Priority 2: default route interface
    nic=$(ip route 2>/dev/null | awk '/default/{print $5; exit}')
    if [ -n "$nic" ] && ip link show "$nic" &>/dev/null; then
        echo "$nic"
        return
    fi

    # Priority 3: pick highest speed link-up interface (skip lo, veth, docker, virbr)
    best_nic=""
    best_speed=0
    for candidate in /sys/class/net/*; do
        candidate=$(basename "$candidate")
        case "$candidate" in
            lo|veth*|docker*|virbr*|br-*|bond*|tun*|tap*) continue ;;
        esac
        # Must be UP
        operstate=$(cat /sys/class/net/$candidate/operstate 2>/dev/null || echo "unknown")
        [ "$operstate" = "up" ] || continue
        # Get speed in Mbps
        s=$(cat /sys/class/net/$candidate/speed 2>/dev/null || echo 0)
        # speed returns -1 for virtual/unknown
        [ "$s" -gt 0 ] 2>/dev/null || continue
        if [ "$s" -gt "$best_speed" ]; then
            best_speed="$s"
            best_nic="$candidate"
        fi
    done

    if [ -n "$best_nic" ]; then
        echo "$best_nic"
        return
    fi

    # Last resort: first non-loopback UP interface
    ip link show | awk '/^[0-9]+: /{gsub(":",""); if ($2 != "lo") print $2}' | head -1
}

NIC=$(detect_nic "${1:-}")
if [ -z "$NIC" ]; then
    err "Cannot detect NIC. Pass it as argument: ./optimize.sh eth0"
    exit 1
fi

# Show detected NIC and its properties
NIC_SPEED=$(cat /sys/class/net/$NIC/speed 2>/dev/null || echo "?")
NIC_DRIVER=$(ethtool -i "$NIC" 2>/dev/null | awk '/^driver:/{print $2}')
NIC_STATE=$(cat /sys/class/net/$NIC/operstate 2>/dev/null || echo "?")
ok "Detected NIC   : $NIC"
ok "Driver         : ${NIC_DRIVER:-unknown}"
ok "Speed          : ${NIC_SPEED}Mbps"
ok "State          : $NIC_STATE"

# If multiple physical NICs exist, list alternatives
ALL_NICS=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^lo$|^veth|^docker|^virbr|^br-|^bond|^tun|^tap')
NIC_COUNT=$(echo "$ALL_NICS" | wc -l)
if [ "$NIC_COUNT" -gt 1 ]; then
    log "Other interfaces found:"
    echo "$ALL_NICS" | while read -r iface; do
        [ "$iface" = "$NIC" ] && continue
        sp=$(cat /sys/class/net/$iface/speed 2>/dev/null || echo "?")
        st=$(cat /sys/class/net/$iface/operstate 2>/dev/null || echo "?")
        log "  $iface  speed=${sp}Mbps  state=$st"
    done
    log "  To tune a different NIC: ./optimize.sh <NIC>"
fi

# -- INSTALL PACKAGES ------------------------------------------
sep
p "  Checking packages..."
for pkg in irqbalance ethtool sysstat; do
    if rpm -q "$pkg" &>/dev/null; then
        ok "$pkg: installed"
    else
        log "Installing $pkg..."
        yum install -y "$pkg" &>/dev/null && ok "$pkg: installed" || err "$pkg: FAILED"
    fi
done

if [ "$SKIP_NUMA" -eq 0 ]; then
    if rpm -q numactl &>/dev/null; then
        ok "numactl: installed"
    else
        log "Installing numactl (timeout 30s)..."
        if timeout 30 yum install -y numactl &>/dev/null; then
            ok "numactl: installed"
        else
            warn "numactl timed out - setting SKIP_NUMA=1"
            SKIP_NUMA=1
        fi
    fi
else
    skip "numactl (SKIP_NUMA=1)"
fi

# -- CPU INFO --------------------------------------------------
sep
p "  CPU INFO"
lscpu | grep -E 'CPU\(s\)|Thread|Core|Socket|NUMA' | tee -a "$LOG"
TOTAL_CPU=$(nproc)
ok "Total CPU Threads: $TOTAL_CPU"

# Pure bash bitmask - exclude CPU0 (handles kernel IRQs)
MASK_ALL=$(printf '%x' $(( (1 << TOTAL_CPU) - 1 )))
MASK_RPS=$(printf '%x' $(( ((1 << TOTAL_CPU) - 1) & ~1 )))
ok "Mask ALL CPUs : $MASK_ALL"
ok "Mask RPS/XPS  : $MASK_RPS (CPU0 excluded)"

# FIX v2.5: Convert flat hex mask to kernel cpumask format
# Kernel sysfs cpumask expects comma-separated 32-bit groups
# Example: 48 CPUs -> "fffffffffffe" -> "0000ffff,fffffffe"
hex_to_cpumask() {
    local hex="$1"
    local padded result chunk rem pad

    # Pad hex string to multiple of 8 characters
    rem=$(( ${#hex} % 8 ))
    if [ "$rem" -ne 0 ]; then
        pad=$(( 8 - rem ))
        padded=$(printf "%0${pad}d" 0)$hex
    else
        padded="$hex"
    fi

    # Split into 8-char groups separated by commas
    result=""
    while [ ${#padded} -gt 0 ]; do
        chunk="${padded:0:8}"
        padded="${padded:8}"
        if [ -n "$result" ]; then
            result="$result,$chunk"
        else
            result="$chunk"
        fi
    done
    echo "$result"
}

CPUMASK_RPS=$(hex_to_cpumask "$MASK_RPS")
CPUMASK_ALL=$(hex_to_cpumask "$MASK_ALL")
ok "Kernel cpumask RPS: $CPUMASK_RPS"

# -- BUILD CPU MASK FROM LIST ----------------------------------
build_mask() {
    local cpulist M cpu
    cpulist=$(echo "$1" | tr ',' ' ')
    M=0
    for cpu in $cpulist; do
        case "$cpu" in *[!0-9]*) continue ;; esac
        M=$(( M | (1 << cpu) ))
    done
    printf '%x' $M
}

# -- NUMA TOPOLOGY ---------------------------------------------
sep
if [ "$SKIP_NUMA" -eq 1 ]; then
    skip "NUMA topology (SKIP_NUMA=1)"
    skip "NUMA IRQ pinning (SKIP_NUMA=1)"
    warn "Balance relies on irqbalance + RPS only."
else
    p "  NUMA TOPOLOGY"
    numactl --hardware 2>/dev/null | head -10 | tee -a "$LOG"

    NIC_NUMA=$(cat /sys/class/net/$NIC/device/numa_node 2>/dev/null || echo "N/A")
    ok "NIC $NIC is on NUMA node: $NIC_NUMA"

    # Parse CPU lists from lscpu output
    NODE0_CSV=$(lscpu | grep "NUMA node0" | awk -F: '{print $2}' | tr -d ' ')
    NODE1_CSV=$(lscpu | grep "NUMA node1" | awk -F: '{print $2}' | tr -d ' ')
    NODE0_LIST=$(echo "$NODE0_CSV" | tr ',' ' ')
    NODE1_LIST=$(echo "$NODE1_CSV" | tr ',' ' ')

    ok "Node 0 CPUs: $NODE0_CSV"
    ok "Node 1 CPUs: $NODE1_CSV"

    MASK_N0=$(build_mask "$NODE0_LIST")
    MASK_N1=$(build_mask "$NODE1_LIST")
    CPUMASK_N0=$(hex_to_cpumask "$MASK_N0")
    CPUMASK_N1=$(hex_to_cpumask "$MASK_N1")
    ok "Node 0 mask: $MASK_N0  cpumask: $CPUMASK_N0"
    ok "Node 1 mask: $MASK_N1  cpumask: $CPUMASK_N1"

    # -- IRQ PINNING (with managed IRQ detection) --------------
    sep
    p "  NUMA-AWARE IRQ PINNING"

    NIC_IRQS=$(grep "$NIC" /proc/interrupts 2>/dev/null | awk -F: '{print $1}' | tr -d ' ')
    if [ -z "$NIC_IRQS" ]; then
        warn "No IRQs found for $NIC - skipping."
    else
        TOTAL_IRQS=$(echo "$NIC_IRQS" | wc -l)
        ok "Found $TOTAL_IRQS IRQs for $NIC"

        # Test if IRQ affinity is writable (managed IRQs are driver-locked)
        FIRST_IRQ=$(echo "$NIC_IRQS" | head -1)
        TEST_WRITE=$(echo "$CPUMASK_N0" > /proc/irq/$FIRST_IRQ/smp_affinity 2>&1)
        if [ $? -ne 0 ]; then
            warn "IRQs are managed by driver ($NIC_DRIVER) - smp_affinity is read-only."
            warn "Using ethtool RSS spreading instead (see below)."
            IRQ_MANAGED=1
        else
            IRQ_MANAGED=0
            ok "IRQ affinity is writable - pinning across NUMA nodes"
            IDX=0
            while IFS= read -r irq; do
                [ -z "$irq" ] && continue
                if [ $(( IDX % 2 )) -eq 0 ]; then
                    TGT="$CPUMASK_N0"; LBL="Node0/Socket0"
                else
                    TGT="$CPUMASK_N1"; LBL="Node1/Socket1"
                fi
                OLD=$(cat /proc/irq/$irq/smp_affinity 2>/dev/null || echo "?")
                if echo "$TGT" > /proc/irq/$irq/smp_affinity 2>/dev/null; then
                    ok "IRQ $irq: $OLD -> $TGT ($LBL)"
                else
                    warn "IRQ $irq: write failed"
                fi
                IDX=$(( IDX + 1 ))
            done <<EOF_IRQS
$NIC_IRQS
EOF_IRQS
        fi
    fi

    # -- ETHTOOL RSS SPREADING ---------------------------------
    # Used when IRQs are managed (driver-locked) - Intel ixgbe/i40e/igb
    # RSS indirection table spreads flows across all queues -> both sockets
    sep
    p "  ETHTOOL RSS SPREADING"
    MAX_QUEUES=$(ethtool -l "$NIC" 2>/dev/null \
        | awk '/Pre-set/,/Current/' | awk '/Combined/{print $2; exit}')
    [ -z "$MAX_QUEUES" ] && MAX_QUEUES=0

    if [ "$MAX_QUEUES" -gt 0 ]; then
        # Spread RSS across all available queues
        if ethtool -X "$NIC" equal "$TOTAL_CPU" 2>/dev/null; then
            ok "RSS indirection: spread across $TOTAL_CPU CPUs"
        elif ethtool -X "$NIC" equal "$MAX_QUEUES" 2>/dev/null; then
            ok "RSS indirection: spread across $MAX_QUEUES queues"
        else
            warn "ethtool -X not supported on $NIC_DRIVER - RSS not changed"
        fi
        # Show RSS table summary
        log "RSS table (first 16 entries):"
        ethtool -x "$NIC" 2>/dev/null | head -20 | tee -a "$LOG" || true
    else
        warn "Cannot determine queue count for RSS spreading"
    fi
fi

# -- NIC COMBINED QUEUES ---------------------------------------
sep
p "  NIC COMBINED QUEUES"
MAX_Q=$(ethtool -l "$NIC" 2>/dev/null | awk '/Pre-set/,/Current/' | awk '/Combined/{print $2; exit}')
CUR_Q=$(ethtool -l "$NIC" 2>/dev/null | awk '/Current hardware/,0' | awk '/Combined/{print $2; exit}')

if [ -n "$MAX_Q" ] && echo "$MAX_Q" | grep -qE '^[0-9]+$'; then
    if [ "$CUR_Q" = "$MAX_Q" ]; then
        ok "Combined queues already at max: $MAX_Q"
    else
        ethtool -L "$NIC" combined "$MAX_Q" 2>/dev/null \
            && ok "Combined queues: $CUR_Q -> $MAX_Q" \
            || warn "Cannot set combined queues (driver may not support)"
    fi
else
    warn "Combined channels not supported on $NIC"
fi

# -- RPS / XPS (FIX v2.5: use proper cpumask format) -----------
sep
p "  RPS / XPS  (cpumask: $CPUMASK_RPS)"

RX_Q=(/sys/class/net/$NIC/queues/rx-*)
if [ -e "${RX_Q[0]}" ]; then
    RPS_OK=0; RPS_FAIL=0
    for q in "${RX_Q[@]}"; do
        qn=$(basename "$q")
        if echo "$CPUMASK_RPS" > "$q/rps_cpus" 2>/dev/null; then
            RPS_OK=$(( RPS_OK + 1 ))
        else
            RPS_FAIL=$(( RPS_FAIL + 1 ))
        fi
        echo "32768" > "$q/rps_flow_cnt" 2>/dev/null || true
    done
    echo 65535 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
    ok "RPS: $RPS_OK queues set, $RPS_FAIL failed"
    ok "rps_sock_flow_entries -> 65535"
else
    warn "No RX queues found for $NIC"
fi

TX_Q=(/sys/class/net/$NIC/queues/tx-*)
if [ -e "${TX_Q[0]}" ]; then
    XPS_OK=0; XPS_FAIL=0
    for q in "${TX_Q[@]}"; do
        if echo "$CPUMASK_RPS" > "$q/xps_cpus" 2>/dev/null; then
            XPS_OK=$(( XPS_OK + 1 ))
        else
            XPS_FAIL=$(( XPS_FAIL + 1 ))
        fi
    done
    ok "XPS: $XPS_OK queues set, $XPS_FAIL failed"
else
    warn "No TX queues found for $NIC"
fi

# -- SYSCTL TUNING ---------------------------------------------
sep
p "  SYSCTL TUNING -> $SYSCTL_DROP"
printf '%s\n' \
    "# Omni CPU Balance - auto-generated" \
    "net.core.netdev_max_backlog   = 250000" \
    "net.core.somaxconn            = 65535" \
    "net.ipv4.tcp_max_syn_backlog  = 262144" \
    "net.core.rmem_max             = 134217728" \
    "net.core.wmem_max             = 134217728" \
    "net.ipv4.tcp_rmem             = 4096 87380 134217728" \
    "net.ipv4.tcp_wmem             = 4096 65536 134217728" \
    "kernel.sched_migration_cost_ns = 500000" \
    "kernel.numa_balancing          = 1" \
    "kernel.sched_autogroup_enabled = 0" \
    > "$SYSCTL_DROP"
sysctl -p "$SYSCTL_DROP" 2>&1 | tee -a "$LOG" && ok "sysctl applied" || err "sysctl FAILED"

# -- IRQBALANCE ------------------------------------------------
sep
p "  IRQBALANCE"
systemctl enable irqbalance --quiet 2>/dev/null
systemctl restart irqbalance 2>&1 | tee -a "$LOG"
ok "irqbalance: $(systemctl is-active irqbalance)"

# -- IRQ DISTRIBUTION ------------------------------------------
sep
p "  IRQ DISTRIBUTION - $NIC (first 10 queues)"
grep "$NIC" /proc/interrupts | head -10 | tee -a "$LOG"

# -- LIVE VERIFICATION -----------------------------------------
sep
p "  VERIFICATION"
RX0="/sys/class/net/$NIC/queues/rx-0/rps_cpus"
[ -f "$RX0" ] && ok "RPS rx-0 cpumask : $(cat $RX0)" || warn "rx-0 rps_cpus not readable"
for key in net.core.somaxconn net.core.netdev_max_backlog kernel.numa_balancing; do
    ok "$key = $(sysctl -n $key 2>/dev/null || echo N/A)"
done
ok "irqbalance PID : $(pgrep irqbalance 2>/dev/null || echo NOT_RUNNING)"

# -- DONE ------------------------------------------------------
sep
if [ "$ERRORS" -eq 0 ]; then
    p "  [DONE] OK - 0 errors. No reboot needed."
else
    p "  [WARN] Done with $ERRORS error(s). Check: $LOG"
fi
if [ "$SKIP_NUMA" -eq 1 ]; then
    p "  [NOTE] Install numactl + set SKIP_NUMA=0 for full dual-socket balance."
fi
p ""
p "  NIC tuned: $NIC ($NIC_DRIVER, ${NIC_SPEED}Mbps)"
p "  Log      : $LOG"
p ""
p "  -- Verify balance --"
p "  mpstat -P ALL 2 5                       # CPU load per socket"
p "  numastat -c                             # NUMA memory locality"
p "  watch -n1 'grep $NIC /proc/interrupts | head -5'  # IRQ spread"
p "  ethtool -x $NIC | head -20              # RSS table"
sep
