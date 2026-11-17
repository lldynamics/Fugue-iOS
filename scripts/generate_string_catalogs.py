#!/usr/bin/env python3
"""Generates iOSBox/Localizable.xcstrings and iOSBox/InfoPlist.xcstrings.

Source language is zh-Hans (the strings in code); this file holds the English translations.
Keys come from the compiler-extracted .stringsdata (see /tmp/iosbox-keys.json); the script
fails if any Chinese key lacks a translation or a translation's format specifiers differ.
"""
import json, re, sys, pathlib

EN = {
    # --- Tabs & navigation
    "对话": "Chats",
    "助手": "Assistants",
    "服务商": "Providers",
    "助手预设": "Assistants",
    "服务商与设置": "Providers & Settings",
    "数据库已重建": "Database Rebuilt",
    "知道了": "OK",
    "好": "OK",
    "确定": "OK",
    "完成": "Done",
    "取消": "Cancel",
    "关闭": "Close",
    "保存": "Save",
    "创建": "Create",
    "添加": "Add",
    "删除": "Delete",
    "编辑": "Edit",
    "复制": "Copy",
    "已复制": "Copied",
    "粘贴": "Paste",
    "已保存": "Saved",
    "继续": "Continue",
    "，": ", ",
    "、": ", ",

    # --- Protocols
    "OpenAI 兼容协议": "OpenAI-Compatible",
    "Anthropic Claude 原生": "Anthropic Claude (Native)",
    "Google Gemini 原生": "Google Gemini (Native)",
    "支持 OpenAI / DeepSeek / OpenRouter / 硅基流动 / Ollama / 各类中转站": "Works with OpenAI, DeepSeek, OpenRouter, SiliconFlow, Ollama and API relays",
    "使用 /v1/messages 接口，原生支持 Extended Thinking 与 PDF 文档": "Uses /v1/messages with native Extended Thinking and PDF support",
    "使用 streamGenerateContent 接口，原生支持多模态与思考链": "Uses streamGenerateContent with native multimodal input and thinking",

    # --- Provider templates
    "自定义 OpenAI 兼容中转站": "Custom OpenAI-Compatible Relay",
    "支持 NewAPI / OneAPI / LiteLLM / vLLM 等任意兼容接口；URL 末尾加 # 可禁用自动补全 /v1": "Any compatible API such as NewAPI, OneAPI, LiteLLM or vLLM. End the URL with # to skip adding /v1 automatically",
    "DeepSeek 深度求索": "DeepSeek",
    "官方直连，支持 DeepSeek-V3 与 DeepSeek-R1 深度思考链": "Official API with DeepSeek-V3 and DeepSeek-R1 reasoning",
    "一个 Key 聚合全球数百个主流与开源模型，支持一键拉取全部模型": "One key for hundreds of commercial and open models; fetch them all in one tap",
    "SiliconFlow 硅基流动": "SiliconFlow",
    "国内高速推理平台，聚合 DeepSeek / Qwen / GLM 等模型": "Fast inference platform hosting DeepSeek, Qwen, GLM and more",
    "OpenAI 官方接口，支持一键拉取账户可用模型": "Official OpenAI API; fetch the models available to your account",
    "Anthropic 原生 /v1/messages 协议，支持 Extended Thinking 与原版 PDF 解析": "Native Anthropic /v1/messages with Extended Thinking and native PDF input",
    "Google AI Studio 原生协议，支持多模态识图、PDF 文档及思考过程展示": "Native Google AI Studio API with image, PDF and thinking support",
    "Ollama / 局域网本地模型": "Ollama / Local Network Models",
    "连接局域网电脑运行的 Ollama / LM Studio，API Key 可留空": "Connect to Ollama or LM Studio on your local network; API key optional",

    # --- Default assistant presets
    "全能日常助手": "Everyday Assistant",
    "清晰、准确、结构化回答各类问题": "Clear, accurate, well-structured answers",
    "你是一位专业、高效的 AI 助手。请用清晰、结构化的 Markdown 格式回答问题，必要时提供代码示例或分步说明。":
        "You are a professional, efficient AI assistant. Answer in clear, well-structured Markdown, adding code examples or step-by-step explanations when helpful.",
    "资深架构与编程专家": "Senior Software Architect",
    "专注高质量代码实现、架构设计与排错": "High-quality code, architecture and debugging",
    "你是一位资深软件架构师与全栈工程师。输出代码时优先遵循现代最佳实践，处理边界条件与并发安全，简要解释核心设计思路，避免冗余套话。":
        "You are a senior software architect and full-stack engineer. Follow modern best practices, handle edge cases and concurrency safety, briefly explain key design decisions, and skip filler.",
    "深度推理分析师": "Deep Reasoning Analyst",
    "多角度拆解复杂问题、利弊权衡与决策建议": "Break down complex problems, weigh trade-offs, recommend decisions",
    "你擅长第一性原理与系统性思考。面对问题时，先拆解核心假设与关键变量，对比不同方案的优劣与适用边界，最后给出可落地的结论。":
        "You excel at first-principles and systems thinking. Start by identifying core assumptions and key variables, compare the strengths, weaknesses and limits of each option, then give an actionable conclusion.",
    "地道双语翻译官": "Bilingual Translator",
    "中英互译、母语级润色与术语对齐": "Chinese–English translation with native polish and consistent terms",
    "你是一位精通中英文母语表达的专业译者。若输入为中文则翻译为地道自然的英文；若输入为外文则翻译为流畅优雅的中文。保留专有名词与格式，并在必要时简短说明关键措辞。":
        "You are a professional translator fluent in Chinese and English. Translate Chinese input into natural, idiomatic English, and other languages into fluent, elegant Chinese. Preserve proper nouns and formatting, and briefly explain key word choices when needed.",
    "精炼写作与润色": "Writing & Editing",
    "去 AI 味，优化逻辑节奏与表达感染力": "Remove the AI tone; improve flow, rhythm and impact",
    "你是一位资深编辑与写作教练。帮用户改写或起草文本时，去除生硬的套话与翻译腔，让句式长短有致、逻辑顺畅、重点突出。":
        "You are a seasoned editor and writing coach. When rewriting or drafting text, remove stiff clichés and translationese, vary sentence length, keep the logic smooth, and make the key points stand out.",

    # --- Conversation list
    "iOSBox": "iOSBox",
    "置顶对话": "Pinned",
    "最近对话": "Recent",
    "全部对话": "All Chats",
    "搜索标题或聊天内容": "Search titles or messages",
    "并发对比": "Compare",
    "对比": "Compare",
    "新对话": "New Chat",
    "新建对话": "New Chat",
    "多模型对比": "Compare Models",
    "正在生成…": "Generating…",
    "[附件消息]": "[Attachment]",
    "点击开始对话": "Tap to start chatting",
    "置顶": "Pin",
    "取消置顶": "Unpin",
    "聚合你的所有 AI 模型": "All Your AI Models in One Place",
    "自由接入 OpenAI 兼容中转、DeepSeek、OpenRouter、Claude 与 Gemini。\n既可单聊随时切换模型，也可一键开启多模型同屏对比。":
        "Connect OpenAI-compatible relays, DeepSeek, OpenRouter, Claude and Gemini.\nSwitch models any time in a chat, or compare several side by side.",

    # --- Chat detail
    "重命名对话": "Rename Chat",
    "对话标题": "Chat title",
    "切换单聊模型": "Switch Model",
    "配置多模型并发对比": "Set Up Model Comparison",
    "系统提示词与参数": "System Prompt & Parameters",
    "清空当前消息记录": "Clear Messages",
    "更多操作": "More",
    "还没有可用的模型": "No Models Available",
    "暂时无法发送": "Can't Send Yet",
    "请先在「服务商」页面启用服务商并添加模型。你输入的内容已保留。": "Enable a provider and add models on the Providers tab first. Your message has been kept.",
    "上一条回复仍在生成或正在停止，请稍候再发送。你输入的内容已保留。": "The previous reply is still generating or stopping. Please wait a moment. Your message has been kept.",
    "去配置": "Set Up",
    "当前模型尚未填入 API Key": "This model has no API key yet",
    "前往「服务商」页面配置自有 API Key 后即可直接流式对话": "Add your own API key on the Providers tab to start chatting",
    "多模型并发对比已开启": "Model Comparison Is On",
    "开始自由 AI 对话": "Start a Conversation",
    "发送一条提问，同时请求多个服务商模型并排比对思考链与答案质量。": "Send one prompt to several models at once and compare their reasoning and answers side by side.",
    "支持随时在底部切换不同服务商的模型接力回答，也可发送图片与 PDF 文档。": "Switch to any provider's model from the bar below at any time, and send images or PDFs.",
    "帮我对比一下 Swift Actor 和传统锁的性能与适用场景": "Compare Swift actors and traditional locks in performance and use cases",
    "用通俗生动的语言解释 Transformer 的自注意力机制": "Explain Transformer self-attention in plain, vivid language",
    "帮我写一段高质量的 Python 异步并发请求模板": "Write a high-quality Python template for concurrent async requests",

    # --- Composer
    "并发对比 · %lld 模型": "Comparing · %lld models",
    "选择模型": "Choose Model",
    "退出对比": "Exit Compare",
    "从相册选择图片": "Choose from Photos",
    "拍照识图": "Take Photo",
    "上传文档或代码文件": "Upload Document or Code File",
    "添加附件": "Add Attachment",
    "从相册、相机或文件中添加图片与文档": "Add images and documents from Photos, the camera or Files",
    "输入消息，支持随时切换模型或发图…": "Message — switch models or attach images any time…",
    "停止生成": "Stop Generating",
    "发送": "Send",
    "附件提示": "Attachment",
    "读取文件失败：%@": "Couldn't read the file: %@",
    "移除附件 %@": "Remove attachment %@",
    "%@ 未标记支持识图，图片可能被忽略或导致报错。": "%@ not marked as supporting images; images may be ignored or cause an error.",
    "当前模型「%@」未标记支持识图，图片可能被忽略或导致报错（可在服务商页修改「识图」标记）。":
        "“%@” isn't marked as supporting images; images may be ignored or cause an error (change the Vision flag on the Providers tab).",

    # --- Messages
    "复制提问": "Copy Prompt",
    "查看图片 %@": "View image %@",
    "AI 助手": "AI Assistant",
    "正在连接模型生成回复…": "Connecting to the model…",
    "重试请求": "Retry",
    "使用原模型重答 (%@)": "Regenerate with Original Model (%@)",
    "使用当前顶部所选模型重答": "Regenerate with Current Model",
    "重答": "Regenerate",
    "%lld tok": "%lld tok",
    "深度思考中…": "Thinking…",
    "已深度思考": "Thought",
    "已深度思考（%@ 秒）": "Thought for %@ s",
    "已停止生成": "Generation stopped",
    "服务端返回成功，但回复内容为空": "The server responded successfully but returned no content",
    "思考过程用完了输出长度上限，未生成正文。请调大「最大输出 Tokens」或降低思考预算后重答。":
        "Thinking used up the output limit before any answer was written. Increase Max Output Tokens or lower the thinking budget, then regenerate.",
    "未找到对应的服务商配置（可能已被删除）": "Provider not found (it may have been deleted)",
    "回复生成被中断（App 已退出或在后台被系统挂起），可点击重试。": "Generation was interrupted (the app quit or was suspended in the background). Tap Retry.",
    "识图：%@": "Image: %@",
    "文档：%@": "Document: %@",

    # --- Markdown cards
    "复制代码": "Copy Code",
    "复制公式": "Copy Formula",
    "复制 LaTeX 源码": "Copy LaTeX Source",
    "公式 · LaTeX": "Formula · LaTeX",
    "公式：%@": "Formula: %@",

    # --- Arena
    "多模型并发对比 (%lld)": "Model Comparison (%lld)",
    "标签视图": "Tabs",
    "并排横滑": "Side by Side",
    "上下文主回复": "Used as Context",
    "设为上下文": "Use as Context",

    # --- Model picker
    "暂无已启用的模型": "No Enabled Models",
    "请前往底部「服务商」页面填入 API Key，一键拉取或手动添加模型": "Go to the Providers tab to add an API key, then fetch or add models",
    "勾选 2–4 个模型，发送消息时将同时并发请求并同屏对比结果。": "Select 2–4 models. Each message is sent to all of them at once and the results are shown side by side.",
    "Key 已就绪": "Key Ready",
    "未填 Key": "No Key",
    "思考": "Thinking",
    "识图": "Vision",
    "搜索模型名称或 ID": "Search model name or ID",
    "切换对话模型": "Switch Model",
    "选择并发对比模型": "Choose Models to Compare",
    "开启对比 (%lld)": "Compare (%lld)",

    # --- Chat settings / assistant editor
    "会话参数与预设": "Chat Settings",
    "一键套用助手角色": "Apply an Assistant",
    "输入系统提示词（System Prompt）…": "Enter a system prompt…",
    "系统提示词 (System Prompt)": "System Prompt",
    "对当前会话内的所有模型（含并发对比模型）生效。": "Applies to every model in this chat, including compared models.",
    "推理与深度思考": "Reasoning",
    "启用深度思考 (Thinking / R1)": "Enable Thinking (Reasoning Models)",
    "思考 Token 预算：%lld": "Thinking Budget: %lld tokens",
    "采样与上下文控制": "Sampling & Context",
    "自定义随机度 (Temperature)": "Custom Temperature",
    "Temperature": "Temperature",
    "Top P": "Top P",
    "携带上下文条数": "Context Messages",
    "默认携带上下文": "Default Context Messages",
    "全部历史": "Entire History",
    "最近 %lld 条": "Last %lld",
    "最大输出 Tokens (0=默认)": "Max Output Tokens (0 = default)",
    "0": "0",
    "新建助手预设": "New Assistant",
    "编辑助手预设": "Edit Assistant",
    "外观与名称": "Appearance & Name",
    "助手名称（例如：Swift 专家）": "Assistant name (e.g. Swift Expert)",
    "简短描述（可选）": "Short description (optional)",
    "System Prompt（系统提示词）": "System Prompt",
    "定义角色身份、输出风格与约束条件…": "Define the role, output style and constraints…",
    "默认参数": "Defaults",
    "默认开启深度思考": "Thinking On by Default",
    "新建助手": "New Assistant",
    "点击卡片可编辑提示词与采样参数，点击「对话」立即创建专属会话": "Tap a card to edit its prompt and parameters; tap Chat to start a conversation with it",

    # --- Providers list
    "API 服务商与自定义中转站": "API Providers & Custom Relays",
    "点进任意服务商可填入 API Key、修改 Base URL，并支持一键拉取 /models 模型列表或手动添加模型。":
        "Open a provider to add its API key, edit the Base URL, fetch models from /models or add models manually.",
    "支持接入的协议说明": "Supported Protocols",
    "数据与隐私安全": "Data & Privacy",
    "纯客户端本地直连": "Direct, On-Device Connections",
    "API Key 加密存储于 iOS 系统 Keychain，所有请求由手机直接发往你配置的 API 地址。": "API keys are encrypted in the iOS Keychain, and every request goes straight from your device to the API you configured.",
    "导出完整备份 (JSON)": "Export Full Backup (JSON)",
    "正在生成备份…": "Creating Backup…",
    "点击分享或保存导出的备份文件": "Share or Save the Backup File",
    "从备份文件导入": "Import from Backup",
    "正在导入…": "Importing…",
    "备份包含服务商配置、助手和全部对话（含附件），不含 API Key 与敏感请求头。导入为合并模式：已存在的项目会跳过，不会覆盖或重复。":
        "Backups include providers, assistants and all chats (with attachments), but not API keys or sensitive headers. Importing merges: existing items are skipped, never overwritten or duplicated.",
    "添加 API": "Add API",
    "无法打开文件": "Couldn't Open File",
    "导出失败": "Export Failed",
    "导入完成": "Import Complete",
    "导入失败": "Import Failed",
    "Key 已配置": "Key Set",
    "待填 Key": "Needs Key",
    "· 已启用 %lld 个模型": "· %lld models enabled",
    "%@ · %@": "%@ · %@",

    # --- Backup service
    "无法识别该文件，请选择由 iOSBox 导出的 JSON 备份。": "This file isn't recognized. Choose a JSON backup exported by iOSBox.",
    "该备份来自更新版本的 iOSBox（格式 v%lld），请先升级 App 再导入。": "This backup comes from a newer version of iOSBox (format v%lld). Update the app before importing.",
    "对话 %lld 个（消息 %lld 条）": "%lld chats (%lld messages)",
    "服务商 %lld 个": "%lld providers",
    "助手 %lld 个": "%lld assistants",
    "跳过已存在的 %lld 项": "%lld existing items skipped",
    "已导入：%@。": "Imported: %@.",

    # --- Persistence
    "已将旧数据库备份到 App 的 Application Support/%@ 目录。": "The old database was backed up to Application Support/%@ in the app's container.",
    "旧数据库备份失败。": "Backing up the old database failed.",
    "本地数据库无法打开，已为你创建新的数据库。%@": "The local database couldn't be opened, so a new one was created. %@",
    "本地数据库无法创建，本次运行的数据不会被保存。请检查设备存储空间后重启 App。": "The local database couldn't be created, so nothing will be saved this session. Check your free storage and restart the app.",

    # --- Add provider sheet
    "添加自定义 API": "Add Custom API",
    "快速选择常见模板（或自定义）": "Quick Templates (or Custom)",
    "接口协议与地址": "Protocol & Address",
    "服务商显示名称": "Display name",
    "API 协议类型": "API Protocol",
    "Base URL（如 https://api.xxx.com/v1）": "Base URL (e.g. https://api.xxx.com/v1)",
    "实际对话端点：%@": "Chat endpoint: %@",
    "粘贴 API Key（加密保存在系统钥匙串）": "Paste API key (stored encrypted in the Keychain)",
    "API Key": "API Key",
    "API Key 仅保存在本机 iOS 安全钥匙串（Keychain）中，直连目标接口，不经过任何第三方服务器。": "Your API key stays in this device's iOS Keychain and is sent only to the API you configure — never through a third-party server.",
    "初始模型（可选，创建后也可一键拉取）": "Initial Model (optional — you can fetch models later)",
    "例如：gpt-4.1 / deepseek-r1 / claude-sonnet-4-5": "e.g. gpt-4.1 / deepseek-r1 / claude-sonnet-4-5",
    "自定义服务商": "Custom Provider",
    "https://api.example.com/v1": "https://api.example.com/v1",

    # --- Provider detail
    "基础连接配置": "Connection",
    "启用该服务商": "Enable Provider",
    "服务商名称": "Provider name",
    "接口协议": "Protocol",
    "Base URL": "Base URL",
    "请求预览：%@": "Request preview: %@",
    "URL 格式待完善": "Incomplete URL",
    "输入或粘贴 API Key": "Enter or paste API key",
    "显示 API Key": "Show API Key",
    "隐藏 API Key": "Hide API Key",
    "API Key（iOS 钥匙串加密存储）": "API Key (encrypted in the iOS Keychain)",
    "支持随时修改；若使用末尾带 # 的自定义网关地址可跳过自动拼接 /v1。": "You can change it any time. End a custom gateway URL with # to skip adding /v1 automatically.",
    "••••••••（已存入钥匙串）": "•••••••• (stored in Keychain)",
    "删除请求头 %@": "Delete header %@",
    "添加自定义 HTTP Header": "Add Custom HTTP Header",
    "自定义请求头（可选）": "Custom Headers (optional)",
    "正在请求 /models 拉取可用模型…": "Fetching models from /models…",
    "一键从接口拉取模型列表 (/models)": "Fetch Model List (/models)",
    "手动添加模型 ID": "Add Model ID Manually",
    "在 %lld 个模型中搜索…": "Search %lld models…",
    "清除搜索": "Clear Search",
    "模型列表（已启用 %lld/%lld）": "Models (%lld/%lld enabled)",
    "批量操作": "Bulk Actions",
    "全部启用": "Enable All",
    "全部停用": "Disable All",
    "启用后的模型会出现在聊天框的模型切换器与多模型并发对比列表中。左滑可删除模型。": "Enabled models appear in the chat's model switcher and comparison list. Swipe left to delete a model.",
    "思考链": "Thinking",
    "模型标识": "Model Identifier",
    "模型 ID（必填，如 deepseek-reasoner）": "Model ID (required, e.g. deepseek-reasoner)",
    "显示名称（选填，留空则同 ID）": "Display name (optional, defaults to the ID)",
    "模型能力标记": "Capabilities",
    "支持图片多模态输入": "Supports Image Input",
    "支持深度思考过程展示": "Supports Thinking",
    "手动添加模型": "Add Model",
    "HTTP 请求头": "HTTP Header",
    "Header 名称（如 HTTP-Referer）": "Header name (e.g. HTTP-Referer)",
    "Header 值": "Header value",
    "敏感信息（存入钥匙串）": "Sensitive (store in Keychain)",
    "用于鉴权 Token 等敏感值：只保存在 iOS 钥匙串中，不写入本地数据库，界面上也不再显示明文。": "For auth tokens and other secrets: stored only in the iOS Keychain, never in the local database, and never shown in plain text.",
    "添加自定义 Header": "Add Custom Header",
    "接口返回成功，但未解析到可用模型，请尝试手动添加。": "The request succeeded but no models were found. Try adding models manually.",
    "成功拉取 %lld 个模型（新增 %lld 个，已自动启用前几个，可搜索按需开启）。": "Fetched %lld models (%lld new; the first few were enabled automatically — search to enable others).",
    "连接正常，共同步 %lld 个可用模型（新增 %lld 个）。": "Connection OK. Synced %lld models (%lld new).",
    "该地址使用 http:// 且指向公网：iOS 会阻止此类明文连接，API Key 与对话内容也会以明文传输。请改用 https:// 地址；局域网内的 http 服务（如 Ollama）不受影响。":
        "This address uses http:// on the public internet: iOS blocks such unencrypted connections, and your API key and messages would travel in plain text. Use an https:// address instead; http services on your local network (such as Ollama) still work.",

    # --- Errors & notices (LLMClient / adapters)
    "无效的接口地址：%@": "Invalid API address: %@",
    "请先在「服务商」页面为「%@」配置 API Key（本地服务若免鉴权可忽略）": "Add an API key for “%@” on the Providers tab first (not needed for local services without auth)",
    "服务端未返回有效内容": "The server returned no usable content",
    "回复已达到最大输出长度，内容可能不完整。可在会话参数中调大「最大输出 Tokens」后重答。": "The reply hit the max output length and may be incomplete. Increase Max Output Tokens in chat settings, then regenerate.",
    "回复被模型服务商的安全策略拦截或截断。": "The reply was blocked or cut off by the provider's safety policy.",
    "请求失败（无详细错误信息）": "Request failed (no error details)",
    "请求被服务端拒绝": "The server rejected the request",
    "提问内容被 Gemini 安全策略拦截（%@），请调整后重试。": "Your prompt was blocked by Gemini's safety policy (%@). Please rephrase and try again.",
    "[附件: %@ (%@)]": "[Attachment: %@ (%@)]",
    "--- 第 %lld 页 ---\n%@": "--- Page %lld ---\n%@",
    "%@\n\n...[文件内容较长，已截取前 %lld 个字符]...": "%@\n\n...[File truncated to the first %lld characters]...",
}

