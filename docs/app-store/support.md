# 夜奔 Fugue 支持页草稿

> **发布前待确认** — 公开支持页 HTTPS 网址、支持邮箱、发布者公开名称，以及应公开的电话或地址（如适用）。确认是否公布服务时间和预计回复时间。隐私政策链接须指向已发布的政策页。

## 简体中文

### 开始使用

夜奔（Fugue）适用于运行 iOS 18 或 iPadOS 18 及以上版本的 iPhone 和 iPad。要开始聊天，请准备一个可用的模型接口。公网接口通常需要 API Key。允许免鉴权的自部署局域网接口可将密钥留空。

1. 打开「对话」，进入「连接模型」，选一个服务商或添加自定义接口。
2. 核对 API Base URL、协议和模型 ID，按需填写 API Key，再选「验证连接并使用此模型」。验证可能发送一条固定的测试消息。
3. 首次发送时核对接收服务商和数据范围，再决定是否发送。

### 请求失败或模型列表为空

先核对接口地址、协议、模型 ID 和服务商后台的 API 权限与额度。可在「设置」打开该服务商，刷新模型列表或手动添加模型。公网接口使用 HTTPS。连接局域网服务时，请确认设备和服务端可互通，并在系统设置中允许夜奔访问局域网。

费用疑问可在「设置 → 用量与费用账本」核对实际服务商和请求次数。账本中显示的费用是估算，服务商账单是最终金额。

### 书架和知识库

在「工作台 → 书架」导入文档，或在对话中绑定书架资料。要用第三方向量服务，在「设置 → 全文检索与知识库索引」选择服务商和模型，点「查看并授权向量服务」。确认页会列出接收方和可能发送的内容。向量服务不可用、未获授权或授权撤回后，知识库检索仍可使用本地索引。

在「设置 → 关于与隐私声明」可以分别撤回对话发送和向量服务授权，也可以管理 Spotlight、实时活动和桌面小组件的预览选项。「设置 → 隐私锁与防窥遮罩」可配置设备认证。

### 备份与换机

- 在「设置」选择「导出完整备份 (JSON)」，再保存文件。普通备份会省略 API Key，迁移后需要按需重新配置连接。
- 要连同凭据一起迁移，请选「导出密码加密备份 (含 API Key)」。请妥善保存备份和密码，导入时要使用该密码解密。
- 在新设备的「设置」选「从备份文件导入」。如使用 WebDAV，可在「设置 → WebDAV 加密云同步」检查服务器、凭据、路径和加密口令。

### 联系我们

支持邮箱 **【待确认：对外支持邮箱】**

发布者 **【待确认：公开发布者名称和适用的联系信息】**

来信请附设备型号、系统版本、夜奔版本、重现步骤和完整错误提示。连接问题可附服务商名称、模型 ID 和公开接口域名。截图请遮住密钥、私有地址、对话内容及个人信息。

隐私相关问题见 **【待确认：公开隐私政策 HTTPS 网址】**。

## English

### Get started

Fugue runs on iPhone with iOS 18 or later and iPad with iPadOS 18 or later. To start chatting, set up a working model endpoint. Public endpoints typically require an API key. You can leave the key blank for a self-hosted endpoint on your local network that allows unauthenticated access.

1. Open Chats, choose Connect a Model, and select a provider or add a custom endpoint.
2. Check the API base URL, protocol, and model ID. Enter your API key if needed, then choose Verify Connection and Use This Model. Verification can send a fixed test message.
3. Before the first send, review the receiving provider and the data involved, then decide whether to send.

### Fix a failed request or an empty model list

Check the endpoint, protocol, and model ID, then verify API permissions and quota with your provider. Open the provider in Settings to refresh its model list or add a model manually. Use HTTPS for public endpoints. For a local server, check that your device can reach it and that Fugue has Local Network permission in system Settings.

If you have a billing question, check the provider and request count in Settings → Usage & Cost Ledger. Fugue shows estimates. The provider’s bill determines the amount you pay.

### Bookshelf and knowledge search

Import documents in Workspace → Bookshelf or link bookshelf documents to a chat. To use a third-party embedding service, choose a provider and model in Settings → Full-Text Search & Knowledge Index, then tap Review and Authorize Embedding Service. The confirmation shows the recipient and what may be sent. Knowledge search can use the local index if permission is absent or revoked, or if the service is unavailable.

In Settings → About & Privacy, you can withdraw chat sending permission or embedding service permission and manage previews for Spotlight, Live Activities, and Home Screen widgets. Go to Settings → Privacy Lock & Blur Shield to configure device authentication.

### Back up or move to a new device

- In Settings, choose Export Full Backup (JSON) and save the file. A standard backup omits API keys. Set up your connections again as needed after moving to a new device.
- To move credentials with the backup, choose Export Encrypted Backup (Includes API Keys). Keep the file and its password safe. You will need the password to decrypt it on import.
- On the new device, choose Import from Backup in Settings. If you use WebDAV, check the server, credentials, path, and encryption passphrase in Settings → Encrypted WebDAV Cloud Sync.

### Contact us

Support email **[Confirm: public support email]**

Publisher **[Confirm: public publisher name and applicable contact details]**

Include your device model, system version, Fugue version, steps to reproduce the issue, and the full error message. For connection issues, you can also include the provider name, model ID, and public endpoint domain. Redact keys, private addresses, conversation contents, and personal information from screenshots.

For privacy questions, see **[Confirm: public HTTPS privacy policy URL]**.
