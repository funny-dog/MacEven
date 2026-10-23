# 手动清理实战洞察 vs MacEven 源码核实报告

> 背景：2026-10 在本机完成的一次真实手动磁盘清理（ZCode 会话）积累了 10 条实战洞察。
> 本文逐条对照 MacEven 源码核实覆盖情况，给出判定（已覆盖 / 部分覆盖 / 未覆盖）、
> 证据（文件路径 + 行号）与可落地的改进建议。
> 核实日期：2026-10-24；基线：当时工作树（v0.36.x 后）。

## 一、核实结论总表

| # | 洞察 | 判定 | 关键证据 |
|---|------|------|----------|
| 1 | 卸载残留检测要覆盖 CLI 工具（~/.cache/mole 类孤儿缓存） | 未覆盖（磁盘分析可手动发现） | `OrphanLeftovers` 只扫 `~/Library` 固定位置；`~/.cache` 只按已安装 .app 归属扫描 |
| 2 | 临时目录的大头是"泄漏 staging"（随机后缀 + mtime 老旧 + 工具 tmp 父目录） | 未覆盖 | 全库无 staging 检测；`.codex/.tmp` 不在任何清理规则中 |
| 3 | 同一目录内部按 mtime 分层清理（>30 天删、活跃保留） | 部分覆盖 | `AICleanupRows` 已按文件 mtime 分层，但仅限 Codex/Claude 会话 .jsonl 单文件；目录型规则与 .db 会话无分层 |
| 4 | 活跃度判断必须用内容 mtime 而非目录 mtime/目录名 | 部分覆盖 | 会话文件用自身 `FileIdentity.modified`（内容 mtime）判断；但目录型候选无"内部最新 mtime"聚合，靠整目录保守保留兜底 |
| 5 | 运行中应用的缓存删了也腾不出空间（退出→清理→重启） | 已覆盖（缺"清理后重启"环节） | `ApplicationCloser` + `CacheModel`/`DeveloperCleanupModel` 退出后重扫再清理；UI 有"运行中 · 确认后退出并清理" |
| 6 | Docker/OrbStack 卷需要内容可见性（compose 分组、named/anonymous 区分） | 未覆盖 | 仅一条固定路径提示"用 docker system prune 管理"，无卷级枚举与抽查 |
| 7 | 清理后空间不立即变化需要解释（废纸篓 / purgeable / 稀疏盘异步回收） | 部分覆盖 | "移到废纸篓不会立即释放空间"已反复解释；APFS purgeable 与 Docker/OrbStack 稀疏盘回收滞后完全无解释 |
| 8 | 增长率（月增量）是清理时机的好指标 | 未覆盖 | `MonitorHistory` 只记录 CPU/内存/网络等系统指标，无磁盘占用历史；无处显示月增量 |
| 9 | 成对重复应用识别（Qoder + Qoder CN、WorkBuddy + WorkBuddy AI） | 未覆盖（有相邻机制） | `normalizedName` 归一仅用于单应用数据匹配且刻意防误配；软件/卸载页无相似应用配对提示 |
| 10 | 聚合大小会误导，任何可清理项必须可下钻 | 部分覆盖 | AI 会话行可展开逐项确认、磁盘分析可全量下钻；缓存/工作资料卡片只有聚合大小 + 路径，无内部构成下钻 |

---

## 二、逐条核实

### 1. 卸载残留检测要覆盖 CLI 工具 — 未覆盖

**证据**

- `Sources/MacEvenCore/OrphanLeftovers.swift:40-45`：残留候选只来自 `~/Library` 固定位置（Caches、Application Support、Preferences、Containers、Saved Application State、Logs、HTTPStorages、WebKit、Application Scripts、Cookies），不含 `~/.cache`、`~/.local` 等主目录点目录。
- `Sources/MacEvenCore/OrphanLeftovers.swift:58-65`：`candidateIdentifier` 要求"至少三段、字符合法"的 bundle 标识——`mole` 这类单词名 CLI 工具即使出现在 ~/Library 也不会命中。
- `Sources/MacEvenCore/CacheCleanup.swift:90-111`：会扫 `~/.cache`，但候选取决于 `owners` 映射，而 owners 来自 `CacheCatalog.discover()`（`Sources/MacEven/CacheModel.swift:40-59`）——只枚举 `/Applications` 等 .app 包。mole 没有 .app、不在 brew，`~/.cache/mole` 无归属，被跳过。
- `Sources/MacEvenCore/ApplicationCachePaths.swift:13-30`：`relativeRoots(for:)` 依赖 .app 的 Info.plist bundle id / 产品名，同样覆盖不到无 .app 的 CLI 工具。
- 全库无 `brew list`、`which`/PATH 交叉验证（grep 无命中）。

