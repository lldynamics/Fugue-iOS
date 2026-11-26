# App Store 提审凭据准备与加密出口合规核对清单

本文档梳理提交 App Store Connect 审核时的 **App Review 专用测试 API 准备方案（Guideline 2.1）** 与 **加密出口合规问卷填报依据（Export Compliance）**。

---

## 1. App Review 专用测试 API 凭据准备（防 Guideline 2.1 拒审）

夜奔（Fugue）是纯客户端 BYOK 应用，安装包内不内置开发者密钥。为确保审核员无需自备 API Key 即可在 10 秒内验证全部联网能力，提审前需准备一组**独立、限额、可随时吊销**的测试凭据：

### 推荐准备方式（任选其一）
1. **OpenRouter 独立受限子 Key（最省事）**
   - 在 OpenRouter 控制台创建一把专门命名为 `app-store-review` 的 Key，设置 **Credit Limit = \$5**，审核通过上架后可随时暂停或保留给后续版本审核。
   - 推荐测试模型：`openai/gpt-4.1-mini` 或 `google/gemini-2.5-flash`（兼顾文本、识图与流式速度，确保审核员测试拍照/传图也能直接通过）。
2. **自有网关 / Cloudflare Worker 轻量转发 Key**
   - 绑定自有 HTTPS 域名（如 `https://review-api.<yourdomain>/v1`），签发仅允许访问指定轻量模型的临时 Bearer Token，避免暴露主账号 Key，且不受单一上游地区网络波动影响。

### 填入 App Store Connect「App Review 审核备注」的整段配置块
代码中的 `ClipboardProviderParser` 已原生支持一次性解析 `Base URL`、`Protocol`、`Model ID` 与 `API Key`。将以下四行填入审核备注（详见 `docs/app-store/app-store-listing.md`）：

```text
Base URL: https://openrouter.ai/api/v1
Protocol: openai_compatible
Model ID: openai/gpt-4.1-mini
API Key: sk-or-v1-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

### 提审前自测 3 步核验
- [ ] 在真机或全新模拟器（无历史数据的空白状态）复制上述 4 行文本；
- [ ] 打开夜奔 → 点「写个新问题…」→ 点「连接模型」→ 展开「导入连接信息」→ 点「读取剪贴板自动识别」→ 点「验证连接」→ 确认首字响应成功并点「保存并继续」；
- [ ] 发送 1 条文字提问 + 1 张测试图片，确认首次「第三方 AI 数据直连说明」授权弹窗正常弹出、同意后流式回复正常输出。

---

## 2. 加密出口合规核对（Export Compliance）

### 代码库密码学能力全量盘点
经对工程源码及第三方依赖（`SwiftMath 1.7.3`、`ZIPFoundation 0.9.20`）逐项核查，夜奔**未自行实现任何加密算法，也未引入任何第三方密码学库**（无 OpenSSL / BoringSSL / libsodium 等）：

| 用途 | 调用的系统框架与算法 | 是否属于 Apple OS 内置加密 |
|---|---|---|
| 模型 API / 网页 / WebDAV 传输 | `Foundation.URLSession` 标准 HTTPS / TLS | 是（系统内置） |
| API Key 与敏感请求头本机存储 | `Security` 框架（iOS Keychain，`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`） | 是（系统内置） |
| 用户导出加密备份 & WebDAV 同步文件 | Apple `CryptoKit`（`AES.GCM` 256-bit、`SHA256`）+ 系统 `CommonCrypto`（`CCKeyDerivationPBKDF` / `PBKDF2-HMAC-SHA256`） | 是（系统内置） |

### `Info.plist` 声明与 App Store Connect 问卷填报对照

- 当前 `Config/Info.plist` 已配置：
  ```xml
  <key>ITSAppUsesNonExemptEncryption</key>
  <false/>
  ```
- **情形 A：上架国家/地区不包含法国（France）**
  - 由于应用**仅调用 Apple 操作系统内置加密接口**（Question: *"Does your app implement any standard encryption algorithms instead of, or in addition to, using or accessing the encryption within Apple's operating system?"* → **否 / No**），`ITSAppUsesNonExemptEncryption = false` 完全符合豁免条件，构建上传至 TestFlight 与 App Store 后无需额外上传 BIS/CCATS 文档即可直接过审。
- **情形 B：上架国家/地区包含法国（France）**
  - 法国 ANSSI 对含加密能力（含调用系统加密用于本地备份/云同步）的应用要求提交法国加密声明：
    1. 在 App Store Connect 进入 **App 信息 → 服务 → 加密（Encryption）**；
    2. 按向导勾选「仅使用 Apple 操作系统内置加密」并选择「将在法国上架」，下载简表签字上传；
    3. 获批后将 App Store Connect 生成的键值填入 `Config/Info.plist`：
       ```xml
       <key>ITSEncryptionExportComplianceCode</key>
       <string>【填入 App Store Connect 分配的合规代码】</string>
       ```

---

## 3. App Store Connect「App 隐私（营养标签）」勾选核对

与 `iOSBox/PrivacyInfo.xcprivacy` 及 `docs/app-store/privacy-policy.md` 保持严格一致：
- **数据收集（Data Collection）**：开发者无任何自建后端、中转服务器、账号系统、崩溃统计或广告/分析 SDK，所有模型请求均由用户设备直连用户自行填写的第三方接口 → 在 App Store Connect 的 App 隐私问卷中选择 **「否，我们不会从此 App 收集数据（No, we do not collect data from this app）」**。
- **追踪（Tracking）**：`NSPrivacyTracking = false`（不读取 IDFA，不跨应用追踪用户）。
