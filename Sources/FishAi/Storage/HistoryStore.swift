import Foundation

/// 翻译记录：写入 SQLite，提供数据查询、容量提醒统计与导出功能
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    /// 当前显示的记录列表（默认展示最新 500 条）
    @Published private(set) var records: [TranslationRecord] = []
    /// 数据库中当前保存的实际总记录数
    @Published private(set) var totalCount: Int = 0
    /// 数据库文件在磁盘占用的总大小（格式化）
    @Published private(set) var storageSizeFormatted: String = "0 KB"
    /// 历史记录最大容量上限
    let maxCapacity: Int = Database.maxHistoryRecords

    @Published var search = "" {
        didSet { reload() }
    }
    /// 按来源筛选，nil 表示全部
    @Published var originFilter: TranslationRecord.Origin? {
        didSet { reload() }
    }

    /// 容量占比 (0.0 ~ 1.0)
    var capacityRatio: Double {
        guard maxCapacity > 0 else { return 0 }
        return min(1.0, Double(totalCount) / Double(maxCapacity))
    }

    /// 容量百分比文本，如 "15.4%"
    var capacityPercentageString: String {
        String(format: "%.1f%%", capacityRatio * 100)
    }

    private let db = Database.shared

    init() {
        reload()
    }

    func add(_ record: TranslationRecord) {
        guard AppSettings.shared.historyEnabled else { return }
        db.insertRecord(record)
        reload()
    }

    func reload() {
        let keyword = search.trimmingCharacters(in: .whitespaces)
        records = db.fetchRecords(search: keyword, origin: originFilter, limit: 500)
        totalCount = db.recordCount()
        storageSizeFormatted = Database.formatBytes(db.storageSize())
    }

    func delete(_ record: TranslationRecord) {
        db.deleteRecord(id: record.id)
        reload()
    }

    func clear() {
        db.clearRecords()
        reload()
    }

    /// 导出为 Markdown/纯文本文件内容
    func exportAsText() -> String {
        let allRecords = db.fetchRecords(search: "", limit: Database.maxHistoryRecords)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var output = "# FishAi 翻译历史记录导出\n"
        output += "导出时间：\(formatter.string(from: Date()))\n"
        output += "总记录数：\(allRecords.count) 条\n\n---\n\n"

        for (index, r) in allRecords.enumerated() {
            output += "### \(index + 1). [\(formatter.string(from: r.createdAt))] \(r.service) (\(r.sourceLang ?? "auto") -> \(r.targetLang))\n"
            output += "**原文：**\n\(r.sourceText)\n\n"
            output += "**译文：**\n\(r.resultText)\n\n---\n\n"
        }
        return output
    }
}
