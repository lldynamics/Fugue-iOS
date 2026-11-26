# 夜奔（Fugue）

原生 **iOS / iPadOS** 多模型聚合与自定义 API（BYOK）AI 对话与阅读工作台（Swift + SwiftUI + SwiftData + Keychain）。中文系统下显示为「夜奔」，英文及其他语言环境下显示为 **Fugue**（Xcode 工程 Target、Bundle ID 与本地存储标识保留 `iOSBox` 以兼容既有数据与钥匙串）。

> 当前阶段聚焦打磨 iOS / iPadOS 原生体验；同时保留开放、版本化的本地数据导出与端到端加密备份/WebDAV 同步格式，为后续跨平台客户端预留完整的数据互通能力（详见 [数据导出与跨平台互通规范](docs/data-interoperability.md)）。

## 从这里开始

- 首次打开可先体验本地示例书摘。书架搜索结果可直接定位原文，选择段落可存为带出处的阅读笔记，或带入一份可编辑的提问草稿。
- 点「连接模型」验证服务后，可以新增账号或更新指定账号。个人和工作账号可使用相同端点。在对话中搜索已发现的模型，可直接启用并使用。
- Safari 分享的链接和选文、图片及支持的 PDF 可以先存为本地草稿，回到首页再继续编辑。草稿附件支持检查原件、校对识别文字和选择发送内容。
- 在书架点「用一组资料新建对话」，可选择书目和助手，或复用最近讨论过的一组书。资料库也可启用圆桌和英语私教。关闭英语私教后，已有学习日志仍可在「管理可选功能」中查看。
- 并发对比与圆桌在发送前显示请求数或发言上限、已知输入费用和预算提醒。多模型回答可以记录采纳理由、加标签，在资料库回看当时的答案与用量。
- 对话的「分享与导出」可以选择分支或勾选消息，先预览再分享。Markdown 和分页 PDF 默认仅含正文，思考过程、系统提示词及引文可自行勾选。

## 核心特性

1. **四大协议原生支持 + 自由接入 BYOK API**
   - **OpenAI 官方 Responses API & OpenAI 兼容协议**：支持 `/v1/responses` 与 `/v1/chat/completions`，通吃 OpenAI、DeepSeek、OpenRouter、SiliconFlow 硅基流动、OneAPI / NewAPI 中转站、Ollama / LM Studio 局域网本地模型等。
   - **Anthropic Claude 原生协议**：使用 `/v1/messages`，原生支持 Extended Thinking 思考链、Prompt Caching 与原版 PDF 输入。
   - **Google Gemini 原生协议**：使用 `:streamGenerateContent?alt=sse`，原生支持多模态图像、PDF 文档及思考过程。
   - **智能端点解析与连接韧性**：自动处理 `/v1` 补全与多版本路径（结尾加 `#` 强制原始路径）；支持自定义敏感/普通 HTTP Header、多 API Key 轮换池、自定义流式空闲超时、指数退避重试与模型列表一键拉取。

2. **单聊切换、多模型并发对比（Arena）与圆桌群聊**
   - **单聊模式**：同一对话内随时切换不同服务商与协议接力回答，自动完成跨协议上下文转换。
   - **多模型并发对比（Arena）**：一次提问同时并发请求 2–4 个模型，支持**标签切换**与**并排横滑**两种视图；可指定上下文追问主回复，或选择任意模型进行**裁判综合汇总（Judge Synthesis）**。
   - **AI 圆桌群聊 & 独立人物档案**：支持配置多角色群聊、人物参考资料片段、公开博客 / RSS / Atom 订阅动态，以及「从书中创建好友」按阅读进度防剧透伴读。

3. **本地书架与 FTS5 全文知识库检索**
   - 导入本地 `TXT` / `MD`（Markdown）/ `EPUB` / `PDF`（支持扫描件本地 `Vision` 离线 OCR）/ `DOCX` / `XLSX` / `PPTX`，按会话或助手预设绑定最多 12 本参考书目。
   - 使用本地持久化 **SQLite FTS5 BM25** 索引执行毫秒级全历史消息检索与知识库引用检索，无需外部向量 API，回答附带可跳转原文的精确章节/页码摘录。

