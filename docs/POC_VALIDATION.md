# 外部 Bug Bounty PoC 验证指南

在我方节点正常挖矿、组网，且提交者不控制集群的条件下，验证对方声称的问题是否成立。脚本参数见 [README](../README.md)。

**先读 PoC 并给出影响预判，确认后再测。** 不要运行对方的安装/启动脚本，不要动项目现有 `tmp/`。验证结束后**保持集群继续运行**，不要 `down` / `clean`，方便继续核对问题。主要结果不是 PoC 打印 `success`，而是：攻击前提成立、因果链成立、影响有证据。

## 1. 三步

1. **预判（只读）**：对方打什么入口、需要什么权限、对我方集群可能造成什么、原 PoC 要改哪些地方。交给用户确认。
2. **适配**：删掉对方自建节点/Docker/链的步骤，只把攻击载荷指向我方已启动集群。
3. **测试并评级**：正常挖矿组网下观察；给出技术结论、实际影响、赏金建议。集群留下，等用户确认后再说是否停止。

确认前不发包、不起验证集群、不改现有集群。攻击阶段不要用我方停矿、改配置、`add-node`、开放管理 RPC 来“帮它复现”。验证完不要 `down` 或 `clean`，除非用户明确要求。

## 2. 默认集群与主动连接

完整验证默认：

```bash
bash ckb-cluster.sh up --root "$ROOT" --ckb "$CKB_BIN" \
  --miners 4 --syncs 10 --boots 4 \
  --pow Eaglesong --mode race --timeout 300 \
  --rpc-bind 127.0.0.1 --p2p-bind 0.0.0.0 \
  --rpc-base 28114 --p2p-base 28215
```

独立 `--root`（推荐 `.verification/bounty/<CASE>/<RUN>/cluster`），避开默认 18114/18215。RPC 仅本机运维；P2P 可对外。`race` 无固定块间隔。18 节点同机，全节点一起卡更可能是宿主机争用，不能直接写成协议层全网影响。Dummy / `solo` / 缩容只做初筛。

攻击节点**不要主动 `add_node` 多个矿工**（约定，不是防火墙硬隔离）。`add_node` 打在攻击者自有节点上：

| 角色 | 主动 add_node | 默认目标 | P2P |
| --- | --- | --- | --- |
| miner | 只选 1 个 | miner-0 | 28215 |
| sync | 最多 4 个 | sync-0 … sync-3 | 28219–28222 |
| boot | 不限制 | 全部 4 个 | 28229–28232 |

发现协议连上其他节点算正常组网，记下来即可。原 PoC 若对每个矿工拨号，改成只拨 miner-0，写进预判等确认。不要用我方集群 RPC 把攻击者拉进来。

`cluster.state` 列为 `id role rpc p2p peer_id`，顺序 miners → syncs → boots。默认观察 `sync-0`，并对照未被拨号的 `miner-1` / `sync-9`。

## 3. 预判（确认前停止）

登记：声称影响、版本、入口、PoC 哈希与命令、对方是否自建环境、副作用、可测量判据、资源上限。

对方自建 CKB/Docker、硬编码 `localhost:8114`、复制 `secret_key`、停矿、关验证、改 spec，都不能原样执行。只提供共享 `spec.toml` / genesis hash，攻击者自备网络身份。

```text
报告 / 声称问题与影响 / 版本：
入口：P2P / 受控 RPC / 自有节点广播
add_node：miner-0 + sync-0..3 + 全部 boot；原 PoC 是否对多个矿工拨号：
可能影响：崩溃 / 停块 / 分叉 / 无效 tx 或块被接受 / 同步中断 / 资源放大
范围：单节点 / 本机争用 / 声称网络级；能否自动恢复；会否打满 CPU、写爆盘
必须改掉：对方启动节点的命令、硬编码地址、对多个矿工 add_node
建议：允许测试 / 先补材料 / 需要额外权限 / 信息不足

[ ] 独立 --root，不碰 tmp/
[ ] 只对 1 个矿工 add_node
[ ] RPC 对攻击侧：无 / 限定方法
[ ] 接受风险，可以开始测
```

## 4. 适配与取证目录

保留攻击载荷；删除对方启动节点、改配置、停矿、对每个矿工 `add_node`。交给攻击侧：可达地址、上述 add_node 目标、必要时 spec/genesis、窗口与停止条件。禁止 SSH、文件系统、管理 RPC、停矿、改我方配置。

```text
pocs/<CASE>/REPORT.md IMPACT.md ADAPTATION.md
.verification/bounty/<CASE>/<run>/
  cluster/                 # --root
  evidence/{operator,attacker,observations,verdict.md}
```

`.verification/` 已被 Git 忽略。

## 5. 测试与结论

顺序：无攻击基线 → 同入口正常对照 → PoC 窗口（我方只观察）→ 停攻击后看是否自行恢复 → 新 root 重复 → 修复版对照。实验中途停矿/重启只算诊断，不能替代无控制权复现。

| 主张 | 不要误判为 |
| --- | --- |
| 崩溃 | 单次 RPC 超时；launchd 可能已重启 |
| 可用性下降 | 仅攻击者被拒；Eaglesong 挖矿负载；宿主机争用 |
| 停块 | 偶发长间隔；我方停了矿工 |
| 分叉 | 不同高度的 tip hash 不同 |
| 无效 tx/块被接受 | 只看 RPC 返回或 PoC 自报成功 |
| 资源放大 | 大流量占满链路 |

