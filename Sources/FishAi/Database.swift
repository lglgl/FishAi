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

    func insertRecord(_ record: TranslationRecord) {
        try? execute("""
            INSERT INTO translations
                (created_at, origin, source_text, source_lang, target_lang, service, model, result_text)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, [.real(record.createdAt.timeIntervalSince1970), .text(record.origin.rawValue),
                  .text(record.sourceText), record.sourceLang.map(Value.text) ?? .null,
                  .text(record.targetLang), .text(record.service),
                  record.model.map(Value.text) ?? .null, .text(record.resultText)])
    }

    /// 按原文或译文搜索，最新的在前
    func fetchRecords(search: String = "", limit: Int = 500) -> [TranslationRecord] {
        let pattern = "%\(search)%"
        return (try? query("""
            SELECT id, created_at, origin, source_text, source_lang, target_lang, service, model, result_text
            FROM translations
            WHERE ? = '' OR source_text LIKE ? OR result_text LIKE ?
            ORDER BY created_at DESC LIMIT ?
            """, [.text(search), .text(pattern), .text(pattern), .int(Int64(limit))]) { row in
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
