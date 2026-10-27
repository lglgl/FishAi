# FishAi 开发约定

> 面向开发者（包括 AI）。给用户看的说明在 [README.md](README.md)（用户手册）。

每次修改都要加入单次修改的内容和时间（在update log文件)！！！

macOS 原生的截图 / 划词 / 剪贴板翻译工具，交互参考 Bob。文字识别用系统 Vision（本地 OCR），翻译可以同时走两路：

- **系统翻译**（默认）：Apple Translation 框架，离线，作为内置模型出现在模型列表第一位
- **大模型**：任意 OpenAI 兼容的 `/chat/completions` 接口（OpenAI、DeepSeek、智谱、Ollama 等），流式输出，可以和提示词自由组合

翻译面板里选哪个模型，就用哪种方式翻译。

本文档写给接手的开发者（包括 AI）：读完就能构建、运行、理解架构并继续开发。

---

## 1. 快速开始

### 环境要求

| 项目   | 要求                                                                                                                              |
| ------ | --------------------------------------------------------------------------------------------------------------------------------- |
| 系统   | macOS 15+（Translation 框架的 `.translationTask` 从 15 开始提供）                                                               |
| 工具链 | Xcode 16+ / Swift 6 工具链（`Package.swift` 是 `swift-tools-version: 6.0`，语言模式锁在 Swift 5）                             |
| 依赖   | 无第三方依赖，只用系统框架：AppKit、SwiftUI、Vision、Translation、NaturalLanguage、Carbon、ApplicationServices、Security、SQLite3 |

### 构建与运行

```bash
./build.sh                  # swift build -c release → 组装 build/FishAi.app → 签名
open build/FishAi.app       # 菜单栏出现气泡图标，没有 Dock 图标
./build.sh community        # 社区版 dmg（免费，不公证），见下方「社区版发布」
./build.sh release          # 正式版 dmg，见下方「发布（Developer ID + 公证）」
```

`build.sh` 不依赖 Xcode 工程。它先 `swift build`，再手工组装 `.app`（写 Info.plist，`LSUIElement=true`，Bundle ID `com.lglgl.FishAi`），最后用 `/usr/bin/codesign` 签名。这里特意写了绝对路径：有些机器上 anaconda 带了一个同名的 `codesign`，会抢在系统的前面。

### 代码签名（重要）

`build.sh` 默认用钥匙串里名为 **`FishAi Dev`** 的证书签名，也可以用 `FISHAI_SIGN_IDENTITY` 指定别的证书；找不到证书时退回 ad-hoc 签名。

原因：ad-hoc 签名时，系统按每次构建的 cdhash 识别应用，**一重新构建，屏幕录制、辅助功能、钥匙串的授权就全部失效**。用固定证书签名后，系统按「Bundle ID + 证书」识别，授权可以一直保留。新机器上可以这样生成自签名证书，有效期 10 年：

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

验证签名：`codesign -d -r- build/FishAi.app`，输出应为 `designated => identifier "com.lglgl.FishAi" and certificate leaf = H"…"`。如果输出是 `cdhash H"…"`，说明退回了 ad-hoc 签名。

### 社区版发布（免费，不公证）

没有 Apple 开发者账号时用这种方式，在 GitHub Releases 分发：

1. 修改 `build.sh` 顶部的 `VERSION` / `BUILD_NUMBER`，在 `UPDATE_LOG.md` 记一笔；
2. `./build.sh community`：编译通用二进制（arm64 + x86_64），用 `FishAi Dev` 证书签名，生成 `build/FishAi-<版本>.dmg` 和 `.sha256` 校验文件；
3. 在 GitHub 上新建 Release（标签如 `v0.1.0`），上传 dmg 和 `.sha256`，说明里贴上用户手册里的「安装」一节。

**所有社区版都必须用同一张 `FishAi Dev` 证书签名。** 系统按「Bundle ID + 证书」识别应用：证书不变，用户更新后屏幕录制、辅助功能授权仍然有效；换证书或退回 ad-hoc，每次更新都要重新授权。所以脚本找不到证书时直接报错，而不是退回 ad-hoc。证书私钥要备份（钥匙串访问 → 导出 .p12），换电脑时导入。

