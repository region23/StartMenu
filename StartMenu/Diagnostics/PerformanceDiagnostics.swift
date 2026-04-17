import AppKit
import Foundation
import OSLog

enum PerformanceDiagnostics {
    enum Level: String, Sendable {
        case debug
        case info
        case notice
        case error
    }

    private static let logger = Logger(
        subsystem: AppFlavor.current.logSubsystem,
        category: "performance"
    )

    static var logURL: URL { PerformanceTraceStore.logURL }

    static var logDirectoryURL: URL { PerformanceTraceStore.logDirectoryURL }

    static func begin(
        category: String,
        name: String,
        thresholdMs: Double = 16,
        fields: [String: String] = [:],
        alwaysRecord: Bool = false,
        level: Level = .notice
    ) -> PerformanceSpan {
        PerformanceSpan(
            category: category,
            name: name,
            thresholdMs: thresholdMs,
            fields: fields,
            alwaysRecord: alwaysRecord,
            level: level
        )
    }

    static func recordEvent(
        _ name: String,
        category: String,
        level: Level = .info,
        fields: [String: String] = [:]
    ) {
        emit(
            level: level,
            category: category,
            name: name,
            durationMs: nil,
            fields: fields
        )
    }

    static func recordDuration(
        _ name: String,
        category: String,
        durationMs: Double,
        thresholdMs: Double = 16,
        level: Level = .notice,
        fields: [String: String] = [:],
        alwaysRecord: Bool = false
    ) {
        guard alwaysRecord || durationMs >= thresholdMs else { return }
        emit(
            level: level,
            category: category,
            name: name,
            durationMs: durationMs,
            fields: fields
        )
    }

