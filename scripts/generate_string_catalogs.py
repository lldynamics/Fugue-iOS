#!/usr/bin/env python3
"""Generates iOSBox/Localizable.xcstrings and iOSBox/InfoPlist.xcstrings.

Source language is zh-Hans (the strings in code); this file holds the English translations.
Keys come from the compiler-extracted .stringsdata (see /tmp/iosbox-keys.json); the script
fails if any Chinese key lacks a translation or a translation's format specifiers differ.
"""
import json, re, sys, pathlib

EN = {
    "个人对话：%@。群聊：%@。群内回复可能提到后续情节。": "Personal chat: %@. Group chat: %@. Group replies may reveal later events.",
    "以下服务商的连接或请求头与备份不一致，请在服务商设置中核对并重新填写凭据：%@。": "Review the connection and re-enter credentials in Providers for these accounts with mismatched endpoints or headers: %@.",
    "使用群内阅读进度？": "Use the group’s reading progress?",
    "保留原文件并新建空卡库？": "Keep the original file and start an empty card library?",
    "保留损坏副本并重建卡库": "Keep a copy and rebuild the card library",
    "原文件将另存为副本。重建后可重新导入备份中的闪卡。": "A copy of the original file will be kept. After rebuilding, you can import flashcards from a backup.",
    "备份需继续处理": "Backup needs attention",
    "当前数据库无法持久保存。请检查设备存储空间，重启后再导入备份。": "This database can’t save changes permanently. Check your device storage, restart the app, then import the backup again.",
    "按此进度邀请": "Invite with this reading progress",
    "无法读取闪卡库。请解锁设备并重试。": "The card library couldn’t be read. Unlock your device and try again.",
    "有 %lld 项凭据未能存入钥匙串。请解锁设备后重新导入此备份。": "Keychain couldn’t save %lld credentials. Unlock your device and import this backup again.",
    "正在搜索…": "Searching…",
    "群内阅读进度较远，请先确认本次邀请的范围。": "The group has read further. Confirm the reading range for this invitation.",
    "配置 API 与模型": "Set up an API and model",
    "重建卡库": "Rebuild card library",
    "重新读取": "Read again",
    "闪卡库文件损坏，原文件已保留。可在学习卡包中保留副本并重建卡库。": "The card library is damaged. The original file is intact. In Study Cards, you can keep a copy and rebuild the library.",
    "闪卡未能保存。请检查设备存储空间后重试。": "The flashcards couldn’t be saved. Check your device storage and try again.",
    "闪卡未能保存。请检查闪卡库和设备存储，再重新导入此备份。": "Flashcards couldn’t be saved. Check your card library and device storage, then import this backup again.",
    "请选择用于本次对话的已启用模型。": "Choose an enabled model for this chat.",
    "已确认 %lld 项凭据保存在钥匙串中。": "Confirmed %lld credentials in Keychain.",
    "尚未配置可用的 API": "No API configured for chat",
    "请在「服务商」中配置 API 连接并启用模型。": "Configure an API connection and enable a model in Providers.",
    "暂无可选模型，请刷新列表或在「服务商」中启用模型。": "Refresh the list or enable a model in Providers.",
    "刷新模型列表": "Refresh model list",
    "刷新失败，显示已保存的模型。": "Refresh failed. Showing saved models.",
    "已移出可选列表，可手动启用": "No longer listed by the API. Enable manually to use it.",
    "DeepSeek 官方接口，支持对话和深度思考。": "The official DeepSeek API supports chat and reasoning.",
    "从接口获取模型": "Fetch models from API",
    "内置参考模型": "Built-in suggestions",
    "初始模型（可选）": "Initial model (optional)",
    "填写连接信息后可获取当前接口提供的模型。也可以直接输入模型 ID。": "Enter your connection details to fetch models from this API, or enter a model ID directly.",
    "已配置的模型": "Configured models",
    "手动输入模型 ID": "Enter a model ID manually",
    "可从接口获取模型，或返回手动输入模型 ID。": "Fetch models from the API, or go back to enter a model ID.",
    "没有匹配的模型": "No matching models",
    "接口返回的模型": "Models from API",
    "正在获取模型…": "Fetching models…",
    "《%@》读书群": "%@ Book Club",
    "书籍操作": "Book actions",
    "从好友选择": "Choose from friends",
    "从该章另开对话": "Start a new chat at this chapter",
    "候选人物": "Suggested characters",
    "先在「书中好友」导入书籍并创建一个人物。": "Import a book and create a character in Book Friends first.",
    "创建读书群": "Create a book club",
    "只带入人物和原书资料。群聊单独保存阅读进度和聊天记录。": "Only the character and source book are used. The group keeps its own reading progress and chat history.",
    "只应用发言规则": "Apply speaking rules only",
    "好友操作": "Friend actions",
    "如何套用这个模板？": "How would you like to apply this template?",
    "已在群中": "Already in group",
    "新建": "New",
    "普通对话": "Regular chat",
    "更新阅读进度": "Update reading progress",
    "替换将移除当前成员及其人物资料。保存群设置后生效。": "Replacing the roster removes existing members and their character materials when you save the group.",
    "替换群成员与设置": "Replace members and settings",
    "本群中来自这本书的好友共用此阅读进度。": "Friends from this book share this reading limit in this group.",
    "本群已有六位成员。": "This group already has six members.",
    "模型待连接": "Model needs setup",
    "群成员已满": "Group is full",
    "请先连接一个可用模型。": "Connect a model first.",
    "读至%@": "Read through %@",
    "读至第 %lld 节": "Read through section %lld",
    "调整阅读进度": "Change reading progress",
    "较晚章节可能已出现在原聊天。新对话将从空白记录开始，原聊天会保留。": "Later chapters may appear in the original chat. The new chat starts empty, and the original is kept.",
    "这位好友已经在本群。": "This friend is already in the group.",
    "连接后将继续选择群成员。": "After connecting, you’ll continue choosing group members.",
    "邀请到已有群聊": "Invite to an existing group",
    "邀请进群": "Invite to group",
    "群成员或阅读进度已更新，请重新打开群设置。": "Members or reading progress changed. Reopen group settings to load the changes.",
    # --- Book friends and local bookshelf
    "%@ · 书中角色 AI": "%@ · AI book character",
    "书中好友": "Book Friends",
    "书籍": "Book",
    "书籍 %lld 本": "%lld books",
    "书籍文件最大为 64 MB。": "Book files can be up to 64 MB.",
    "从书中创建好友": "Create a friend from a book",
    "从书架移除": "Remove from bookshelf",
    "从书架移除这本书？": "Remove this book from the bookshelf?",
    "从文件导入书籍": "Import a book from Files",
    "你好，可以讲讲你的故事吗？": "Hello! Would you tell me a little about your story?",
    "全书": "Entire book",
    "其他称呼（可选）": "Other names (optional)",
    "创建书中好友": "Create a book friend",
    "可用逗号分隔别名。选定阅读进度后，只从该章及之前的正文查找人物。": "Separate other names with commas. Reading progress limits the search to that chapter and the chapters before it.",
    "和《%@》中的%@聊聊天。": "From “%@” · Chat with %@.",
    "开始对话": "Start conversation",
    "当前数据库无法保存书籍或好友。": "This database can’t save books or book friends right now.",
    "我的书架": "My bookshelf",
    "所选章节中没找到这个人物。请核对书里的名字、补充别名或调整阅读进度。": "This character wasn’t found within your reading progress. Check the name used in the book, add an alias, or select another chapter.",
    "找不到这本书，请到「书中好友」重新导入同一版本。": "This book is missing. Import the same edition again in Book Friends.",
    "找到的人物片段": "Passages featuring this character",
    "支持 EPUB、TXT、Markdown 和带文字的 PDF。正文保存在本机，也会随完整备份导出。": "Choose an EPUB, TXT, Markdown, or text-based PDF. The text stays on this device and is included in full backups.",
    "无法读取这本书的目录或正文。": "Couldn’t read this book’s structure or text.",
    "最多填写 8 个别名，每个不超过 60 个字符。": "Enter up to eight other names of up to 60 characters each.",
    "本卷正文过长，请将书籍分卷后导入。": "This volume’s text is too long. Split it into smaller volumes and import them separately.",
    "本次参考 · 《%@》": "Source passages · %@",
    "本次操作可能发送消息、选用的历史上下文、引用、附件和系统提示词。启用个人记忆时，也会发送适用的记忆。圆桌人物的参考片段会发送给其绑定的模型。与书中好友聊天时，会附上本次选取的原书片段。": "This action may send messages, selected history, quotes, attachments, and system instructions. Applicable personal memories are included when enabled. A roundtable persona’s writing samples go to its assigned model. Book friend chats include the passages selected for this reply.",
    "查找人物": "Find character",
    "正在读取书中资料…": "Reading the book…",
    "正文": "Main text",
    "没有找到可读正文。扫描版 PDF 可以先做文字识别。": "No readable text was found. For a scanned PDF, run text recognition first.",
    "第 %lld 节": "Section %lld",
    "第 %lld 页": "Page %lld",
    "聊天时按话题选取最多三段原文，随消息发送给对话所用的模型。": "Up to three passages are selected for the topic and sent to the model with your message.",
    "角色姓名": "Character name",
    "请填写书中的人物姓名，最多 60 个字符。": "Enter the character’s name as it appears in the book, up to 60 characters.",
    "请选择 EPUB、TXT、Markdown 或带文字的 PDF 文件。": "Choose an EPUB, TXT, Markdown, or text-based PDF file.",
    "已有聊天记录和引用会保留。继续与这本书的好友聊天时，需要重新导入同一版本。": "Chat history and quoted passages will be kept. Import the same edition again to continue chatting with its characters.",
    "这本书的正文受保护，请选择可以直接读取文字的文件。": "The book’s text is protected. Choose a file with readable text.",
    "选择一本书": "Select a book",
    "遇到难以决定的事时，你会怎么做？": "What do you do when you face a difficult choice?",
    "阅读进度": "Reading progress",

    # --- Roundtable persona sources and updates
    "不可用 · %@": "Unavailable · %@",
    "%@ · AI 模拟": "%@ · AI simulation",
    "%@ · 订阅动态": "%@ · Source update",
    "%@的聊天记录": "Chat excerpts from %@",
    "%lld / 4000": "%lld / 4000",
    "X API Bearer Token": "X API Bearer Token",
    "X 接口返回 HTTP %lld，请检查读取权限、账户额度或稍后再试。": "X returned HTTP %lld. Check your read access and API credits, or try again later.",
    "X 用户名或个人主页": "X username or profile URL",
    "X 读取权限": "X read access",
    "上次检查 %@": "Last checked %@",
    "人物资料与动态": "Persona sources & updates",
    "从文件选择": "Choose a file",
    "使用你自己的 X API 读取额度。凭据立即保存到本机钥匙串，供此设备上的 X 订阅共用。": "X subscriptions use your own API credits. The credential is saved immediately to this device’s Keychain and shared by its X subscriptions.",
    "保存读取凭据": "Save read credential",
    "内容较长，已选取前 4,000 个字符。可在保存前编辑。": "The first 4,000 characters are selected. Edit the excerpt before saving.",
    "博客": "Blog",
    "博客主页或 RSS / Atom 地址": "Blog homepage or RSS / Atom URL",
    "博客文章": "Blog article",
    "参考片段": "Reference excerpt",
    "发言人名字": "Speaker’s name",
    "发言参考": "Writing samples",
    "只提取这位发言人的消息。支持「姓名：内容」或带发言人和正文的 JSON 记录。": "Only this speaker’s messages are extracted. Use “Name: message” lines or a JSON export with author and text fields.",
    "导入参考资料": "Import a writing sample",
    "已检查 %lld 个订阅，新增 %lld 条动态。": "Checked %lld subscriptions and added %lld updates.",
    "已添加这个订阅。": "This subscription is already on the list.",
    "待导入文字": "Text to import",
    "成员订阅动态": "Member source updates",
    "打开原文": "Open original",
    "支持 TXT、Markdown 和 JSON，文件最大 2 MB。": "Choose a TXT, Markdown, or JSON file up to 2 MB.",
    "文字": "Text",
    "文章或博客主页的 HTTPS 地址": "HTTPS URL of an article or blog homepage",
    "从博客订阅挑选文章": "Choose an article from the blog feed",
    "订阅里还没有可选的文章。": "The feed has no articles to choose from yet.",
    "无法更新人物设置": "Couldn’t update persona settings",
    "无法更新钥匙串，请重试。": "Couldn’t update the Keychain. Try again.",
    "替换读取凭据": "Replace read credential",
    "最多 6 份。发言时，相关片段会发送给这位成员绑定的模型。群内发言标注为 AI 模拟，资料随对话备份导出。": "Add up to six samples. Relevant excerpts go to this member’s assigned model when it speaks. Its replies are labeled as AI simulations. Samples are included in chat backups.",
    "未找到可读取的 RSS 或 Atom 订阅，请填写博客公布的订阅地址。": "No readable RSS or Atom feed was found. Enter the feed URL provided by the blog.",
    "核对参考资料": "Review writing sample",
    "检查成员动态": "Check member updates",
    "没有可导入的文字。": "No text was found to import.",
    "没有待检查的订阅。": "No subscriptions are due for a check.",
    "没有找到此人的发言。请核对名字和聊天记录格式。": "No messages matched this speaker. Check the name and chat export format.",
    "添加订阅": "Add subscription",
    "移除读取凭据": "Remove read credential",
    "等待首次检查": "Awaiting first check",
    "粘贴文字或选择文件": "Paste text or choose a file",
    "群聊设置保存失败": "Couldn’t save group settings",
    "聊天记录": "Chat log",
    "自动分享到本群": "Share new posts to this group",
    "订阅类型": "Subscription type",
    "请填写有效的 X 用户名或个人主页地址。": "Enter a valid X username or profile URL.",
    "请输入记录中这位发言人的名字。": "Enter the speaker’s name as it appears in the chat log.",
    "请选择不超过 2 MB 的文本文件。": "Choose a text file no larger than 2 MB.",
    "读取 X 动态需要在人物资料中保存有读取权限的 X API Bearer Token。": "To read X updates, save an X API bearer token with read access in persona settings.",
    "资料名称": "Sample title",
    "资料来源": "Sample source",
    "部分订阅正在检查或群内正在发言，稍后可再检查。": "Some subscriptions are already being checked or the group is generating replies. Check again later.",
    "重新选取内容": "Choose content again",
    "预览提取结果": "Preview excerpt",
    "首次检查只记录现有内容。之后的新动态会附原文链接发进本群。iOS 决定后台检查时间，也可从群聊菜单手动检查。": "The first check records existing posts. Later posts appear in this group with a link to the original. iOS schedules background checks. You can also check from the group menu.",
    "首次检查已记录现有内容，之后只分享新动态。": "The first check recorded existing posts. New posts will appear here.",

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
    "夜奔": "Fugue",
    "置顶对话": "Pinned",
    "最近对话": "Recent",
    "全部对话": "All Chats",
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
    "无法识别该文件，请选择由「夜奔」导出的 JSON 备份。": "This file isn't recognized. Choose a JSON backup exported by Fugue.",
    "该备份来自更新版本的「夜奔」（格式 v%lld），请先升级 App 再导入。": "This backup comes from a newer version of Fugue (format v%lld). Update the app before importing.",
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

EN.update({'备份包含冲突的标识，未导入任何数据。': 'The backup contains conflicting IDs. No data was imported.', '连接提前结束，回复可能不完整，请重试。': 'The connection ended early. The reply may be incomplete. Please retry.', '保存失败，请保留输入并重试。': 'Save failed. Keep your input and retry.', '草稿保存失败': 'Unable to save draft', '重试': 'Retry', '无法读取图片，或图片超过 20 MB 限制。': 'Unable to read the image, or it exceeds the 20 MB limit.', '附件超出限制：单文件最多 20 MB，每次最多 8 个附件，总内容最多 32 MB。': 'Attachment limit exceeded: 20 MB per file, 8 attachments per message, 32 MB total content.'})

EN.update({'流式响应格式无效，回复可能不完整。': 'Invalid streaming response. The reply may be incomplete.', '正在处理附件': 'Processing attachments', '删除失败': 'Unable to delete', '…[PDF 内容较长，仅提取前 200 页、最多 80000 个字符]…': '…[Long PDF: extracted only the first 200 pages, up to 80000 characters]…'})

# Phase 1: synthesis, request metrics and pricing.
EN.update({'全部': 'All',
 '单价': 'Pricing',
 '原答案已更新，此汇总已过期，不会用于后续上下文。请重新汇总。': 'The source answers changed. This synthesis is outdated and excluded from '
                                   'follow-up context. Generate a new synthesis.',
 '失败': 'Failed',
 '完整完成': 'Completed successfully',
 '将原问题、相关上下文及 %lld 条完整答案发送给所选裁判，产生一次额外请求。失败、取消和截断的答案不参与。': 'The original question, relevant context and %lld complete answers will '
                                                     'be sent to the selected judge in an additional '
                                                     'request. Failed, cancelled and truncated answers are '
                                                     'excluded.',
 '尝试次数': 'Attempt',
 '已中断': 'Interrupted',
 '已取消': 'Cancelled',
 '已完成': 'Completed',
 '已完成 %lld/%lld · 速度样本 %lld': 'Completed %lld/%lld · Speed samples %lld',
 '币种': 'Currency',
 '开始汇总': 'Synthesize',
 '总耗时': 'Total time',
 '按服务商、模型和请求类型分组。首段包含思考；正文为首个正文片段。速度仅统计完整流式回复，用 API 返回的输出 Token 除以首末输出间隔，可能包含思考 Token。不同提示词和输入长度会影响结果。': 'Grouped '
                                                                                                         'by '
                                                                                                         'provider, '
                                                                                                         'model '
                                                                                                         'and '
                                                                                                         'request '
                                                                                                         'type. '
                                                                                                         'First '
                                                                                                         'output '
                                                                                                         'includes '
                                                                                                         'reasoning; '
                                                                                                         'first '
                                                                                                         'answer '
                                                                                                         'measures '
                                                                                                         'answer '
                                                                                                         'text. '
                                                                                                         'Speed '
                                                                                                         'uses '
                                                                                                         'only '
                                                                                                         'completed '
                                                                                                         'streams: '
                                                                                                         'API-reported '
                                                                                                         'output '
                                                                                                         'tokens '
                                                                                                         'divided '
                                                                                                         'by '
                                                                                                         'the '
                                                                                                         'interval '
                                                                                                         'between '
                                                                                                         'first '
                                                                                                         'and '
                                                                                                         'last '
                                                                                                         'output, '
                                                                                                         'possibly '
                                                                                                         'including '
                                                                                                         'reasoning '
                                                                                                         'tokens. '
                                                                                                         'Prompts '
                                                                                                         'and '
                                                                                                         'input '
                                                                                                         'lengths '
                                                                                                         'affect '
                                                                                                         'results.',
 '按服务商返回用量估算，不含缓存折扣、阶梯价格和额外收费。': 'Estimated from provider-reported usage; excludes cache discounts, tiered '
                                 'pricing and extra charges.',
 '按服务商返回用量估算，不含缓存折扣、阶梯价格和额外收费。单价只影响新请求，清空两项可停止计价。': 'Estimated from provider-reported usage; excludes cache '
                                                    'discounts, tiered pricing and extra charges. Prices '
                                                    'apply only to new requests. Clear both fields to stop '
                                                    'pricing.',
 '按请求开始时间归入本地日期。费用采用请求当时的单价，不合并不同币种；可在服务商的模型列表设置单价。': 'Requests are grouped by their start time in your '
                                                      'local time zone. Costs use the price saved when each '
                                                      'request started. Currencies are kept separate. Set '
                                                      'prices in the provider’s model list.',
 '显示更多': 'Show More',
 '暂无请求记录': 'No requests yet',
 '服务商返回了非流式结果，不计算输出速率。': 'The provider returned a non-streaming response; output speed is unavailable.',
 '未发出': 'Not sent',
 '未找到原始问题，无法汇总。': 'The original question could not be found. Synthesis is unavailable.',
 '未设置': 'Not set',
 '未返回': 'Not reported',
 '模型': 'Model',
 '模型已被删除或停用，请重新选择。': 'The model was removed or disabled. Select another model.',
 '模型已被删除，请关闭后重试。': 'The model was removed. Close this sheet and try again.',
 '模型计价': 'Model Pricing',
 '正文 %@': 'Answer %@',
 '每百万输入 Token 单价': 'Price per million input tokens',
 '每百万输出 Token 单价': 'Price per million output tokens',
 '汇总 · %@': 'Synthesis · %@',
 '汇总会列出共识、分歧和待核实项。模型意见一致不代表事实已经核实。': 'The synthesis lists consensus, disagreements and claims needing '
                                     'verification. Agreement between models is not fact verification.',
 '测速榜（中位数）': 'Speed Ranking (Median)',
 '状态': 'Status',
 '用量': 'Usage',
 '用量与测速': 'Usage & Speed',
 '用量与预估费用': 'Usage & Estimated Cost',
 '用量或单价不完整，费用未知。': 'Usage or pricing is incomplete. Cost is unknown.',
 '由裁判模型综合提炼': 'Synthesize with a Judge Model',
 '类型': 'Type',
 '统计周期': 'Period',
 '缺少用量或单价：%lld 次（不按零费用计算）': 'Missing usage or pricing: %lld requests (not counted as free)',
 '耗时与用量': 'Timing & Usage',
 '至少需要两条完整答案才能汇总。': 'At least two complete answers are required for synthesis.',
 '裁判汇总': 'Judge Synthesis',
 '设置单价': 'Set Prices',
 '请同时填写两个非负单价，或同时留空。': 'Enter both nonnegative prices, or leave both empty.',
 '请求': 'Request',
 '请求时的计价': 'Price at Request Time',
 '请求明细': 'Request History',
 '请求次数': 'Requests',
 '请求详情': 'Request Details',
 '请等待当前生成结束后重试。': 'Wait for the current generation to finish, then try again.',
 '输入 Token': 'Input Tokens',
 '输出 Token': 'Output Tokens',
 '输出不完整': 'Incomplete',
 '输出速率（估算）': 'Output Speed (Approx.)',
 '进行中': 'In Progress',
 '选择裁判模型': 'Choose Judge Model',
 '预估费用': 'Estimated Cost',
 '首段 %@': 'First output %@',
 '首段思考': 'First Reasoning',
 '首段正文': 'First Answer',
 '首段输出': 'First Output',
 '按日': 'Daily',
 '按月': 'Monthly',
 '统计日期': 'Reference Date',
 '已知输入 Token': 'Reported Input Tokens',
 '已知输出 Token': 'Reported Output Tokens',
 '暂无可计价记录': 'No priced requests yet'})

EN.update({"裁判模型": "Judge Model"})

# Phase 2: system sharing, reading and App Intents
EN["请描述并分析这张图片。"] = "Describe and analyze this image."
EN["部分分享结果尚未导入，将在下次打开时重试。"] = "Some shared results could not be imported. Fugue will retry the next time you open it."
EN.update({'%lld 个字符': '%lld characters',
 'AI 模型': 'AI Model',
 '停止并关闭': 'Stop and Close',
 '允许系统分享使用此服务商': 'Allow this provider in Share',
 '共享空间不可用，请检查主 App 与分享扩展的 App Group 签名配置。': 'Shared storage is unavailable. Check the App Group signing configuration for the app and '
                                            'Share extension.',
 '共享钥匙串不可用，请解锁设备并在主 App 中重新启用系统分享。': 'The shared Keychain is unavailable. Unlock your device and enable sharing again in Fugue.',
 '关闭后可在「夜奔」的对话和用量中查看。': 'After closing, find the result in Chats and Usage in Fugue.',
 '内容较长，仅发送前 60000 个字符。': 'This content is long. Only the first 60,000 characters will be sent.',
 '分享与精读': 'Share & Read',
 '分享处理已超时，已保留收到的内容。可回到「夜奔」查看并重答。': 'Share processing timed out. Received content was saved; open Fugue to review it and retry.',
 '分享处理被系统中断，已保留收到的内容。': 'Share processing was interrupted by the system. Received content was preserved.',
 '分享精读': 'Shared Reading',
 '分享结果': 'Share Result',
 '分析图片': 'Analyze Image',
 '发送内容预览': 'Content to Send',
 '向 ${model} 询问 ${question}': 'Ask ${model} about ${question}',
 '启用后，分享扩展可读取此服务商的模型配置与共享钥匙串中的凭据。关闭后新的分享请求将无法使用它，已发出的请求不受影响。': 'Allows the Share extension to read this provider’s models and credentials '
                                                               'in the shared Keychain. Turning this off prevents new share requests; '
                                                               'requests already sent are unaffected.',
 '回复过长，已停止并保留收到的内容。': 'The response is too long. Generation stopped and received content was preserved.',
 '图片': 'Image',
 '处理方式': 'Action',
 '处理结果': 'Result',
 '将问题发送给你配置的模型并返回文字结果；较长请求可转入「夜奔」继续。': 'Send a question to a configured model and return its text answer. Continue longer requests in '
                                           'Fugue.',
 '开始处理': 'Start',
 '快捷指令': 'Shortcuts',
 '总结': 'Summarize',
 '所选模型未启用识图能力，请选择支持图片的模型。': 'Image support is disabled for this model. Choose a model that supports images.',
 '接收截图或照片，发送给指定的视觉模型并返回分析结果。': 'Send a screenshot or photo to a selected vision model and return its analysis.',
 '操作': 'Action',
 '无法处理分享': 'Unable to Process Share',
 '未提取到正文。网页可能需要登录或 JavaScript，可在 Safari 选中文字后分享。': 'No readable text was found. The page may require sign-in or JavaScript. Try selecting '
                                                   'text in Safari and sharing it.',
 '模型仍在生成，请在「夜奔」中继续。': 'The model is still generating. Continue in Fugue.',
 '正在读取分享内容…': 'Reading shared content…',
 '正在读取网页…': 'Reading webpage…',
 '没有可用模型，请先在「夜奔」的服务商设置中启用模型与系统分享。': 'No models are available. Enable models and system sharing in Fugue provider settings.',
 '用 ${applicationName} 分析图片': 'Analyze an image with ${applicationName}',
 '用 ${applicationName} 提问': 'Ask with ${applicationName}',
 '用 ${model} 分析 ${image}': 'Analyze ${image} with ${model}',
 '目标语言': 'Target Language',
 '简体中文': 'Simplified Chinese',
 '系统分享': 'System Sharing',
 '结果保存失败，请保留当前窗口并重试。': 'The result could not be saved. Keep this window open and retry.',
 '网页精读': 'Read Webpage',
 '网页精读仅支持不含账号密码的公开 HTTPS 链接。': 'Web reading supports public HTTPS links without embedded credentials.',
 '网页读取失败（HTTP %lld）。': 'Unable to read the webpage (HTTP %lld).',
 '网页超过 2 MB，无法在分享窗口中读取。请改为分享选中的文字。': 'The webpage exceeds 2 MB. Share selected text instead.',
 '网页链接（可选）': 'Webpage URL (Optional)',
 '翻译': 'Translate',
 '询问指定模型': 'Ask a Model',
 '询问模型': 'Ask Model',
 '该链接不是 HTML 或纯文本网页。PDF 请在 App 中作为附件发送。': 'This URL is not an HTML or plain-text page. Send PDFs as attachments in the app.',
 '请将以下内容翻译为%@：': 'Translate the following content into %@:',
 '请总结以下内容：': 'Summarize the following content:',
 '请提供文字、网页链接或有效图片。': 'Provide text, a webpage URL, or a valid image.',
 '请求已中止，已收到的内容保存在「夜奔」对话中。': 'The request stopped. Received content is saved in Fugue Chats.',
 '请求耗时过长，已保留部分结果，请在对话中重答。': 'The request took too long. Partial results were saved; retry from the conversation.',
 '读取公开网页，不使用浏览器登录状态。读取失败时可直接粘贴或分享正文。': 'Reads public webpages without your browser sign-in. If reading fails, paste or share the page '
                                       'text.',
 '读取网页正文': 'Read Page Text',
 '重试保存': 'Retry Saving',
 '问题': 'Question',
 '预览中的内容将发送给所选服务商，可能产生 API 费用。结果与用量保存在「夜奔」；模型总结不等于事实核查。': 'The previewed content will be sent to the selected provider and may incur '
                                                             'API costs. Results and usage are saved in Fugue. Model summaries are not '
                                                             'fact checks.'})

# Phase 3: personal memory, routing, fallback and web search.
EN.update({'Tavily 控制台': 'Tavily Dashboard',
 '个人长期记忆': 'Personal Memory',
 '个性化与联网': 'Personalization & Search',
 '仅单聊生效，最多 3 个备用模型。尚未收到正文或思考时，HTTP 429/502/503/504 或网络超时会按顺序切换；已输出、鉴权错误、内容拦截和取消不会切换。上下文及启用的记忆会发给备用服务商，每次尝试独立记账。': 'Single '
                                                                                                                  'chat '
                                                                                                                  'only, '
                                                                                                                  'with '
                                                                                                                  'up '
                                                                                                                  'to '
                                                                                                                  '3 '
                                                                                                                  'backup '
                                                                                                                  'models. '
                                                                                                                  'Before '
                                                                                                                  'any '
                                                                                                                  'text '
                                                                                                                  'or '
                                                                                                                  'reasoning '
                                                                                                                  'arrives, '
                                                                                                                  'HTTP '
                                                                                                                  '429/502/503/504 '
                                                                                                                  'or '
                                                                                                                  'a '
                                                                                                                  'network '
                                                                                                                  'timeout '
                                                                                                                  'tries '
                                                                                                                  'backups '
                                                                                                                  'in '
                                                                                                                  'order. '
                                                                                                                  'Partial '
                                                                                                                  'output, '
                                                                                                                  'authentication '
                                                                                                                  'errors, '
                                                                                                                  'content '
                                                                                                                  'filtering '
                                                                                                                  'and '
                                                                                                                  'cancellation '
                                                                                                                  'never '
                                                                                                                  'trigger '
                                                                                                                  'a '
                                                                                                                  'switch. '
                                                                                                                  'Context '
                                                                                                                  'and '
                                                                                                                  'enabled '
                                                                                                                  'memories '
                                                                                                                  'are '
                                                                                                                  'sent '
                                                                                                                  'to '
                                                                                                                  'the '
                                                                                                                  'backup '
                                                                                                                  'provider; '
                                                                                                                  'every '
                                                                                                                  'attempt '
                                                                                                                  'is '
                                                                                                                  'recorded '
                                                                                                                  'separately.',
 '仅用于单聊新消息。图片优先；含 Markdown 代码围栏或代码文件时使用代码模型。其余输入使用当前模型。未配置图片模型时会检查当前模型的识图能力；指定模型不可用时保留输入并提示。': 'For new messages in '
                                                                                               'single chat. Images '
                                                                                               'take priority; fenced '
                                                                                               'Markdown code or code '
                                                                                               'files use the code '
                                                                                               'model. Other input '
                                                                                               'uses the current '
                                                                                               'model. Without an '
                                                                                               'image model, the '
                                                                                               'current model must '
                                                                                               'support vision. If a '
                                                                                               'selected model is '
                                                                                               'unavailable, your '
                                                                                               'input is kept.',
 '代码模型': 'Code Model',
 '使用个人记忆': 'Use Personal Memory',
 '使用当前模型': 'Use Current Model',
 '例如：我使用 Swift，偏好简体中文回答。': 'For example: I use Swift and prefer answers in English.',
 '发送前打开「联网搜索」并确认搜索词。只把该搜索词发给 Tavily，不发送记忆、附件或聊天历史；来源摘要会发给回答模型。搜索可能消耗 Tavily 额度，费用不计入模型 Token 费用。': 'Enable Web Search '
                                                                                                   'and review the '
                                                                                                   'query before '
                                                                                                   'sending. Only that '
                                                                                                   'query is sent to '
                                                                                                   'Tavily; memories, '
                                                                                                   'attachments and '
                                                                                                   'chat history are '
                                                                                                   'excluded. Source '
                                                                                                   'snippets are sent '
                                                                                                   'to the answering '
                                                                                                   'model. Searches '
                                                                                                   'may use Tavily '
                                                                                                   'credits, billed '
                                                                                                   'separately from '
                                                                                                   'model tokens.',
 '含联网搜索 %lld 次；搜索费用另计。': 'Includes %lld web searches, billed separately.',
 '启用故障降级': 'Enable Fallback',
 '启用记忆': 'Enable Memory',
 '图片模型': 'Image Model',
 '备用切换：%@ · %@ → %@ · %@': 'Fallback: %@ · %@ → %@ · %@',
 '备用链路（按顺序）': 'Backup Models (In Order)',
 '密钥仅存入本机钥匙串，不写入备份或分享扩展。清空后保存可移除密钥。': 'The key is stored only in the local Keychain, excluded from backups and the '
                                      'share extension. Clear the field and save to remove it.',
 '已不可用：%@': 'Unavailable: %@',
 '已使用 %lld 条个人记忆': 'Used %lld personal memories',
 '已按输入类型选择：%@ · %@': 'Selected for this input: %@ · %@',
 '开启后，将启用的记忆发送给此会话使用的模型。发送前可选择「本次不使用记忆」。': 'Send enabled memories to models used in this chat. Choose Skip Memory This '
                                           'Time before sending to omit them.',
 '手动记录职业、技术栈或语言偏好，最多 20 条，每条 500 字。启用会话记忆后，这些内容会随请求发送给所选模型及备用服务商；可在发送前临时关闭。不会自动提取聊天内容。': 'Manually record your work, '
                                                                                         'technology stack or language '
                                                                                         'preferences: up to 20 '
                                                                                         'entries of 500 characters '
                                                                                         'each. When memory is enabled '
                                                                                         'for a chat, these entries '
                                                                                         'are sent with requests to '
                                                                                         'selected models and backup '
                                                                                         'providers. You can skip them '
                                                                                         'before sending. Nothing is '
                                                                                         'extracted automatically from '
                                                                                         'chats.',
 '按输入类型选择模型': 'Route by Input Type',
 '搜索不使用模型 Token 计价，费用请以 Tavily 账单为准。成功结果的来源与返回额度保存在对应回答中。': 'Search is not priced by model tokens. Refer to your '
                                                            'Tavily bill for charges. Sources and reported credit '
                                                            'usage are saved with successful search results in the '
                                                            'answer.',
 '搜索服务返回了无法读取的数据。': 'The search service returned unreadable data.',
 '搜索结果超过大小限制。': 'The search response exceeds the size limit.',
 '搜索词将发送给 Tavily；来源摘要将发送给回答模型。': 'The query goes to Tavily; source snippets go to the answering model.',
 '搜索词需为 1–400 个字符，请编辑后重试。': 'The search query must contain 1–400 characters. Edit it and try again.',
 '搜索词（仅发送此内容给 Tavily）': 'Search query (only this is sent to Tavily)',
 '搜索请求失败（HTTP %lld），未调用模型。': 'Search failed (HTTP %lld). The model was not called.',
 '搜索调用': 'Search Request',
 '搜索额度：%@ credits': 'Search usage: %@ credits',
 '无法保存到钥匙串，请重试。': 'Unable to save to Keychain. Try again.',
 '本次不使用记忆': 'Skip Memory This Time',
 '本次模型：%@ · %@': 'Model for this request: %@ · %@',
 '来源为搜索服务返回的摘要，并不代表已独立核实。': 'Sources are snippets returned by the search service, not independently verified facts.',
 '正在搜索网页…': 'Searching the web…',
 '每次使用基础搜索，最多保留 5 个 HTTPS 来源。失败时停止本次回答；请修改搜索词，或关闭联网搜索重新发送。': 'Each request uses basic search and keeps up to 5 HTTPS '
                                                             'sources. If search fails, the answer stops. Edit the '
                                                             'query or turn off Web Search and send again.',
 '没有找到可用的网页来源，请修改搜索词或关闭联网搜索后重试。': 'No usable web sources were found. Edit the query or turn off Web Search and try '
                                  'again.',
 '添加备用模型': 'Add Backup Model',
 '添加记忆': 'Add Memory',
 '移除备用模型': 'Remove Backup Model',
 '管理个人长期记忆': 'Manage Personal Memory',
 '编辑记忆': 'Edit Memory',
 '网页来源 · %lld': 'Web Sources · %lld',
 '联网搜索': 'Web Search',
 '联网搜索 · Tavily': 'Web Search · Tavily',
 '能力路由': 'Model Routing',
 '记忆 %lld 条': '%lld memories',
 '记忆保存在本机，并包含在完整 JSON 备份中。删除记忆不会清除服务商已收到的内容，也不会改写历史回答。': 'Memories are stored locally and included in full JSON '
                                                         'backups. Deleting a memory does not remove content already '
                                                         'sent to providers or change past answers.',
 '请先在「服务商 → 联网搜索」配置 Tavily API Key。': 'Configure a Tavily API key in Providers → Web Search first.',
 '请启用服务商和模型，并检查会话参数中的路由目标与识图能力。你输入的内容已保留。': 'Enable a provider and model, then check routing targets and vision '
                                            'support in chat settings. Your input has been kept.',
 '跨模型个人记忆': 'Memory Across Models',
 '路由模型不可用，请检查会话参数中的能力路由。': 'The routing model is unavailable. Check Model Routing in chat settings.'})

EN.update({
    '复制表格': 'Copy Table',
    '编辑重发': 'Edit & Resend',
    '删除此条消息': 'Delete Message',
    '编辑提问并重发': 'Edit & Resend',
    '重新发送': 'Resend',
    '最新输出': 'Latest',
    '正在测速验证…': 'Testing connection…',
    '测试连通性与首字测速 (%@)': 'Test Connection & Latency (%@)',
    '连通正常 · 首字响应 %lld ms（总耗时 %lld ms）': 'Connected · First token %lld ms (total %lld ms)',
    '第三方 AI 数据直连说明': 'Third-Party AI Data Notice',
    '首次发送前请确认数据流向与隐私保护机制': 'Confirm how your data is sent before your first request',
    '将发送哪些数据': 'What Data Is Sent',
    '数据发送到哪里': 'Where Data Is Sent',
    '密钥与本地存储': 'Keys & Local Storage',
    'API Key 与敏感请求头仅加密保存在本机 iOS 系统钥匙串（Keychain）中，开发者无法读取或收集你的任何对话与凭据。': 'API keys and sensitive headers are stored encrypted in the local iOS Keychain. The developer cannot read or collect your chats or credentials.',
    'AI 模型生成的内容可能存在不准确之处，涉及医疗、法律、财务等重要决策时请独立核实。': 'AI-generated responses may be inaccurate. Independently verify important medical, legal or financial information.',
    '同意并继续发送': 'Agree and Send',
    '暂不发送': 'Not Now',
    '数据与隐私确认': 'Data & Privacy',
    '应用信息': 'App Info',
    '版本': 'Version',
    '连接架构': 'Architecture',
    '纯客户端本地直连 (BYOK)': 'Direct On-Device Connection (BYOK)',
    '第三方 AI 数据传输说明': 'Third-Party AI Data Transmission',
    '本应用不设任何中间转发服务器，也不收集账号、遥测或聊天数据。当你发起对话时，消息、附件及启用的个人记忆会直接由设备发往你自行配置的目标 API 服务商。': 'This app operates no relay servers and collects no accounts, telemetry or chat data. Messages, attachments and enabled memories go directly from your device to the API providers you configure.',
    '免责声明': 'Disclaimer',
    '对话回复由你接入的第三方人工智能模型生成，可能存在虚构或滞后信息，仅供参考，不构成专业医疗、法律或投资建议。': 'Responses are generated by third-party AI models you connect and may contain inaccuracies or outdated information. They are for reference only and do not constitute medical, legal or financial advice.',
    '支持与政策': 'Support & Policies',
    '查看隐私政策网页': 'Privacy Policy',
    '联系与反馈 (%@)': 'Contact & Feedback (%@)',
    '关于与隐私声明': 'About & Privacy',
})

# P0/P1/P2 conversation enhancements
EN.update({
    '%@ · 分支': '%@ · Branch',
    'AI 智能生成标题': 'Generate Smart Title',
    'Arena 双盲对比模式': 'Blind Comparison Mode',
    '· 约 %@': '· ~%@',
    '一句话讲清楚': 'TL;DR',
    '与另一模型并排对比': 'Compare with Another Model',
    '中英互译并保留专业术语与排版': 'Translate between Chinese and English while preserving technical terms and formatting',
    '互评修正': 'Cross-Critique',
    '仅显示已收藏消息': 'Bookmarked Only',
    '从此处分叉新对话': 'Fork New Chat from Here',
    '代码审查': 'Code Review',
    '代码讲解': 'Explain Code',
    '会话内查找与收藏': 'Find & Bookmarks',
    '使用原模型重答': 'Regenerate with Original Model',
    '保存后将生成新的对话分支并保留原有历史记录。': 'Saves as a new branch while preserving the previous history.',
    '保留聊天记录，但后续请求不再携带之前上下文': 'Keep chat history visible, but start fresh context for upcoming messages',
    '停止朗读': 'Stop Speaking',
    '停止语音输入': 'Stop Voice Input',
    '先给结论，再用 3 条要点概括': 'Start with the conclusion, followed by 3 key points',
    '写作润色': 'Polish Writing',
    '切换助手 · %@': 'Switch Assistant · %@',
    '匹配结果 (%lld)': 'Matches (%lld)',
    '匿名模型 %@': 'Anonymous Model %@',
    '去除 AI 味与翻译腔，优化逻辑与节奏': 'Remove stiff AI phrasing, improve logic and flow',
    '双盲': 'Blind',
    '双盲评测中：投票选出最佳回复后将揭晓模型身份。': 'Blind evaluation active: vote for the best reply to reveal model identities.',
    '双盲评测胜率榜': 'Blind Arena Leaderboard',
    '取消临时指定模型': 'Clear Temporary Model',
    '取消收藏': 'Remove Bookmark',
    '含收藏': 'Bookmarked',
    '启用提示词缓存 (Prompt Caching)': 'Enable Prompt Caching',
    '在当前会话中搜索': 'Search in Conversation',
    '地道翻译': 'Idiomatic Translate',
    '存入记忆': 'Save Memory',
    '对当前会话内的所有模型（含并发对比模型）生效。支持插入 {{date}}、{{time}}、{{model}} 等动态变量。': 'Applies to every model in this chat, including compared models. Supports dynamic variables such as {{date}}, {{time}} and {{model}}.',
    '导出 Markdown': 'Export Markdown',
    '尝试更换关键词，或关闭收藏筛选。': 'Try another keyword or turn off the bookmark filter.',
    '展开全部代码（共 %lld 行）': 'Expand all code (%lld lines)',
    '工具调用': 'Tool Call',
    '工具调用 · %lld': 'Tool Calls · %lld',
    '已清除上文，以下开启新话题': 'Context cleared — new topic below',
    '已移出上下文': 'Excluded from Context',
    '开启智能工具 (联网 / 网页 / 记忆建议)': 'Enable Agent Tools (Search / Web / Memory Suggestions)',
    '引用追问': 'Quote & Reply',
    '当前日期': 'Current Date',
    '当前时间': 'Current Time',
    '当前模型': 'Current Model',
    '当前设备暂不支持语音识别。': 'Speech recognition is not available on this device.',
    '待用户确认': 'Awaiting Confirmation',
    '忽略': 'Dismiss',
    '总结提炼': 'Summarize Key Points',
    '恢复携带上下文': 'Include in Context',
    '恢复默认模型': 'Restore Default Model',
    '排查 Bug、性能隐患、内存泄漏与安全漏洞': 'Find bugs, performance bottlenecks, memory leaks and security risks',
    '提取核心观点、关键论据与行动建议': 'Extract core takeaways, key arguments and action items',
    '提示词缓存可显著降低 Anthropic 长上下文与系统提示词成本；智能工具仅在单聊生效，记忆建议需经你手动确认后才会保存。': 'Prompt caching reduces long-context and system prompt costs on supported providers. Agent tools apply to single chat only, and memory suggestions require your confirmation before saving.',
    '提问': 'Prompt',
    '插入清除上下文分割线': 'Insert Clear-Context Divider',
    '搜索标题、标签或聊天内容': 'Search titles, tags or messages',
    '收藏消息': 'Bookmark Message',
    '收起代码（共 %lld 行）': 'Collapse code (%lld lines)',
    '星期': 'Weekday',
    '显示行号': 'Line Numbers',
    '智能增强': 'Smart Enhancements',
    '暂无收藏消息': 'No Bookmarked Messages',
    '更多消息操作': 'More Message Actions',
    '朗读回复': 'Speak Reply',
    '未找到匹配消息': 'No Matching Messages',
    '本次临时指定模型': 'Temporary Model Override',
    '本次指定：%@ · %@': 'Pinned for this message: %@ · %@',
    '标签': 'Tag',
    '标签名称（留空清除）': 'Tag name (leave blank to clear)',
    '清除上文分割线': 'Clear Context Above',
    '源码': 'Source',
    '生成分享长图': 'Share as Image Card',
    '移出上下文': 'Exclude from Context',
    '移除引用': 'Remove Quote',
    '系统语言': 'System Language',
    '继续生成': 'Continue Generating',
    '续写': 'Continuation',
    '缓存 %lld': 'Cached %lld',
    '缓存写入 Token': 'Cache Write Tokens',
    '缓存命中 Token': 'Cached Input Tokens',
    '胜 %lld/%lld': 'Wins %lld/%lld',
    '视图': 'View',
    '记忆建议': 'Suggested Memory',
    '设置分组标签': 'Set Folder Tag',
    '语音输入': 'Voice Input',
    '语音输入提示': 'Voice Input Notice',
    '请各模型审阅同组其他候选答案，吸收优点并修正遗漏或错误，给出完善后的最终回答。': 'Please review the peer candidate answers in this comparison, incorporate their strengths, fix any omissions or errors, and provide a refined final answer.',
    '请在系统设置中允许语音识别权限后再使用语音输入。': 'Allow Speech Recognition access in Settings to use voice input.',
    '请在系统设置中允许麦克风权限后再使用语音输入。': 'Allow Microphone access in Settings to use voice input.',
    '请对以下代码进行严格审查，指出潜在 Bug、并发隐患、性能瓶颈与改进建议：\n\n': 'Review the following code thoroughly for bugs, concurrency hazards, performance bottlenecks and improvements:\n\n',
    '请将以下内容翻译为地道自然的表达（中文译英文，外文译简体中文），保留格式与专有名词：\n\n': 'Translate the following content into natural, idiomatic prose (Chinese to English, other languages to Simplified Chinese), preserving formatting and proper nouns:\n\n',
    '请帮我提炼以下内容的核心要点、关键结论与行动建议：\n\n': 'Summarize the core takeaways, key conclusions and actionable recommendations from the following:\n\n',
    '请帮我润色以下文字，去除生硬套话，使逻辑更清晰、表达更自然有力：\n\n': 'Polish the following text to remove stiff clichés and make the logic clearer and the phrasing more natural and compelling:\n\n',
    '请用最精炼的语言回答：先给出一句话结论，再用不超过 3 条要点说明原因。\n\n': 'Answer as concisely as possible: start with a one-sentence conclusion, followed by at most 3 bullet points explaining why.\n\n',
    '请逐层解析这段代码的核心流程、关键设计意图及潜在边界问题：\n\n': 'Explain the core flow, key design intent and potential edge cases of the following code step by step:\n\n',
    '输入消息，支持 / 指令、@ 模型或发图…': 'Message — type / for commands, @ for models, or attach images…',
    '逐段解析实现原理、并发安全与边界条件': 'Walk through how it works, concurrency safety and edge cases',
    '长按或点击消息收藏按钮即可将重要回答加入收藏。': 'Bookmark important messages from a message row to find them quickly here.',
    '预估输入 ~%lld tok': 'Est. input ~%lld tok',
    '预览': 'Preview',
    '首轮对话后自动生成标题': 'Auto-Generate Title After First Turn',
})

EN.update({
    '使用模型': 'Model to Use',
    '先写草稿': 'Write a Draft',
    '同意后，今后主动发起的 AI 操作将使用你选择的服务商。你可以在「关于与隐私声明」中撤回授权。': 'Your approval also applies to future AI requests you initiate with your chosen providers. You can withdraw it in About & Privacy.',
    '导入备份会恢复对话和附件，并为已有对话补回缺失的消息与分支。保留本机已有的消息和配置。API Key 与敏感请求头的值留在钥匙串中。': 'Import restores chats and attachments and adds missing messages and branches to existing chats. Existing messages and settings are preserved. API keys and secret header values stay in the Keychain.',
    '将所选图片和问题发给 %@。同意此次及后续主动发起的 AI 请求？可在「夜奔」中撤回。': 'Send the selected image and question to %@? Your approval also covers future AI requests you initiate. You can withdraw it in Fugue.',
    '将移除所有分支中的 %lld 条消息及其附件。可以在此页面撤销，也可以从已有备份恢复。': 'This removes %lld messages across all branches, including their attachments. You can undo this here or restore from an existing backup.',
    '将问题发给 %@。同意此次及后续主动发起的 AI 请求？可在「夜奔」中撤回。': 'Send the question to %@? Your approval also covers future AI requests you initiate. You can withdraw it in Fugue.',
    '尚未授权，下次发送前会显示接收方并请你确认。': 'Permission has not been granted. You will see the recipients and be asked to confirm before sending.',
    '尚未连接可用于本次对话的模型': 'Connect a model for this chat',
    '已清空 %lld 条消息': 'Cleared %lld messages',
    '已恢复 %lld 个原对话': 'Existing chats restored: %lld',
    '新建对话 %lld 个': 'New chats: %lld',
    '消息 %lld 条': 'Messages: %lld',
    '请求记录 %lld 条': 'Request records: %lld',
    '备份中没有需要导入的内容。': 'The backup has no items to import.',
    '撤回发送授权': 'Withdraw Permission to Send',
    '撤销清空': 'Undo Clear',
    '本地地址': 'Local Endpoint',
    '发送内容或接收方已更改，请重新确认。': 'The content or recipients changed. Please review before sending again.',
    '无法更新对话记录': 'Could Not Update Chat History',
    '智能工具可按模型的请求读取公开网址，配置了搜索密钥时还可将模型生成的搜索词发给 Tavily。工具结果会发回模型。': 'Tools can read public URLs requested by the model. With a search key configured, they can also send model-generated queries to Tavily. Results go back to the model.',
    '清空全部分支': 'Clear All Branches',
    '清空整个对话？': 'Clear the Entire Chat?',
    '联网搜索会把搜索词发给 Tavily，并将返回的摘要交给回答模型。': 'Web search sends the query to Tavily and passes the resulting summaries to the answering models.',
    '请先确认接收方并授权发送。': 'Confirm the recipients and grant permission before sending.',
    '连接模型': 'Connect a Model',
    '连接第一个模型': 'Connect Your First Model',
    '连接配置已更改，请重新验证。': 'The connection settings changed. Please verify them again.',
    '选择服务商': 'Choose a Provider',
    '选择服务商并验证模型连接，完成后可以继续编辑这份草稿。': 'Choose a provider and verify its connection, then continue working on this draft.',
    '验证仅发送一条固定测试消息，可能产生少量 API 费用。验证成功后返回对话。': 'Verification sends a fixed test message and may incur a small API charge. You will return to the chat after it succeeds.',
    '验证连接并使用此模型': 'Verify Connection and Use This Model',
    '本地存储与权限边界': 'Local Storage & Permissions',
    'API Key 与标记为敏感的请求头仅保存在本机 iOS 钥匙串（Keychain）中；对话、附件、请求记录与个人记忆保存在本机 SwiftData 数据库，支持导出不含密钥的 JSON 备份，并可随时单条删除、清空对话或移除服务商销毁对应凭据。': 'API keys and headers marked as sensitive are stored only in the local iOS Keychain. Chats, attachments, request records and personal memories are stored in the local SwiftData database, can be exported to JSON backups without keys, and can be deleted individually, cleared per chat, or destroyed when removing a provider.',
    '相机、相册、麦克风、语音识别与局域网权限仅在你主动点击拍照、选图、语音听写或连接本地模型地址时按需请求，不会在后台静默采集。': 'Camera, Photos, Microphone, Speech Recognition and Local Network permissions are requested only when you actively take a photo, pick images, start voice input, or connect to a local model endpoint, and are never accessed silently in the background.',
    '缺少搜索词': 'Missing query',
    '%lld 个来源': '%lld sources',
    '无效链接': 'Invalid URL',
    '内容为空': 'Empty content',
    '不支持的工具': 'Unsupported tool',
    '更新时间：%@': 'Updated: %@',
    '模型：%@ · %@': 'Model: %@ · %@',
    '系统提示词': 'System Prompt',
    '附件：%@': 'Attachments: %@',
    '思考过程': 'Reasoning',
    '参考来源（%@）': 'Sources (%@)',
    '日期与时间': 'Date & Time',
    '模型 ID': 'Model ID',
})

# Multi-model persona group chat (roundtable discussion)
EN.update({
    '%@ 正在发言…': '%@ is speaking…',
    '%@ 由 %@ 总结': '%@ Summarize by %@',
    '%@ 绑定的模型未标记支持识图，图片可能被忽略或导致报错。': '%@ uses a model not marked for vision; images may be ignored or cause an error.',
    '%lld 位成员：%@': '%lld members: %@',
    '%lld 条': '%lld turns',
    '@所有人 帮我从各自角度挑一下这套新方案最容易翻车的风险点': '@all Poke holes in this proposal from each of your perspectives',
    '一键套用圆桌模板': 'Quick Roundtable Templates',
    '一键混搭模型': 'Mix Models Automatically',
    '不同角色可绑定不同服务商的模型同群碰撞；点击成员可展开修改人设、头像色与底层模型。': 'Assign different providers and models to each persona. Tap a member to edit its persona, badge color and underlying model.',
    '乐观产品 + 毒舌架构师 + 挑剔投资人，全方位拷问你的想法': 'Optimistic PM + blunt architect + skeptical VC stress-testing your idea',
    '产品经理': 'Product Manager',
    '亮牌表决': 'Vote',
    '仅 @ 点名发言': 'Mention Only (@)',
    '从助手拉人': 'Add from Assistants',
    '你专注安全攻防、鉴权越权、数据泄漏、网络超时与异常恢复，专门抓别人忽略的极端边界条件。': 'You focus on security, authorization boundaries, data leaks, network timeouts and failure recovery, catching extreme edge cases others miss.',
    '你推崇 KISS 原则和可读性，反对炫技与过度抽象，总能给出代码量最少、半年后最好改的务实方案。': 'You champion the KISS principle and readability, reject over-engineering, and propose pragmatic solutions with minimal code that stay easy to maintain.',
    '你是一位有十五年一线经验的毒舌首席架构师，最讨厌画大饼与过度设计，专门一针见血指出技术瓶颈、边界异常、维护成本和安全隐患。': 'You are a blunt principal architect with 15 years of hands-on experience. You despise hype and over-design, and pinpoint bottlenecks, edge cases, maintenance traps and security risks.',
    '你是一位直觉敏锐的产品经理，擅长站在真实高频场景挖掘痛点、传播钩子与最小可行产品（MVP）切口，说话干练有感染力。': 'You are a sharp product manager skilled at uncovering real user pain points, viral hooks and crisp MVP wedges, speaking concisely and persuasively.',
    '你是一位眼光毒辣的早期风险投资人，只关心获客成本、留存壁垒、付费意愿以及为什么大厂或竞品做不了，喜欢用犀利反问逼出真相。': 'You are a discerning early-stage VC focused on customer acquisition cost, retention moats, willingness to pay and competitive defensibility, asking pointed questions.',
    '你是客观克制的决策顾问，擅长指出正反双方各自成立的前提条件，并向群主追问最关键的个人约束。': 'You are an objective, measured decision advisor who identifies the assumptions behind each side and asks the host about the most critical personal constraints.',
    '你是果断行动派，擅长放大核心收益、时间窗口与向上赔率，用强有力的论据推动决策落地。': 'You are a decisive advocate for action who highlights upside potential, timing windows and asymmetric gains with compelling arguments.',
    '你是深度风险厌恶的冷静挑刺王，专门戳破幸存者偏差、隐性沉没成本与最坏情况，绝不附和盲目乐观。': "You are a cool-headed devil's advocate who exposes survivorship bias, hidden sunk costs and worst-case scenarios without echoing blind optimism.",
    '你是群主认识十年的幽默损友，说话风趣接地气，擅长用玩笑话一针见血点破内耗，护短但嘴上不饶人。': "You are the host's witty close friend of ten years — grounded, funny and sharp at defusing overthinking with playful banter while always having their back.",
    '你沉稳务实，等大家吐槽完后，总能帮群主把乱麻理顺，给出一两个明天一早就能轻松做到的小动作。': 'You are calm and practical: once everyone has vented, you untangle the mess and suggest one or two small, concrete steps for tomorrow morning.',
    '你痴迷底层性能、内存布局、并发竞争与主线程卡顿优化，对低效循环和多余拷贝零容忍。': 'You obsess over low-level performance, memory layout, concurrency races and main-thread responsiveness, with zero tolerance for wasteful copies or loops.',
    '你细腻温暖、观察力强，能听懂群主没明说的委屈或疲惫，先接住情绪再温和梳理感受，从不说教。': 'You are warm, perceptive and empathetic: you hear the unspoken exhaustion beneath the surface, validate feelings first and never lecture.',
    '保留交锋锋芒的同时允许展开详细论据与代码示例。': 'Keeps sharp debate dynamics while allowing detailed arguments and code examples.',
    '像真人群聊一样抛出一句话，不同模型扮演的角色会互相接话、挑刺反驳或向你反问；你也可以随时输入 @ 点名或插话打断。': 'Drop a message like a real group chat — personas powered by different models will chime in, challenge each other or ask you back. Type @ to mention or interrupt any time.',
    '创业点子审委会': 'Startup Pitch Board',
    '创建群聊': 'Create Group',
    '单轮自动接力上限': 'Max Auto-Relay Turns',
    '去 AI 公文味，每次 2～4 句直击要害，像真人在微信群里拿手机回消息。': 'Drops the stiff essay tone — 2–4 punchy sentences per turn, like real people texting in a group chat.',
    '反方挑刺': 'Con Challenger',
    '发消息进群讨论，输入 @ 点名角色…': 'Message the group — type @ to mention a persona…',
    '发言调度': 'Turn Scheduling',
    '发起圆桌群聊': 'New Group Chat',
    '发起多角色圆桌群聊': 'Start a Multi-Persona Group Chat',
    '发起表决': 'Call a Vote',
    '另辟蹊径': 'Alternative',
    '可直接输入插话': 'Type any time to jump in',
    '向你抛出了问题，等你拍板回应': 'Asked for your call',
    '周凛': 'Zhou Lin',
    '嘴硬损友': 'Witty Friend',
    '回复 %@：%@': 'Replying to %@: %@',
    '图标': 'Icon',
    '圆桌深度交锋': 'Deep Roundtable Debate',
    '圆桌群聊': 'Group Chat',
    '头像': 'Avatar',
    '头衔（如：架构师）': 'Title (e.g. Architect)',
    '安全审计': 'Security Auditor',
    '幽默损友 + 温柔共情师 + 理性军师，陪聊解闷也能出主意': 'Witty friend + empathetic listener + pragmatic strategist for casual chat and advice',
    '底层模型': 'Underlying Model',
    '当前为「仅 @ 点名」模式，输入 @ 选择要回答的群成员': 'Mention-Only mode is active — type @ to choose who replies',
    '性格发散度 %@': 'Creativity %@',
    '性能极客': 'Performance Geek',
    '性能极客 + 安全专家 + 极简维护派，代码与架构全方位会诊': 'Performance geek + security auditor + minimalist pragmatist reviewing your code and design',
    '总结纪要': 'Summarize',
    '成员%lld': 'Member %lld',
    '成员平时保持潜水，只有被你 @ 点名或点击「全员表决」时才发言。': 'Members stay silent until you @mention them or call a group vote.',
    '我想做一个面向独立开发者的订阅记账工具，大家觉得有戏吗？': 'I want to build a subscription tracker for indie developers — does this have legs?',
    '手里有两个 Offer：大厂边缘部门涨薪 30% vs 明星创业公司早期期权，怎么选？': 'Two offers: +30% pay in a non-core big-tech team vs early equity at a hot startup — how should I choose?',
    '技术方案三堂会审': 'Architecture Review Panel',
    '折中收敛': 'Synthesis',
    '按群成员座位顺序依次表态，适合多视角方案评审与头脑风暴。': 'Members speak in seat order — ideal for multi-angle reviews and brainstorming.',
    '挑刺反驳': 'Rebuttal',
    '描述该角色的思考视角、说话风格与关注重点…': "Describe this persona's perspective, tone and focus areas…",
    '插话发送': 'Interrupt & Send',
    '支持 @ 点名与成员互相点名抢麦，有话接话、没话潜水，自动碰撞 2～6 句后停下等你拍板。': 'Supports @mentions and peer handoffs — members chime in when relevant and pause after 2–6 turns for your input.',
    '方远': 'Fang Yuan',
    '早期投资人': 'Early-Stage VC',
    '昵称（必填，用于 @点名）': 'Name (required, used for @mentions)',
    '智能接力': 'Smart Relay',
    '智能接力讨论': 'Smart Relay Discussion',
    '暂时静音（只旁观不发言）': 'Mute Temporarily (Observe Only)',
    '极简工程派': 'Pragmatic Minimalist',
    '林晓': 'Lin Xiao',
    '正在组织发言…': 'Composing reply…',
    '正方主辩': 'Pro Advocate',
    '正方力挺 + 反方挑刺 + 冷静裁判，专治买房跳槽选型纠结': 'Pro advocate + con challenger + impartial referee for tough decisions',
    '毒舌架构师': 'Blunt Architect',
    '沈总': 'Partner Shen',
    '深夜吹水智囊团': 'Late-Night Brain Trust',
    '温柔树洞': 'Empathetic Listener',
    '潜水禁言': 'Muted',
    '点名': 'Mention',
    '点名群成员': 'Mention Group Member',
    '独立裁判': 'Impartial Referee',
    '知夏': 'Zhi Xia',
    '移出群聊': 'Remove from Group',
    '红蓝杠精辩论局': 'Red vs. Blue Debate',
    '继续聊一轮': 'Keep Discussing',
    '群公共背景或讨论议题（可选，对全员生效）': 'Shared group context or topic (optional, applies to all members)',
    '群成员': 'Member',
    '群成员与模型分配（%lld/6）': 'Members & Models (%lld/6)',
    '群成员正在接力讨论…': 'Group members are discussing…',
    '群聊': 'Group',
    '群聊 · %lld 人 · %@': 'Group · %lld · %@',
    '群聊信息': 'Group Info',
    '群聊口语短句': 'Conversational Short Bubbles',
    '群聊名称（如：创业点子审委会）': 'Group name (e.g. Startup Pitch Board)',
    '群聊成员与规则': 'Group Members & Rules',
    '老王': 'Lao Wang',
    '老赵': 'Lao Zhao',
    '自动拆分为连发短气泡': 'Split into Consecutive Short Bubbles',
    '自定义新角色': 'Add Custom Persona',
    '表达语感': 'Speaking Style',
    '角色立场与性格提示词': 'Persona & Stance Prompt',
    '角色色标': 'Badge Color',
    '讨论嘉宾': 'Panelist',
    '讨论纪要': 'Takeaways',
    '讨论节奏与规则': 'Discussion Pacing & Rules',
    '讨论进行中，可直接输入插话打断…': 'Discussion live — type to jump in and steer…',
    '请先在「服务商」页面启用至少一个模型后再配置群成员。': 'Enable at least one model on the Providers tab before configuring group members.',
    '请结合你的独立专业判断参与讨论，有不同意见直接指出。': 'Contribute your independent perspective and point out disagreements directly.',
    '调整群成员与发言规则': 'Edit Group Members & Rules',
    '轮流': 'Round-Robin',
    '轮流依次发言': 'Round-Robin Turns',
    '这是一个产品与创业想法评审群。大家围绕群主抛出的点子真实讨论：有人挖掘用户痛点，有人评估技术可行性与坑点，有人拷问商业变现与护城河。': "This is a startup idea review group. Members debate the host's ideas candidly: uncovering user pain points, probing technical pitfalls, and challenging monetization and moats.",
    '这是一个红蓝对抗决策群。面对群主纠结的选择，正反双方必须针锋相对摆事实讲利弊，裁判负责拆穿逻辑漏洞并提炼拍板标准。': 'This is a structured red-vs-blue decision group. Pro and con debaters clash over trade-offs with concrete arguments while the referee exposes logical gaps and distills decision criteria.',
    '这是一个资深工程技术评审群。针对群主发来的代码、Bug 或架构方案，分别从性能吞吐、安全边界和长期可维护性切入讨论。': 'This is a senior engineering review panel examining code, bugs and architecture proposals across performance, security boundaries and long-term maintainability.',
    '这是一个轻松真实的老友微信群。大家像认识多年的朋友一样跟群主聊天吐槽、提供情绪价值和实在建议，绝对不要说官话套话。': 'This is a relaxed close-friends group chat. Speak naturally like old friends — share banter, emotional support and grounded advice without stiff clichés.',
    '追问细节': 'Follow-Up',
    '退出群聊模式（切回普通单聊）': 'Exit Group Mode (Switch to Single Chat)',
    '配置圆桌群聊角色': 'Configure Group Chat Personas',
    '阿杰': 'Ajie',
    '阿泽': 'Aze',
    '陆工': 'Engineer Lu',
    '陈锋': 'Chen Feng',
    '靠谱军师': 'Trusted Strategist',
    '顾言': 'Gu Yan',
    '📋 %@请帮大家梳理总结目前讨论的核心共识、关键分歧与下一步行动建议。': '📋 %@Please summarize the core consensus, key disagreements and next-step recommendations from the discussion so far.',
    '📣 @所有人': '📣 @all',
    '📣 所有人': '📣 Everyone',
    '🗳️ 发起圆桌表决：请各位明确亮牌（赞成 / 反对 / 中立），并用 1～3 句话说明核心理由。': '🗳️ Group Vote: Please state your stance (Approve / Reject / Neutral) and explain your core reasoning in 1–3 sentences.',
    '部分群成员模型尚未就绪：%@，轮到其发言时可能报错。': 'Some group member models are not ready (%@) and may fail on their turn.',
    '部分对比模型尚未就绪：%@。': 'Some comparison models are not ready: %@.',
    '当前对话暂无可生成分享图的消息内容。': 'There are no messages available to export as an image card.',
    '调整': 'Adjust',
    '%@ 回应了 %@': '%@ reacted with %@',
    '点名 %@': 'Mention %@',
    '换用其他模型重答此条': 'Regenerate This Turn with Another Model',
    '颜色方案 %lld': 'Color %lld',
})

EN.update({
    "无法保存消息。请检查设备存储空间后重试。": "Couldn't save the message. Check your device storage and try again.",
    "此服务商或模型已停用、删除或更改，请重新选择模型。": "This provider or model was disabled, removed, or changed. Select a model again.",
    "模型请求了本轮未启用的工具，已停止处理。": "The model requested a tool that isn't enabled for this turn. Processing stopped.",
    "智能标题": "Smart Title",
    "请求失败，详细错误仅保留在原设备。": "The request failed. Detailed diagnostics are available on the original device.",
    "导入会补回缺失的对话、附件和分支，并保留本机已有配置。备份会省略密钥、敏感请求头的值，以及带用户信息、查询参数或自定义路径的连接地址。恢复到新设备后，请补填这些地址并启用服务商。": "Import restores missing chats, attachments, and branches and keeps your existing settings. Backups omit API keys, secret header values, and connection URLs with credentials, query parameters, or custom paths. On a new device, re-enter these URLs and enable the providers.",
})

EN.update({
    "仅本条消息": "This Message Only",
    "本会话": "This Chat",
    "本会话允许工具": "Tools enabled for this chat",
    "本次 · %@": "This message · %@",
    "本次联网": "Web search for this message",
    "发送选项": "Send Options",
    "打开发送选项": "Open send options",
    "其他分支": "Other Branch",
    "在此分支继续": "Continue in This Branch",
    "打开对话": "Open Chat",
    "当前追问回复": "Current follow-up reply",
    "投票并揭晓": "Vote and Reveal",
    "沿这条回答追问": "Follow Up on This Reply",
    "盲评得票": "Your blind pick",
    "此轮已揭晓，未记录独立选票。": "This round was revealed without a separately recorded vote.",
    "尚无独立选票": "No recorded votes yet",
    "胜率按投票时已完成的回答统计。旧版已揭晓的轮次没有独立选票，不计入胜率。": "Win rates count replies that were complete at voting time. Previously revealed rounds without a recorded vote are excluded.",
})

# UI/UX polish, appearance, cache pricing, charts, encrypted backup, OCR & native grounding
EN.update({
    "%lld 人 · %@": "%lld members · %@",
    "Prompt 缓存折扣（选填）": "Prompt Cache Discount (Optional)",
    "Token 消耗趋势": "Token Usage Trend",
    "一键填入：%@": "Quick Fill: %@",
    "书籍提示": "Book Notice",
    "从主流模型单价表选择…": "Choose from Reference Price Catalog…",
    "代码块默认显示行号": "Show Line Numbers in Code Blocks by Default",
    "保存为我的圆桌模板": "Save as My Roundtable Template",
    "共 %lld 节 · %@": "%lld sections · %@",
    "关闭思考": "Thinking Off",
    "内嵌预览": "Inline Preview",
    "分类": "Category",
    "创建角色": "Create Character",
    "删除模板": "Delete Template",
    "加密备份密码": "Backup Password",
    "加密生成": "Encrypt & Export",
    "取消置顶模型": "Unstar Model",
    "圆桌阵容": "Roundtables",
    "在任意圆桌群聊的设置页点击「保存为我的圆桌模板」，即可在此一键复用自定义角色组合。": "Tap “Save as My Roundtable Template” in any group chat’s settings to reuse your custom persona lineup here in one tap.",
    "均衡思考 (8K)": "Balanced Thinking (8K)",
    "填写缓存命中或写入单价后，新请求将自动按实际缓存 Token 折算费用并统计缓存节省金额。单价只影响新请求，清空输入与输出两项可停止计价。": "When cache hit or write prices are set, new requests automatically discount cached tokens and track cache savings. Prices apply only to new requests; clear both input and output fields to stop pricing.",
    "备份密码不正确，或加密备份文件已损坏。": "Incorrect backup password, or the encrypted backup file is corrupted.",
    "复制全文": "Copy All",
    "大字": "Large",
    "好友与书架": "Friends & Books",
    "密钥派生失败，请重试。": "Key derivation failed. Please try again.",
    "对话正文大小": "Message Text Size",
    "导出密码加密备份 (含 API Key)": "Export Encrypted Backup (Includes API Keys)",
    "将使用 AES-GCM 加密导出所有对话、服务商自定义地址及 API Key。请牢记密码，遗忘后无法恢复。": "Exports all chats, custom provider URLs, and API keys encrypted with AES-GCM. Keep your password safe — it cannot be recovered if forgotten.",
    "工具": "Tools",
    "已为 %lld 个未设价模型填入参考单价。": "Filled reference prices for %lld unpriced models.",
    "已保存为圆桌模板": "Saved as Roundtable Template",
    "常用置顶": "Starred",
    "开聊": "Chat",
    "快捷填充参考单价": "Quick-Fill Reference Prices",
    "快捷记录": "Quick History",
    "思考完成后自动折叠思考链": "Auto-Collapse Reasoning When Finished",
    "思考流式输出期间会显示限高实时预览窗；开启自动折叠后，正文开始输出时会自动收起思考过程。": "Shows a compact live preview while reasoning streams; when enabled, reasoning collapses automatically once the answer begins.",
    "我的书架（%lld）": "My Bookshelf (%lld)",
    "我的圆桌阵容": "My Roundtables",
    "按服务商返回用量与已设单价（含缓存单价快照）估算，不含阶梯价格和额外收费。": "Estimated from provider-reported usage and saved prices (including cache price snapshots); excludes tiered pricing and extra fees.",
    "排版预览": "Typography Preview",
    "操作与生成完成触感反馈": "Haptic Feedback",
    "支持 EPUB、TXT、Markdown 和 PDF（含扫描版离线文字识别）。正文保存在本机，并随完整备份导出。": "Supports EPUB, TXT, Markdown, and PDF (including offline OCR for scanned pages). Text stays on this device and is included in full backups.",
    "无法识别该加密备份文件。": "This encrypted backup file isn’t recognized.",
    "时间": "Time",
    "最近使用": "Recent",
    "服务商原生联网": "Provider-Native Web Search",
    "服务商原生联网 (Gemini / Claude / OpenAI)": "Provider-Native Web Search (Gemini / Claude / OpenAI)",
    "服务商原生联网（免 Tavily Key）": "Provider-Native Web Search (No Tavily Key Needed)",
    "未配置 Tavily Key 时，在对话输入栏点按「联网」或在「发送选项」开启「服务商原生联网」，会直接向支持联网的接口请求内置检索（Gemini Google Search、Anthropic Web Search、OpenAI / OpenRouter Web Search），如网关不支持则自动回退。": "When no Tavily key is set, tapping Web in the composer or enabling Provider-Native Web Search in Send Options requests built-in grounding (Gemini Google Search, Anthropic Web Search, OpenAI / OpenRouter Web Search), falling back automatically if unsupported.",
    "极限推理 (32K)": "Max Reasoning (32K)",
    "标准": "Standard",
    "检测到密码加密备份包，输入密码后将自动恢复数据与 API 凭据。": "Encrypted backup detected. Enter the password to restore your data and API credentials.",
    "正在聆听，请直接说话…": "Listening — speak now…",
    "每百万缓存写入单价": "Cache Write Price per Million Tokens",
    "每百万缓存写入单价（选填）": "Price per million cache-write tokens (optional)",
    "每百万缓存命中单价": "Cached Input Price per Million Tokens",
    "每百万缓存命中单价（选填）": "Price per million cached input tokens (optional)",
    "消息与交互": "Messages & Interaction",
    "深度思考 (16K)": "Deep Thinking (16K)",
    "清晰、自然的排版能让长对话与推理内容更易阅读。": "Clear, balanced typography makes long conversations and reasoning easier to read.",
    "清空最近使用的模型记录": "Clear Recent Model History",
    "留空则按普通输入计价": "Defaults to standard input price",
    "精选圆桌阵容": "Featured Roundtables",
    "紧凑": "Compact",
    "缓存已节省": "Cache Savings",
    "置顶常用模型": "Star Model",
    "群聊 · %lld 人": "Group · %lld",
    "联网": "Web",
    "自动匹配主流参考单价": "Auto-Fill Reference Prices",
    "自定义": "Custom",
    "自定义圆桌阵容": "Custom Roundtable",
    "至少 4 位字符的密码": "Password (at least 4 characters)",
    "舒适": "Comfortable",
    "角色与书架": "Characters & Bookshelf",
    "解密并导入": "Decrypt & Import",
    "设置加密备份密码": "Set Backup Password",
    "请提取图片中的文字并翻译为%@。": "Extract the text from this image and translate it into %@.",
    "请设置至少 4 位字符的备份密码。": "Enter a backup password of at least 4 characters.",
    "轻量思考 (2K)": "Light Thinking (2K)",
    "输入你的指令或问题…": "Enter your question or instruction…",
    "输入备份解密密码": "Enter Backup Password",
    "输出吞吐速率对比 (tok/s)": "Output Throughput Comparison (tok/s)",
    "选择文本": "Select Text",
    "阅读与交互偏好": "Appearance & Reading",
    "阅读排版": "Reading & Typography",
})

# Socratic Coach, Feynman Student, Skill Drills & Spaced-Repetition Flashcards
EN.update({
    "%lld 天": "%lldd",
    "10 分钟": "10m",
    "Lv.1 → Lv.3 逐级出题实战批改，练透编程、算法或外语技能": "Progressive Lv.1 → Lv.3 hands-on challenges with instant grading for coding, algorithms, or languages",
    "⏭️ 下一关挑战": "⏭️ Next Challenge",
    "✅ 考考我": "✅ Quiz Me",
    "下面我用自己的话给你讲一遍 HTTPS 握手流程，请你扮演挑刺学生追问漏洞。": "Let me explain the HTTPS handshake in my own words — act as a sharp student and poke holes in my explanation.",
    "下面我用自己的话给你讲一遍这个概念，请你扮演挑刺学生指出我没讲清或跳步的地方：\n\n": "I’ll explain this concept in my own words below — act as an inquisitive student and point out any gaps or logical leaps:\n\n",
    "不直接给答案，先追问定位你的理解盲区，循序渐进启发思考": "Guides you step by step with probing questions and hints instead of handing out the answer",
    "不直接给答案，通过递进追问帮你定位盲区并独立推导": "Uses guided questions to uncover blind spots and help you derive the solution yourself",
    "互动导师工作流": "Interactive Study Coaches",
    "今日到期复习": "Today’s Due Review",
    "例如：Swift 并发 / 《渡河记》": "e.g. Swift Concurrency / Book Notes",
    "全部卡组": "All Decks",
    "全部收入卡包": "Save All to Deck",
    "共巩固 %lld 张卡片 · 顺畅掌握率 %lld%%": "Reviewed %lld cards · %lld%% smooth recall",
    "关闭助学导师": "Study Coach Off",
    "助学": "Study",
    "助学制卡": "Study Cards & Quiz",
    "助学导师模式": "Study Coach Mode",
    "助学闪卡": "Flashcards",
    "卡壳时给自己的小提示…": "Optional memory cue when stuck…",
    "原对话": "Source Chat",
    "吃力": "Hard",
    "在任意对话消息底部点击「助学」即可一键提炼闪卡与随堂测验；导出的 .tsv 文件可直接导入 Anki。": "Tap “Study” under any assistant reply to generate flashcards or a quiz. Exported .tsv files import directly into Anki.",
    "完成本轮闪卡复习！": "Review Session Complete!",
    "导出 Anki": "Export Anki",
    "导师": "Coach",
    "已入库": "Saved",
    "已全部入库": "All Saved",
    "已熟记": "Mastered",
    "已转闪卡": "Saved as Card",
    "常规直接解答模式": "Standard direct-answer mode",
    "开启启发式追问导师，先探测盲区再给提示": "Enable guided Socratic questioning with progressive hints",
    "开启苏格拉底启发导师": "Start Socratic Tutor",
    "开启费曼挑刺学生演练": "Start Feynman Practice",
    "开启闯关实战特训": "Start Progressive Skill Drill",
    "开始今日复习 (%lld)": "Review Due Cards (%lld)",
    "待复习": "Due",
    "得分 %lld/%lld": "Score %lld/%lld",
    "总卡片": "Total",
    "我已经独立思考过了，请直接给出完整的标准解析与核心要点总结。": "I’ve thought it through — please reveal the complete solution and key takeaways.",
    "我想真正吃透 Swift Concurrency 的 Actor 隔离机制，请用苏格拉底式提问引导我。": "Help me truly master Swift Concurrency actor isolation through Socratic questioning.",
    "我想真正吃透下面这个概念/技能，请用苏格拉底启发式提问引导我逐步思考，先不要直接揭晓答案：\n\n": "Help me deeply master the following concept or skill using Socratic questioning — guide me step by step without giving away the answer upfront:\n\n",
    "我有点卡住了，请给我一个小提示（先不要直接揭晓最终答案）。": "I’m stuck — please give me a small hint without revealing the final answer yet.",
    "我来试着解释 Transformer 的注意力机制，请指出我没讲透的地方。": "Let me try explaining Transformer attention — point out anything I leave vague or incomplete.",
    "我的闪卡库（%lld）": "My Flashcards (%lld)",
    "所属卡组": "Deck",
    "技能学习与导师引导": "Skill Learning & Study Coach",
    "掌握": "Good",
    "搜索卡片问题或解析…": "Search card questions or answers…",
    "收入卡包": "Save",
    "新建闪卡": "New Flashcard",
    "显示提示": "Show Hint",
    "显示答案": "Show Answer",
    "暂无可用于生成学习卡片的内容。": "No content is available to generate study cards.",
    "暂无闪卡。可在任意对话回复底部点按「助学 → 生成记忆闪卡」，或点击右上角 + 手动创建。": "No flashcards yet. Tap “Study → Generate Flashcards” under any reply, or tap + to add one manually.",
    "查看提示": "Show Hint",
    "模型返回格式无法解析为学习卡片，请重试或切换模型。": "Couldn’t parse study cards from the model’s response. Please retry or switch models.",
    "正在提炼互动助学卡片…": "Generating interactive study cards…",
    "正面 · 回想问题": "Front · Recall Prompt",
    "正面（回想提问）": "Front (Prompt / Question)",
    "点击分享或保存导出的 Anki 卡包 (.tsv)": "Share or Save Exported Anki Deck (.tsv)",
    "点击切回正面": "Tap to flip to front",
    "点击翻转看答案": "Tap to flip for answer",
    "生成记忆闪卡": "Generate Flashcards",
    "生成随堂测验": "Generate Quiz",
    "由你扮演老师讲解概念，AI 扮演挑刺学生追问漏洞并给掌握度评分": "You teach the concept in plain words; AI plays a sharp student probing gaps and scoring mastery",
    "由你用白话讲解概念，AI 追问逻辑漏洞并输出掌握度评分卡": "Explain concepts in your own words while AI probes logical gaps and scores your mastery",
    "由你讲解概念，AI 扮演挑刺学生追问漏洞": "Teach the concept yourself while AI probes gaps as a curious student",
    "由浅入深出实战题（Lv.1 → Lv.3），逐题批改反馈后再解锁下一关": "Hands-on practice from Lv.1 to Lv.3 with per-turn grading before unlocking the next level",
    "给我开启 SQL 窗口函数实战闯关特训（从 Lv.1 开始出题）。": "Start a hands-on SQL window functions drill for me (begin with Lv.1).",
    "编辑闪卡": "Edit Flashcard",
    "考考我正则表达式进阶语法，每次出一道实战题等我作答。": "Drill me on advanced regular expressions — one hands-on challenge at a time.",
    "背面 · 标准解析": "Back · Answer & Explanation",
    "背面（核心答案与解析）": "Back (Answer & Explanation)",
    "苏格拉底": "Socratic",
    "苏格拉底引导": "Socratic Tutor",
    "解析": "Answer",
    "记忆线索（选填）": "Memory Cue (Optional)",
    "记忆闪卡 · %lld": "Flashcards · %lld",
    "请围绕上文的核心知识点出 3 道由浅入深的理解与实战自测题（先出题等我作答，暂不公布答案）。": "Create 3 progressive comprehension and practice questions on the key concepts above (wait for my answers before revealing solutions).",
    "请帮我循序渐进掌握动态规划的状态转移推导方法。": "Guide me step by step to master deriving dynamic programming state transitions.",
    "请挑一个我刚才忽略的极端情况或底层原理继续追问我。": "Pick an edge case or underlying mechanism I glossed over and quiz me on it.",
    "请根据刚才的回想顺畅度选择下方间隔档位": "Rate how smoothly you recalled the answer to schedule the next review",
    "请评估我刚才的费曼讲解，给出清晰度与准确度评分，指出我没讲透的盲区，并示范一个更通俗精妙的类比。": "Evaluate my Feynman explanation: score clarity and accuracy, point out blind spots, and suggest a sharper analogy.",
    "请进入下一关难度更高的实战练习题！": "Let’s move on to the next, harder practice challenge!",
    "请针对刚才的知识点出一道简短的快问快答，检验我是否真正理解了。": "Give me one quick check-for-understanding question on this topic to test my grasp.",
    "费曼学生": "Feynman",
    "费曼挑刺学生": "Feynman Student",
    "费曼输出演练": "Feynman Practice",
    "轻松": "Easy",
    "轻点卡片翻转核对答案": "Tap card to flip and check answer",
    "这道题我还没头绪，请只提示第一步切入方向，让我自己完成作答。": "I’m not sure where to start — give me just the first-step angle so I can solve it myself.",
    "追问这道题": "Follow Up in Chat",
    "重来": "Again",
    "针对当前话题出 3 道递进实战题检验掌握程度": "Generate 3 progressive practice questions on the current topic",
    "错题转闪卡": "Save as Flashcard",
    "闯关实战特训": "Skill Drill",
    "闯关特训": "Drill",
    "间隔 %lld 天": "Interval %lldd",
    "间隔重复记忆舱": "Spaced-Repetition Deck",
    "随堂理解小测": "Quick Quiz",
    "随堂理解测验": "Comprehension Quiz",
    "随机巩固复习": "Practice Review",
    "随机抽查巩固": "Practice Shuffle",
    "默认卡组": "General",
    "🆘 给第一步思路": "🆘 First-Step Hint",
    "🎯 给我的讲解打分": "🎯 Score My Explanation",
    "💡 给点提示": "💡 Hint",
    "📖 揭晓完整解析": "📖 Reveal Full Solution",
    "🔍 追问边界条件": "🔍 Probe Edge Cases",
    "%lld 秒": "%lld sec",
    "自动（常规 45s / 推理与本地 120s）": "Automatic (45s standard / 120s reasoning & local)",
    "流式空闲超时": "Stream Idle Timeout",
    "轮询 Key #%lld": "Pool Key #%lld",
    "移除轮询 Key": "Remove pool key",
    "添加轮询 / 备用 API Key": "Add Rotation / Backup API Key",
    "已启用 %lld 个 Key 自动轮询，遇 429 限流或额度耗尽自动熔断切换。": "%lld keys active in round-robin pool with automatic failover on 429/quota errors.",
    "输入或粘贴备用 API Key": "Enter or paste backup API key",
    "多个 API Key 会按轮询（Round-Robin）分摊请求；当某个 Key 返回 429 限流、401/402/403 鉴权或余额不足时将自动冷却并秒切下一个 Key。": "Multiple API keys share load via round-robin; any key hitting 429 rate limits or 401/402/403 quota errors cools down and fails over to the next key.",
    "添加轮询 Key": "Add Pool Key",
})

# Project Knowledge Base (NotebookLM mode), RunSkillIntent, EventKit Cards, Spotlight & Live Activities
EN.update({
    "%lld 处片段": "%lld passages",
    "AI 技能": "AI Skill",
    "《%@》知识问答": "%@ Q&A",
    "专属知识库 (NotebookLM 模式)": "Project Knowledge (NotebookLM Mode)",
    "书架中暂无文档。点击上方按钮即可导入技术文档、论文、财报或电子书（支持扫描版 PDF 离线 OCR）。": "No documents on your shelf yet. Tap above to import technical docs, papers, reports, or ebooks (including offline OCR for scanned PDFs).",
    "从会议记录或长文提取待办事项、负责人与截止时间": "Extract action items, owners, and deadlines from meeting notes or long text",
    "从截图或文本提取金额、商户、日期与明细 JSON": "Extract merchant, date, amount, and line items as structured JSON from screenshots or text",
    "从文件导入新参考资料 (PDF / EPUB / MD / TXT)": "Import Reference Document (PDF / EPUB / MD / TXT)",
    "使用此助手开启新对话时，将自动挂载所选书架文档并支持章节引用问答。": "New chats started with this assistant automatically attach the selected documents for cited Q&A.",
    "先给一句话结论，再列核心论据与建议": "Start with a one-sentence conclusion followed by core arguments and next steps",
    "加入提醒事项": "Add to Reminders",
    "加入系统日历": "Add to Calendar",
    "图片（可选）": "Image (Optional)",
    "地道中英互译": "Idiomatic Bilingual Translation",
    "已写入系统日历": "Added to Calendar",
    "已加入系统提醒事项": "Added to Reminders",
    "已绑定 %lld 份": "%lld bound",
    "指定模型（留空自动选就绪模型）": "Model (Optional — auto-selects when empty)",
    "提取待办与日程": "Extract Reminders & Schedule",
    "提取账单与结构化 JSON": "Extract Receipt & Structured JSON",
    "提炼行动项与日程清单": "Distill Action Items & Schedule",
    "提醒事项": "Reminder",
    "收藏": "Bookmarked",
    "日历日程": "Calendar Event",
    "日程提示": "Schedule Notice",
    "未从该条内容中识别出明确的待办事项或日程安排。": "No concrete reminders or schedule items were found in this message.",
    "未找到可用的系统默认列表或日历。": "No default Calendar or Reminders list is available.",
    "未绑定": "None",
    "未绑定文档": "No documents bound",
    "未获得「提醒事项」权限，请在系统设置中开启后重试。": "Reminders access was denied. Enable it in Settings and try again.",
    "未获得「日历」写入权限，请在系统设置中开启后重试。": "Calendar write access was denied. Enable it in Settings and try again.",
    "本地参考知识库": "Project Knowledge Base",
    "核心要点精炼总结": "Executive Summary",
    "正在发言…": "Speaking…",
    "正在导入并索引文档…": "Importing and indexing document…",
    "清空本会话已绑定的知识库": "Unbind All Documents from This Chat",
    "用 ${applicationName} 运行技能": "Run a skill with ${applicationName}",
    "用 ${applicationName} 运行 ${skill}": "Run ${skill} with ${applicationName}",
    "相机、相册、麦克风、语音识别、日历/提醒事项与局域网权限仅在你主动点击拍照、选图、语音听写、确认添加待办日程或连接本地模型地址时按需请求，不会在后台静默采集。": "Camera, Photos, Microphone, Speech Recognition, Calendar/Reminders, and Local Network permissions are requested only when you actively take a photo, pick images, start voice input, confirm adding a schedule item, or connect to a local model endpoint — never silently in the background.",
    "知识库": "Docs",
    "知识库 · %lld": "Docs · %lld",
    "知识库引用 · %lld 处": "Document Citations · %lld",
    "知识问答": "Doc Q&A",
    "绑定参考资料后，单聊、Arena 并发对比与圆桌群聊会自动检索高相关原文片段并带精确章节/页码作答；开启「工具」时模型也可主动调用 search_documents 深入查阅。": "When documents are bound, Single Chat, Arena Comparison, and Group Roundtable automatically retrieve relevant passages with exact section/page citations; when Tools are on, the model can also call search_documents directly.",
    "绑定本地参考知识库": "Bind Reference Documents",
    "自动识别语种并输出母语级译文": "Auto-detect language and translate into natural, native prose",
    "请从以下内容中提炼核心结论、待办行动项与关键时间节点：\n\n": "Distill the core conclusions, actionable to-do items, and key deadlines from the following:\n\n",
    "请按当前助手设定分析这张图片。": "Analyze this image according to your assistant instructions.",
    "请提取以下内容或图片中的关键信息并输出标准 JSON：\n\n": "Extract the key structured fields from the following text or image and output valid JSON:\n\n",
    "调用「夜奔」中的自定义助手或结构化技能（如提取账单 JSON、提炼待办、翻译总结），支持绑定操作按钮与快捷指令流水线。": "Run a custom assistant or structured skill in Fugue (such as receipt JSON extraction, action-item distillation, or translation), ready for Action Button and Shortcuts workflows.",
    "输入文本（可选）": "Input Text (Optional)",
    "运行 AI 技能": "Run AI Skill",
    "运行技能 ${skill}": "Run skill ${skill}",
    "选择参考资料（已选 %lld/12）": "Select Documents (%lld/12 selected)",
    # --- Audit fixes & refinements
    "闪卡 %lld 张": "%lld flashcards",
    "导入会补回缺失的对话、附件、分支与助学闪卡，并保留本机已有配置。普通备份会省略密钥、敏感请求头及自定义路径地址；使用「加密导出完整备份」时才会以密码加密包含 API Key 与完整连接地址。": "Importing restores missing conversations, attachments, branches, and study flashcards while keeping local settings. Standard backups omit API keys, sensitive header values, and custom-path URLs; use Encrypted Full Backup to password-protect and include API keys and full endpoints.",
    "个人长期记忆已达到上限（%lld 条），请先在「服务商 → 个人长期记忆」清理后再保存。": "Personal memory has reached the limit of %lld items. Remove older entries in Providers → Personal Memory before saving.",
    "记忆容量已满": "Memory Limit Reached",
    "同时开启时，Gemini 将优先使用自定义工具，Anthropic 若已配置 Tavily 将优先使用 Tavily 搜索。": "When both are enabled, Gemini prioritizes custom tools, and Anthropic uses Tavily search if a Tavily key is configured.",
    "操作失败": "Action Failed",
    "生成失败": "Generation Failed",
    "日程提取失败": "Schedule Extraction Failed",
    "不支持的二进制文件格式，请选择图片、PDF 或纯文本/代码文件。": "Unsupported binary file format. Please choose an image, PDF, or plain text/code file.",
    # --- Comprehensive review fixes (DB protection, privacy fallback, Spotlight opt-in, webpage approval gate, 8-char backup)
    "1. 零自建后端与零数据收集": "1. Zero Backend Servers & Zero Data Collection",
    "2. 向第三方服务商的直连传输": "2. Direct Transmission to Third-Party Providers",
    "3. 本机存储、备份加密与删除控制": "3. On-Device Storage, Encrypted Backups & Deletion",
    "4. 系统扩展、权限与安全防护": "4. System Extensions, Permissions & Security Safeguards",
    "@所有人 ": "@all ",
    "AI 请求访问你未直接输入的外部链接：\n%@": "The AI requested access to an external URL you did not directly enter:\n%@",
    "API Key 与标记为敏感的请求头仅保存在本机 iOS 钥匙串（Keychain）中；对话、附件、请求记录与个人记忆保存在本机 SwiftData 数据库，支持导出不含密钥的 JSON 备份或使用 AES-256-GCM 密码加密的完整备份，并可随时单条删除、清空对话或移除服务商销毁对应凭据。": "API keys and headers marked as sensitive are stored only in the local iOS Keychain. Chats, attachments, request records, and personal memories stay in the local SwiftData database, support keyless JSON export or AES-256-GCM password-encrypted full backup, and can be deleted individually, cleared per chat, or purged when removing a provider.",
    "仅在你首次确认数据出境/第三方传输披露后，你主动发送的会话上下文、所选附件、已启用的个人记忆或联网搜索关键词才会从你的设备直接发送至你所配置的模型 API 地址（如 OpenAI、Anthropic、Google Gemini、DeepSeek、OpenRouter、Tavily 或局域网服务）。相关数据的留存与使用受对应服务商自身的隐私条款约束。你可随时在本页点击「撤回发送授权」。": "Only after you confirm the third-party data disclosure will your active conversation context, selected attachments, enabled personal memories, or web search queries be sent directly from your device to the API endpoints you configured (such as OpenAI, Anthropic, Google Gemini, DeepSeek, OpenRouter, Tavily, or LAN services). Retention and use of sent data are governed by each provider's own privacy policy. You can revoke permission here at any time.",
    "允许本次": "Allow Once",
    "允许系统 Spotlight 索引对话": "Allow Spotlight Indexing",
    "删除并清除密钥": "Delete & Clear Keys",
    "备份文件超过 256 MB 安全上限，无法导入。": "The backup file exceeds the 256 MB safety limit and cannot be imported.",
    "夜奔（Fugue）是纯本地运行的自带密钥（BYOK）客户端。开发者不运营账号系统、不转发明文请求、不接入第三方广告或行为分析 SDK，也不会向开发者服务器上传任何提示词、回复、电子书、闪卡或 API 密钥。": "Fugue is a purely on-device Bring-Your-Own-Key (BYOK) client. The developer operates no account system or relay servers, embeds no third-party advertising or analytics SDKs, and never uploads your prompts, replies, ebooks, flashcards, or API keys to any developer server.",
    "将使用 AES-GCM 加密导出所有对话、服务商自定义地址及 API Key。请设置至少 8 位密码并妥善保管，遗忘后无法恢复。": "Exports all chats, custom provider URLs, and API keys encrypted with AES-GCM. Set a password of at least 8 characters and keep it safe — it cannot be recovered if forgotten.",
    "将移除「%@」及其保存在本机钥匙串中的 API Key 与敏感请求头。": "This removes “%@” along with its API keys and sensitive headers stored in the local Keychain.",
    "已将旧数据库完整备份到 App 的 Application Support/%@ 目录。": "The previous database files were backed up to Application Support/%@ in the app container.",
    "思考 · %lldK": "Think · %lldK",
    "拒绝": "Deny",
    "所有 API 密钥、备用密钥与敏感自定义请求头均存储在受系统硬件级保护的 iOS Keychain 中；会话、知识库与用量账本保存在沙盒内 SwiftData 数据库。普通备份会自动剥离全部密钥与含私密凭据的端点；加密备份采用 Apple CryptoKit（PBKDF2-HMAC-SHA256 + AES-256-GCM）在本地完成加解密，密码仅由你本人掌握。删除对话、清空历史或移除服务商将同步清理对应本地记录与钥匙串凭据。": "All API keys, rotation keys, and sensitive custom headers are stored in the hardware-backed iOS Keychain, while conversations, documents, and usage logs reside in the sandboxed SwiftData store. Standard backups strip all secrets and sensitive endpoints; encrypted backups use Apple CryptoKit (PBKDF2-HMAC-SHA256 + AES-256-GCM) locally with a password known only to you. Deleting chats, clearing history, or removing providers purges the corresponding local records and Keychain secrets.",
    "本地存储提示": "Local Storage Notice",
    "本地数据库异常且自动归档备份未成功（可能存储空间不足），为保护原有文件未覆盖数据库。请清理设备空间后重试。": "The local database encountered an error and automatic backup failed (possibly due to low storage). Existing files were left untouched in read-only recovery mode; free up space and restart the app.",
    "本地数据库当前正被占用、权限受限或存储空间不足，已进入临时保护模式且未改动原有数据。请检查存储空间并重启 App。": "The local database is temporarily busy, permission-restricted, or out of disk space. Fugue entered temporary recovery mode without modifying your existing data; check available storage and restart the app.",
    "本地数据库结构损坏无法读取，已为你创建新的数据库。%@": "The local database was corrupted and could not be read, so a fresh database was initialized. %@",
    "本对话始终允许 %@": "Always Allow %@ in This Chat",
    "查看完整隐私政策说明": "View Built-In Privacy Policy",
    "用户已拒绝访问": "Access denied by user",
    "确认删除服务商？": "Delete Provider?",
    "确认读取外部网页？": "Allow Reading External Webpage?",
    "系统分享扩展与实时活动仅通过本机 App Group 安全容器与主应用交换必要的最小化任务状态；智能工具访问外部网页时默认启用内网地址（SSRF）拦截与非受信域名人工确认闸门；系统 Spotlight 索引默认关闭，仅在你手动开启时在设备本地建立搜索条目。": "The Share Extension and Live Activities exchange only minimal task state with the main app via the local App Group container. Agent webpage reading enforces private-network (SSRF) blocking and requires user approval for unrequested external domains. Spotlight indexing is off by default and indexes locally only when explicitly enabled.",
    "系统搜索与本地索引": "System Search & Local Index",
    "至少 8 位字符的密码": "Password (at least 8 characters)",
    "草稿暂未读取成功": "Draft could not be loaded",
    "草稿读取失败": "Unable to Load Draft",
    "设备尚未完成解锁保护验证，暂时进入只读保护模式，原有本地数据库完好保留。解锁后重新打开 App 即可恢复。": "Protected storage is not yet available before device unlock. Fugue entered temporary read-only recovery mode and left your existing database untouched; unlock your device and reopen the app.",
    "请设置至少 8 位字符的备份密码。": "Enter a backup password of at least 8 characters.",
    "重置草稿": "Reset Draft",
    "隐私与数据处理说明": "Privacy & Data Handling",
    "隐私政策说明": "Privacy Policy",
    "默认关闭。开启后，最近对话标题与收藏片段会写入本机 CoreSpotlight 以便从系统桌面搜索直达；关闭时会立即清空已写入的系统索引。": "Off by default. When enabled, recent chat titles and bookmarked excerpts are indexed locally in CoreSpotlight for home-screen search; turning this off immediately clears all indexed entries.",
})

INFO_PLIST_EN = {
    "CFBundleDisplayName": "Fugue",
    "CFBundleName": "Fugue",
    "NSCameraUsageDescription": "Used to take photos and send them to AI models for analysis.",
    "NSPhotoLibraryUsageDescription": "Used to choose images to send to AI models for analysis and Q&A.",
    "NSLocalNetworkUsageDescription": "Used to connect to model servers on your local network (such as Ollama or LM Studio). Requests go directly to the address you enter.",
    "NSMicrophoneUsageDescription": "Used to dictate chat messages by voice through the microphone.",
    "NSSpeechRecognitionUsageDescription": "Used to transcribe your voice into chat message text.",
    "NSCalendarsWriteOnlyAccessUsageDescription": "Used to add confirmed schedule items from conversations to your Calendar.",
    "NSRemindersFullAccessUsageDescription": "Used to add confirmed action items from conversations to your Reminders.",
}
INFO_PLIST_ZH = {
    "CFBundleDisplayName": "夜奔",
    "CFBundleName": "夜奔",
    "NSCameraUsageDescription": "用于拍摄照片并发送给 AI 模型进行多模态分析",
    "NSPhotoLibraryUsageDescription": "用于选择图片发送给 AI 模型进行识图与问答",
    "NSLocalNetworkUsageDescription": "用于连接你在局域网内部署的模型服务（如 Ollama、LM Studio），请求直接发往你填写的地址。",
    "NSMicrophoneUsageDescription": "用于通过麦克风进行语音听写输入对话内容。",
    "NSSpeechRecognitionUsageDescription": "用于将你的语音实时转换为对话文本输入。",
    "NSCalendarsWriteOnlyAccessUsageDescription": "用于在你点击确认后将对话中提炼的日程写入系统日历。",
    "NSRemindersFullAccessUsageDescription": "用于在你点击确认后将对话中提炼的待办事项加入系统提醒事项。",
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