社区版没有公证，用户第一次打开会被 Gatekeeper 拦下，需要在「系统设置 → 隐私与安全性」里点「仍要打开」（macOS 15 起右键「打开」不再能绕过）。如果以后加入 Apple Developer Program，改用下面的 `release` 模式，用户就能直接打开。注意 Developer ID 证书和 `FishAi Dev` 不同，从社区版换到正式版时用户需要重新授权一次。

### 发布（Developer ID + 公证）

FishAi 不上 App Store：App Store 要求开启沙盒，开了以后就不能用辅助功能读取选中文字。发布版通过官网或 GitHub 分发 dmg，`./build.sh release` 会依次完成：

1. 编译通用二进制（arm64 + x86_64）；
2. 用 Developer ID Application 证书签名，开启 Hardened Runtime（`--options runtime`）并加时间戳；
3. 打包 `build/FishAi-<版本>.dmg`（内含 `/Applications` 快捷方式），并给 dmg 签名；
4. 用 `notarytool` 提交公证并等待结果，被拒时打印苹果返回的日志；
5. 用 `stapler` 把公证票据装订到 dmg 和 `build/FishAi.app`，最后用 `spctl` 验证。

一次性准备：

- 加入 Apple Developer Program，在 Xcode → Settings → Accounts → Manage Certificates 里创建 **Developer ID Application** 证书；
- 在 appleid.apple.com 生成 App 专用密码，把公证凭据存进钥匙串：
  ```bash
  xcrun notarytool store-credentials FishAi-notary --apple-id <Apple ID> --team-id <Team ID> --password <App 专用密码>
  ```

脚本默认使用钥匙串里第一个 Developer ID Application 证书和 `FishAi-notary` 凭据，可以用 `FISHAI_DEVELOPER_ID`、`FISHAI_NOTARY_PROFILE` 覆盖。版本号写在 `build.sh` 顶部的 `VERSION` / `BUILD_NUMBER`，每次发布前修改。

注意：Developer ID 证书和本地的 `FishAi Dev` 证书不同，系统会把它们当成两个应用，屏幕录制、辅助功能等权限要重新授权一次。

### 首次运行需要的系统权限

| 权限               | 用途                               | 何时申请                                                             |
| ------------------ | ---------------------------------- | -------------------------------------------------------------------- |
| 屏幕与系统音频录制 | 截图翻译                           | 第一次按 `⌥S`                                                     |
| 辅助功能           | 划词翻译（读取选中文字、模拟 ⌘C） | 第一次按 `⌥D`                                                     |
| 钥匙串访问         | 读取各模型的 API Key               | 第一次读取时，选「始终允许」                                         |
| 翻译语言包         | 系统翻译                           | 「系统设置 → 通用 → 语言与地区 → 翻译语言」，没下载时系统会弹提示 |

授权后需要**退出 FishAi 再重新打开**才生效。重复执行 `open` 只会激活正在运行的那个旧进程，不会重启。

---

## 2. 功能一览

| 功能       | 默认快捷键            | 说明                                                |
| ---------- | --------------------- | --------------------------------------------------- |
| 截图翻译   | `⌥S`               | `screencapture -i` 框选区域 → Vision OCR → 翻译 |
| 划词翻译   | `⌥D`               | 读取前台应用选中的文字 → 翻译                      |
| 剪贴板翻译 | `⌥V`               | 剪贴板有文字就直接翻译；是图片则先 OCR 再翻译       |
| 设置       | `⌘,`（菜单栏菜单） | 通用 / 模型 / 提示词 / 翻译记录 四个标签页          |

翻译面板（浮动的毛玻璃窗口）：

