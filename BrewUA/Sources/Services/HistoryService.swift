import Foundation

/// 更新历史服务:把每次升级运行的结果持久化到
/// `~/.config/brew-ua/update_history.json`(与 CLI 配置同目录)。
/// JSON 数组按时间倒序存储,超过 maxRecords 自动裁剪最旧的。
final class HistoryService {
    static let shared = HistoryService()

    private let maxRecords: Int
    private let lock = NSLock()
    private let customURL: URL?

    /// 测试可注入临时文件路径
    init(fileURL: URL? = nil, maxRecords: Int = 50) {
        self.customURL = fileURL
        self.maxRecords = maxRecords
    }

    var fileURL: URL {
        if let customURL { return customURL }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/brew-ua/update_history.json")
    }

    /// 读取全部历史(新→旧)
    func load() -> [UpdateRecord] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    /// 追加一条记录(置于最前;超出上限裁剪最旧)。写入失败静默忽略(历史非关键数据)。
    func append(_ record: UpdateRecord) {
        lock.lock()
        defer { lock.unlock() }
        var records = loadLocked()
        records.insert(record, at: 0)
        if records.count > maxRecords {
            records = Array(records.prefix(maxRecords))
        }
        saveLocked(records)
    }

    /// 清空全部历史
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - 私有(调用方已持锁)

    private func loadLocked() -> [UpdateRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([UpdateRecord].self, from: data)) ?? []
    }

    private func saveLocked(_ records: [UpdateRecord]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // 历史记录写入失败不中断升级流程
        }
    }
}