**间接覆盖**：`Sources/MacEvenCore/PurposeRules.swift:98` 把 `~/.cache` 整体标注为"命令行工具缓存 · 可重建"，磁盘分析页可以看到并手动选中移到废纸篓；`DeveloperCleanupRule` 覆盖 `~/.cache/devin`、`~/.cache/chroma` 两个固定子路径（`DeveloperCleanup.swift:95-96`）。但这不是"孤儿检测"，用户必须自己发现并判断。

**改进建议**

- 新增"CLI 工具孤儿缓存"扫描：枚举 `~/.cache`、`~/Library/Caches` 一级子目录，若同时满足：(a) 不匹配任何已安装应用（复用现有 `owners`）；(b) 不匹配 `DeveloperCleanupRule` 已管路径；(c) 不在 PATH（`/opt/homebrew/bin`、`/usr/local/bin`、`~/.local/bin` 等）中找到同名可执行，也不被 Homebrew Cellar/关联链接引用——则列为"可能属于已卸载的命令行工具"。
- 风险控制：默认 `.review` 只读（沿用 `LeftoverOwnership.review` 语义），理由写明"未找到对应可执行"；用户逐项确认后才可清理；目录内有 30 天内修改的文件时追加 advisory。
- UI：并入「软件 › 残留」或智能扫描新卡片，标题如"疑似已卸载命令行工具的缓存"。

### 2. 泄漏 staging 是独立模式 — 未覆盖

**证据**

- 全库 grep `staging`、`marketplace`、`git-*` 无命中。
- `AIWorkCleanupRule`（`AIWorkCleanup.swift:5-9`）只有 sessions / archived_sessions / claude 三类；`OtherStorage.aiLocations`（`OtherStorage.swift:60-84`）列出 `.codex` 多个子目录但不含 `.tmp`。
- `AIWorkCleanup.validateSafety`（`AIWorkCleanup.swift:291-308`）把 `.codex` 根目录列为禁止整体删除的混合根——方向正确，但没有规则去清理它下面的泄漏子目录。
- 最接近的机制：npm 规则要求 `.npm/tmp` 非空即保留（`DeveloperCleanup.swift:466-467` "npm 临时目录非空，可能仍在使用，已保留"）——说明设计上意识到"工具 tmp 目录"这一类，但仅限 npm 且是反向保护，没有"泄漏 staging 清理"。

**改进建议**

- 新增"泄漏临时克隆"规则族，模式定义：父目录是某工具自己的 tmp 目录（`.codex/.tmp`、`<tool>/tmp`、`<tool>/.staging` 等，逐个登记 + marker 校验，复用 `requireMarker` 思路），子目录名匹配工具已知前缀 + 随机后缀（如 `marketplace-upgrade-*`、`git-*`、UUID/哈希后缀），且子目录内**最新内容 mtime 超过阈值（如 14 天）**、对应工具进程未运行。
- 阈值分层：直接子目录只有几 KB 的（如 git-* 锁目录）可放宽；大目录必须同时满足 mtime 老旧 + 工具未运行。
- 风险控制：仅白名单登记的工具 tmp 根目录生效；统计走完整遍历（`requireCompleteTraversal`），不完整即保留；结果默认不选中，逐项确认。
- UI：在「缓存/AI清理」新分组"工具升级残留（泄漏的临时克隆）"，行内说明"父目录是 X 的临时区，子目录 7 月后未再修改"。

### 3. 同一目录内部按 mtime 分层清理 — 部分覆盖

**证据（已做到的）**

- `Sources/MacEven/AICleanupRows.swift:39`：`ageOptions = [30, 90, 180, 365]`；`rows()`（45-53 行）把会话文件按自身 mtime 拆成"旧会话记录 / 近期活跃会话（不建议删除）"，另有"项目已删除的会话"一组。
- `Sources/MacEven/AICleanupView.swift:218-228`：界面提供"未使用时长"阈值选择器，切换即重新分组；209 行明确说明"按会话文件的最后修改时间判断"。这正是"删 >30 天、保留活跃"的精细化思路，比"整目录删/不删"细。