- **原文卡片**：可以编辑，`⌘↩` 重新翻译
- **语言栏**：显示检测到的源语言，目标语言可选（「自动」= 原文是中文译成英文，否则译成简体中文）
- **模型 / 提示词下拉框**：模型默认是「系统翻译」；选了大模型才能选提示词。切换后立即重新翻译
- **结果卡片**：显示所选模型的结果（「系统翻译」或「模型名 · 提示词名」），大模型流式输出，可以复制
- **右上角图钉**：不固定时，点击其他应用或切到其他应用就关闭面板；固定后面板常驻，位置也不再跟随鼠标
- `Esc` 关闭

设置窗口：

| 页面     | 内容                                                                                                                                          |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| 通用     | 三个快捷键（点击录制，需包含 ⌘ / ⌥ / ⌃，F1–F12 可单独用；可清除、恢复默认；被占用时显示橙色警告）；是否保存翻译记录                       |
| 模型     | 左边列表（新建 / 删除 / 复制），第一项是内置的「系统翻译」（带锁，不可删除或编辑）；大模型右边编辑：名称、Base URL、API Key、模型名、测试连接 |
| 提示词   | 左边列表，右边编辑：名称、系统提示词、用户提示词。预置「翻译」「解释」「润色」                                                                |
| 翻译记录 | 搜索原文或译文，右键复制或删除，可以清空                                                                                                      |

---

## 3. 目录结构

```
FishAi/
├── Package.swift              SwiftPM 清单：单个 executableTarget，macOS 15，Swift 5 语言模式
├── build.sh                   构建 → 组装 .app（Info.plist）→ 签名；community 模式打包 dmg；release 模式另做 Developer ID 签名、公证
├── README.md                用户手册
├── DEVELOPMENT.md           开发约定（本文档）
├── UPDATE_LOG.md            每次修改的内容和时间
├── .gitignore                 忽略 .build/ 和 build/
└── Sources/FishAi/
    ├── main.swift             入口：NSApplication + AppDelegate，设为 .accessory（无 Dock 图标）
    ├── AppDelegate.swift      编排层：菜单栏菜单、隐藏主菜单、注册全局快捷键、三个功能入口、设置窗口
    │
    ├── HotKey.swift           Carbon RegisterEventHotKey 封装；注册失败返回 nil（用于检测冲突）
    ├── Shortcut.swift         快捷键模型（Carbon keyCode + 修饰键），可 Codable；从 NSEvent 构造；显示字符串
    │
    ├── ScreenCapture.swift    屏幕录制权限检查与引导；调用 /usr/sbin/screencapture -i -x 交互截图
    ├── SelectionReader.swift  读取选中文字：AX API（kAXSelectedTextAttribute），失败时模拟 ⌘C 并还原剪贴板
    ├── TextRecognizer.swift   Vision VNRecognizeTextRequest（accurate，自动检测语言），按行拼接
    │
    ├── TranslatorModel.swift  面板的 ViewModel：语言检测、目标语言、驱动系统翻译和大模型、写入记录
    ├── OpenAIClient.swift     OpenAI 兼容 Chat Completions：流式 SSE，退化为非流式，错误解析
    │
    ├── ResultPanel.swift      NSPanel（浮动、毛玻璃、可成为 key）+ 控制器（定位、图钉、失焦关闭）
    ├── ResultView.swift       SwiftUI 面板：原文卡片、语言栏、模型/提示词栏、结果卡片；挂 .translationTask
    │
    ├── AppSettings.swift      全局设置单例：UserDefaults 开关、快捷键、模型/提示词增删改、当前选择、钥匙串、旧数据迁移
    ├── Database.swift         libsqlite3 轻封装 + schema 版本迁移 + 模型/提示词/记录的 CRUD；数据模型定义也在这里
    ├── HistoryStore.swift     翻译记录的 ObservableObject（写入、搜索、删除、清空）
    └── SettingsView.swift     设置窗口：TabView（通用 / 模型 / 提示词 / 翻译记录）、ManagerLayout、ShortcutRecorder
```

共 16 个 Swift 文件，约 2000 行。最大的几个是 `SettingsView`（约 420 行）、`Database`（约 300 行）、`AppSettings`（约 260 行）。

---

## 4. 架构

### 分层

