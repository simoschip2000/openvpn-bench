# OpenVPN IFF_BACKPRESSURE benchmark

Measures TCP throughput through OpenVPN with and without `--tun-backpressure`,
for different TUN queue lengths (`--txqueuelen`).

```
ns1: iperf3 -c + OpenVPN client  ──veth──  ns2: OpenVPN server + iperf3 -s
          10.0.0.1 / tun 10.8.0.1           10.0.0.2 / tun 10.8.0.2
```

- Unshaped veth, UDP transport, `--disable-dco`, AES-256-GCM, TLS with
  self-signed certificates and `--peer-fingerprint`.
- `--tun-backpressure`, `--txqueuelen` and `--rcvbuf` are set on both ends,
  and the TUN flags and queue length are checked before each run.
- Both sockets get an 8 MiB receive buffer, so the server's UDP socket does
  not drop packets first. `net.core.rmem_max` caps it, so it has to be
  raised before the run (see below).

## Requirements

- Linux 7.3 or later, root
- iproute2, iperf3 (3.16 or later for one thread per stream), openssl
- An OpenVPN build with `--tun-backpressure` (default:
  `../openvpn/src/openvpn/openvpn`), see below

## Setup

The included OpenVPN patch is v1 of the upstream submission. It adds
`--tun-backpressure`, so both modes can be compared with the same binary;
v2 always sets the flag. Build OpenVPN next to this repository,
on the commit the patch was tested on. `CPPFLAGS` is only needed if the
kernel headers lack `IFF_BACKPRESSURE`, but does no harm otherwise.

```sh
sudo apt install build-essential autoconf automake libtool pkg-config \
    libssl-dev libcap-ng-dev python3-docutils iperf3 iproute2 openssl
git clone git@github.com:simoschip2000/openvpn-bench.git
git clone https://github.com/OpenVPN/openvpn.git
cd openvpn
git checkout 54a66f355
git apply ../openvpn-bench/0001-tun-add-tun-backpressure-option-for-Linux.patch
autoreconf -fi
./configure --disable-lzo --disable-lz4 --disable-plugin-auth-pam --disable-dco \
    CPPFLAGS=-DIFF_BACKPRESSURE=0x0080
make -j"$(nproc)"
```

## Usage

Raise the socket receive buffer limit first (not per network namespace, and
reset on reboot), then run the benchmark:

```sh
sudo sysctl -w net.core.rmem_max=8388608
sudo ./bench.sh
```

Settings via environment variables (`sudo env VAR=... ./bench.sh`):

| Variable | Default | |
|---|---|---|
| `OPENVPN` | `../openvpn/src/openvpn/openvpn` | OpenVPN binary |
| `STREAMS` | `8` | iperf3 `-P` |
| `TXQUEUELEN` | `500 5000` | TUN queue lengths to test |
| `DURATION` | `30` | seconds per run |
| `OMIT` | `2` | seconds omitted at the start of each run |
| `REPS` | `40` | repetitions |
| `CIPHER` | `AES-256-GCM` | data channel cipher |
| `UDP_RCVBUF` | `8388608` | OpenVPN `--rcvbuf` in bytes, `0` for the OS default |
| `OUT` | `results/<timestamp>` | output directory |

The defaults take about 1 hour 40 minutes.

## Output

At the end, the mean throughput, TX drops of the client TUN device and TCP
retransmits (iperf3 sender) per queue length are printed and saved to
`summary.txt`:

```
txqueuelen   off Mbit/s    on Mbit/s   change  off drops   on drops   off retr    on retr
       500         3971         3952    -0.5%      40226          0      36624        531
      5000         4005         3923    -2.1%       1358          0        658          0
```

`OUT` also contains `results.txt` (one line per run: mode, queue length,
repetition, Mbit/s, TUN drops, retransmits), the iperf3 and OpenVPN output
of each run, and `meta.txt` with kernel, OpenVPN version and settings.

## Results

AMD Ryzen 9 9950X, Linux 7.3.0-rc3, OpenVPN 54a66f355 with the patch,
default settings (8 streams, 30 s per run, 40 repetitions, AES-256-GCM):

| txqueuelen | off Mbit/s | on Mbit/s | change | off drops | on drops | off retr | on retr |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 500 | 3971 | 3952 | -0.5% | 40226 | 0 | 36624 | 531 |
| 5000 | 4005 | 3923 | -2.1% | 1358 | 0 | 658 | 0 |

Throughput, drops and retransmits are means per run. Individual runs range
from about 3550 to 4550 Mbit/s in every configuration (standard deviation
340 to 380 Mbit/s).
