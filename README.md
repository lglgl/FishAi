# FishAi（macOS 原生原型）

参考 Bob 的原生 macOS 截图翻译原型：截图 → Vision 本地 OCR → 翻译。翻译服务可同时启用：

- **系统翻译**：Apple Translation 框架，全程离线
- **OpenAI 兼容接口**：任意兼容 `/chat/completions` 的服务（OpenAI、DeepSeek、Ollama 等），流式输出，提示词可自定义

## 要求

- macOS 15+，Xcode 16+
- 在「系统设置 → 通用 → 语言与地区 → 翻译语言」中下载所需语言包（未下载时首次翻译会弹出系统下载提示）

## 构建与运行

```bash
./build.sh
open build/FishAi.app
```

- 截图翻译：全局快捷键 `⌥S`，或菜单栏图标 → 截图翻译
- 划词翻译：全局快捷键 `⌥D`，翻译前台应用中选中的文字（需在「隐私与安全性 → 辅助功能」中授权 FishAi）
- 剪贴板翻译：全局快捷键 `⌥V`，翻译剪贴板中的文字；剪贴板是图片时先识别文字
- 首次截图需要在「隐私与安全性 → 屏幕录制」中授权 FishAi
- 设置：菜单栏图标 → 设置…（`⌘,`）
- 调试：`build/FishAi.app/Contents/MacOS/FishAi --image <图片路径>` 跳过截图直接识别翻译；`--clipboard` 启动后立即执行剪贴板翻译

### 代码签名

`build.sh` 默认用钥匙串里名为 `FishAi Dev` 的证书签名（可用环境变量 `FISHAI_SIGN_IDENTITY` 指定其他证书）。固定证书签名后，系统按「Bundle ID + 证书」识别应用，重新构建不会丢失屏幕录制、钥匙串等授权。找不到证书时会退回 ad-hoc 签名，此时每次构建后都需要重新授权。

生成自签名证书（有效期 10 年）：

```bash
cat > /tmp/fishai-cert.cnf <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = FishAi Dev
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
cd /tmp && /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config fishai-cert.cnf -keyout fishai.key -out fishai.crt
/usr/bin/openssl pkcs12 -export -inkey fishai.key -in fishai.crt -name "FishAi Dev" \
  -out fishai.p12 -passout pass:fishai
security import fishai.p12 -k ~/Library/Keychains/login.keychain-db -P fishai -T /usr/bin/codesign
rm fishai.key fishai.p12
```

## 设置

| 页面 | 说明 |
|---|---|
| 通用 | 截图 / 划词 / 剪贴板翻译快捷键（点击录制，需包含 ⌘、⌥ 或 ⌃，可清除或恢复默认，被占用时警告）；系统翻译与大模型开关；是否保存翻译记录 |
| 模型 | 管理多个 OpenAI 兼容模型：名称、Base URL（`.../v1` 或完整 `.../chat/completions`）、API Key（存钥匙串）、模型名，可新建 / 复制 / 删除 / 测试连接 |
| 提示词 | 管理多组提示词：名称、系统提示词、用户提示词，变量 `{from}` 源语言、`{to}` 目标语言、`{text}` 原文。预置「翻译」「解释」「润色」 |
| 翻译记录 | 搜索、复制、删除、清空 |

## 翻译面板

- 中间两个下拉框选择大模型和提示词，切换后立即用新组合重新请求，可用于翻译、解释、润色或自定义问答
- 右上角图钉：未固定时点击其他应用即关闭面板；固定后面板常驻，新的翻译也不会移动位置
- 可编辑原文后 `⌘↩` 重新翻译，`Esc` 关闭

## 本地存储

模型配置与翻译记录保存在 SQLite 数据库 `~/Library/Application Support/FishAi/fishai.sqlite`：

| 表 | 内容 |
|---|---|
| `models` | 模型名称、Base URL、模型名 |
| `prompts` | 提示词名称、系统提示词、用户提示词 |
| `translations` | 时间、来源（截图 / 划词 / 剪贴板）、原文、源语言、目标语言、翻译服务、模型、译文 |

设置 →「翻译记录」可搜索、复制、删除和清空记录；「通用」里可关闭记录保存。旧版保存在 UserDefaults 中的配置会在首次启动时自动迁移。

## 结构

| 文件 | 作用 |
|---|---|
| `AppDelegate.swift` | 菜单栏、快捷键、串联流程 |
| `HotKey.swift` / `Shortcut.swift` | Carbon 全局快捷键与快捷键模型 |
| `ScreenCapture.swift` | 调用 `screencapture -i` 交互选区 |
| `TextRecognizer.swift` | Vision OCR |
| `SelectionReader.swift` | 读取选中文字（辅助功能接口，失败时模拟 ⌘C 并还原剪贴板） |
| `TranslatorModel.swift` | 语言检测、目标语言、调度各翻译服务 |
| `OpenAIClient.swift` | OpenAI 兼容接口（流式 / 非流式） |
| `AppSettings.swift` / `SettingsView.swift` | 设置（UserDefaults + SQLite + 钥匙串）与设置窗口（通用 / 模型 / 提示词 / 翻译记录） |
| `Database.swift` / `HistoryStore.swift` | SQLite 存储（模型、提示词、翻译记录，带版本迁移） |
| `ResultPanel.swift` / `ResultView.swift` | 毛玻璃浮动面板与 Bob 风格 SwiftUI 界面 |