```
┌──────────────────────────────────────────────────────────────────────┐
│ 入口 / 编排   main.swift → AppDelegate                                │
│              菜单栏菜单 · 全局快捷键(HotKey) · 截图/划词/剪贴板三个入口 · 设置窗口 │
├──────────────────────────────────────────────────────────────────────┤
│ 输入采集     ScreenCapture   SelectionReader   NSPasteboard            │
│              TextRecognizer（图片 → 文字）                              │
├──────────────────────────────────────────────────────────────────────┤
│ 翻译编排     TranslatorModel（@MainActor ObservableObject）              │
│              按所选模型二选一：                                         │
│              ├─ 系统翻译：设置 TranslationSession.Configuration          │
│              │            → ResultView 的 .translationTask 回调 run()   │
│              └─ 大模型：OpenAIClient.translate（流式回调 onDelta）        │
├──────────────────────────────────────────────────────────────────────┤
│ 界面         ResultPanelController / ResultPanel / ResultView           │
│              SettingsView（四个标签页）                                  │
├──────────────────────────────────────────────────────────────────────┤
│ 状态与存储   AppSettings（单例）  HistoryStore（单例）  Database（单例）  │
│              UserDefaults · SQLite · 钥匙串                              │
└──────────────────────────────────────────────────────────────────────┘
```

### 主流程（以截图翻译为例）

```
⌥S（Carbon 热键） ─► AppDelegate.screenshotTranslate()
  ├─ ScreenCapture.ensurePermission()            未授权：CGRequestScreenCaptureAccess + 提示框
  ├─ ScreenCapture.captureInteractively()        子进程 screencapture -i -x <tmp.png>，Esc 取消返回 nil
  └─ recognizeAndTranslate(image, origin: .screenshot)
       ├─ panel.show()                            首次显示定位到鼠标附近；激活本应用
       ├─ model.beginRecognizing(origin:)         清空状态，显示“正在识别文字…”
       ├─ TextRecognizer.recognize(image)         Vision OCR（后台队列）
       └─ model.setSource(text, origin:) → translate()
            ├─ NLLanguageRecognizer 检测源语言 → resolvedTarget() 得到目标语言
            ├─ 所选模型是系统翻译：awaitingSystem = true；configuration = .init(source:target:)，相同则 invalidate()
            │     └─ SwiftUI .translationTask 触发 → model.run(session) → session.translate()
            │           → result = .done → record(service: "system")
            └─ 所选模型是大模型：startOpenAI(text)
                  └─ Task { OpenAIClient.translate(..., onDelta) }   每个增量追加到 result.text
                        → result = .done → record(service: "openai", model: "模型名 · 提示词名")
```

划词（`⌥D`）和剪贴板（`⌥V`）只是入口不同：拿到文字后直接调用 `panel.show()` + `model.setSource(text, origin:)`，剪贴板是图片时走 `recognizeAndTranslate`。

### 关键设计

