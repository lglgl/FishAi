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

- 菜单栏图标 → 截图翻译，或全局快捷键 `⌥S`
- 首次截图需要在「隐私与安全性 → 屏幕录制」中授权 FishAi
- 结果面板：可编辑原文后 `⌘↩` 重新翻译，`Esc` 关闭
- 设置：菜单栏图标 → 设置…（`⌘,`）
- 调试：`build/FishAi.app/Contents/MacOS/FishAi --image <图片路径>` 跳过截图直接识别翻译

> 构建使用 ad-hoc 签名，每次重新构建后系统可能要求重新授权屏幕录制，读取钥匙串中的 API Key 时也可能再次询问。

## 设置

| 项目 | 说明 |
|---|---|
| 翻译服务 | 分别开关「系统翻译」和「OpenAI 兼容接口」，结果面板为每个启用的服务显示一张卡片 |
| Base URL | 如 `https://api.openai.com/v1`，也可填完整的 `.../chat/completions` |
| API Key | 保存在系统钥匙串；本地服务（如 Ollama）可留空 |
| 模型 | 如 `gpt-4o-mini`、`deepseek-chat` |
| 提示词 | 系统提示词与用户提示词，变量：`{from}` 源语言、`{to}` 目标语言、`{text}` 原文 |

## 结构

| 文件 | 作用 |
|---|---|
| `AppDelegate.swift` | 菜单栏、快捷键、串联流程 |
| `HotKey.swift` | Carbon 全局快捷键 |
| `ScreenCapture.swift` | 调用 `screencapture -i` 交互选区 |
| `TextRecognizer.swift` | Vision OCR |
| `TranslatorModel.swift` | 语言检测、目标语言、调度各翻译服务 |
| `OpenAIClient.swift` | OpenAI 兼容接口（流式 / 非流式） |
| `AppSettings.swift` / `SettingsView.swift` | 设置存储（UserDefaults + 钥匙串）与设置窗口 |
| `ResultPanel.swift` / `ResultView.swift` | 毛玻璃浮动面板与 Bob 风格 SwiftUI 界面 |