**证据（缺口）**

- 分层仅作用于 `isSessionFile == true` 的规则（Codex/Claude 的单个 .jsonl 文件，`AIWorkCleanup.swift:49-54`）。目录型规则（claudeFileHistory、claudePlans）是整目录候选，无 mtime 分层。
- 洞察中的具体场景 antigravity conversations（497 个 .db 按 30 天分层）完全不支持：`.gemini` 在 `OtherStorage.aiLocations` 中整体标注"保留"（`OtherStorage.swift:74`），没有任何会话/数据库级规则。

**改进建议**

- 为 Gemini/Antigravity 增加会话规则：扫描 `.gemini`（及 antigravity 数据目录）下的会话数据库文件（.db），复用 `AIWorkCleanupTarget.modifiedAt` + `AICleanupRows` 分层展示；严格排除 memory/brain/知识库目录（见第 4 条）。
- 目录型规则（file-history、plans）改为"按内容 mtime 聚合分层"：对目录计算内部文件的最大/最新 mtime（扫描索引已存每个文件的 modified，`Models.swift:31`），旧目录整体列旧、混合目录给出"其中 N 个文件超过 X 天"的子分层或至少在详情中说明。
- 风险控制沿用现状：阈值默认 90 天、老组默认不选中、执行前逐项核验（`AIWorkCleanup.move` 已有身份复核与 lsof 占用检查）。

### 4. 活跃度判断必须用内容 mtime — 部分覆盖

**证据（已做到的）**

- `Sources/MacEvenCore/AIWorkCleanup.swift:163` 与 427 行：`AIWorkCleanupTarget.modifiedAt` 取自候选文件自身的 `FileIdentity.modified`（`Sources/MacEvenCore/Models.swift:31,45`，即 st_mtime）；对单文件会话记录而言这就是"内容 mtime"。
- `Sources/MacEven/AICleanupView.swift:209`："多久未用按会话文件的最后修改时间判断"——没有用目录名或目录 mtime。
- 磁盘分析侧：`SpaceFilter.notModifiedSince`（`Sources/MacEvenCore/SpaceInsights.swift:31`）作用在文件级 `DiskEntry`（每个文件自己的 mtime），大文件/空间洞察按文件冷热过滤（`SpaceInsightsView.swift:30,98-109`）。
- TrashService 操作前"重新校验文件身份、类型和修改时间"（`DiskAnalysisView.swift:57`）。

**证据（缺口）**

- 没有通用的"目录活跃度 = 内部最新内容 mtime"聚合指标：目录型候选（整目录规则、OtherStorage 卡片）不计算 `max(child.modified)`。antigravity brain 场景（1.4G 中 16246 个 30 天内修改的文件、目录 mtime 可能很老）目前靠"整目录保留"（`.gemini` 不在任何清理规则）兜底——不会误删，但也无法精细清理其中真正陈旧的部分。
- 若未来把 `.gemini`/brain 纳入清理，必须先有内容级活跃度判断，否则目录 mtime 会误导。

**改进建议**

- 在 `DiskIndex`/扫描摘要中为目录候选增加 `newestContentModified`（内部最新文件 mtime）与 `recentFileCount(30d)` 两个派生指标，随扫描一次算好。
- 任何目录型清理候选的 UI 都展示"最近内容修改时间"，与目录自身 mtime 并列；两者差异大时提示"目录时间老但内容仍活跃"。
- 把"recentFileCount > 0 ⇒ 默认保留"固化为目录型规则的安全断言。

### 5. 运行中应用的缓存：退出→清理 — 已覆盖（缺"清理后重启"）

**证据**