- **系统翻译只能在 SwiftUI 里拿到 session。** macOS 15 上没有公开的 `TranslationSession` 构造器（26 以后的 `init(installedSource:)` 只适用于已安装的语言），所以要通过 `ResultView` 上的 `.translationTask(model.configuration)` 拿 session。`TranslatorModel` 改写 `configuration`，或调用 `invalidate()`，就会触发一次 `run(_:)`。**面板视图必须已经创建**：`panel.show()` 要在 `setSource` 之前调用。
- **一个模型对应一个结果。** `TranslatorModel.result` 只保存当前所选模型的结果。切换模型或提示词下拉框时直接调 `translate()`（系统翻译模式下切换提示词不触发）。
- **取消。** 每次新翻译都会 `cancelPending()`：取消大模型 Task（流式回调和结束时都会检查 `Task.isCancelled`），并清除 `awaitingSystem`，丢弃迟到的系统翻译回调，避免旧结果覆盖新结果。
- **提示词变量。** `{from}`、`{to}` 用英文语言名（`englishName`，比如 `Chinese, Simplified`），`{text}` 是原文。系统提示词为空时不发 system 消息。
- **OpenAI 兼容处理。** Base URL 可以填 `…/v1`，也可以填完整的 `…/chat/completions`。响应是 `text/event-stream` 就按 SSE 逐行解析 `data:`；否则读完整个 body，按非流式 JSON 解析，非 200 时取 `error.message`。没有填 API Key 就不带 `Authorization` 头（适用于本地 Ollama）。不发送 `temperature`，因为部分推理模型会拒绝这个参数。
- **全局快捷键。** 用 Carbon `RegisterEventHotKey`，不需要辅助功能权限。`AppSettings` 里三个快捷键或 `isRecordingShortcut` 一变，就调 `registerHotKeys()` 全部重新注册。录制快捷键期间会暂停全部热键，防止按下已注册的组合时触发功能。注册失败的写入 `shortcutConflicts`，设置页据此显示警告。注意：`@Published` 在 willSet 时发出通知，所以订阅里要 `.receive(on: DispatchQueue.main)` 推迟一拍，再读取新值。
- **菜单栏应用的编辑快捷键。** `.accessory` 应用默认没有主菜单，`⌘C`、`⌘V`、`⌘W` 都不生效。`setupMainMenu()` 建了一个不显示的主菜单（应用菜单 + 编辑菜单）来响应这些快捷键。
- **面板点击外部关闭。** `ResultPanelController` 注册了全局鼠标监听 `NSEvent.addGlobalMonitorForEvents(.leftMouseDown/.rightMouseDown/.otherMouseDown)`（只会收到发往其他应用的点击，不需要辅助功能权限），并监听 `NSApplication.didResignActiveNotification`。没有固定时，这两种事件都会让面板 `orderOut`；点击本应用的窗口或菜单栏图标不会触发。早期用 `windowDidResignKey` 判断，在浮动面板上不可靠，已经弃用。图钉按钮是 `NSTitlebarAccessoryViewController`（`.trailing`），没有放在 SwiftUI 里，因为透明标题栏区域的 SwiftUI 控件不一定能收到点击。
- **划词。** 先用 AX 读 `kAXFocusedUIElement → kAXSelectedText`，原生应用一般都能读到。读不到时（Chrome、Electron 等）就备份剪贴板的全部条目，发送一个 flags 只含 `.maskCommand` 的 ⌘C（这样可以忽略用户还按着的 ⌥），再轮询 `changeCount`，最多约 500ms，读完后还原剪贴板。
- **并发模型。** 所有状态类（`AppSettings`、`HistoryStore`、`Database`、`TranslatorModel`、`AppDelegate`）都是 `@MainActor`。SQLite 操作都很小，直接在主线程执行。Vision 在全局队列上执行；网络请求用 URLSession 的 async API。

---

## 5. 数据与存储

| 数据                   | 位置                                                                             |
| ---------------------- | -------------------------------------------------------------------------------- |
| 模型、提示词、翻译记录 | SQLite：`~/Library/Application Support/FishAi/fishai.sqlite`（WAL 模式）       |
| 开关、快捷键、当前选择 | UserDefaults，域 `com.lglgl.FishAi`                                            |
| API Key                | 登录钥匙串，service `com.lglgl.FishAi`，account `openai-api-key-<models.id>` |

### SQLite schema（`PRAGMA user_version = 3`）

```sql
CREATE TABLE models (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,              -- 显示名，如「DeepSeek」
    base_url TEXT NOT NULL,          -- https://api.openai.com/v1 或完整 /chat/completions
    model TEXT NOT NULL,             -- 请求体里的 model 字段（系统翻译为空）
    kind TEXT NOT NULL DEFAULT 'openai', -- system（内置系统翻译，唯一且不可删）| openai
    created_at REAL NOT NULL,        -- Unix 时间戳（秒）
    updated_at REAL NOT NULL
);

CREATE TABLE prompts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,              -- 如「翻译」「解释」「润色」
    system_prompt TEXT NOT NULL,     -- 支持 {from} {to} {text}
    user_prompt TEXT NOT NULL,       -- 默认 "{text}"
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL
);

CREATE TABLE translations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at REAL NOT NULL,
    origin TEXT NOT NULL,            -- screenshot | selection | clipboard | manual
    source_text TEXT NOT NULL,
    source_lang TEXT,                -- 检测到的语言，如 en；可能为空
    target_lang TEXT NOT NULL,       -- 如 zh、en
    service TEXT NOT NULL,           -- system | openai
    model TEXT,                      -- openai 时为「模型名 · 提示词名」
    result_text TEXT NOT NULL
);
CREATE INDEX idx_translations_created_at ON translations (created_at DESC);
```