INFO_PLIST_EN = {
    "CFBundleDisplayName": "iOSBox",
    "NSCameraUsageDescription": "Used to take photos and send them to AI models for analysis.",
    "NSPhotoLibraryUsageDescription": "Used to choose images to send to AI models for analysis and Q&A.",
    "NSLocalNetworkUsageDescription": "Used to connect to model servers on your local network (such as Ollama or LM Studio). Requests go directly to the address you enter.",
}
INFO_PLIST_ZH = {
    "CFBundleDisplayName": "iOSBox",
    "NSCameraUsageDescription": "用于拍摄照片并发送给 AI 模型进行多模态分析",
    "NSPhotoLibraryUsageDescription": "用于选择图片发送给 AI 模型进行识图与问答",
    "NSLocalNetworkUsageDescription": "用于连接你在局域网内部署的模型服务（如 Ollama、LM Studio），请求直接发往你填写的地址。",
}

CJK = re.compile(r"[\u4e00-\u9fff\u3000-\u303f\uff00-\uffef]")
SPEC = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|lf|f)")


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def build_catalog(keys):
    strings, problems = {}, []
    for key in keys:
        if key in EN:
            en = EN[key]
        elif not CJK.search(key):
            en = key  # format-only / English / URL keys are identical
        else:
            problems.append(f"missing translation: {key!r}")
            continue
        if sorted(SPEC.findall(key)) != sorted(SPEC.findall(en)):
            problems.append(f"format mismatch: {key!r} -> {en!r}")
        # Explicit zh-Hans entries make Xcode emit zh-Hans.lproj/Localizable.strings. Without
        # it, iOS (development region = en) would fall back to the English table for Chinese
        # users instead of using the source keys.
        strings[key] = {"localizations": {"en": unit(en), "zh-Hans": unit(key)}}
    unused = sorted(set(EN) - set(keys))
    return strings, problems, unused


def main():
    root = pathlib.Path(sys.argv[1])
    keys = json.load(open(sys.argv[2]))
    strings, problems, unused = build_catalog(keys)
    if problems:
        print("\n".join(problems))
        sys.exit(1)
    if unused:
        print("note: translations not used by code:", unused)
    catalog = {"sourceLanguage": "zh-Hans", "strings": strings, "version": "1.0"}
    (root / "Localizable.xcstrings").write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n")

    info = {
        "sourceLanguage": "zh-Hans",
        "strings": {
            k: {"localizations": {"en": unit(INFO_PLIST_EN[k]), "zh-Hans": unit(INFO_PLIST_ZH[k])}}
            for k in INFO_PLIST_EN
        },
        "version": "1.0",
    }
    (root / "InfoPlist.xcstrings").write_text(json.dumps(info, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    print(f"wrote {len(strings)} strings")


if __name__ == "__main__":
    main()