- 阻断与提示：`Sources/MacEvenCore/CacheCleanup.swift:169`——应用运行中时 `blockedReason = "应用正在运行，请退出后重新检查。"`；`refresh(isRunning:)` 全程接 `NSWorkspace.runningApplications`（`CacheCatalog.isRunning`，`CacheModel.swift:60-65`）。
- 代为退出：`Sources/MacEven/ApplicationCloser.swift`（全文件）——正常退出请求、保存提示等待、辅助进程处理、超时不强杀、系统/自身/他人进程保护。
- 清理流程：`Sources/MacEven/CacheModel.swift:220-249` `executeCleanup` 逐组"退出应用 → `rescanAfterQuit` 重扫 → move"；浏览器缓存同理（`CacheModel.swift:487-497` + `DeveloperCleanup.rescanBrowserAfterQuit`，`DeveloperCleanup.swift:636-653`）。
- UI：`Sources/MacEven/CleanupDetailsView.swift:223`"运行中 · 确认后退出并清理"；确认窗说明"应用与浏览器缓存会先请求相关应用正常退出……拒绝退出或超时会保留相应缓存"（`DiskRecommendationsView.swift:165`）。

**缺口**

- 没有"关闭 X 可释放 Y"的主动汇总：被 blocked 的运行中缓存归入"受限项"，不会在扫描结果顶部提示"退出 Claude/Chrome 可再释放约 3G"。
- 清理完成后不会代为重启应用（洞察建议的第三步"重启"未实现）——应用要用户自己重开。

**改进建议**

- 扫描完成后计算"可再释放潜力"：`Σ blockedReason 含"正在运行" 的组 allocatedSize`，若超过阈值（如 500M）在页首显示 InlineNotice"退出 Claude、Chrome 后可再清理约 X GB"。
- 可选的"退出并清理后重启"：清理成功后用 `NSWorkspace.shared.openApplication(at:options:)` 恢复刚才代为退出的应用；默认关闭、按组勾选，失败不影响清理结果。

### 6. Docker/OrbStack 卷内容可见性 — 未覆盖

**证据**

- `Sources/MacEvenCore/OtherStorage.swift:51`：仅一条"Docker 数据"（`~/Library/Containers/com.docker.docker/Data`）+ note"用 Docker Desktop 或 docker system prune 管理"。
- `Sources/MacEvenCore/PurposeRules.swift:101,106`：`~/.orbstack` 与 Docker 虚拟磁盘均为 opaque keep（"请在 OrbStack 中清理"）。
- 全库无 `docker volume`、`docker system df`、compose 项目名、named/anonymous 卷区分、只读挂载抽查等任何实现（grep 无命中）。

**改进建议**

- 第一步（只读可见性，风险最低）：检测 `docker`/`orbstack` CLI 可用且 daemon 运行时，在「其他存储」Docker 卡片展开"卷明细"：`docker volume ls` + `docker system df -v`（只读命令，复用 `DeveloperCleanupActivity.command` 的受控子进程模式），按 compose 项目名（`com.docker.compose.project` label）分组展示，named 与 anonymous 分列，标注 109/114 孤儿这类统计；提供"在 OrbStack/Docker Desktop 中打开"跳转，MacEven 不直接删卷。
- 第二步（可选）：对孤儿卷提供 `docker volume inspect` 的挂载记录与"最近使用时间"（从 label/mountpoint mtime 估算），帮助判断孤儿；删除动作仍交给 `docker volume rm`/`prune`，并把命令回显写入操作日志。
- 明确文案区分"docker volume prune 默认只删 anonymous 卷"，避免用户以为 prune 已覆盖 named 孤儿卷。

### 7. 清理后空间不立即变化的解释 — 部分覆盖

**证据（已做到的）**

- "移到废纸篓不会立即释放空间，清空废纸篓后释放"贯穿全 UI：`DiskAnalysisView.swift:16`（页副标题）、48、57-59（确认窗）；`DiskRecommendationsView.swift:168`；`CleanupDetailsView.swift:41`（"空间将在清空废纸篓后释放"）；`OtherStorage.swift:47`（废纸篓 note"MacEven 不会清空废纸篓"）。

**证据（缺口）**

- 全库无 `purgeable`（可清除空间）概念：硬件/磁盘页不显示 APFS purgeable，也没有"删除后可用空间延迟上涨"的解释。
- 无容器稀疏盘场景解释：Docker/OrbStack 内部回收后主机 `df` 滞后（稀疏磁盘异步 trim）完全未提及——而 MacEven 的 Docker 入口恰恰引导用户去 `docker system prune`（`OtherStorage.swift:51`），清完不涨空间时用户必然困惑。

**改进建议**

