# CKB Local Multi-Node Cluster

Bash scripts for running a local CKB cluster. Requires `ckb`, `curl`, `jq`, `awk`, `lsof`, and `realpath`. No Python dependency.

## Quick Start

Run these commands from the repository directory. The cluster automatically finds CKB downloaded into this project's `bin/ckb/` directory; no `CKB_BIN` configuration, PATH changes, or `--ckb` argument are needed.

```bash
# Download once (skip this step if already downloaded).
bash download-ckb.sh && bash ckb-cluster.sh up

# Subsequent starts, including after cleaning the cluster:
bash ckb-cluster.sh up
```

For a new cluster, `--ckb` overrides `CKB_BIN`; otherwise the script uses a local download matching the current OS/architecture (including portable builds), and prompts you to run `./download-ckb.sh` or specify `--ckb /absolute/path/to/ckb` if none is found. It does not silently fall back to a CKB installation in PATH. If multiple matching downloads exist, it lists them and requires `--ckb` rather than guessing a version. Downloads are not triggered automatically.

To select a specific release, pass its version to the downloader, for example `./download-ckb.sh v0.209.0`. If CKB is already installed, skip the download and run `./ckb-cluster.sh up --ckb /absolute/path/to/ckb`.

The initialized cluster saves the binary path in `tmp/cluster.env`. Subsequent commands, including `./ckb-cluster.sh up` after stopping the cluster, reuse that path; no repeated download or `--ckb` argument is needed as long as the binary remains available. After cleaning the cluster, run `bash ckb-cluster.sh up` to reuse the local download. A saved binary path remains pinned; a missing explicit or saved binary is an error, not a reason to switch versions.

## External Node Access

New clusters default to **`--rpc-bind 0.0.0.0 --p2p-bind 0.0.0.0`**, allowing access through any reachable IPv4 interface. The two options are independent and accept `0.0.0.0` or `127.0.0.1`.

```bash
# Default: RPC and P2P listen on all IPv4 interfaces.
./ckb-cluster.sh up

# Keep RPC local while allowing external P2P connections (new cluster).
./ckb-cluster.sh up --root tmp-external --rpc-bind 127.0.0.1 --p2p-bind 0.0.0.0 \
  --rpc-base 19114 --p2p-base 19215

# Change an existing cluster only after stopping its nodes and miners.
./ckb-cluster.sh down
./ckb-cluster.sh up --rpc-bind 0.0.0.0 --p2p-bind 0.0.0.0

# To return to local-only access, stop it and use both --*-bind 127.0.0.1.
```

- External clients must use the machine's reachable LAN/public IP, **not `0.0.0.0`**: RPC is `http://HOST_IP:18114`, and miner-0's P2P address is `/ip4/HOST_IP/tcp/18215/p2p/PEER_ID`. Get each node's ports and peer ID with `status`.
- External CKB nodes need the same chain spec and genesis as this cluster: use the generated `tmp/shared/spec.toml` (or the corresponding custom root). Do not independently generate a different dev-chain genesis. Network private keys must remain unique; do not copy the cluster's network keys.
- Open/forward the required TCP ports in the host firewall/router as appropriate. Binding all interfaces alone does not configure NAT, firewalls, or public-address advertisement.
- **The generated dev RPC configuration exposes administrative/debug APIs without adding authentication. Limit RPC access to trusted hosts using firewall rules or an authenticated proxy; avoid exposing it directly to the public internet.** Set `--rpc-bind 127.0.0.1` when remote RPC is unnecessary.
- Binding settings are persisted as `RPC_BIND` and `P2P_BIND`. If these fields are absent, both default to `0.0.0.0`. An attempted rebind while any cluster node/miner is running is rejected before configuration files change.
- Internal RPC requests, miner RPC URLs, and local peer connections continue using `127.0.0.1`; wildcard addresses are only used for listening.

## Proof of Work and Mining Modes

`--pow dummy|eaglesong` (also accepting `Dummy` and `Eaglesong`) selects the consensus algorithm independently of `--mode solo|staggered|race|ondemand`. The default is `dummy`, preserving existing behavior and compatibility with older cluster configurations.

```bash
# Real CPU PoW, using a new cluster directory and separate ports.
./ckb-cluster.sh up --root tmp-eaglesong --pow eaglesong --mode solo \
  --rpc-base 19114 --p2p-base 19215 --timeout 120

# An independent on-demand Eaglesong cluster (use unused ports).
./ckb-cluster.sh up --root tmp-eaglesong-demand --pow eaglesong --mode ondemand \
  --rpc-base 20114 --p2p-base 20215
./ckb-cluster.sh mine --root tmp-eaglesong-demand --blocks 5 --timeout 120
```

