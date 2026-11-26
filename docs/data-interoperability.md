# 夜奔（Fugue）数据导出与未来跨平台互通规范

本文档定义了夜奔（Fugue）iOS 客户端当前提供的数据导出、加密备份与单文件 WebDAV 同步格式，作为未来扩展 Android、macOS、桌面端或 Web 端时的数据互通契约。

> 权威参考实现位于：
> - 明文备份与合并规则：`iOSBox/Services/BackupService.swift`
> - 加密信封与凭据打包：`iOSBox/Services/EncryptedBackupService.swift`
> - 删除墓碑语义：`iOSBox/Services/SyncTombstoneStore.swift`
> - 确定性书籍 ID：`iOSBox/Models/BookVolume.swift`
> - 单文件 WebDAV 传输：`iOSBox/Services/WebDAVSyncService.swift`、`iOSBox/Services/WebDAVAutoSyncCoordinator.swift`

---

## 1. 导出与同步能力清单

| 能力 | 文件格式 | 包含凭据 | 适用场景 |
|---|---|---|---|
| **普通 JSON 备份** | UTF-8 JSON（`BackupArchive` v8） | 否（自动剥离 API Key、敏感 Header 与私有路径） | 归档留存、跨设备无密钥迁移、第三方脚本处理 |
| **密码加密完整备份** | UTF-8 JSON 信封（`IOSBOX_ENCRYPTED_BACKUP_V1`） | 是（含主/备 API Key、敏感 Header、Tavily Key、完整 Base URL） | 完整换机、跨平台端到端加密迁移 |
| **WebDAV 单文件加密同步** | 与「密码加密完整备份」**字节级一致**（默认路径 `Fugue/fugue-sync.enc.json`） | 是（并携带 `tombstones` 删除墓碑） | 跨设备持续同步与增量合并 |
| **阅读与文档导出** | 单/批量 Markdown（`.md`）、分页 PDF（`.pdf`）、分享长图（`.png`） | 否 | 笔记沉淀与对外分享 |

---

## 2. 明文备份格式（`BackupArchive` v8）

- **版本号**：`formatVersion = 8`；客户端读取到高于自身支持的版本时必须拒绝导入并提示升级，不得静默丢弃数据。
- **单文件上限**：`256 MiB`（`268,435,456` 字节）。
- **编码约定**：
  - 所有时间戳使用 **ISO-8601 UTC** 字符串（如 `2026-11-25T08:00:00Z`）。
  - 所有实体 `UUID` 使用标准 36 字符 **大写** 连字符格式（如 `550E8400-E29B-41D4-A716-446655440000`）；解析时大小写不敏感。
  - 未来客户端在读取 JSON 时必须**容忍未知字段**；若某端暂不支持某字段（如 `englishCoach` 或未来新增的扩展配置），在往返导出时建议按不透明 JSON 保留，避免覆盖丢失。

### 顶层字段

| 字段 | 类型 | 说明 |
|---|---|---|
| `formatVersion` | `Int` | 当前为 `8`，仍可导入旧版文件 |
| `exportedAt` | `ISO-8601 Date` | 导出时间 |
| `appVersion` | `String` | 导出端应用版本号 |
| `providers` | `[ProviderBackup]` | 服务商配置（明文备份不含密钥；支持 `openai_compatible`、`openai_responses`、`anthropic`、`gemini`） |
| `presets` | `[PresetBackup]` | 助手预设及关联的 `knowledgeVolumeIDs` |
| `conversations` | `[ConversationBackup]` | 会话、完整消息分支树（`parentMessageID` / `activeLeafMessageID`）、Arena 对比组、圆桌群聊设置与修订历史 |
| `requests` | `[RequestRecord.Snapshot]?` | 请求用量与测速账本记录（不含正文与凭据） |
| `memories` | `[PersonalMemory.Snapshot]?` | 个人长期记忆（当前上限：60 条、每条 1,000 字符） |
| `books` | `[BookVolume.Snapshot]?` | 书架文档快照（单卷文本上限 12 MiB、最多 5,000 章节） |
| `personaProfiles` | `[GroupMember]?` | 独立保存的人物档案 |
| `shelfPositions` | `[ShelfReadingState.Position]?` | 书架阅读进度位置 |
| `tombstones` | `[SyncTombstone]?` | 跨设备删除墓碑记录 |
| `englishCoach` | `EnglishCoachStore.PersistedState?` | iOS 英语私教状态（不支持该模块的客户端应忽略或透传保留） |
| `annotations` | `[ReadingAnnotation.Snapshot]?` | 带章节、UTF-16 偏移及引用原文的读书摘录与批注，可独立保留 |
| `memoryCollections` | `[NamedMemoryCollection]?`（`[MemoryCollectionBackup]?`） | 命名记忆集合（每项包含集合 `id`、`name` 与 `memoryIDs`；仅手工完整备份写入，WebDAV 同步归档省略） |
| `friendMemories` | `FriendMemoryStore.PersistedState?` | 好友持续记忆（覆盖人物档案 `persona:<uuid>` 与书中好友 `book:<bookUUID>:<name>` 的关系小结、最多 25 条带章节进度与更新时间戳的共同记忆条目及单条删除墓碑；随手工完整备份与加密 WebDAV 同步合并） |

