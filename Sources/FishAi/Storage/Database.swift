import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 一个翻译模型：内置的系统翻译，或 OpenAI 兼容的大模型接口（API Key 不入库，按 id 存在钥匙串）
struct LLMModel: Identifiable, Equatable {
    enum Kind: String {
        /// macOS 系统翻译（Apple Translation 框架），内置且不可删除
        case system
        case openAI = "openai"
    }

    var id: Int64
    var name: String
    var baseURL: String
    var model: String
    var kind: Kind = .openAI

    var isSystem: Bool { kind == .system }
}

/// 一组提示词，变量：{from} 源语言、{to} 目标语言、{text} 原文
struct PromptTemplate: Identifiable, Equatable {
    var id: Int64
    var name: String
    var systemPrompt: String
    var userPrompt: String
}

/// 一条翻译记录
struct TranslationRecord: Identifiable, Equatable {
    enum Origin: String {
        case screenshot, selection, clipboard, manual
    }

    var id: Int64 = 0
    var createdAt = Date()
    var origin: Origin
    var sourceText: String
    var sourceLang: String?
    var targetLang: String
    /// "system" 或 "openai"
    var service: String
    /// OpenAI 兼容接口使用的模型与提示词，如 "GPT-4o mini · 翻译"
    var model: String?
    var resultText: String
}

/// 基于系统 libsqlite3 的本地存储，位于 ~/Library/Application Support/FishAi/fishai.sqlite
@MainActor
final class Database {
    static let shared = Database()

    enum Value {
        case int(Int64), text(String), real(Double), null
    }

    struct DBError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var db: OpaquePointer?