同高度用运维侧只读 RPC：`get_tip_block_number`、`get_block_hash`（如 `["0x1"]`）、`get_tip_header`、`get_peers`。

```text
结论：REPRODUCED / NOT_REPRODUCED / INCONCLUSIVE / REQUIRES_ADDITIONAL_PRIVILEGES
一句话：无集群控制权、正常挖矿组网时，是否打出声称现象。
add_node 了几个矿工（应为 1）；get_peers 哪些节点有攻击者（拨号 vs 发现）：
现象 / 持续 / 是否恢复 / 开放节点与未拨号节点是否不同：
证据路径：预判、适配、status/snapshot/日志、攻击侧命令、导出包
建议：接受评估 / 补材料 / 仅有限影响 / 不支持该攻击模型
未验证部分：
```

- **REPRODUCED**：外部可达、未主动连多个矿工、判据成立、有因果证据。发现连上其他节点不妨碍。
- **NOT_REPRODUCED**：条件成立但本次未触发。
- **INCONCLUSIVE**：材料或环境不够。
- **REQUIRES_ADDITIONAL_PRIVILEGES**：需要我方控制权，或只能在对方自建环境里打出。若必须对每个矿工 `add_node` 才出现，单独写明。

复现 ≠ 应付赏金。金额按计划规则另判。修复对照用新 root、显式 `--ckb`；新链 genesis 不同，旧交易不能当修复证据。

## 6. 运维命令

在仓库根目录、我方终端执行。`CKB_BIN` 换成待测二进制。失败先看输出，再往下做。

```bash
PROJECT=$(pwd -P)
CASE_ID=BOUNTY-001
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
ROOT="$PROJECT/.verification/bounty/$CASE_ID/$RUN_ID/cluster"
EVIDENCE="$PROJECT/.verification/bounty/$CASE_ID/$RUN_ID/evidence"
mkdir -p "$ROOT" "$EVIDENCE"/{operator,attacker,observations}
CKB_BIN=/absolute/path/to/ckb

bash "$PROJECT/ckb-cluster.sh" up --root "$ROOT" --ckb "$CKB_BIN" \
  --miners 4 --syncs 10 --boots 4 \
  --pow Eaglesong --mode race --timeout 300 \
  --rpc-bind 127.0.0.1 --p2p-bind 0.0.0.0 \
  --rpc-base 28114 --p2p-base 28215
cp "$ROOT/cluster.env" "$ROOT/cluster.state" "$EVIDENCE/operator/"
cp -R "$ROOT/shared" "$EVIDENCE/operator/shared"
bash "$PROJECT/ckb-cluster.sh" status --root "$ROOT"
bash "$PROJECT/ckb-cluster.sh" snapshot --root "$ROOT"
```

`status` 退出码 0 仍要看 `OFFLINE`。启动超时不是漏洞。

```bash
# 运维侧健康检查（不是攻击）
RPC_PORT=$(awk '$1=="sync-0" {print $3}' "$ROOT/cluster.state")
curl --noproxy '*' --fail --silent --show-error --max-time 10 \
  -H 'Content-Type: application/json' \
  --data-binary '{"id":1,"jsonrpc":"2.0","method":"get_tip_header","params":[]}' \
  "http://127.0.0.1:$RPC_PORT"

# 攻击后：每个节点 get_peers，对照攻击侧 add_node 日志
printf '%s\n' '{"id":1,"jsonrpc":"2.0","method":"get_peers","params":[]}' \
  > "$EVIDENCE/operator/get-peers.json"
while read -r id role rpc p2p peer; do
  echo "=== $id ==="
  curl --noproxy '*' --fail --silent --show-error --max-time 5 \
    -H 'Content-Type: application/json' \
    --data-binary "@$EVIDENCE/operator/get-peers.json" "http://127.0.0.1:$rpc"
done < "$ROOT/cluster.state"

bash "$PROJECT/ckb-cluster.sh" logs --root "$ROOT" --node sync-0
ARCHIVE=$(bash "$PROJECT/ckb-cluster.sh" export --root "$ROOT" | tail -n 1)
cp "$ARCHIVE" "$EVIDENCE/observations/"
mkdir -p "$EVIDENCE/observations/full-logs"
for d in "$ROOT"/nodes/*; do
  [ -d "$d/logs" ] && cp -R "$d/logs" "$EVIDENCE/observations/full-logs/$(basename "$d")"
done
```

验证结束后集群保持运行，方便继续查状态和日志。不要执行 `down` 或 `clean`，除非用户明确要求。

- `snapshot` 不是数据库备份，无 restore。
- `export` 只有配置、共享链信息和日志末 **2000** 行；无库、无网络私钥。
- `logs` 默认末 **100** 行。需要完整日志时从 `nodes/*/logs/` 另存，不要为了拷日志而停集群。
- 若用户之后要求清理：`clean` 必须带 `--root`，否则会删项目 `tmp/`。`down` 后再 `up` 同一 root 是续跑，不是回滚。