v8 将阅读位置、个人记忆和消息收藏的修改时间记录为 Unix 秒数（包含小数秒），双向同步采用较新的显式修改。清空对话会在该会话的 `messageChanges` 中记录具体消息 UUID、操作时间及删除状态。跨端合并保留另一台设备独有的新消息。手工恢复被清空的消息或在原设备撤销会产生更新的恢复记录。参与持续同步的设备应同时升级到支持 v8 的版本。

### `memoryCollections` 在手工完整备份与 WebDAV 同步中的差异语义

顶层可选字段 `memoryCollections`（Swift 实现类型为 `[NamedMemoryCollection]?`，契约等价于 `[MemoryCollectionBackup]?`）记录命名记忆集合的 `id`（UUID）、`name`（非空集合名称）和 `memoryIDs`（关联的个人记忆 UUID 列表）。套用集合时会把当前已启用的对应条目复制到会话或助手预设的记忆范围：

- **手工完整备份（普通 JSON 备份与手工密码加密备份，`tombstoneStore == nil` / `tombstonePolicy == .ignore`）**：
  - **导出时**：打包所有命名记忆集合，并将每组 `memoryIDs` 过滤为当前归档内实际存在的记忆条目（无集合时省略为 `nil`）。
  - **导入恢复时**：校验集合 `id` 唯一性与字段有效性后按集合 `id` 合并——保留本机已存在的同 `id` 集合版本，补充本机缺失的集合，并自动剔除在合并后仍不存在的 `memoryIDs`。
- **WebDAV 自动/手动加密云同步（携带墓碑存储，`tombstoneStore != nil` / `tombstonePolicy == .enforce`）**：
  - **导出上传时**：命名记忆集合属于本机快捷勾选模板，不含单集合级修改时间戳或删除墓碑，因此 WebDAV 同步归档在生成 `BackupArchive` 时**主动省略 `memoryCollections`（置为 `nil`）**；单条个人记忆（`memories`）及助手预设已套用的 `memoryIDs` 仍正常随同步包传输。
  - **拉取合并时**：同步合并仍校验外来包中 `memoryCollections`（若存在）的结构合法性，并从本机现有命名集合中自动清理已被远端墓碑删除的 `memoryIDs`（`removeFromMemoryCollections`），但**不执行 `restoreMemoryCollections` 导入覆盖本机集合列表**。

### 确定性书籍 ID（`BookVolume.id`）计算契约

为避免同一本书在不同客户端导入后生成不同 UUID 或在导入校验时触发 `conflictingIDs`，**所有客户端必须使用完全一致的规范 JSON 序列化计算书籍 ID**：

1. 将 `[BookChapter]` 数组按 **Key 字典序（`text` 在前，`title` 在后）且不转义 `/`（`withoutEscapingSlashes`）** 编码为紧凑 UTF-8 JSON：
   ```json
   [{"text":"...","title":"..."}]
   ```
2. 计算 UTF-8 字节流的 `SHA-256` 摘要，取前 16 字节 `b[0..<16]`。
3. 按如下掩码写入字节 6 和字节 8，格式化为大写 UUID 字符串：
   - `b[6] = (b[6] & 0x0F) | 0x80`
   - `b[8] = (b[8] & 0x3F) | 0x80`