- **Dummy:** the chain uses `Dummy` PoW and miners use `Dummy` / `Constant` workers. `--interval-ms` controls the simulated delay (default: 8000 ms).
- **Eaglesong:** the chain uses `Eaglesong` PoW and each mining process runs an `EaglesongSimple` worker with **one CPU thread**. The generated `specs/dev.toml` sets `[params]` to `epoch_duration_target = 14400` and `genesis_epoch_length = 1000`, removing all other dev parameter overrides and nested tables such as `[params.hardfork]` so CKB supplies defaults for the remaining parameters. The genesis `compact_target` is set to `0x1e015555`. All nodes copy the same shared spec. This applies to newly initialized clusters; use a new `--root` rather than changing an existing chain's spec. Real mining consumes CPU, difficulty can adjust, and block times are probabilistic rather than fixed. `--timeout` bounds the startup wait for four new blocks (default: 60 seconds); startup failure preserves the nodes and data, so use `down` to stop them.
- Both algorithms support all four scheduling modes. `solo` runs only `miner-0`; `race` runs all miners; `ondemand` starts mining only on `mine`. With Eaglesong, `staggered` only spaces out miner startup using `--interval-ms`; it does not impose a per-block delay or strict turn-taking. On-demand mining may exceed the requested block count with either algorithm.
- The selected algorithm is saved as `POW_ALGO` in `cluster.env` and must agree with the shared chain spec. Changing algorithms requires a **new `--root`**; editing `POW_ALGO` does not convert an existing chain. Existing cluster commands reuse the saved algorithm without repeating `--pow`.

