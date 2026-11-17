# iOSBox

原生 iOS（Swift + SwiftUI + SwiftData）多模型聚合与自定义 API（BYOK）AI 对话客户端。

## 核心特性

1. **三大原生协议全覆盖 + 自由添加 API**
   - **OpenAI 兼容协议**：支持自定义 `Base URL` 与 `API Key`，通吃 OpenAI、DeepSeek、OpenRouter、SiliconFlow 硅基流动、OneAPI / NewAPI 中转站、Ollama 局域网本地模型等。
   - **Anthropic Claude 原生协议**：使用 `/v1/messages`，原生支持 Extended Thinking 思考链与原版 PDF 文档输入。
   - **Google Gemini 原生协议**：使用 `:streamGenerateContent?alt=sse`，原生支持多模态图像、PDF 文档及思考过程。
   - **智能端点解析**：自动处理 `/v1` 补全与多版本路径（如 `/v4`、`/v1beta`）；在 `Base URL` 末尾添加 `#` 可强制使用原始路径不补全 `/v1`。
   - **自定义 HTTP Header**：支持为网关追加鉴权或路由请求头。

2. **单聊随时切换 + 多模型同屏并发对比（Arena 模式）**
   - **单聊模式**：同一段对话中可随时切换不同服务商、不同协议的模型接力回答，自动完成跨协议上下文转换。
   - **多模型并发对比**：一次提问同时并发请求 2–4 个模型，支持**标签切换**与**并排横滑卡片**两种对比视图，并可一键指定某条回复作为后续追问的上下文主回复。

3. **一键拉取 `/models` + 手动模型管理**
   - 在服务商详情页点击「一键从接口拉取模型列表」即可自动同步可用模型，支持搜索过滤、批量启停及手动增删模型 ID。

4. **推理思考过程折叠展示**
   - 原生解析 `reasoning_content`、Anthropic `thinking_delta`、Gemini `thought` 以及流式 `<think>...</think>` 标签，实时统计思考耗时并支持折叠/展开。

5. **多模态输入与助手预设库**
   - 支持**相机拍照**、**相册多图选择**（自动压缩适配接口体积）、**PDF 与代码/文本文件附件**（内置 `PDFKit` 文本提取兜底 + 原生 PDF 块双模适配）。
   - 内置常用 System Prompt 助手角色库，支持自定义创建角色及调节 `Temperature`、`Top P`、上下文携带条数与思考 Token 预算。

6. **纯本地直连与隐私安全**
   - 无任何第三方后端中转，API Key 加密保存在 iOS 系统安全钥匙串（**Keychain**）中，对话与配置保存在本地 **SwiftData** 数据库，支持一键导出 JSON 备份。
   - 自定义请求头可标记为「敏感信息」，其值同样只存入钥匙串，不写入数据库。
   - 公网接口必须使用 `https://`；`http://` 明文仅允许局域网 / 本机地址（如 Ollama、LM Studio）。

## 运行方式

1. 使用 Xcode 打开工程文件：`iOSBox.xcodeproj`
2. 选择 iPhone 模拟器或连接真机（真机运行需在 `Signing & Capabilities` 中选择你的个人 Apple ID Team）
3. 按 `Cmd + R` 编译运行
4. 进入底部「服务商」页面填入你的 API Key 或添加自定义 API 地址，即可开始流式对话