---

书籍 `id` 在后台 OCR 补录 PDF 页面后仍保持稳定，已有引文和书友始终引用同一个 ID。v8 的书籍快照含当前规范章节数据的 `manuscriptID`；导入时校验正文并按页合并。旧版扫描 PDF 快照缺少这个字段时，通过导入器生成的有序页标题处理已有资料。

## 3. 密码加密完整备份格式（`IOSBOX_ENCRYPTED_BACKUP_V1`）

加密备份与 WebDAV 同步共用同一外层 JSON 信封（键按字典序输出）：

```json
{
  "combinedCiphertextBase64": "<Base64(12B nonce || ciphertext || 16B GCM tag)>",
  "iterations": 600000,
  "magic": "IOSBOX_ENCRYPTED_BACKUP_V1",
  "saltBase64": "<Base64(16B random salt)>"
}
```

### 密码学参数

- **口令规则**：至少 8 个字符且不可为空白字符串；派生密钥时使用密码的 **UTF-8 字节流**。
- **KDF**：`PBKDF2-HMAC-SHA256`，`iterations = 600_000`，随机 16 字节 `salt`，派生 32 字节（256-bit）对称密钥。
- **认证加密**：`AES-256-GCM`，随机 12 字节 `nonce`，16 字节认证标签；**AAD（附加认证数据）** 固定为 UTF-8 字节流 `"IOSBOX_ENCRYPTED_BACKUP_V1"`。
- **明文载荷（`FullPayload`）**：ISO-8601 编码的 UTF-8 JSON，包含：
  - `versionedArchive`: 上述 `BackupArchive` v8 对象。读取旧包时使用原有的 `archive` 键。写入 v8 时仅用新键，因此缺少版本检查的旧加密客户端也会在合并前停止。
  - `providerSecrets`: `[ProviderSecretBundle]`（`providerID`、`rawBaseURL`、`isEnabled`、`apiKey`、`extraAPIKeys?`、`idleTimeoutSeconds?`、`secretHeaders: [HeaderUUID: SecretValue]`）
  - `tavilyAPIKey`: `String`
  - `drafts`: 可选的会话 UUID 和未发送草稿，手工加密导出时由用户勾选。普通 JSON 与自动 WebDAV 上传均省略草稿。同一会话的本机草稿与备份存在差异时，本机草稿继续保留，备份版本完整保存为「找回的草稿」中的独立会话。

> **未来跨平台实现注意**：其他平台在大文件（接近 256 MiB）导入导出时，建议采用流式临时文件加解密，避免一次性在堆内存同时持有明文 JSON、密文与 Base64 字符串导致 OOM。

---

## 4. 删除墓碑与 WebDAV 同步语义

### 删除墓碑（`SyncTombstone`）

```json
{
  "kind": "conversation | memory | book | preset | personaProfile | provider | readingAnnotation",
  "id": "<UPPERCASE-UUID>",
  "deletedAt": "2026-11-25T08:00:00Z"
}
```

- **保留周期**：180 天，最多 10,000 条记录，按 `deletedAt` 最新者胜出。
- **两种应用策略**：
  - **手工导入备份（`ignore`）**：允许用户手动恢复曾经删除的数据，同时清除对应的本地陈旧墓碑。
  - **多端同步（`enforce`）**：合并双端墓碑，阻止已删除实体复活，并删除本地早于 `deletedAt` 的对应实体；对于没有独立 `updatedAt` 的实体（`provider`、`preset`、`personaProfile`），只要存在有效墓碑即无条件阻止复活。

### WebDAV 单文件传输约定

- 默认远端路径：`Fugue/fugue-sync.enc.json`（公网强制 HTTPS，仅局域网/本机允许 HTTP，禁止跨主机重定向）。
- 变更检测：通过 `HEAD` 读取 `ETag` 与 `Last-Modified`，结合本地变更标记决定「拉取合并 / 推送上传 / 先拉合并再推」。
- 智能同步在 `PUT` 时使用 `If-Match: <etag>`（首次创建 `If-None-Match: *`），遇到 `412 Precondition Failed` 时自动重走「拉取 → 合并 → 重传」流程。