Configuration reference: [CKB's dev-chain miner guide](https://github.com/nervosnetwork/ckb/blob/develop/docs/dev-miner.md).

## Optional Miner CPU Limit

`--miner-cpu N` limits **each miner process** to approximately `N` percent of one logical CPU core. The default is **0 (unlimited)**; supported limits are 1–100. Node processes are not throttled. Two miners limited to 20 each can together consume roughly 40 percent of one core, plus node and supervisor overhead. This controls average CPU use, not a precise hash rate, and lower limits can increase block times and mining timeouts.

Install the optional dependency:

```bash
./install-cpulimit.sh             # macOS: project-local build (requires Xcode CLT)
sudo apt install cpulimit         # Debian / Ubuntu
```

```bash
# New capped CPU-mining cluster; choose unused ports.
./ckb-cluster.sh up --root tmp-capped --pow eaglesong --miner-cpu 20 \
  --rpc-base 25114 --p2p-base 25215 --timeout 180

# Change a saved limit without stopping the node processes.
./ckb-cluster.sh pause-mining --root tmp-capped
./ckb-cluster.sh resume-mining --root tmp-capped --miner-cpu 30

# Disable the limit explicitly.
./ckb-cluster.sh pause-mining --root tmp-capped
./ckb-cluster.sh resume-mining --root tmp-capped --miner-cpu 0
```

- On macOS, the installer builds checksum-pinned upstream 0.2 with a Mach-timebase correction, retains the source archive/license/patch, and installs only into `bin/cpulimit/`. This addresses the incorrect CPU accounting observed with the stock Homebrew 0.2 build on Apple Silicon. It leaves Homebrew and PATH unchanged; repeated installation verifies the existing binary. The cluster prefers this local build, then searches PATH. A detected stock Homebrew 0.2 on Apple Silicon is treated as unavailable, with a warning and installation hint.
- `cpulimit` is **optional**. If a nonzero limit is requested but the tool is missing, the script prints installation instructions and an explicit warning, then continues with **unlimited miners**. It never installs packages automatically. The requested value is retained, so it can apply after installation and a miner restart.
- The value is saved as `MINER_CPU` and applies to both continuous and on-demand mining (`mine --miner-cpu N`). Pause all miners before changing an active limit. `status` shows the requested setting and each active miner's effective `cpu_limit` (`0` means unlimited).
- Capped miners run under the internal `miner-runner.sh` supervisor, which owns the CKB worker and the PID-targeted limiter. `miner_pid` identifies the supervisor; `worker_pid` identifies the actual CKB mining process. Uncapped miners still launch directly.
- Pause, shutdown, and on-demand completion stop the limiter and resume/terminate a suspended worker. If the limiter exits unexpectedly after startup, the supervisor stops its miner rather than silently removing the cap. A supervised miner restart starts a fresh limiter for its new PID. Keep `miner-runner.sh` alongside `ckb-cluster.sh`.

CPU usage varies over short sampling windows. The limiter uses process suspension/resumption; see the [cpulimit implementation](https://github.com/opsengine/cpulimit).

## Managing the Cluster

```bash
./ckb-cluster.sh status           # PID, RPC/P2P, peer ID, connection count, height/hash, block interval
./ckb-cluster.sh pause-mining     # Stop mining processes only; nodes keep running
./ckb-cluster.sh resume-mining
./ckb-cluster.sh add-node --role sync
./ckb-cluster.sh snapshot
./ckb-cluster.sh export
./ckb-cluster.sh down             # Stop processes and retain data
./ckb-cluster.sh clean --force    # Stop the cluster and delete tmp/; use with care
```

## Stopping Nodes and Cleaning Up

```bash
./stop-ckb.sh                       # Stop all nodes and mining processes; retain data
./stop-ckb.sh --node sync-0          # Stop only sync-0; leave other nodes running
./stop-ckb.sh --node miner-0         # Stop both the miner-0 node and its mining process
./ckb-cluster.sh up                 # Resume the cluster using retained data
./clean-ckb.sh --force              # Stop all nodes, then delete the project's tmp/ environment
```

Both helper scripts support `--root DIR`. Cleanup deletes the selected cluster's databases, configuration, network private keys, logs, and snapshots, while **preserving downloaded binaries in `bin/ckb/`, scripts, and other project files**. Cleanup requires `--force` and only accepts a dedicated directory with a cluster marker. Stop and cleanup commands can be called repeatedly. On macOS, the cluster's launchd jobs are also removed. If a process fails to stop, cleanup retains the data and reports an error.

- By default (`--pow dummy --mode solo`), only `miner-0` mines, using Dummy/Constant with a target block interval of approximately 8 seconds.
- Before startup, the script checks ports for all nodes being started and checks for overlapping RPC/P2P port ranges. Consult node logs for actual bind failures.
- New clusters bind RPC/P2P to `0.0.0.0` by default (all IPv4 interfaces). Default RPC ports are 18114–18117; P2P ports are 18215–18218. Restrict RPC access to trusted hosts with a firewall.
- On startup, the script checks peer connections, genesis blocks, block hashes at a common height, and synchronization lag, then saves a baseline snapshot. Except in `ondemand` mode, it also waits for four new blocks.
- `tmp/cluster.env` contains plain `KEY=value` entries; it is not executed as shell code. Run `down` before changing the mining mode or interval. Use a new `--root` when changing topology, ports, or genesis settings.
- Supported modes: `--mode solo|staggered|race|ondemand`. Staggered mode uses heuristic scheduling; race mode does not guarantee a block interval.
- On-demand mining: use a new directory with `up --root tmp-demand --mode ondemand`, then run `mine --root tmp-demand --blocks 5 --timeout 60`. Mining stops based on observed block height and may slightly exceed the target.
- All nodes share the same fixed chain spec and genesis timestamp, with independent peer IDs. The CKB version is pinned at startup.
- Logs are stored in `tmp/nodes/<id>/logs/`. Snapshots and export bundles are stored in `tmp/evidence/`; export bundles exclude network private keys and chain databases.
- Commands are serialized using a directory lock. After an abnormal exit, check the process recorded in `.lock/owner` before manually removing the lock. Failed startup preserves data and any nodes already started; use `down` to stop them.

Locally verified with CKB 0.204.0 (original Dummy workflow) and 0.209.0 (Dummy/Eaglesong mining). The script uses CLI arguments verified on the local installation. For RPC interfaces, see the [CKB RPC documentation](https://github.com/nervosnetwork/ckb/blob/develop/rpc/README.md).

## Downloading CKB (Latest Release by Default)

```bash
./download-ckb.sh                         # Query the latest stable GitHub release; detect OS/architecture
./download-ckb.sh v0.209.0                 # Select a version; the v prefix is optional
./download-ckb.sh --version 0.209.0 --print-url
./download-ckb.sh && ./ckb-cluster.sh up --root tmp-new
```

Binaries are installed at `bin/ckb/<version>/<platform>/ckb`. The downloader verifies the GitHub release asset's SHA256 digest and saves a verification receipt. Repeated downloads revalidate the existing binary without overwriting it. Supported platforms are macOS/Linux on x86_64/aarch64, with `--portable` support when a matching release asset is available. No Python dependency is required. The script does not modify PATH or upgrade running clusters. For older release assets without a GitHub SHA256 digest, supply `--sha256` from a trusted source.

On macOS, nodes are managed by launchd without creating startup jobs; `down` removes the corresponding jobs. Linux uses nohup.

## Regression Tests

```bash
bash tests/default-ckb.sh
bash tests/pow.sh
bash tests/bind.sh
bash tests/miner-cpu.sh
```

These tests use local fixtures and do not start nodes or download binaries.
