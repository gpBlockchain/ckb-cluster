# 外部 Bug Bounty PoC 验证指南

## 1. 验证目标

本项目用于评估外部提交的 CKB Bug Bounty 报告：

> 在我方节点正常挖矿、组网和同步，且提交者不控制我方集群的条件下，提交者能否通过攻击者实际可达的接口触发所声称的问题？问题具有多大的实际影响，是否值得接受并进入赏金评估？

**主要结果不是“PoC 程序跑通”，而是“攻击前提成立、因果链成立、影响有证据”。**

对方 PoC 通常会自己拉起一套独立节点。验证时不要跟着对方的启动脚本走，而是：

1. 先阅读 PoC，说明它会对**我方已部署集群**造成什么影响，等待确认。
2. 确认后，把对方“自己启动环境再打”的步骤，改成“只攻击我方已经用本仓库脚本启动的节点”。
3. 按对方声称的入口和输入测试，把可核对的证据和评级材料展示出来。

本文面向我方审阅者、验证人员和后续协助验证的 AI 助手。集群脚本参数以 [README](../README.md) 为准。本文是操作指南，不表示任何外部报告已经复现或确认有效。是否符合赏金范围和支付标准，按我方实际计划规则单独判定。

编写本文时没有启动、停止或清理项目现有 `tmp/` 集群。后续验证也必须使用独立 `--root`，不要占用或清理现有环境。

## 2. 强制流程：先预判，确认后再测

收到外部 PoC 后，**禁止直接运行提交者安装/启动脚本，禁止对现有集群执行 `up` / `down` / `clean`，禁止把对方 PoC 接到项目 `tmp/`。** 按下面三步执行；第一步没有得到明确确认前，不得进入第二步。