    static func revealLogInFinder() {
        let fileManager = FileManager.default
        let url = logURL
        if fileManager.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(logDirectoryURL)
        }
    }

    static func copyLogPathToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(logURL.path, forType: .string)
    }

    static func clearLogs() {
        Task {
            await PerformanceTraceStore.shared.clear()
            recordEvent(
                "trace_cleared",
                category: "diagnostics",
                level: .notice,
                fields: ["path": logURL.path]
            )
        }
    }

    private static func emit(
        level: Level,
        category: String,
        name: String,
        durationMs: Double?,
        fields: [String: String]
    ) {
        let metadataText = metadataDescription(fields)
        let durationText = durationMs.map { " durationMs=\(Self.format(milliseconds: $0))" } ?? ""
        let message = "[\(category)] \(name)\(durationText)\(metadataText)"

        switch level {
        case .debug:
            logger.debug("\(message, privacy: .public)")
        case .info:
            logger.info("\(message, privacy: .public)")
        case .notice:
            logger.notice("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        }

        Task {
            await PerformanceTraceStore.shared.append(
                level: level.rawValue,
                category: category,
                name: name,
                durationMs: durationMs,
                fields: fields
            )
        }
    }

    private static func format(milliseconds: Double) -> String {
        String(format: "%.1f", milliseconds)
    }

    private static func metadataDescription(_ fields: [String: String]) -> String {
        guard !fields.isEmpty else { return "" }
        let parts = fields
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        return " " + parts
    }
}

struct PerformanceSpan: Sendable {
    private let category: String
    private let name: String
    private let thresholdMs: Double
    private let fields: [String: String]
    private let alwaysRecord: Bool
    private let level: PerformanceDiagnostics.Level
    private let clock = ContinuousClock()
    private let startedAt: ContinuousClock.Instant

    init(
        category: String,
        name: String,
        thresholdMs: Double,
        fields: [String: String],
        alwaysRecord: Bool,
        level: PerformanceDiagnostics.Level
    ) {
        self.category = category
        self.name = name
        self.thresholdMs = thresholdMs
        self.fields = fields
        self.alwaysRecord = alwaysRecord
        self.level = level
        self.startedAt = clock.now
    }

    func end(extraFields: [String: String] = [:]) {
        let duration = startedAt.duration(to: clock.now)
        let durationMs = Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
        let mergedFields = fields.merging(extraFields) { _, new in new }

        PerformanceDiagnostics.recordDuration(
            name,
            category: category,
            durationMs: durationMs,
            thresholdMs: thresholdMs,
            level: level,
            fields: mergedFields,
            alwaysRecord: alwaysRecord
        )
    }
}

final class MainThreadStallMonitor {
    private let queue = DispatchQueue(
        label: "\(AppFlavor.current.logSubsystem).main-thread-stall",
        qos: .utility
    )
    private let sampleInterval: TimeInterval
    private let stallThresholdMs: Double
    private let minimumLogGap: TimeInterval
    private var timer: DispatchSourceTimer?
    private var lastLoggedAt: TimeInterval = 0

    init(
        sampleInterval: TimeInterval = 0.25,
        stallThresholdMs: Double = 120,
        minimumLogGap: TimeInterval = 0.75
    ) {
        self.sampleInterval = sampleInterval
        self.stallThresholdMs = stallThresholdMs
        self.minimumLogGap = minimumLogGap
    }

    func start() {
        guard timer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + sampleInterval,
            repeating: sampleInterval,
            leeway: .milliseconds(50)
        )
        timer.setEventHandler { [weak self] in
            self?.sampleMainThread()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func sampleMainThread() {
        let scheduledAt = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let now = DispatchTime.now().uptimeNanoseconds
            let delayMs = Double(now - scheduledAt) / 1_000_000
            guard delayMs >= self.stallThresholdMs else { return }

            let wallClockNow = CFAbsoluteTimeGetCurrent()
            guard wallClockNow - self.lastLoggedAt >= self.minimumLogGap else { return }
            self.lastLoggedAt = wallClockNow

            PerformanceDiagnostics.recordDuration(
                "main_thread_stall",
                category: "watchdog",
                durationMs: delayMs,
                thresholdMs: self.stallThresholdMs,
                level: .error,
                fields: [
                    "sampleIntervalMs": String(Int(self.sampleInterval * 1_000)),
                    "thresholdMs": String(Int(self.stallThresholdMs))
                ],
                alwaysRecord: true
            )
        }
    }
}

private actor PerformanceTraceStore {
    static let shared = PerformanceTraceStore()

    static let logDirectoryURL: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        return base
            .appendingPathComponent(AppFlavor.current.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }()

    static let logURL = logDirectoryURL.appendingPathComponent(
        "performance-trace.jsonl",
        isDirectory: false
    )

    private static let archivedLogURL = logDirectoryURL.appendingPathComponent(
        "performance-trace.previous.jsonl",
        isDirectory: false
    )

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let maxBytes = 1_500_000
    private var fileHandle: FileHandle?

    func append(
        level: String,
        category: String,
        name: String,
        durationMs: Double?,
        fields: [String: String]
    ) {
        do {
            try ensureLogDirectoryExists()

            let record = PerformanceTraceRecord(
                timestamp: isoFormatter.string(from: Date()),
                level: level,
                category: category,
                name: name,
                durationMs: durationMs,
                fields: fields
            )
            let data = try encoder.encode(record) + Data([0x0A])

            try rotateIfNeeded(incomingByteCount: data.count)
            let handle = try openHandleForAppending()
            try handle.write(contentsOf: data)
        } catch {
            NSLog("PerformanceTraceStore append failed: %@", String(describing: error))
        }
    }

    func clear() {
        let fileManager = FileManager.default
        closeHandle()
        try? fileManager.removeItem(at: Self.logURL)
        try? fileManager.removeItem(at: Self.archivedLogURL)
    }

    private func ensureLogDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: Self.logDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    private func rotateIfNeeded(incomingByteCount: Int) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: Self.logURL.path) else { return }

        let attributes = try fileManager.attributesOfItem(atPath: Self.logURL.path)
        let currentSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard currentSize + incomingByteCount > maxBytes else { return }

        closeHandle()
        try? fileManager.removeItem(at: Self.archivedLogURL)
        try fileManager.moveItem(at: Self.logURL, to: Self.archivedLogURL)
    }

    private func openHandleForAppending() throws -> FileHandle {
        if let fileHandle {
            return fileHandle
        }

        if !FileManager.default.fileExists(atPath: Self.logURL.path) {
            FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: Self.logURL)
        try handle.seekToEnd()
        fileHandle = handle
        return handle
    }

    private func closeHandle() {
        try? fileHandle?.close()
        fileHandle = nil
    }
}

private struct PerformanceTraceRecord: Codable, Sendable {
    let timestamp: String
    let level: String
    let category: String
    let name: String
    let durationMs: Double?
    let fields: [String: String]
}
