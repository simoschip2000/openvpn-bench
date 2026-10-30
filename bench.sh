#!/bin/bash
# OpenVPN TCP throughput with and without --tun-backpressure.
#
# ns1: iperf3 client + OpenVPN client  --veth-->  ns2: OpenVPN server + iperf3 server
#
# Usage: sudo ./bench.sh   (settings via environment variables, see README.md)

set -euo pipefail
export LC_ALL=C

HERE=$(cd "$(dirname "$0")" && pwd)

OPENVPN=${OPENVPN:-$HERE/../openvpn/src/openvpn/openvpn}
STREAMS=${STREAMS:-8}
TXQUEUELEN=${TXQUEUELEN:-"500 5000"}
DURATION=${DURATION:-30}
OMIT=${OMIT:-2}
REPS=${REPS:-3}
CIPHER=${CIPHER:-AES-256-GCM}
UDP_RCVBUF=${UDP_RCVBUF:-8388608}
OUT=${OUT:-$HERE/results/$(date +%Y%m%d-%H%M%S)}

NS1=ovpnbench1
NS2=ovpnbench2
VPN1=10.8.0.1
VPN2=10.8.0.2

die() { echo "error: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
for tool in ip iperf3 openssl; do
    command -v "$tool" >/dev/null || die "$tool not found"
done
[ -x "$OPENVPN" ] || die "OpenVPN binary not found: $OPENVPN"
OPENVPN=$(realpath "$OPENVPN")

mkdir -p "$OUT"
OUT=$(realpath "$OUT")
WORK=$(mktemp -d)

stop_tunnel() {
    local pidfile pid
    for pidfile in "$WORK"/*.pid; do
        [ -e "$pidfile" ] || continue
        pid=$(cat "$pidfile")
        kill "$pid" 2>/dev/null || true
        while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done
        rm -f "$pidfile"
    done
}

cleanup() {
    stop_tunnel
    ip netns del "$NS1" 2>/dev/null || true
    ip netns del "$NS2" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

# SO_RCVBUF is capped at net.core.rmem_max.
(( UDP_RCVBUF <= $(sysctl -n net.core.rmem_max) )) ||
    die "net.core.rmem_max is too small, run 'sysctl -w net.core.rmem_max=$UDP_RCVBUF' first"

setup_netns() {
    ip netns del "$NS1" 2>/dev/null || true
    ip netns del "$NS2" 2>/dev/null || true
    ip netns add "$NS1"
    ip netns add "$NS2"
    ip -n "$NS1" link set lo up
    ip -n "$NS2" link set lo up
    ip link add veth1 netns "$NS1" type veth peer name veth2 netns "$NS2"
    ip -n "$NS1" addr add 10.0.0.1/24 dev veth1
    ip -n "$NS2" addr add 10.0.0.2/24 dev veth2
    ip -n "$NS1" link set veth1 up
    ip -n "$NS2" link set veth2 up
}

gen_certs() {
    local side
    for side in server client; do
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
            -days 30 -subj "/CN=$side" -keyout "$WORK/$side.key" -out "$WORK/$side.crt" 2>/dev/null
    done
}

fingerprint() { openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2; }

# start_tunnel <off|on> <txqueuelen>
start_tunnel() {
    local mode=$1 qlen=$2 extra=() common i flags ns side rcvbuf
    [ "$mode" = on ] && extra=(--tun-backpressure)
    common=(--dev tun0 --dev-type tun --proto udp --port 1194 --disable-dco
            --data-ciphers "$CIPHER" --rcvbuf "$UDP_RCVBUF" --txqueuelen "$qlen"
            --verb 3 --daemon "${extra[@]}")

    ip netns exec "$NS2" "$OPENVPN" "${common[@]}" --tls-server --dh none \
        --local 10.0.0.2 --remote 10.0.0.1 --ifconfig "$VPN2" "$VPN1" \
        --cert "$WORK/server.crt" --key "$WORK/server.key" \
        --peer-fingerprint "$(fingerprint "$WORK/client.crt")" \
        --writepid "$WORK/server.pid" --log "$OUT/openvpn-server-$mode-q$qlen.log"
    ip netns exec "$NS1" "$OPENVPN" "${common[@]}" --tls-client \
        --local 10.0.0.1 --remote 10.0.0.2 --ifconfig "$VPN1" "$VPN2" \
        --cert "$WORK/client.crt" --key "$WORK/client.key" \
        --peer-fingerprint "$(fingerprint "$WORK/server.crt")" \
        --writepid "$WORK/client.pid" --log "$OUT/openvpn-client-$mode-q$qlen.log"

    for i in $(seq 30); do
        grep -q 'Initialization Sequence Completed' "$OUT/openvpn-client-$mode-q$qlen.log" && break
        [ "$i" -eq 30 ] && die "tunnel did not come up, see $OUT/openvpn-*-$mode-q$qlen.log"
        sleep 1
    done

    for side in server client; do
        rcvbuf=$(sed -n 's/.*Socket Buffers: R=\[[0-9]*->\([0-9]*\)\].*/\1/p' "$OUT/openvpn-$side-$mode-q$qlen.log" | tail -1)
        (( rcvbuf >= UDP_RCVBUF )) || die "$side UDP receive buffer is $rcvbuf, wanted $UDP_RCVBUF"
    done

    for ns in "$NS1" "$NS2"; do
        flags=$(ip netns exec "$ns" cat /sys/class/net/tun0/tun_flags)
        if [ "$mode" = on ] && (( (flags & 0x80) == 0 )); then
            die "IFF_BACKPRESSURE not set in $ns (tun_flags $flags), was OpenVPN built with it?"
        elif [ "$mode" = off ] && (( (flags & 0x80) != 0 )); then
            die "IFF_BACKPRESSURE unexpectedly set in $ns (tun_flags $flags)"
        fi
        [ "$(ip netns exec "$ns" cat /sys/class/net/tun0/tx_queue_len)" = "$qlen" ] ||
            die "tx_queue_len in $ns is not $qlen"
    done
}

# TX drops of the client TUN device, where the iperf3 data enters the tunnel
tun_tx_dropped() { ip netns exec "$NS1" cat /sys/class/net/tun0/statistics/tx_dropped; }

# run_one <mode> <txqueuelen> <rep>
run_one() {
    local mode=$1 qlen=$2 rep=$3 log srv mbps d0 drops
    log="$OUT/iperf3-$mode-q$qlen-r$rep.txt"

    ip netns exec "$NS2" iperf3 -s -1 -B "$VPN2" >/dev/null 2>&1 &
    srv=$!
    sleep 1
    d0=$(tun_tx_dropped)
    ip netns exec "$NS1" iperf3 -c "$VPN2" -P "$STREAMS" -t "$DURATION" -O "$OMIT" -f m >"$log" 2>&1 || true
    drops=$(( $(tun_tx_dropped) - d0 ))
    kill "$srv" 2>/dev/null || true
    wait "$srv" 2>/dev/null || true

    # The last receiver line is the sum over all streams.
    mbps=$(awk '/receiver/ { v = $(NF - 2) } END { print v + 0 }' "$log")
    echo "$mode $qlen $rep $mbps $drops" >>"$OUT/results.txt"
    printf '  txqueuelen %-5s backpressure %-3s %6s Mbit/s %8s tun drops\n' "$qlen" "$mode" "$mbps" "$drops"
    sleep 2
}

summary() {
    awk -v qlens="$TXQUEUELEN" '
        { sum[$1, $2] += $4; drops[$1, $2] += $5; n[$1, $2]++ }
        END {
            printf "%10s %12s %12s %8s %10s %10s\n", "txqueuelen", "off Mbit/s", "on Mbit/s", "change",
                   "off drops", "on drops"
            split(qlens, qs, " ")
            for (i = 1; i in qs; i++) {
                q = qs[i]
                if (!n["off", q] || !n["on", q]) continue
                off = sum["off", q] / n["off", q]
                on = sum["on", q] / n["on", q]
                change = off ? sprintf("%+.1f%%", 100 * (on - off) / off) : "-"
                printf "%10d %12.0f %12.0f %8s %10.0f %10.0f\n", q, off, on, change,
                       drops["off", q] / n["off", q], drops["on", q] / n["on", q]
            }
        }' "$OUT/results.txt"
}

{
    echo "date: $(date -Iseconds)"
    echo "kernel: $(uname -r)"
    echo "openvpn: $("$OPENVPN" --version | head -1)"
    echo "streams: $STREAMS, txqueuelen: $TXQUEUELEN, duration: $DURATION s, reps: $REPS, cipher: $CIPHER, udp rcvbuf: $UDP_RCVBUF"
} >"$OUT/meta.txt"

setup_netns
gen_certs

for rep in $(seq "$REPS"); do
    echo "rep $rep/$REPS"
    # Alternate the order so slow drift affects both modes equally.
    if (( rep % 2 )); then modes="off on"; else modes="on off"; fi
    for qlen in $TXQUEUELEN; do
        for mode in $modes; do
            start_tunnel "$mode" "$qlen"
            run_one "$mode" "$qlen" "$rep"
            stop_tunnel
        done
    done
done

echo
summary | tee "$OUT/summary.txt"
echo "(mean over $REPS repetitions, results in $OUT)"