### 迁移

`Database.migrate()` 按 `user_version` 依次执行：

- **v1**：建 `model_configs`（模型和提示词放在同一张表）和 `translations`。
- **v2**（在一个事务里）：建 `models` 和 `prompts`。把 `model_configs` **保留原 id** 复制到 `models`，这样钥匙串的 `openai-api-key-<id>` 仍能对上。旧配置里的提示词去重后写入 `prompts`（第一组叫「翻译」）。最后删除 `model_configs`。
- **v3**（在一个事务里）：`models` 增加 `kind` 列，插入一条 `kind = 'system'` 的「系统翻译」。`fetchModels()` 按 `kind = 'system' DESC, id` 排序，所以系统翻译总在第一位；`deleteModel` 的 SQL 里也排除了 system。

新增 schema 变更时，加一个 `migrateToV4()`，在 `migrate()` 里追加 `if version < 4`，并把 `user_version` 设为 4。

`AppSettings.init` 里还有两步应用层的初始化，每一步都可以重复执行：

1. `migrateLegacyConfigIfNeeded()`：最早的版本把单组配置存在 UserDefaults（`openAIBaseURL` 等）和钥匙串（`openai-api-key`）。存在这些旧值、又还没有大模型时，用它们建一个「默认」模型，再清掉旧键（连同 v3 起不再使用的 `systemEnabled`、`openAIEnabled`）；旧 API Key 归到第一个大模型名下。
2. 预置提示词只补一次（标记 `builtinPromptsSeeded`）：名称不重复的「翻译」「解释」「润色」才会插入，用户删掉后不会再出现。
3. 系统翻译设为默认模型只做一次（标记 `systemModelDefaulted`），之后尊重用户在面板里的选择。

### UserDefaults 键

| 键                                                                     | 类型                                                                        | 默认                                       |
| ---------------------------------------------------------------------- | --------------------------------------------------------------------------- | ------------------------------------------ |
| `historyEnabled`                                                     | Bool                                                                        | true                                       |
| `selectedModelID` / `selectedPromptID`                             | Int64                                                                       | 不存在时取第一个（模型的第一个即系统翻译） |
| `systemModelDefaulted`                                               | Bool                                                                        | false                                      |
| `screenshotShortcut` / `selectionShortcut` / `clipboardShortcut` | Data（JSON 编码的 `Shortcut`）。键不存在 = 用默认值；空 Data = 用户已清除 | `⌥S` / `⌥D` / `⌥V`                |
| `builtinPromptsSeeded`                                               | Bool                                                                        | false                                      |

---

## 6. 调试与测试

项目目前**没有自动化测试**。验证方式如下：

- **调试启动参数**（直接运行可执行文件）：
  ```bash
  build/FishAi.app/Contents/MacOS/FishAi --image <图片路径>   # 跳过截图，直接 OCR 并翻译这张图
  build/FishAi.app/Contents/MacOS/FishAi --clipboard          # 启动后立即执行一次剪贴板翻译
  ```
- **模拟大模型接口**：用 Python 写一个本地 HTTP 服务，分别返回 SSE 流、普通 JSON、401 错误，然后把某个模型的 Base URL 指向 `http://127.0.0.1:<port>/v1`。服务端记录收到的请求体，可以核对提示词变量替换得对不对。
- **单独测某个文件**：`swiftc` 可以把单个源文件和一个测试用的 `main.swift` 一起编译，比如 `Database.swift`、`OpenAIClient.swift`、`Shortcut.swift + HotKey.swift`。数据库测试用临时路径：`Database(url:)`。
- **查看数据**：
  ```bash
  sqlite3 ~/Library/Application\ Support/FishAi/fishai.sqlite "select * from models; select * from prompts;"
  defaults read com.lglgl.FishAi
  ```