- 结果页（`CleanupResultsSection`）在涉及废纸篓的清理后追加一行可展开说明："为什么可用空间没变？"，分三种情况：移到废纸篓（需清空）、APFS purgeable（系统稍后异步回收，可在"关于本机 › 存储"观察）、容器稀疏磁盘（Docker/OrbStack 内部回收后由宿主异步 trim，需要等待或重启 OrbStack）。
- 硬件状态页读取并展示卷的 purgeable 容量（`URLResourceKey.volumeAvailableCapacityForImportantUsageKey`），让"总空间 vs 可用空间"的差额有出处。

### 8. 增长率（月增量）指标 — 未覆盖

**证据**

- `Sources/MacEvenCore/MonitorHistory.swift`：分钟级聚合只含 cpu、memory、compressed、swap、download、upload、gpu、pressure、温度、风扇（`MinuteAggregate` 定义，33-52 行）——没有磁盘占用历史。
- 全库无"月增量/增长率"展示（grep `月增|增长率|perMonth` 仅命中内存探针测试）。
- 现有最接近的能力：文件级 `notModifiedSince` 过滤（冷热）与 `AIWorkCleanupTarget.modifiedAt`，都是"时点"而非"趋势"。

**改进建议**

- 低成本方案：在 AI 清理扫描时把每条规则（或每个目标目录）的 `allocatedSize` + 时间戳追加写入本地小表（可复用 OperationLog 的落盘模式或 `MonitorHistory` 的 SQLite 队列）；UI 在规则行显示"较 30 天前 +230M（约 +230M/月）"。
- 首次使用无历史时，用目录内文件的 mtime 分布估算"近 30 天新增"（扫描索引已有每个文件 modified），标注"估算"。
- 月增量超过阈值（如 100M/月）的行加轻量徽标，帮助排定清理优先级。

### 9. 成对重复应用识别 — 未覆盖（有相邻机制）

**证据**

- `Sources/MacEvenCore/ApplicationDataDiscovery.swift:71-73` `normalizedName`（忽略大小写/空格/点/横线/下划线）存在，但只用于**单个应用**的关联数据匹配；248-249 行注释明确"名称按归一写法全名匹配，WorkBuddy 与 WorkBuddy AI 不会互相误配"——即现有设计刻意**避免**把它们混同，方向与"识别重复对"相反。
- `Sources/MacEven/LeftoverModel.swift:14,34`：vendor（前两段）分组仅用于残留的只读复核（"同厂商应用仍已安装"），不作用于已安装应用列表。
- `Sources/MacEvenCore/SoftwareUpdates.swift` 的应用发现与软件页（`SoftwareModel.swift`）无相似名称/同厂商配对逻辑；grep `相似|similar|功能重复` 无命中。

**改进建议**

- 在「软件 › 卸载」扫描完成后做一次性配对：对全部已安装应用按 `normalizedName` 相似度（一方是另一方的前缀、或仅差 `CN`/`AI`/`Pro` 等已知后缀 token）+ bundle id vendor 前缀分组。
- 命中对时在两个条目上显示中性徽标"与 X 并存（功能可能重复）"，展开给出各自占用（复用 `ApplicationDataPreview` 的 included/retained 统计）与卸载入口；**只提示，不推荐删哪个**（国行/CN 版与海外版各有用途，判断留给用户）。
- 风险控制：配对结果不参与任何自动清理；两应用数据目录的匹配仍走现行 `normalizedName` 全名规则，互不污染。

### 10. 聚合大小必须可下钻 — 部分覆盖

**证据（已做到的）**

- AI 会话：`Sources/MacEven/AICleanupView.swift:204-243`——行可展开（`expandChevron`）列出每个会话文件（分页 100 条，带路径、大小、最后修改、项目名），且"选择全部…"也逐项确认（`AIWorkCleanup.swift:204-210` 的 grouped 语义）。洞察 10 的教训（3.4G 聚合误导）在这条产品线上已被结构性解决。
- 磁盘分析：treemap"其他"可点开分页（`TreemapView.swift:70`）、目录双击进入（`DiskAnalysisView.swift:444`）、用途列表可展开文件——全量下钻能力存在。
- 缓存组在确认窗列出具体路径（`CleanupDetailsView.swift:240-241,375-376,493-494`）。

**证据（缺口）**

