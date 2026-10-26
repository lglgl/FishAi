import Foundation

/// 翻译记录：写入 SQLite，并为设置里的「翻译记录」页提供数据
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var records: [TranslationRecord] = []
    @Published var search = "" {
        didSet { reload() }
    }

    private let db = Database.shared

    func add(_ record: TranslationRecord) {
        guard AppSettings.shared.historyEnabled else { return }
        db.insertRecord(record)
        reload()
    }

    func reload() {
        records = db.fetchRecords(search: search.trimmingCharacters(in: .whitespaces))
    }

    func delete(_ record: TranslationRecord) {
        db.deleteRecord(id: record.id)
        reload()
    }

    func clear() {
        db.clearRecords()
        reload()
    }
}