- **系统日志**：`/usr/bin/log show --last 5m --predicate 'process == "FishAi"'`（有些 shell 里 `log` 被定义成了别的函数，所以写绝对路径）。截图权限问题查 `process == "screencapture"`，看有没有 `TCC Disallow`。

---

## 7. 已知问题与坑

| 现象                                   | 原因 / 处理                                                                                                           |
| -------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| 每次重新构建后又要授权                 | 用的是 ad-hoc 签名。改用 `FishAi Dev` 证书签名，见第 1 节                                                           |
| 截图没有弹出框选                       | 应用没有屏幕录制权限，系统会静默拒绝。日志里能看到 `TCC Disallow`。授权后要重启应用                                 |
| 第一次 OCR 要 20–30 秒                | 系统要为神经网络引擎（ANE）编译 OCR 模型，之后会缓存。如果每次都慢（缓存失效），执行 `sudo killall aned` 或重启电脑 |
| 运行 `open` 后新代码没生效           | 旧进程还在运行。先从菜单栏退出，再打开                                                                                |
| 迁移时卡住                             | 读取旧钥匙串项会弹授权框，此时进程在等待。不要强杀；迁移可以重复执行，下次启动会补完                                  |
| `codesign` 报 NotAMachOFileException | PATH 里有别的 `codesign`（anaconda）。脚本已经写死 `/usr/bin/codesign`                                            |
| 划词在部分应用里取不到                 | AX 读不到时会走模拟 ⌘C 的方式。两种方式都依赖辅助功能权限                                                            |

---

## 8. 待办 / 可改进

- **界面打磨**（对照 Bob）：
  - 语言名太长：现在显示的是「English (Latin, United States)」，应只显示语言名；
  - 源语言在原文卡片和语言栏重复显示了两遍；
  - 卡片高度固定，应该随内容自适应；
  - 顶部留白偏大；
  - 目标语言下拉框样式偏重；
  - OCR 结果首尾会出现孤立的符号（如「•」），可以过滤掉。
- 自动化测试：Database 迁移、OpenAIClient 解析、Shortcut 编解码都适合写单元测试（可以拆出一个 library target）。
- 翻译记录目前只取最近 500 条，没有分页或导出。
- 大模型请求没有设置超时重试或并发控制；也不支持在一次请求里同时跑多个模型。
- 发布：没有公证（notarization），没有自动更新，没有应用图标。
- 只支持 macOS。

---

## 9. 开发约定

每次修改都要加入单次修改的内容和时间（在update log文件)！！！

- 代码注释和界面文案用中文，标识符用英文，界面保持简洁。
- 不引入第三方依赖，
- UI 状态和存储都在 `@MainActor` 上；新的状态类也照此处理。
- 新增设置项：UserDefaults 键加到 `AppSettings.Key`，在 `init` 里读出初始值，在 `didSet` 里写回。结构化数据放 SQLite，同时加一个迁移版本。
- 新增全局快捷键：在 `Shortcut` 里加默认值，在 `AppSettings` 里加 `@Published` 属性、键和 `ShortcutAction`，在 `AppDelegate.registerHotKeys()` 的 `bindings` 里加一行，在合并订阅里也加上并调整 `dropFirst` 的数量，最后在 `GeneralSettingsView` 里加一个 `ShortcutRecorder`。
- 新增一种翻译引擎：在 `LLMModel.Kind` 里加一个值（必要时加 schema 迁移），在 `TranslatorModel.translate()` 里按 kind 分支并实现启动 / 取消逻辑，完成时调 `record(service:)`；在 `ModelsView` 里为它提供编辑界面。
- 提交信息用英文，祈使句。