    nonisolated static var defaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FishAi", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("fishai.sqlite")
    }

    /// 打开失败时退回内存数据库，保证应用可用
    init(url: URL = Database.defaultURL) {
        if sqlite3_open(url.path, &db) != SQLITE_OK {
            NSLog("[FishAi] open database failed: %@", String(cString: sqlite3_errmsg(db)))
            sqlite3_close(db)
            sqlite3_open(":memory:", &db)
        }
        try? migrate()
    }

    private func migrate() throws {
        try execute("PRAGMA journal_mode = WAL")
        let version = try query("PRAGMA user_version", row: { $0.int(0) }).first ?? 0
        if version < 1 { try migrateToV1() }
        if version < 2 { try migrateToV2() }
        if version < 3 { try migrateToV3() }
        if version < 4 { try migrateToV4() }
    }

    private func migrateToV1() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS model_configs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                base_url TEXT NOT NULL,
                model TEXT NOT NULL,
                system_prompt TEXT NOT NULL,
                user_prompt TEXT NOT NULL,
                is_active INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS translations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at REAL NOT NULL,
                origin TEXT NOT NULL,
                source_text TEXT NOT NULL,
                source_lang TEXT,
                target_lang TEXT NOT NULL,
                service TEXT NOT NULL,
                model TEXT,
                result_text TEXT NOT NULL
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS idx_translations_created_at ON translations (created_at DESC)")
        try execute("PRAGMA user_version = 1")
    }

    /// v2：模型与提示词拆成两张表，可自由组合。保留原 id，钥匙串里的 API Key 仍能对上
    private func migrateToV2() throws {
        try execute("BEGIN")
        do {
            try execute("""
                CREATE TABLE models (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL,
                    base_url TEXT NOT NULL,
                    model TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
                """)
            try execute("""
                CREATE TABLE prompts (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL,
                    system_prompt TEXT NOT NULL,
                    user_prompt TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
                """)
            try execute("""
                INSERT INTO models (id, name, base_url, model, created_at, updated_at)
                SELECT id, name, base_url, model, created_at, updated_at FROM model_configs ORDER BY id
                """)
            let oldPrompts = try query("SELECT system_prompt, user_prompt FROM model_configs ORDER BY id") {
                [$0.text(0), $0.text(1)]
            }
            var seen: [[String]] = []
            for prompt in oldPrompts where !seen.contains(prompt) {
                seen.append(prompt)
                insertPrompt(PromptTemplate(id: 0, name: seen.count == 1 ? "翻译" : "翻译 \(seen.count)",
                                            systemPrompt: prompt[0], userPrompt: prompt[1]))
            }
            try execute("DROP TABLE model_configs")
            try execute("PRAGMA user_version = 2")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// v3：models 增加 kind 列，并内置一条系统翻译
    private func migrateToV3() throws {
        try execute("BEGIN")
        do {
            try execute("ALTER TABLE models ADD COLUMN kind TEXT NOT NULL DEFAULT 'openai'")
            insertModel(LLMModel(id: 0, name: "系统翻译", baseURL: "", model: "", kind: .system))
            try execute("PRAGMA user_version = 3")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// v4：升级并优化内置中文提示词，保持历史记录上限 10,000 条
    private func migrateToV4() throws {
        try execute("BEGIN")
        do {
            // 优化旧版英文翻译提示词为高质量中文提示词
            let chineseTranslationPrompt = """
                你是一名资深专业同声传译与本地化翻译专家。请将用户提供的文本从 {from} 准确、自然、流畅地翻译为 {to}。
                要求：
                1. 忠实原文：准确传达原意，符合目标语言的母语表达习惯，避免机翻感和生硬直译。
                2. 专业术语：保持专业技术术语、专有名词、代码标识符、缩写和专有格式的准确性。
                3. 排版格式：严格保留原文的段落结构、换行格式、缩进以及特殊符号。
                4. 纯净输出：仅输出翻译后的最终文本，严禁包含任何前缀、解释说明、反问、引号或额外元信息。
                """
            let chineseExplainPrompt = """
                你是一名精通多语言对比与语言教学的专家助手。请使用 {to} 对用户提供的文本进行精炼深入的解析：
                1. 核心意涵：用简练的语言概括句子或段落的主旨意义与语境。
                2. 重点词汇/短语：提取关键生词、俚语、行业术语或固定搭配，标注词性及常见含义。
                3. 语法/句式剖析：简析复杂长难句结构、特殊句式或易混淆语法点（如适用）。
                4. 语境/文化背景：若包含特定文化隐喻、行业行话或背景知识，作简明补充。
                排版清晰条理，便于快速阅读。
                """
            let chinesePolishPrompt = """
                你是一名母语级资深文字编辑与写作导师。请对用户提供的原文进行深度润色与修饰：
                1. 语言表达：消除语病，增强用词的精准度、得体性与地道感，提升语句节奏感与文采。
                2. 逻辑流畅：理顺句间衔接，使行文更加清晰通顺，符合地道自然的表达习惯。
                3. 保持原意：严格忠于作者的原意与核心观点，不凭空增删事实。
                4. 输出要求：仅输出润色后的文本，不添加前后说明或额外解释。
                """

            try execute("""
                UPDATE prompts
                SET system_prompt = ?
                WHERE system_prompt LIKE '%You are a professional translation engine%' OR name = '翻译'
                """, [.text(chineseTranslationPrompt)])
            try execute("""
                UPDATE prompts
                SET system_prompt = ?
                WHERE system_prompt LIKE '%You are a helpful language assistant%' OR name = '解释'
                """, [.text(chineseExplainPrompt)])
            try execute("""
                UPDATE prompts
                SET system_prompt = ?
                WHERE system_prompt LIKE '%You are a professional editor%' OR name = '润色'
                """, [.text(chinesePolishPrompt)])

            // 老用户补充总结摘要提示词（若不存在）。全新安装时 prompts 为空，由 AppSettings 按顺序预置，
            // 这里不插入，否则它会排在「通用翻译」前面成为默认提示词
            let promptCount = (try? query("SELECT COUNT(*) FROM prompts") { $0.int(0) }.first) ?? 0
            let summaryCount = (try? query("SELECT COUNT(*) FROM prompts WHERE name = '总结摘要'") { $0.int(0) }.first) ?? 0
            if promptCount > 0 && summaryCount == 0 {
                insertPrompt(PromptTemplate(id: 0, name: "总结摘要", systemPrompt: """
                    你是一名高效的信息分析与摘要专家。请使用 {to} 对用户提供的文本进行结构化提炼：
                    1. 一句话结论：用最凝练的一句话概括核心结论或主旨。
                    2. 核心要点：提炼 3~5 个关键要点，采用无序列表清晰呈现。
                    3. 关键数据/行动项：若有明确的数据指标、结论或后续行动项，单独列出。
                    要求精炼准确，去除冗余修饰，保持客观中立。
                    """, userPrompt: "{text}"))
            }

            // 清理超出 10,000 条的历史记录
            try execute("""
                DELETE FROM translations
                WHERE id IN (
                    SELECT id FROM translations
                    ORDER BY created_at DESC
                    LIMIT -1 OFFSET 10000
                )
                """)

            try execute("PRAGMA user_version = 4")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - 模型

    /// 系统翻译排在最前
    func fetchModels() -> [LLMModel] {
        (try? query("SELECT id, name, base_url, model, kind FROM models ORDER BY kind = 'system' DESC, id") { row in
            LLMModel(id: row.int(0), name: row.text(1), baseURL: row.text(2), model: row.text(3),
                     kind: LLMModel.Kind(rawValue: row.text(4)) ?? .openAI)
        }) ?? []
    }

    @discardableResult
    func insertModel(_ model: LLMModel) -> Int64 {
        let now = Date().timeIntervalSince1970
        try? execute("""
            INSERT INTO models (name, base_url, model, kind, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)
            """, [.text(model.name), .text(model.baseURL), .text(model.model), .text(model.kind.rawValue),
                  .real(now), .real(now)])
        return sqlite3_last_insert_rowid(db)
    }

    func updateModel(_ model: LLMModel) {
        try? execute("UPDATE models SET name = ?, base_url = ?, model = ?, updated_at = ? WHERE id = ?",
                     [.text(model.name), .text(model.baseURL), .text(model.model),
                      .real(Date().timeIntervalSince1970), .int(model.id)])
    }

    func deleteModel(id: Int64) {
        try? execute("DELETE FROM models WHERE id = ? AND kind != 'system'", [.int(id)])
    }

    // MARK: - 提示词

    func fetchPrompts() -> [PromptTemplate] {
        (try? query("SELECT id, name, system_prompt, user_prompt FROM prompts ORDER BY id") { row in
            PromptTemplate(id: row.int(0), name: row.text(1), systemPrompt: row.text(2), userPrompt: row.text(3))
        }) ?? []
    }

    @discardableResult
    func insertPrompt(_ prompt: PromptTemplate) -> Int64 {
        let now = Date().timeIntervalSince1970
        try? execute("""
            INSERT INTO prompts (name, system_prompt, user_prompt, created_at, updated_at) VALUES (?, ?, ?, ?, ?)
            """, [.text(prompt.name), .text(prompt.systemPrompt), .text(prompt.userPrompt), .real(now), .real(now)])
        return sqlite3_last_insert_rowid(db)
    }

    func updatePrompt(_ prompt: PromptTemplate) {
        try? execute("UPDATE prompts SET name = ?, system_prompt = ?, user_prompt = ?, updated_at = ? WHERE id = ?",
                     [.text(prompt.name), .text(prompt.systemPrompt), .text(prompt.userPrompt),
                      .real(Date().timeIntervalSince1970), .int(prompt.id)])
    }

    func deletePrompt(id: Int64) {
        try? execute("DELETE FROM prompts WHERE id = ?", [.int(id)])
    }

    // MARK: - 翻译记录

    /// 最多保留的历史记录条数
    static let maxHistoryRecords = 10_000

    func insertRecord(_ record: TranslationRecord) {
        try? execute("""
            INSERT INTO translations
                (created_at, origin, source_text, source_lang, target_lang, service, model, result_text)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, [.real(record.createdAt.timeIntervalSince1970), .text(record.origin.rawValue),
                  .text(record.sourceText), record.sourceLang.map(Value.text) ?? .null,
                  .text(record.targetLang), .text(record.service),
                  record.model.map(Value.text) ?? .null, .text(record.resultText)])

        pruneOldRecordsIfNeeded()
    }

    /// 超出 10,000 条上限时，利用 created_at 降序索引自动清除最旧记录 (FIFO)
    func pruneOldRecordsIfNeeded() {
        try? execute("""
            DELETE FROM translations
            WHERE id IN (
                SELECT id FROM translations
                ORDER BY created_at DESC
                LIMIT -1 OFFSET ?
            )
            """, [.int(Int64(Self.maxHistoryRecords))])
    }

    /// 查询当前历史记录总数
    func recordCount() -> Int {
        (try? query("SELECT COUNT(*) FROM translations") { $0.int(0) }.first).map(Int.init) ?? 0
    }

    /// 计算数据库主文件及 WAL / SHM 临时文件的总磁盘占用（字节）
    func storageSize() -> Int64 {
        let base = Database.defaultURL
        let urls = [
            base,
            URL(fileURLWithPath: base.path + "-wal"),
            URL(fileURLWithPath: base.path + "-shm")
        ]
        var total: Int64 = 0
        for url in urls {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        return total
    }

    /// 格式化磁盘字节数为易读字符串（如 "240 KB", "12.4 MB"）
    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// 按原文或译文搜索，最新的在前；默认加载前 500 条
    /// origin 为 nil 时不按来源筛选
    func fetchRecords(search: String = "", origin: TranslationRecord.Origin? = nil,
                      limit: Int = 500, offset: Int = 0) -> [TranslationRecord] {
        let pattern = "%\(search)%"
        let originValue = origin?.rawValue ?? ""
        return (try? query("""
            SELECT id, created_at, origin, source_text, source_lang, target_lang, service, model, result_text
            FROM translations
            WHERE (? = '' OR source_text LIKE ? OR result_text LIKE ?) AND (? = '' OR origin = ?)
            ORDER BY created_at DESC LIMIT ? OFFSET ?
            """, [.text(search), .text(pattern), .text(pattern), .text(originValue), .text(originValue),
                  .int(Int64(limit)), .int(Int64(offset))]) { row in
            TranslationRecord(
                id: row.int(0), createdAt: Date(timeIntervalSince1970: row.double(1)),
                origin: TranslationRecord.Origin(rawValue: row.text(2)) ?? .manual,
                sourceText: row.text(3), sourceLang: row.optionalText(4), targetLang: row.text(5),
                service: row.text(6), model: row.optionalText(7), resultText: row.text(8))
        }) ?? []
    }

    func deleteRecord(id: Int64) {
        try? execute("DELETE FROM translations WHERE id = ?", [.int(id)])
    }

    func clearRecords() {
        try? execute("DELETE FROM translations")
    }

    // MARK: - 底层封装

    struct Row {
        fileprivate let stmt: OpaquePointer

        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func text(_ i: Int32) -> String { optionalText(i) ?? "" }
        func optionalText(_ i: Int32) -> String? {
            sqlite3_column_text(stmt, i).map { String(cString: $0) }
        }
    }

    func execute(_ sql: String, _ params: [Value] = []) throws {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw lastError() }
    }

    func query<T>(_ sql: String, _ params: [Value] = [], row map: (Row) -> T) throws -> [T] {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var results: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw lastError() }
            results.append(map(Row(stmt: stmt)))
        }
        return results
    }

    private func prepare(_ sql: String, _ params: [Value]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw lastError() }
        for (i, value) in params.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(stmt, index, v)
            case .real(let v): sqlite3_bind_double(stmt, index, v)
            case .text(let v): sqlite3_bind_text(stmt, index, v, -1, SQLITE_TRANSIENT)
            case .null: sqlite3_bind_null(stmt, index)
            }
        }
        return stmt
    }

    private func lastError() -> DBError {
        DBError(message: String(cString: sqlite3_errmsg(db)))
    }
}
