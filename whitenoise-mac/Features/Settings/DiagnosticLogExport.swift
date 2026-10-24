import Foundation
import MarmotKit

nonisolated struct DiagnosticLogSnapshot: Sendable {
    let fileName: String
    let data: Data
}

nonisolated enum DiagnosticLogExport {
    enum ExportError: Error {
        case noLogs
        case fileChangedDuringRead
    }

    static func fileForExport(in files: [AuditLogFileFfi], path: String? = nil) throws -> AuditLogFileFfi {
        let file: AuditLogFileFfi?
        if let path {
            file = files.first { $0.path == path && $0.sizeBytes > 0 }
        } else {
            file = latestFile(in: files)
        }
        guard let file else { throw ExportError.noLogs }
        return file
    }

    static func latestFile(in files: [AuditLogFileFfi]) -> AuditLogFileFfi? {
        files.filter { $0.sizeBytes > 0 }.max { left, right in
            let leftTime = left.modifiedAtMs ?? 0
            let rightTime = right.modifiedAtMs ?? 0
            if leftTime != rightTime { return leftTime < rightTime }
            return left.path < right.path
        }
    }

    /// Reads one stable inode and only the bytes present when the read begins. The final-newline
    /// check prevents exporting a JSONL record caught midway through a concurrent append.
    static func snapshot(file: AuditLogFileFfi) throws -> DiagnosticLogSnapshot {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: file.path))
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        var remaining = length
        var data = Data()
        while remaining > 0 {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: Int(min(remaining, 1_024 * 1_024))) ?? Data()
            guard !chunk.isEmpty else { throw ExportError.fileChangedDuringRead }
            data.append(chunk)
            remaining -= UInt64(chunk.count)
        }
        guard !data.isEmpty, data.last == 0x0A else { throw ExportError.fileChangedDuringRead }
        return DiagnosticLogSnapshot(fileName: file.fileName, data: data)
    }
}
