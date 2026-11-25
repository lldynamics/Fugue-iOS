# 夜奔 Fugue 隐私政策草稿

> **发布前待确认** — 发布主体及适用的公开联系信息、生效日期、政策网址、首发地区与未成年人适用范围。请同时确认支持邮件与附件的保存期限、删除流程，发布网站的日志和分析工具，以及是否启用 Apple 诊断报告等发行端设置。请按实际发行版和接入服务核对 App Store 隐私标签。

## 简体中文

### 适用范围和联系方式

本政策适用于夜奔（Fugue）的 iPhone 和 iPad 版本，以及你就该应用向我们提出的支持请求。发布者为 **【待确认：发布者法定名称及适用的公开联系信息】**。政策自 **【待确认：生效日期】** 起生效。隐私或数据请求可发至 **【待确认：隐私联系邮箱】**。最新版政策见 **【待确认：公开隐私政策 HTTPS 网址】**。

### 保存在设备上的数据

夜奔无需注册夜奔账户。对话、草稿、附件、书架文档及索引、助手与人物资料、启用的个人记忆、闪卡、设置和用量记录主要保存在设备上。API 密钥和标记为敏感的请求头保存在系统钥匙串。你启用分享扩展等功能时，应用和扩展可通过本机共享容器或钥匙串交换相应的数据和配置。

夜奔的请求从设备直连下述接收方。发布者没有用于中转模型请求的服务器，应用也未接入广告或行为分析 SDK。你主动联系支持时提交的数据适用下文的支持条款。

### 启用联网功能时发送的数据

- **对话及模型连接。** 你确认第三方 AI 数据传输后，设备将本次请求用到的消息、历史上下文、提示词、附件或提取文字发给你配置的模型接口。启用相关功能时，请求还可能包含个人记忆、书架或人物资料的相关片段、搜索结果和工具结果。在多模型对比、圆桌或备用模型流程中，参与本次请求的服务商会收到各自所需的数据。认证信息随请求提供给相应的接口。验证连接时，应用可能验证凭据、读取模型列表并发送固定的测试消息。
- **书架向量索引。** 向量 API 有独立的授权。在设置中确认接收方、接口与模型后，手动生成书架索引会发送书架文档的原文片段。聊天或工具检索可发送查询词及需要生成向量的已绑定文档片段。生成的向量可保存在本机。未授权、撤回授权或接口不可用时，知识库检索使用本地索引。
- **联网搜索、网页和订阅。** 使用 Tavily 时，搜索词和 API 认证信息会发给 Tavily，返回的搜索摘要可随对话发给回答模型。启用取网页或模型服务商自带的搜索功能时，应用或你所选的服务商会访问相应网站或搜索服务。你启用人物动态订阅后，应用可在前台或由系统安排的后台刷新中访问所填的公开站点、RSS 或 Atom 订阅源。使用 X API 时，请求会携带你配置的 X 凭据。
- **语音。** 听写可使用 Apple 系统语音识别，是否在设备上处理取决于设备、语言及系统服务。选择云端转写会把所选录音发给配置的转写服务。使用云端朗读会把待朗读的文字发给配置的语音服务。转写结果随你发起的对话或摘要请求发送给所选模型。

这些接收方包括你填写的第三方服务、自部署地址及所用的网站。服务商可收到建立连接所需的信息，例如来源 IP 地址。服务商处理、保存和删除所收数据的方式以其政策、所在地区及你的服务设置为准。你可向相应服务商提出删除请求。

### 系统权限及显示选项

你可在 iOS 或 iPadOS 设置里管理系统权限。夜奔在你使用相应功能时调用相机或相册、麦克风和语音识别、局域网，或在你确认后将日程或事项写入系统日历和提醒事项。文档扫描和 OCR 可在本机处理，选择将结果用于模型请求时，结果按该功能的发送规则处理。启用隐私锁时，Face ID 或设备认证由系统完成。

Spotlight 对话索引、实时活动中的对话预览，以及桌面小组件中的最近对话标题可在「设置 → 关于与隐私声明」中管理。启用预览或索引后，部分标题、回答片段或收藏内容可能显示在相应的系统界面。你主动使用系统分享、快捷指令或导出时，所选内容可交给你选定的应用、系统功能或目的地。

### 备份、保留与删除

本机对话、文档、设置等会随应用数据保存。你可以在应用内删除或清空相应内容、移除服务商及其已保存的凭据，或关闭 Spotlight 索引。清空或删除对话后，不含正文和凭据的请求记录可保留在用量账本。

普通 JSON 备份可包含对话、附件、书架及设置等内容，并省略 API 密钥等敏感凭据。密码加密的完整备份可以包含这些凭据和完整接口配置。你启用 WebDAV 同步后，应用会按同步设置将加密备份或加密分片上传到你选择的服务器。同步服务器会处理建立连接所需的账号、网络信息和文件元数据。你可关闭同步。已导出的文件、备份或远端副本需在各自的存储位置或服务中删除。

在「设置 → 关于与隐私声明」可分别撤回对话发送和向量服务授权。撤回会影响后续发送。你也可以关闭联网搜索、语音服务、订阅或 WebDAV 同步，并在系统设置中变更权限。

### 联系支持和行使数据权利

