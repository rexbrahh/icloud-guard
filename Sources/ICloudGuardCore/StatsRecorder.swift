import Foundation

/// Append-only JSONL stats recorder with automatic rotation.
///
/// Writes to AppPaths.stats (~/.icloud-guard/stats.jsonl).
/// When the file exceeds 10MB, it is renamed to stats.1.jsonl
/// and a fresh file is started. Only 1 backup is kept.
public final class StatsRecorder {
    private let statsURL: URL
    private let rotationBackupURL: URL
    private let maxFileSize: Int64 = 10 * 1024 * 1024 // 10MB
    
    public init(statsURL: URL? = nil) {
        let url = statsURL ?? AppPaths.stats
        self.statsURL = url
        self.rotationBackupURL = url.deletingLastPathComponent().appendingPathComponent("stats.1.jsonl")
    }
    
    // MARK: - Stat Types
    
    public struct EvictionStat: Codable, Sendable, Equatable {
        public let timestamp: Date
        public let evictedCount: Int
        public let failedCount: Int
        public let reclaimedBytes: Int64
        public let dryRun: Bool
        
        public init(timestamp: Date = Date(), evictedCount: Int, failedCount: Int, reclaimedBytes: Int64, dryRun: Bool) {
            self.timestamp = timestamp
            self.evictedCount = evictedCount
            self.failedCount = failedCount
            self.reclaimedBytes = reclaimedBytes
            self.dryRun = dryRun
        }
    }
    
    public struct RematerializationStat: Codable, Sendable, Equatable {
        public let timestamp: Date
        public let itemPath: String
        
        public init(timestamp: Date = Date(), itemPath: String) {
            self.timestamp = timestamp
            self.itemPath = itemPath
        }
    }
    
    public struct PollutionStat: Codable, Sendable, Equatable {
        public let timestamp: Date
        public let materializedCount: Int
        public let datalessCount: Int
        public let pollutionRatio: Double
        
        public init(timestamp: Date = Date(), materializedCount: Int, datalessCount: Int, pollutionRatio: Double) {
            self.timestamp = timestamp
            self.materializedCount = materializedCount
            self.datalessCount = datalessCount
            self.pollutionRatio = pollutionRatio
        }
    }
    
    // MARK: - Recording
    
    public func record(_ stat: some Codable & Sendable) {
        do {
            try appendStat(stat)
        } catch {
            // Swallow errors — stats are best-effort
            let msg = "StatsRecorder: failed to record: \(error)\n"
            FileHandle.standardError.write(Data(msg.utf8))
        }
    }
    
    private func appendStat(_ stat: some Codable) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(stat)
        guard let line = String(data: data, encoding: .utf8) else { return }
        
        // Check rotation before writing
        try rotateIfNeeded()
        
        // Ensure directory exists
        let dir = statsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        
        // Append line to file
        let lineData = (line + "\n").data(using: .utf8) ?? Data()
        if FileManager.default.fileExists(atPath: statsURL.path) {
            let handle = try FileHandle(forWritingTo: statsURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: lineData)
        } else {
            try lineData.write(to: statsURL, options: .atomic)
        }
    }
    
    private func rotateIfNeeded() throws {
        guard FileManager.default.fileExists(atPath: statsURL.path) else { return }
        let attrs = try FileManager.default.attributesOfItem(atPath: statsURL.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        if size >= maxFileSize {
            // Remove old backup if exists
            try? FileManager.default.removeItem(at: rotationBackupURL)
            // Rename current to backup
            try FileManager.default.moveItem(at: statsURL, to: rotationBackupURL)
        }
    }
}
