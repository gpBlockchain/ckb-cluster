# CKB 本地多节点集群

单文件 Bash 脚本。依赖：`ckb`、`curl`、`jq`、`awk`、`lsof`、`realpath`，无 Python 依赖。

```bash
./ckb-cluster.sh up               # 默认在本项目 tmp/ 中启动 2 miner + 2 sync
./ckb-cluster.sh status           # PID、RPC/P2P、peer ID、连接数、高度/hash、出块间隔
./ckb-cluster.sh pause-mining     # 只停矿工，节点继续运行
./ckb-cluster.sh resume-mining
./ckb-cluster.sh add-node --role sync
./ckb-cluster.sh snapshot
./ckb-cluster.sh export
./ckb-cluster.sh down             # 停止进程，保留数据
./ckb-cluster.sh clean --force    # 停止并删除 tmp/，谨慎使用
```

## 停节点和清环境

```bash
./stop-ckb.sh                       # 停全部节点和矿工，保留数据
./stop-ckb.sh --node sync-0          # 只停 sync-0，其他节点不受影响
./stop-ckb.sh --node miner-0         # 同时停止 miner-0 的节点和挖矿进程
./ckb-cluster.sh up                 # 从保留的数据恢复集群
./clean-ckb.sh --force              # 停全部节点后删除项目 tmp/ 环境
```

两个入口均支持 `--root DIR`。清理会删除指定集群的数据库、配置、网络私钥、日志和快照，**保留下载的 `bin/ckb/`、脚本及其他项目文件**。没有 `--force` 时不清理；只接受带集群标记的专用目录。停止或清理后可重复调用。macOS 同时移除本集群对应的 launchd 任务；若进程停止失败，则保留数据并报错。

- 默认仅 `miner-0` 挖矿，Dummy/Constant 目标约 8 秒一块。
- 启动前检查所有待启动节点的端口以及 RPC/P2P 端口段重叠；实际监听失败仍以节点日志为准。
- RPC/P2P 仅监听 `127.0.0.1`。默认 RPC 为 18114–18117，P2P 为 18215–18218。
- 首次启动检查四个新块、peer 连接、创世块、共同高度 hash 与同步差，并保存基线快照。
- `tmp/cluster.env` 是纯 `KEY=value`，不执行 Shell 代码。修改模式/间隔前先 `down`；拓扑、端口及创世设置更改应使用新的 `--root`。
- 支持 `--mode solo|staggered|race|ondemand`。staggered 为启发式错峰；race 不保证间隔。
- 按需出块：新目录 `up --root tmp-demand --mode ondemand`，再 `mine --root tmp-demand --blocks 5 --timeout 60`。按高度观测停止，可能略超目标。
- 所有节点使用同一份固化 spec 和创世时间；peer ID 独立。启动时固定 CKB 版本。
- 日志在 `tmp/nodes/<id>/logs/`；快照和不含网络私钥/链数据库的导出包在 `tmp/evidence/`。
- 命令通过目录锁串行执行；异常退出后的锁需先核查 `.lock/owner` 中进程，再手动移除。启动失败保留数据和已启动节点，可用 `down` 收尾。

本机验证版本：CKB 0.204.0。脚本采用本机实际 CLI 参数；RPC 接口参考 [CKB RPC 文档](https://github.com/nervosnetwork/ckb/blob/develop/rpc/README.md)。

## 下载 CKB（默认最新版）

```bash
./download-ckb.sh                         # 查询 GitHub 最新正式版，自动选择系统/架构
./download-ckb.sh v0.209.0                 # 指定版本，省略 v 也支持
./download-ckb.sh --version 0.209.0 --print-url
CKB_BIN=$(./download-ckb.sh)
"$CKB_BIN" --version
./ckb-cluster.sh up --root tmp-new --ckb "$CKB_BIN"
```

下载位置为 `bin/ckb/<版本>/<平台>/ckb`，校验 GitHub asset SHA256 后保存校验记录；重复下载会复核已存二进制，不覆盖。支持 macOS/Linux 的 x86_64/aarch64，以及存在对应资源时的 `--portable`。无 Python 依赖。不自动修改 PATH，也不升级正在运行的集群。老版本资源若没有 GitHub SHA256 digest，需传入可信来源的 `--sha256`。

macOS 节点由 launchd 托管（不创建开机启动项），`down` 会移除对应任务；Linux 使用 nohup。