联系我们时，支持方会收到你的联系方式、问题描述，以及你主动附上的截图或诊断信息，用于回复、排查和跟进。支持记录保存 **【待确认：期限及例外】**。如需查询、更正或删除支持记录，或对本政策有疑问，请发邮件至 **【待确认：隐私联系邮箱】**。我们会按 **【待确认：适用地区及处理方式】** 处理请求。涉及你配置的模型服务、网站或备份主机所保留的数据，请联系对应服务商。

**【待确认：未成年人适用范围及地区特定条款。】**

## English

### Scope and contact

This policy applies to Fugue for iPhone and iPad and to support requests you send us about the app. Fugue is published by **[Confirm: publisher’s legal name and applicable public contact details]**. This policy takes effect on **[Confirm: effective date]**. Send privacy or data requests to **[Confirm: privacy contact email]**. The current policy is available at **[Confirm: public HTTPS privacy policy URL]**.

### Data stored on your device

Fugue works without a Fugue account. Chats, drafts, attachments, bookshelf documents and indexes, assistants and character profiles, enabled memories, flashcards, settings, and usage records are primarily stored on your device. API keys and request headers marked sensitive are stored in the system Keychain. When you enable features such as the share extension, the app and its extensions can exchange the corresponding data and settings through shared storage or the Keychain on your device.

Fugue connects directly from your device to the recipients described below. The publisher operates no relay server for model requests, and the app includes no advertising or behavioral analytics SDKs. The support terms below cover the information you choose to send us when you ask for help.

### Data sent when you use online features

- **Chats and model connections.** After you confirm the third-party AI data disclosure, your device sends the messages, conversation history, prompts, attachments, or extracted text used for the request to the model endpoints you configured. Depending on your settings, a request can also include personal memories, relevant passages from your bookshelf or character references, search results, and tool results. When you compare models, run an AI roundtable, or use a fallback model, the providers involved receive the data needed for their part of the request. Authentication information accompanies requests to the relevant endpoints. Connection verification can check credentials, retrieve a model list, and send a fixed test message.
- **Bookshelf embeddings.** The embedding API requires separate permission. After you approve the recipient, endpoint, and model, manually building the bookshelf index sends passages from your documents. Chat and tool searches can send queries and passages from linked documents that need embeddings. Fugue can store the resulting vectors on your device. Knowledge search uses the local index if permission is absent or withdrawn, or if the endpoint is unavailable.
- **Web search, webpages, and feeds.** When you use Tavily, the search query and API authentication go to Tavily. Returned search summaries can be sent to the model answering your question. When you use webpage tools or a model provider’s built-in search, Fugue or the model provider may access the relevant websites or search services. If you enable character feed subscriptions, Fugue can request the selected public sites or RSS or Atom feeds when the app is open or during a background refresh scheduled by the system. Requests to the X API include the X credentials you configured.
- **Voice.** Dictation can use Apple’s system speech recognition. On-device processing depends on the device, language, and system service. Choosing cloud transcription sends the selected recording to your configured transcription service. Choosing cloud speech sends the text to be read aloud to your configured voice service. Transcripts are sent to the selected model when you use them in a chat or summary request.

Recipients include third-party services, self-hosted endpoints, and websites you use. Recipients can receive connection information such as your IP address. How a provider processes, retains, or deletes the information it receives depends on its policies, region, and your settings with that provider. Contact the provider directly to request deletion of data it has received.

### System permissions and display options

You can manage permissions in iOS or iPadOS Settings. Fugue uses the camera or photo library, microphone and speech recognition, and local network when you use the corresponding features. After you confirm, it can write events or tasks to Calendar and Reminders. Document scanning and OCR can process content on the device. If you use the result in a model request, the rules for that request apply. With Privacy Lock enabled, Face ID or device authentication is handled by the system.

Manage Spotlight indexing, conversation previews in Live Activities, and recent chat titles in Home Screen widgets in Settings → About & Privacy. Enabling these options can display some titles, reply excerpts, or bookmarked content on the corresponding system surfaces. When you use system sharing, Shortcuts, or export, the selected content can go to the app, system feature, or destination you choose.

### Backups, retention, and deletion

Chats, documents, settings, and related records stay with the app’s data on your device. You can delete or clear the relevant items in Fugue, remove a provider and its saved credentials, or turn off Spotlight indexing. Usage records without message contents or credentials can remain in the usage ledger after you clear or delete a chat.

A standard JSON backup can include chats, attachments, bookshelf items, and settings. It omits sensitive credentials such as API keys. A password-encrypted full backup can include those credentials and the complete endpoint settings. If you enable WebDAV, Fugue uploads encrypted backups or encrypted files to the server you choose according to your sync settings. The server handles the account, network information, and file metadata needed for the connection and storage. You can turn off sync. To delete exports, backups, or remote copies, remove them at the storage location or service that holds them.

In Settings → About & Privacy, you can separately withdraw chat sending permission and embedding service permission. Withdrawal applies to future transfers. You can also disable web search, voice services, feed subscriptions, or WebDAV sync and change system permissions in Settings.

### Support and data requests

If you contact us, support receives the contact information, problem description, and any screenshots or diagnostic details you choose to send. We use this information to reply, troubleshoot, and follow up. We retain support records for **[Confirm: retention period and exceptions]**. To request access, correction, or deletion of support records, or ask about this policy, email **[Confirm: privacy contact email]**. We handle requests in accordance with **[Confirm: applicable regions and handling process]**. Contact the relevant model provider, website, or backup host about data it retains.

**[Confirm: applicability to minors and any region-specific terms.]**
