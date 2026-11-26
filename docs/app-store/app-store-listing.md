# 夜奔 Fugue 的 App Store 介绍草稿

> **发布前待确认** — 中英文名称及各区可用性、主语言、首发地区、免费或付费方案、主分类（可先选「效率」）、版权署名、支持和隐私网址。根据首发地区确认年龄分级、隐私标签和加密出口申报。审核备注需填可用的专用模型接口、模型 ID、临时凭据和审核联系人。截图使用正式版的 iPhone 和 iPad 界面。

## 简体中文

### 名称

夜奔

### 副标题

自带 API 的多模型对话与阅读

### 宣传文本

接入你常用的模型，同题比较回答。把书架文档带进对话，查看回答引用的原文，也可以把讨论与笔记导出。

### 介绍

夜奔是一款为 iPhone 和 iPad 设计的多模型 AI 对话与阅读工具。接入你已有的模型 API 或局域网模型，在同一处提问、阅读资料和整理结果。

• 比较不同模型。同一个问题可以交给多个模型并行回答。选中一条回复继续追问，或用 AI 圆桌让不同角色讨论同一个问题。

• 带着原文提问。导入 TXT、MD、EPUB、PDF、DOCX、XLSX 或 PPTX 文档，绑定书架资料后可查看回答引用的原文片段。读书时也可以和书中角色对话，按阅读进度限制参考章节。

• 整理工作和学习材料。用助手预设处理常用任务，搜索和收藏对话。可扫描文档并在本机识别文字，也可用兼容的接口转写音频。

• 保留自己的工作记录。查看模型用量和估算费用，将选中的对话导出为 Markdown 或 PDF。支持本地备份，也可以选择密码加密备份或连接自己的 WebDAV 服务器。

模型请求从设备直接发往你配置的服务，API Key 保存在系统钥匙串。开始 AI 对话需要自备可用的模型接口，API 用量按服务商规则计费。需要 iOS 18 或 iPadOS 18 及以上版本。

### 关键词

大模型对话,资料检索,语音笔记,模型接入,文档阅读,模型对比,文档扫描

## English

### Name

Fugue

### Subtitle

BYOK AI Chat and Reading

### Promotional text

Connect your own models, compare answers, and ask questions about documents from your bookshelf. See the source passages and export your work.

### Description

Fugue brings AI chat and document reading together on iPhone and iPad. Connect a model API you already use or a model on your local network. Ask questions, read your sources, and organize the results in one app.

• Compare models. Send the same question to several models in parallel. Pick a reply to continue from, or set up an AI roundtable to discuss a question from different perspectives.

• Ask questions with the source at hand. Import TXT, MD, EPUB, PDF, DOCX, XLSX, or PPTX documents, link them to a chat, and see the passages cited in an answer. You can also chat with a character from a book and limit references to chapters you’ve reached.

• Organize work and study materials. Use assistant presets for recurring tasks, search chats, and bookmark replies. Scan a document and recognize text on your device, or transcribe audio through a compatible endpoint.

• Keep a record of your work. See model usage and estimated costs, then export selected chats as Markdown or PDF. Back up locally, use a password-encrypted backup, or sync through your own WebDAV server.

Requests go directly from your device to the model services you configure. API keys are stored in the system Keychain. AI chat requires your own working model endpoint. Provider usage charges may apply. Requires iOS 18 or iPadOS 18 or later.

### Keywords

model comparison,document search,voice notes,local models,OCR,roundtable

## App Review 审核备注草稿

### 简体中文

夜奔无需注册应用账号。联网对话通过用户配置的模型接口运行。请直接复制下方测试连接配置块，在应用内一键导入即可完成审核测试：

```text
Base URL: 【待填入审核专用 HTTPS 接口地址，如 https://review-api.yourdomain.com/v1】
Protocol: 【待填入协议：openai_responses / openai_compatible / anthropic / gemini】
Model ID: 【待填入测试模型 ID，如 gpt-4.1-mini】
API Key: 【待填入审核专用临时 API Key】
```

审核联系人：**【待填入姓名、电话与邮箱】**

1. 打开应用，点「写个新问题…」，再点输入框上方的「连接模型」。
2. 展开「导入连接信息」，粘贴上方整段配置并点「识别」（或复制后直接点「读取剪贴板自动识别」），点「验证连接」，验证通过后点「保存并继续」。
3. 发送一条测试消息。首次发送会出现数据接收方与传输内容确认页，点「同意并继续发送」即可对话。
4. 如需试用书架问答，前往「资料库 → 书架」（iPad 为「工作台 → 书架」）导入一份测试文档（支持 `TXT / MD / EPUB / PDF / DOCX / XLSX / PPTX`），再在对话中绑定该文档即可提问并查看原文引用。

### English

Fugue does not require an app account. Online chat runs through a model endpoint configured by the user. Copy the dedicated review configuration block below to connect in one step:

```text
Base URL: [Enter HTTPS review endpoint, e.g. https://review-api.yourdomain.com/v1]
Protocol: [Enter protocol: openai_responses / openai_compatible / anthropic / gemini]
Model ID: [Enter review model ID, e.g. gpt-4.1-mini]
API Key: [Enter review-only temporary API key]
```

Review contact: **[Enter name, phone number, and email]**

1. Open Fugue, tap **Ask a new question…**, then tap **Connect a Model** above the message field.
2. Expand **Import connection details**, paste the block above and tap **Detect** (or copy it first and tap **Read Clipboard to Detect**), tap **Test connection**, and then tap **Save and Continue**.
3. Send a sample message. On the first request, review the recipient and data disclosure sheet, then tap **Agree and Send** to proceed.
4. To try document Q&A, open **Library → Bookshelf** (**Workspace → Bookshelf** on iPad), import a sample file (`TXT / MD / EPUB / PDF / DOCX / XLSX / PPTX`), and link it to a chat to see cited passages.