| 步骤 | 目的 | 产出 | 停止条件 |
| --- | --- | --- | --- |
| **第一步：阅读并预判影响** | 弄清对方到底打什么、需要什么权限、会碰到我方哪些节点 | [第 4 节影响预判](#4-第一步阅读-poc并给出集群影响预判) | 入口不清、依赖集群控制权、实验风险不可接受，或用户尚未确认 |
| **第二步：适配到我方已启动集群** | 去掉对方自己的节点/Docker/Devnet 启动，只保留攻击载荷，指向我方可达入口 | 适配说明、攻击侧最小信息、独立验证集群 | 适配后仍需要停矿、改配置、替换二进制或登录我方主机 |
| **第三步：测试、展示、评级** | 在正常挖矿组网条件下验证声称现象，并给出可核对结论 | 证据目录 + [结果面板](#63-展示给审阅者的结果面板) | 资源失控、影响溢出实验网络、或证据不足时标为 `INCONCLUSIVE` |

给后续验证助手的硬性要求：

- 先交影响预判，用用户能直接确认的语言写清：**打哪个入口、需要我方开放什么、可能造成什么、最坏会搞挂什么、原 PoC 要改哪些地方。**
- 用户确认前只做静态阅读、哈希登记和隔离环境检查，不发送攻击流量，不启动新的受测集群，也不改现有集群。
- 测试时我方只负责部署、正常运行、观察和收尾。攻击阶段的触发动作必须来自攻击侧，不能由我方代为执行管理操作来“帮它复现”。
- 向用户展示的是证据和评级材料，不是 PoC 自己打印的 `success`。

## 3. 信任边界与角色

| 角色 | 拥有的能力 | 不应混入攻击能力的操作 |
| --- | --- | --- |
| 我方运维/观察者 | 建立独立验证集群、选择待测版本、管理配置、保持正常挖矿组网、采集指标与日志、实验结束后清理 | 把停矿、重启、改配置、替换二进制、开放管理 RPC 后才出现的现象，当成外部攻击成功 |
| 外部攻击者 | 访问预先声明可达的 P2P 或业务 RPC；使用自己的节点、账号、资金与构造的消息/交易 | 登录我方主机、读写我方目录、获得管理 RPC、停矿、重启我方节点、修改 spec 或复制网络私钥 |
| 报告提交者 | 提交报告、源码、样本、依赖、运行说明和资源预算 | 要求先关闭关键验证、安装我方节点补丁或授予集群控制权后，再声称是无权限远程问题 |

默认外部攻击者没有我方 SSH、容器控制、文件系统、网络私钥或管理 API 权限。报告若确实依赖这些权限，应如实登记为前提，单独判断范围与价值，而不是在实验中悄悄授予。

```text
我方控制终端 ── 本机 RPC / 运维通道 ── 我方 CKB 验证集群
                                           ↑
                              仅开放已声明的攻击入口
                                           ↑
                                 独立攻击机 / 隔离 VM
                                 外部 PoC + 自有节点
```

- 优先让攻击侧运行在独立主机或隔离 VM，使用不同 IP；不挂载本仓库，不继承我方密钥、宿主机 socket、凭据或环境变量。
- 同机容器只能作为初筛。本项目是单主机多节点启动器，各节点共享宿主机 CPU/内存/磁盘。默认验证集群有 18 个节点、4 个 Eaglesong 矿工同时出块，全节点同时失去响应更可能来自宿主机争用，不直接证明协议层全网影响。高影响结论宜在独立主机节点上复核。
- 脚本默认 `--rpc-bind 0.0.0.0 --p2p-bind 0.0.0.0`。验证实验应显式选择绑定：RPC 默认只给本机运维使用，绑定 `127.0.0.1`；若报告针对 P2P，P2P 可绑定 `0.0.0.0`，再由防火墙只向攻击机开放选定端口。P2P 可达不代表 RPC 也应该开放。
- 如报告明确针对公开 RPC，应建立与实际部署一致的受控入口，记录方法范围、鉴权、限流与请求大小限制。不要为了复现，把含管理/调试能力的整套 Devnet RPC 直接暴露给攻击者。
- 本项目生成 Devnet chain spec。即使使用 Eaglesong，也不等同于主网参数、规模或真实算力。结论必须写明与目标部署的差异。

## 4. 第一步：阅读 PoC，并给出集群影响预判

这一步只读材料和做静态判断。**产出交给用户确认后才能继续。**

### 4.1 接收时必须登记

| 项目 | 必须记录 |
| --- | --- |
| 报告 | 编号、声称影响、受影响版本、触发入口、预期现象 |
| 攻击前提 | 网络可达性、权限、节点角色、链状态、资金、算力或资源要求 |
| PoC | 原始源码/样本、SHA256、依赖版本、构建方式、完整命令 |
| 对方原环境 | 是否自己启动 CKB / Docker / OffCKB / 单节点；硬编码了哪些地址和端口 |
| 副作用 | 文件读写、进程启动、外联地址、下载行为、持久化和清理动作 |
| 成功判据 | 可测量的异常与阈值，不只引用提交者程序打印的 success |
| 资源边界 | 并发、请求/字节总量、速率、最长时长、攻击机与受测机资源 |
| 正常对照 | 相同入口上的正常交互及预期行为 |

检查 PoC 是否依赖：宿主机命令执行、访问我方文件、调用管理 API、暂停出块、修改节点代码、关闭验证、复制我方 `secret_key` / 数据库，或要求我方先变成对方脚本里的拓扑。发现这类条件时，标记为显式前提。

外部代码只允许在隔离攻击环境中阅读和（确认后）运行。不要以我方运维身份在本仓库执行提交者安装脚本。

### 4.2 先识别：对方原来在打谁

把 PoC 从“自建环境”翻译成“对我方集群的动作”。常见模式：

| 对方 PoC 常见写法 | 实际含义 | 对我方集群意味着什么 |
| --- | --- | --- |
| 启动自己的 `ckb` / Docker / OffCKB / `ckb-dev` | 攻击者在控制被测节点 | **不能**原样执行。我方节点必须已由 `ckb-cluster.sh` 启动，攻击侧不得接管 |
| 连接 `127.0.0.1:8114` 或文档里的单节点 RPC | 默认打自己的本机 RPC | 改为我方声明开放的业务 RPC；若验证集群 RPC 仅本机运维使用，则该主张可能不构成外部可达攻击 |
| 连接 `/ip4/.../tcp/.../p2p/...` | P2P 协议攻击 | 目标改为 `cluster.state` 中指定节点的 P2P 端口和 peer ID |
| `send_transaction` / 构造交易后提交 | 需要交易入口或攻击者自有节点广播 | 可用攻击者自有节点加入同一条 Devnet 再广播；不要把我方管理 RPC 整包开放 |
| 自己挖矿、改 spec、关验证、插私有补丁 | 需要被测方配合 | 记为额外权限，不能当作普通外部攻击 |
| 读取 `data/network/secret_key` 或复制链库 | 需要文件系统权限 | 禁止。攻击者自有节点必须自生成网络身份，只复制共享 `spec.toml` / genesis hash |
| 要求先 `pause-mining` 或停节点 | 需要我方改变正常运行状态 | 默认定性为干预实验，不支持“正常挖矿组网时成立” |

### 4.3 影响预判模板（先交给用户确认）

阅读 PoC 后，按下面格式输出。用我方集群的语言写，不要复述对方 README 原文。

```text
报告编号：
声称问题：
声称影响：
受影响版本（对方给出）：

【会碰到我方集群的什么】
- 目标层：RPC / P2P / 同步 / 共识 / 交易池 / CKB-VM / 链上脚本 / 资源耗尽
- 目标节点角色：miner / sync / boot；默认观察只读 sync，避免把 4 个 race 矿工的 Eaglesong 负载误当成漏洞
- 攻击入口：P2P 端口 / 限定 RPC 方法 / 攻击者自有节点广播
- 我方需要开放什么：只 P2P / 受控 RPC / 共享 spec 与 genesis / 都不开放则无法测
- 攻击者还需要：自有节点、资金、特定高度/epoch、算力、并发连接数

【对我方集群可能造成的影响】
- 声称现象：崩溃 / 卡死 / 停块 / 分叉 / 无效交易或区块被接受 / 同步中断 / CPU 内存磁盘放大 / 仅拒绝攻击者请求
- 影响范围：单节点 / 本机全部节点（可能是宿主机争用）/ 声称网络级
- 是否可能自动恢复：是 / 否 / 未知
- 是否可能损坏该验证集群数据：是 / 否 / 未知
- 是否可能影响项目现有 tmp/ 或其他端口上的进程：应通过独立 --root 和独立端口避免

【原 PoC 必须改掉的部分】
- 对方自己启动节点/容器/链的命令：删除或隔离，不在我方机器执行
- 硬编码地址/端口：改为我方交付的目标
- 依赖我方停矿、改配置、关验证、替换二进制：列出；若无法去掉，则不能按无权限远程攻击评级

【实验风险（运行前必须说清）】
- 可能打满本机 CPU / 写爆磁盘 / 让验证集群不可恢复 / 外联未知地址
- 建议的最长攻击窗口、流量上限、紧急停止条件
- 建议使用的独立 ROOT、端口范围；默认拓扑为 4 miner + 10 sync + 4 boot、Eaglesong、`race`，偏离时写明原因

【建议结论（仅预判，不是测试结果）】
- 看起来像：外部可达攻击 / 需要额外权限 / 只能在对方自建环境复现 / 信息不足
- 建议动作：允许测试 / 先补材料 / 只做静态拒绝 / 仅做有限诊断实验

【需要你确认后才能继续】
[ ] 允许的攻击入口和目标节点
[ ] RPC 是否对攻击侧开放；开放哪些方法
[ ] 使用独立 --root，不触碰现有 tmp/
[ ] 使用默认 4 miner / 10 sync / 4 boot、Eaglesong、race（或确认后的替代拓扑）
[ ] 接受上述实验风险和停止条件
[ ] 可以开始适配并测试
```

没有得到上述确认前，停止。不要“先起集群再说”。

## 5. 第二步：把对方 PoC 改打到我方已启动的集群

用户确认后，才建立**独立验证集群**，并改写攻击侧，使其不再启动自己的被测节点。

### 5.1 我方部署原则

- 每个报告、每个版本、每次重复实验使用新的 `--root`。项目现有 `tmp/` 保持不动。
- **默认验证集群**（完整验证一律用这套，除非影响预判里另有理由并经确认）：

  ```bash
  bash ckb-cluster.sh up --miners 4 --syncs 10 --boots 4 \
    --pow Eaglesong --mode race
  ```

  实际执行时还必须带独立 `--root`、明确 `--ckb`、非默认端口，以及 RPC/P2P 绑定，完整命令见 [第 7 节](#7-我方控制终端独立验证集群)。
- 选择这套默认值的原因：4 个 miner 同时出块更接近“正常挖矿”，10 个只读节点提供可观察的同步/验证面，4 个 boot 提供独立发现入口。`race` 没有固定块间隔。Dummy、`solo`、`ondemand` 或更小拓扑只用于初筛或经确认的对照实验，不能单凭它们声称完整场景已验证。
- 18 个节点 + 4 个 Eaglesong 矿工（各 1 个挖矿线程）会明显占用单机 CPU/内存/磁盘。基线阶段先记录正常出块和负载；不要为了“好看”加上 `--miner-cpu`。机器扛不住时，在影响预判里写明缩容并经确认，而不是悄悄改拓扑。
- 不以 `ondemand`、`pause-mining`、停止我方节点或修改配置作为默认攻击前置条件。诊断实验可以另做，结论必须分开写。
- `--root` 必须是专用子目录，不能是仓库根、家目录或 `/`。推荐：`.verification/bounty/<CASE_ID>/<RUN_ID>/cluster`。
- 端口不要使用脚本默认的 18114/18215，以免和现有 `tmp/` 冲突。本例 18 个节点占用 RPC 28114–28131、P2P 28215–28232，先确认整段空闲。

案例目录：

```text
pocs/BOUNTY-001/                     # 适合版本控制的审阅材料，不含数据库
  REPORT.md                         # 原始主张、能力边界、步骤、判据
  IMPACT.md                         # 第一步影响预判与用户确认记录
  ADAPTATION.md                     # 原 PoC 如何改打我方集群
  submission.sha256
.verification/bounty/BOUNTY-001/
  <run-id>/
    cluster/                        # 我方 --root，仅运维可访问
    evidence/                       # 与 cluster 同级，避免被 clean 删除
      operator/                     # 我方操作记录
      attacker/                     # 从攻击机收回的命令、日志与流量
      observations/                 # 节点日志、指标、区块和连接证据
      verdict.md                    # 判断与未验证部分
```

`.verification/` 已被 Git 忽略。重要报告与证据需另行归档。

### 5.2 适配规则

攻击侧只得到“怎么打到已经在跑的节点”，得不到“怎么把我方集群变成对方实验室”。

| 保留 | 删除或改写 | 禁止 |
| --- | --- | --- |
| 构造畸形消息、交易、区块或 P2P 帧的代码 | 对方启动 CKB、初始化链、改 `ckb.toml`、启动 miner 的步骤 | 在我方 `ROOT` 里执行对方安装脚本 |
| 攻击者自有节点（自己的 peer ID、自己的密钥） | 硬编码 `localhost:8114`、对方 docker-compose 端口、对方 genesis | 复制我方 `data/network/secret_key` 或链数据库 |
| 对方提供的样本、种子、交易字节 | 要求我方先停矿、关验证、打补丁才能触发的步骤 | 把我方 RPC 从回环改成公网只为了让脚本少改一行 |
| 超时、重试、资源上限 | 以 PoC 打印 success 作为唯一判据 | 用我方 `add-node` / `mine` / `pause-mining` 代替攻击者动作 |

攻击者若需加入同一条 Devnet：只提供共享 `spec.toml` 和 genesis hash，让对方节点自己生成网络身份。不要复制整个 `nodes/` 目录。

适配完成后写入 `ADAPTATION.md`：原命令、替换后的命令、目标节点、入口、删除了哪些“自建环境”步骤。原提交保持只读；改写后的驱动放在攻击机或隔离目录，并单独计算 SHA256。

### 5.3 向攻击侧交付的最小信息

```text
CASE_ID:
目标主机可达地址（不是 0.0.0.0）：
目标节点角色 / P2P 端口 / peer ID：
允许访问的 RPC URL 与方法（不开放则写“无”）：
共享 spec 路径 / genesis hash（需要加入同一链时）：
允许使用的自有账号、资金及普通交易准备方式：
最大连接数 / 并发 / 速率 / 总数据量：
攻击窗口 / 超时 / 紧急停止条件：
明确禁止：SSH、文件系统、管理 RPC、停矿、改我方配置、替换二进制
```

攻击机上先确认：允许的入口可达，我方管理入口不可达。保存连通性检查结果。仅把 RPC 绑定到 `127.0.0.1` 不能替代攻击环境隔离。

PoC 命令由提交者提供并经审阅后登记，不假设存在统一 `run.sh`。记录实际命令、输入哈希、依赖、stdout/stderr、退出码、开始/结束时间和实测资源量。

## 6. 第三步：测试、展示结果、评级

### 6.1 标准实验顺序

| 阶段 | 我方动作 | 攻击侧动作 | 必须保存 |
| --- | --- | --- | --- |
| A：无攻击基线 | 正常组网、持续挖矿与采样 | 不发送 PoC | 区块进展、连接、负载、RPC 基线 |
| B：正常输入对照 | 保持运行与采样 | 通过同一允许入口做正常交互 | 可达性、正常响应、资源消耗 |
| C：PoC 窗口 | 只观察；达到停止阈值时中止并记录 | 在既定能力与预算内触发 | 输入/流量、异常时间、日志、指标 |
| D：攻击停止后 | 不先重启节点，观察是否自行恢复 | 停止发包/触发 | 恢复耗时、持续影响、链一致性 |
| E：独立重复 | 新 root 重建等价正常环境 | 重复相同条件 | 触发次数/总次数与差异 |
| F：修复对照 | 使用修复版新 root | 重复正常输入和 PoC | 正常行为保留、异常是否消失 |

出现资源失控或超出实验网络的影响时，先停攻击侧流量。若还需我方停机，记录时间与原因。停止阈值必须在实验前写进影响预判。

攻击期间我方若执行了停矿、重启、改配置、断开 peer、注入特殊状态，必须完整标记。该次结果只算干预/诊断实验，不能替代“无集群控制权、正常挖矿组网”条件下的复现。

### 6.2 从现象到真实影响

| 主张 | 确认证据 | 排除的常见误判 |
| --- | --- | --- |
| 节点崩溃 | 与触发对应的 panic/退出证据、PID/重启记录、独立重复 | 单次 RPC 超时；事后 PID 存在不排除 macOS launchd 曾重启 |
| 可用性降低 | 正常业务探针、处理延迟、持续时间、攻击成本与基线对比 | 仅攻击者请求被拒绝；Eaglesong 正常挖矿负载；宿主机争用 |
| 停块/同步故障 | 持续出块基线、各节点进展、peer 与同步状态、窗口内对照 | 单次出块间隔长；矿工被我方停止；临时落后 |
| 链视图分歧 | 各节点在同一高度的区块哈希及后续收敛情况 | 不同高度的 tip hash 不同；短暂分叉 |
| 无效交易/区块被接受 | 独立确认其违反规则及最终链上/交易池状态 | 只看提交 RPC 返回值或 PoC 自报成功 |
| 资源放大 | 攻击侧输入成本与目标侧 CPU/内存/磁盘变化、正常输入对照 | 大流量占满链路被说成低成本漏洞 |

判据必须适配具体报告。不要把“连续几秒没出块”设为所有 Eaglesong 实验的统一失败阈值。

同高度比较可使用本项目已使用的只读 RPC：`get_tip_block_number`、`get_block_hash`、`get_tip_header`、`get_peers`。先选各节点都拥有的高度，再比较 `get_block_hash`，参数格式如 `["0x1"]`。这些观察请求从我方控制终端执行，不为攻击侧开放管理能力。

### 6.3 展示给审阅者的结果面板

测试结束后，用下面这块给用户核对和评级。先给结论，再给证据路径，不要先贴长日志。

```text
报告：
技术结论：REPRODUCED / NOT_REPRODUCED / INCONCLUSIVE / REQUIRES_ADDITIONAL_PRIVILEGES
一句话：对方在无集群控制权、我方正常挖矿组网时，是否打出了声称现象。

【攻击是否成立】
- 声明入口是否真的外部可达：
- 是否未授予 SSH / 文件 / 管理 RPC / 停矿 / 改配置：
- 原 PoC 自建环境是否已去掉：
- 正常对照是否成功（排除“根本连不上”）：

【实际打到了什么】
- 目标节点 / 入口 / 时间窗口：
- 观察到的现象（对照声称）：
- 持续多久 / 是否自动恢复 / 是否要人工介入：
- 单节点、本机全部节点、还是有独立主机证据：

【证据（可直接打开的路径）】
- 影响预判与确认记录：
- 适配说明（原命令 → 改后命令）：
- 基线 / 正常对照 / PoC 窗口的 status、snapshot、日志：
- 攻击侧命令、流量、资源：
- 导出包和完整日志：

【评级材料】
- 影响对象与是否触及共识/数据正确性：
- 攻击成本（连接数、字节、时间、算力、资金）：
- 与主网/真实部署的差异：
- 建议：接受并评估赏金 / 补充材料后复核 / 仅有限影响 / 不支持所声称攻击模型
- 未验证部分与替代解释：
```

### 6.4 结论怎么下

分三个维度写，避免用“复现了”代替“应支付赏金”。

技术复现：

- **REPRODUCED**：声明的外部攻击者能力成立，正常运行场景下满足异常判据，证据支持因果关系。
- **NOT_REPRODUCED**：前置条件成立、实验按要求完成，但本次未触发；不代表问题不存在。
- **INCONCLUSIVE**：代码/输入缺失、前提不清、环境不等价或证据不足。
- **REQUIRES_ADDITIONAL_PRIVILEGES**：只在获得我方控制能力或额外权限后触发，不支持原先的无权限远程主张。对方只能在自己启动的环境里打出的结果，属于这一类或 `INCONCLUSIVE`，不能写成对我方集群的复现。

实际影响：影响对象、攻击面是否实际暴露、持续时间、是否自动恢复、是否需要人工介入、是否影响数据/共识正确性，以及单节点、单主机和网络级影响的证据边界。

赏金建议：按我方计划规则检查受影响版本是否在范围内、是否已知/重复、影响是否达到门槛、攻击成本与可扩展性、是否依赖不现实配置、报告与最小复现是否完整。可给出“建议接受并评估赏金 / 补充材料后复核 / 仅确认有限影响 / 不支持所声称攻击模型”。严重级别和金额不在缺少计划规则时预设。

## 7. 我方控制终端：独立验证集群

下面命令只在**我方控制终端**、仓库根目录的同一个 Bash 会话执行，不交给攻击侧。把 `CKB_BIN` 换成实际待测二进制。这些是操作说明，执行验证前才运行；编写文档时未启动此集群。

```bash
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
bash
```

```bash
PROJECT=$(pwd -P)
CASE_ID=BOUNTY-001
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN="$PROJECT/.verification/bounty/$CASE_ID/$RUN_ID"
ROOT="$RUN/cluster"
EVIDENCE="$RUN/evidence"
mkdir -p "$ROOT" "$EVIDENCE/operator" "$EVIDENCE/attacker" "$EVIDENCE/observations"

check_dependencies() {
  local dep
  for dep in bash curl jq awk lsof realpath shasum; do
    command -v "$dep" >/dev/null || { printf 'Missing dependency: %s\n' "$dep" >&2; return 1; }
  done
}
# 此检查失败时停止操作，补齐依赖后再继续。
check_dependencies

# 替换为已审阅的目标版本；不要直接覆盖其他实验使用的二进制。
CKB_BIN=/absolute/path/to/ckb

record() {
  local label=$1 rc=0
  shift
  {
    date -u +%FT%TZ
    printf 'role=operator host='; hostname
    printf 'command:'; printf ' %q' "$@"; printf '\n'
  } > "$EVIDENCE/operator/$label.command.txt"
  "$@" > "$EVIDENCE/operator/$label.stdout" 2> "$EVIDENCE/operator/$label.stderr" || rc=$?
  printf '%s\n' "$rc" > "$EVIDENCE/operator/$label.exit-code"
  cat "$EVIDENCE/operator/$label.stdout"
  cat "$EVIDENCE/operator/$label.stderr" >&2
  return "$rc"
}

record host uname -a
record project-commit git -C "$PROJECT" rev-parse HEAD
record project-status git -C "$PROJECT" status --short
record binary-version "$CKB_BIN" --version
record hashes shasum -a 256 "$CKB_BIN" "$PROJECT/ckb-cluster.sh" "$PROJECT/miner-runner.sh"
```

检查每条关键命令的实际输出和退出码，失败时先解决。每次 `record` 使用唯一标签。

下面使用 RPC 28114–28131、P2P 28215–28232，避开默认 18114/18215。`0.0.0.0` 只用于监听，攻击者应使用实验主机的实际可达地址。`--timeout 300` 只约束启动时等待 4 个新块，因为 18 节点与 4 矿工争用 CPU 时，脚本默认 60 秒容易误超时；超时不证明漏洞存在。

```bash
record up bash "$PROJECT/ckb-cluster.sh" up \
  --root "$ROOT" --ckb "$CKB_BIN" \
  --miners 4 --syncs 10 --boots 4 \
  --pow Eaglesong --mode race --timeout 300 \
  --rpc-bind 127.0.0.1 --p2p-bind 0.0.0.0 \
  --rpc-base 28114 --p2p-base 28215

record baseline-status bash "$PROJECT/ckb-cluster.sh" status --root "$ROOT"
record baseline-snapshot bash "$PROJECT/ckb-cluster.sh" snapshot --root "$ROOT"
record chain-hashes shasum -a 256 "$ROOT/shared/spec.toml" "$ROOT/shared/genesis.hash"
cp "$ROOT/cluster.env" "$ROOT/cluster.state" "$EVIDENCE/operator/"
cp -R "$ROOT/shared" "$EVIDENCE/operator/shared"
```

- `cluster.state` 列顺序为 `id role rpc p2p peer_id`。初始分配顺序是 miners、syncs、boots。实际地址以该文件为准。
- 本例端口（`rpc-base 28114` / `p2p-base 28215`）：

  | 节点 | 角色 | RPC | P2P |
  | --- | --- | --- | --- |
  | miner-0 … miner-3 | 同时出块 | 28114–28117 | 28215–28218 |
  | sync-0 … sync-9 | 只读同步/验证 | 28118–28127 | 28219–28228 |
  | boot-0 … boot-3 | 发现入口，仍同步验证链 | 28128–28131 | 28229–28232 |

- 默认观察 `sync-0`；声称网络级影响时，再对照其他 sync、未被直接攻击的 miner，以及至少一个 boot。不要只盯正在出块的 miner。
- `race` 下 4 个 miner 都启动矿工，没有固定块间隔。boot 仍是普通 CKB 全节点（`bootnode_mode = true`），不是轻量发现服务。
- `up` 会等待四个新块，并检查 peer、genesis、链名称、同步高度差（不超过 1）及共同高度哈希。
- `status` 不是严格健康断言。即使退出码为 0，也要检查 `OFFLINE`、peer 数、高度与矿工状态。
- 至少保留一段无攻击基线。观察窗口依据报告和基线波动预先确定，不要看见异常后再改。
- 避免为压低负载临时启用 `--miner-cpu`。若使用，记录请求值与有效值；缺少可用 cpulimit 会警告并按无限制运行，且该参数不限制节点 CPU。

我方只读健康检查示例（不是漏洞触发输入）：

```bash
RPC_PORT=$(awk '$1=="sync-0" {print $3}' "$ROOT/cluster.state")
RPC_URL="http://127.0.0.1:$RPC_PORT"
printf '%s\n' '{"id":1,"jsonrpc":"2.0","method":"get_tip_header","params":[]}' \
  > "$EVIDENCE/operator/health-request.json"
record health-rpc curl --noproxy '*' --silent --show-error --fail \
  --connect-timeout 3 --max-time 10 \
  -H 'Content-Type: application/json' \
  --data-binary "@$EVIDENCE/operator/health-request.json" "$RPC_URL"
record health-result jq -e \
  'has("result") and (.result != null) and (has("error") | not)' \
  "$EVIDENCE/operator/health-rpc.stdout"
```

HTTP 成功不等于 JSON-RPC 成功。预期报错的 PoC 应检查具体 `.error`，不要套用这条健康断言。

## 8. 证据采集与脚本能力边界

攻击前后分别采集，标签保持唯一：

```bash
record after-status bash "$PROJECT/ckb-cluster.sh" status --root "$ROOT"
record after-snapshot bash "$PROJECT/ckb-cluster.sh" snapshot --root "$ROOT"
record target-logs bash "$PROJECT/ckb-cluster.sh" logs --root "$ROOT" --node sync-0
record export bash "$PROJECT/ckb-cluster.sh" export --root "$ROOT"
```

导出包写在 `ROOT/evidence/`，清理前复制到同级 `EVIDENCE`：

```bash
ARCHIVE=$(tail -n 1 "$EVIDENCE/operator/export.stdout")
if [ -f "$ARCHIVE" ]; then
  cp "$ARCHIVE" "$EVIDENCE/observations/"
  record export-contents tar -tzf "$EVIDENCE/observations/$(basename "$ARCHIVE")"
  record export-hash shasum -a 256 "$EVIDENCE/observations/$(basename "$ARCHIVE")"
else
  printf '导出未完成，请检查 export.stderr，保留集群现场\n' >&2
fi
```

必须了解的采集限制：

- `snapshot` 是文本状态、tip header 和 peers，不是数据库备份，没有 restore 命令。
- `export` 包含配置、共享链信息、文本快照以及各日志最后 **2000 行**；不含链数据库、网络私钥、CKB 二进制或攻击机证据。
- `logs` 默认仅显示各日志最后 **100 行**。关键日志较早时，另行保存完整文件。
- 节点离线时快照可能生成但 RPC 内容缺失，需检查 stderr 与证据完整性。
- CPU/内存、业务探针、网络流量与攻击机资源统计需要额外采集；脚本没有自动完成这些观测。
- 两侧时钟应同步，并记录可能的时钟偏差。关联输入与异常时避免仅依赖日志顺序。
- 配置和日志可能含本机路径与输入；对外分享前审阅。

## 9. 修复对照、停止与清理

| 版本 | 正常输入 | 相同攻击能力下的 PoC |
| --- | --- | --- |
| 问题版本 | 正常功能成立 | 异常满足判据 |
| 修复版本 | 正常功能仍成立 | 修复预期成立且异常消失 |

保持拓扑、PoW、持续挖矿方式、资源预算、入口策略与观察窗口可比。每版本使用新 `RUN_ID`、新 `ROOT` 和显式 `--ckb`。并行实验端口必须不同。

本项目每集群使用一个二进制路径，没有逐节点混合版本接口。`up` 会校验已保存版本字符串，但相同版本字符串不代表相同文件，务必保存二进制 SHA256。不要在原路径直接覆盖正在使用的二进制。

新 root 会生成新的 genesis timestamp。依赖 genesis、OutPoint 或链状态的输入需按等价前置状态重新构造，并登记差异。不要把旧链交易失败误判为修复成功。当前脚本没有数据库或逐字节 chain fixture 导入接口，不要直接编辑正在使用的 spec，也不要复制在线数据库。

完成攻击停止后的自然恢复观察并取证后，再停止我方集群：

```bash
record down bash "$PROJECT/ckb-cluster.sh" down --root "$ROOT"
mkdir -p "$EVIDENCE/observations/full-logs"
for NODE_DIR in "$ROOT"/nodes/*; do
  [ -d "$NODE_DIR/logs" ] || continue
  cp -R "$NODE_DIR/logs" "$EVIDENCE/observations/full-logs/$(basename "$NODE_DIR")"
done
```

`down` 保留数据；再次 `up --root "$ROOT"` 是继续运行，不是回到攻击前。干净重跑使用新目录。若需保留异常数据库，先保存停止后的现场；不要把 export 当作数据库备份。

确认所需证据已保存到 `ROOT` 外部后，才选择破坏性清理：

```bash
record clean bash "$PROJECT/ckb-cluster.sh" clean --root "$ROOT" --force
```

该命令删除所选集群目录内的数据库、配置、网络密钥、日志和集群内 evidence；同级 `EVIDENCE` 与下载二进制保留。**不要省略 `--root`**，否则默认作用于项目现有 `tmp/`。

## 10. 常见排查

| 场景 | 选择/排查方法 |
| --- | --- |
| 普通 RPC、交易或同步复现 | 用默认 4 miner + 10 sync + 4 boot、Eaglesong、`race`；Dummy 或缩容只做初筛 |
| 真实 PoW / 难度相关问题 | 保持 Eaglesong；不要把 Dummy 结果外推。启动等待用足够 `--timeout` |
| 需要单矿工对照 | 另开新 root，`--mode solo`；不能用 solo 结果代替默认 race 结论 |
| 发现/boot 行为 | 默认已有 4 个 boot；不要再把 miner-0 当成唯一连接中心 |
| RPC 不通 | 核对 `cluster.state`、节点日志、绑定地址与端口；客户端不要把 `0.0.0.0` 当目标 |
| 启动失败 | `up` 失败会保留数据和已启动进程；先取日志，再对指定 root 执行 `down` |
| `up` 卡在共同高度/peer 检查 | 18 节点同机时 `wait_views` 只有约 30 秒。先看 `status` 是否只是暂时落后；不要把启动超时当成漏洞。确认端口整段空闲，必要时加长 `--timeout` 只影响等 4 个新块，不延长该健康检查 |
| 版本/spec 校验失败 | 核对固定二进制和共享 spec；切换 PoW、版本或初始拓扑时使用新 root |
| mine 报模式错误 | 仅 ondemand 支持 `mine`；默认验证场景不要用它当攻击前置 |
| CPU 限制未生效 | `--miner-cpu` 只限制矿工；缺少可用 cpulimit 会警告并无限制运行 |
| 锁残留 | 先核对 `.lock/owner` 所记录进程是否仍在执行；不要直接删活动锁 |
| 对方 PoC 只能打自己的节点 | 回到第一步，标为需要额外权限或信息不足，不要为了复现把控制权交给攻击侧 |

## 11. 完整验证报告模板

```text
报告编号 / 提交者原始主张：
技术结论：
实际影响：
赏金建议及适用规则：

问题版本 / SHA256 / 源码 commit / 构建参数：
项目脚本 commit / 修改状态 / SHA256：
宿主机与攻击机配置 / 隔离方式 / 时钟偏差：
集群拓扑 / 正常挖矿模式 / spec 与 genesis：（默认 4 miner + 10 sync + 4 boot，Eaglesong，race）
与目标实际部署的差异：

攻击者能力与禁止访问的控制面：
实际可达入口 / 前提 / 自有资金与算力要求：
原始 PoC 哈希 / 静态审阅 / 影响预判确认记录：
适配说明（删除的自建环境步骤 / 改写后的目标）：
攻击命令 / 输入 / 流量与资源预算 / 实际成本：
正常对照 / 无攻击基线：
触发时间线 / 我方期间是否有干预：
异常证据 / 持续时间 / 自然恢复情况：
重复次数与触发率 / 替代解释：
修复版本对照 / 未验证部分：

操作日志 / 攻击侧日志 / 指标 / 导出包 / 完整日志路径：
证据 SHA256 / 现场保留与清理状态：
```

## 12. 启动器自身回归测试

以下测试使用本地 fixture，不下载二进制、不启动真实节点。它们只检查启动器行为，不验证任何具体 CKB 漏洞：

```bash
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
bash tests/default-ckb.sh
bash tests/pow.sh
bash tests/bind.sh
bash tests/miner-cpu.sh
bash tests/boots.sh
```

通过仅表示启动器相关行为通过自检。验收时必须区分：文档检查、fixture 自检、真实攻击复现、赏金决策。