4. **推理思考、多模态附件、文档扫描与语音纪要**
   - 原生解析思考链与流式 `<think>` 标签；Markdown 支持表格、嵌套列表、代码高亮与 [SwiftMath](https://github.com/mgriebling/SwiftMath) LaTeX 公式渲染；`html` / `svg` / `mermaid` 支持离线沙盒 `WKWebView` 实时预览与截图导出。
   - 支持相机拍照、文档扫描（`VNDocumentCameraViewController` + 本地 `Vision` OCR 一键转 `.txt` 省识图 Token）、`DOCX` / `XLSX` / `PPTX` / `PDF` 离线文本提取。
   - 录音面板支持实时波形、暂停续录、Whisper 云端转写与 iOS `SFSpeechRecognizer` 本地免费兜底，以及云端 / 系统语音朗读（TTS）。

5. **联网搜索、智能工具与系统深度集成**
   - **联网能力**：支持服务商原生联网 Grounding（Gemini / Anthropic / OpenAI）与 **Tavily** 联网搜索（仅发送确认后的搜索词，附带可核对来源卡片）。
   - **智能工具调用**：单聊可开启 `web_search`、`read_webpage`（直连公开 HTTPS 正文提取，带域名审批门控）、`search_documents` 与 `propose_memory`（经人工确认后写入长期记忆）。
   - **系统集成**：提供 **Share Extension（`iOSBoxShare`）**、**快捷指令（AppIntents）**、**桌面/锁屏小组件与灵动岛（`iOSBoxWidgets`）**、**Spotlight 深链检索**（默认关闭，显式开启）以及 **Face ID / 密码隐私锁与后台防窥遮罩**。

6. **上下文精细控制、助手预设与用量测速账本**
   - 支持无损消息分支树、历史修订版本切换、从任意消息分叉新对话、清除上文分割线、单条移出上下文、滚动上下文摘要、引用追问与截断续写。
   - 支持全局个人长期记忆（最多 60 条、每条 1,000 字，可保存命名集合，套用到助手或会话，并在发送前逐条勾选）、能力路由（图片/代码模型）与故障降级备用链路。
   - 「用量与测速」账本统计输入/输出/缓存 Token、中位输出速率（`tok/s`）、首段/正文延迟与月度预算预警。

7. **纯本地直连、开放数据导出与未来跨平台互通**
   - 无任何第三方中间服务器；API Key 与敏感请求头存入 iOS **Keychain**，本地数据存储于 **SwiftData**（支持 V1 至 V10 自动迁移）。
   - **多样化数据导出**：支持单条/单会话/批量导出 **Markdown**、分页 **PDF** 与 **PNG** 分享长图。
   - **双模备份 + 单文件 WebDAV 加密云同步**：
     - **普通 JSON 备份（v8）**：包含对话、分支树、附件、书架、摘录、记忆、预设、人物档案与用量账本，自动剥离 API Key 与敏感凭据。
     - **密码加密完整备份（`IOSBOX_ENCRYPTED_BACKUP_V1`）**：本地采用 `PBKDF2-HMAC-SHA256`（600,000 次）+ `AES-256-GCM` 端到端加密，完整打包数据与钥匙串凭据，可选带走未发送草稿，恢复前可按资料类别预览和选择。
     - **单文件 WebDAV 加密同步**：与手工加密备份采用**完全一致的单文件加密格式**（默认 `Fugue/fugue-sync.enc.json`），结合删除墓碑（`SyncTombstone`）与 `ETag` / `Last-Modified` 检测实现双向合并，并为未来其他平台客户端预留开放互通契约，详见 [docs/data-interoperability.md](docs/data-interoperability.md)。

---

## 运行与测试

### 环境要求

- **Xcode 16.4+ 或 Xcode 26+**（Swift 6；`AppIntents` 前台续接模式已通过 `#if compiler(>=6.2)` 兼容 Xcode 16.4 与 Xcode 26+ 工具链）
- **iOS 18.0 / iPadOS 18.0 及以上系统**（Deployment Target `18.0`）
- 打开工程文件 `iOSBox.xcodeproj`

### 运行方式

1. 在 Xcode 中打开 `iOSBox.xcodeproj`
2. 选择 iPhone / iPad 模拟器或真机（真机运行需在 `Signing & Capabilities` 中为 `iOSBox`、`iOSBoxShare`、`iOSBoxWidgets` 选择同一开发团队并配置同一 App Group `group.$(IOSBOX_BUNDLE_ID)`）
3. 按 `Cmd + R` 运行

### 命令行构建与单元测试

```bash
xcodebuild build-for-testing \
  -project iOSBox.xcodeproj \
  -scheme iOSBox \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'

xcodebuild test-without-building \
  -project iOSBox.xcodeproj \
  -scheme iOSBox \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -parallel-testing-enabled NO \
  -only-testing:iOSBoxTests
```

---

## 多语言（中文 / English）

- 代码中的文案以简体中文书写（String Catalog 源语言 `zh-Hans`），英文翻译位于 `iOSBox/Localizable.xcstrings`，权限说明位于 `iOSBox/InfoPlist.xcstrings`。
- 系统语言为中文时显示中文，为英文时显示英文，其他语言回退到英文（开发区域为 `en`）。
- 新增或修改文案后，编译工程生成 `.stringsdata`，更新 `scripts/generate_string_catalogs.py` 中的 `EN` 映射后重新生成 String Catalog。
