# CKB Local Multi-Node Cluster

A single-file Bash script for running a local CKB cluster. Requires `ckb`, `curl`, `jq`, `awk`, `lsof`, and `realpath`. No Python dependency.

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

## Proof of Work and Mining Modes

`--pow dummy|eaglesong` selects the consensus algorithm independently of `--mode solo|staggered|race|ondemand`. The default is `dummy`, preserving existing behavior and compatibility with older cluster configurations.

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
- **Eaglesong:** the chain uses `Eaglesong` PoW and each mining process runs an `EaglesongSimple` worker with **one CPU thread**. The initial compact target and epoch settings come from the downloaded CKB's dev spec; the Dummy-only fixed-difficulty setting is removed. Real mining consumes CPU, difficulty can adjust, and block times are probabilistic rather than fixed. `--timeout` bounds the startup wait for four new blocks (default: 60 seconds); startup failure preserves the nodes and data, so use `down` to stop them.
- Both algorithms support all four scheduling modes. `solo` runs only `miner-0`; `race` runs all miners; `ondemand` starts mining only on `mine`. With Eaglesong, `staggered` only spaces out miner startup using `--interval-ms`; it does not impose a per-block delay or strict turn-taking. On-demand mining may exceed the requested block count with either algorithm.
- The selected algorithm is saved as `POW_ALGO` in `cluster.env` and must agree with the shared chain spec. Changing algorithms requires a **new `--root`**; editing `POW_ALGO` does not convert an existing chain. Existing cluster commands reuse the saved algorithm without repeating `--pow`.

Configuration reference: [CKB's dev-chain miner guide](https://github.com/nervosnetwork/ckb/blob/develop/docs/dev-miner.md).

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
- RPC/P2P listens only on `127.0.0.1`. Default RPC ports are 18114–18117; P2P ports are 18215–18218.
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
```

These tests use local fixtures and do not start nodes or download binaries.