- 缓存页与 AI 工作资料卡片的聚合行不可下钻：`DeveloperCleanupGroup`/`CacheGroup`/`StorageMeasurement` 在列表里只有聚合大小 + 一行路径 + "在 Finder 查看"（`AICleanupView.swift:425-433` pathRow）；想知道 Gradle 缓存、`.codex` 卡片里到底装了什么，只能切到磁盘分析自己找，没有页内"查看构成"。
- `OtherStorage` 卡片（备份、VM、Docker 等）同样只有大小 + note，无内容抽查。

**改进建议**

- 为整目录型清理组（DeveloperCleanup 全目录规则、CacheGroup、aiStorage/OtherStorage 条目）增加"查看构成"：从已有 SQLite 索引取该 root 的直接子项 top-N（大小排序），弹层展示子目录构成（如"两个完全为空的卷"在抽查中一眼可见）；只读，不引入新扫描。
- 构成弹层提供"在磁盘分析中打开"深链，把清理页与磁盘分析的既有下钻能力打通。
- 洞察 10 的验收标准建议写入测试：任何 `allocatedSize` 展示处，两步内必能看到其子项构成或到达可下钻视图。

---

## 三、改进建议清单（按优先级）

### P0（直接对应本次清理中"删错重点/漏掉大头"的风险）

1. **工具 tmp/泄漏 staging 规则族**（洞察 2、10）：登记 `.codex/.tmp` 等工具 tmp 根 + marker 校验 + 随机后缀识别 + 内容 mtime 阈值 + 工具未运行；默认不选中、逐项确认。本次 2.8G 的 marketplace-upgrade-* 泄漏正属此类，也是现有规则完全触不到的最大类别。
2. **Gemini/Antigravity 会话规则 + mtime 分层推广**（洞察 3、4）：`.gemini` 系会话数据库纳入 `AIWorkCleanupRule`（沿用 modifiedAt 分层与"近期活跃不建议删除"），目录型候选增加 `newestContentModified` 派生指标；brain/memory 类目录继续硬保护（`/memories|/memory` 保护规则已存在，`AIWorkCleanup.swift:312-317`，可扩展到 brain 命名）。
3. **清理组"查看构成"下钻**（洞察 10）：聚合行两步内可见子项构成，弹层只读、复用扫描索引。

### P1（提升判断质量与用户信任）

4. **CLI 工具孤儿缓存检测**（洞察 1）：`~/.cache`、`~/Library/Caches` 一级目录 × （已安装应用 ∪ brew/PATH 交叉验证）求差，孤儿默认只读 review。
5. **"为什么可用空间没涨"结果页解释 + purgeable 展示**（洞察 7）：废纸篓 / APFS purgeable / 容器稀疏盘三种情形的说明文案与 `volumeAvailableCapacityForImportantUsage` 展示。
6. **月增量指标**（洞察 8）：AI 清理规则行显示"较 30 天前 +X（估算）"，历史快照落盘。
7. **"关闭 X 可释放 Y"汇总提示**（洞察 5 补全）：运行中应用被跳过的缓存在页首汇总为可再释放潜力。

### P2（锦上添花）

8. **成对重复应用徽标**（洞察 9）：卸载页相似度配对 + 中性提示，不参与自动清理。
9. **Docker/OrbStack 卷只读明细**（洞察 6）：CLI 可用时展示卷清单、compose 项目分组、named/anonymous 区分，删除引导到原工具。
10. **清理后可选重启应用**（洞察 5 补全）：代为退出的应用在清理成功后可一键恢复。

---

## 四、本次核实的方法与边界

- 只读探索：通读了 LeftoverModel / OrphanLeftovers / CacheModel / CacheCleanup / DeveloperCleanup / AIWorkCleanup / ApplicationDataDiscovery / ApplicationCachePaths / OtherStorage / PurposeRules / ApplicationCloser / AICleanupView / AICleanupRows / DiskAnalysisView / DiskRecommendationsView / CleanupDetailsView / SmartScanModel（节选）/ SoftwareModel / MonitorHistory / Models 等源码，并对 staging、purgeable、增长率、vendor、similar、docker volume 等关键词做了全库 grep。
- 未运行任何构建、脚本或 git 命令；未改动除本文档外的任何文件。
- 行号以当前工作树为准，后续重构可能漂移，引用时建议以文件 + 函数/符号名定位。
