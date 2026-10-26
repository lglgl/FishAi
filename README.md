# FishAi（macOS 原生原型）

参考 Bob 的原生 macOS 截图翻译原型：截图 → Vision 本地 OCR → 系统翻译（Translation 框架），全程离线。

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
- 调试：`build/FishAi.app/Contents/MacOS/FishAi --image <图片路径>` 跳过截图直接识别翻译

> 构建使用 ad-hoc 签名，每次重新构建后系统可能要求重新授权屏幕录制。

## 结构

| 文件 | 作用 |
|---|---|
| `AppDelegate.swift` | 菜单栏、快捷键、串联流程 |
| `HotKey.swift` | Carbon 全局快捷键 |
| `ScreenCapture.swift` | 调用 `screencapture -i` 交互选区 |
| `TextRecognizer.swift` | Vision OCR |
| `TranslatorModel.swift` | 语言检测、目标语言、调用系统翻译 |
| `ResultPanel.swift` / `ResultView.swift` | 毛玻璃浮动面板与 Bob 风格 SwiftUI 界面 |
