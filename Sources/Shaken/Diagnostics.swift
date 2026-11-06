import AppKit
import ApplicationServices
import os
import ShakenCore

/// Unified logging (Console.app, subsystem com.noxhsxrk.shaken) plus a short in-memory
/// history so "Copy Diagnostics" can include recent errors in a bug report.
enum Log {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.noxhsxrk.shaken", category: "app")
    private static var recent: [String] = []
    private static let lock = NSLock()

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        remember("info  " + message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        remember("error " + message)
    }

    private static func remember(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        lock.lock()
        recent.append(stamp + "  " + line)
        if recent.count > 40 { recent.removeFirst(recent.count - 40) }
        lock.unlock()
    }

    static var history: [String] {
        lock.lock(); defer { lock.unlock() }
        return recent
    }
}

enum Diagnostics {
    /// Plain text for a bug report: versions, setup and recent errors. No file names or contents.
    static func report(settings: ShakenSettings, actions: Int, shelfItems: Int) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String ?? "-"
        var arch = utsname()
        uname(&arch)
        let machine = withUnsafeBytes(of: &arch.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let kinds = settings.slots.map(\.kind.rawValue).joined(separator: ", ")
        var lines = [
            "Shaken \(version) (\(build))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(machine)",
            "Accessibility: \(AXIsProcessTrusted() ? "allowed" : "not allowed")",
            "Sensitivity \(settings.gesture.sensitivity), hold \(settings.gesture.modifier.rawValue), hot key \(settings.hotKey.display)",
            "Main wheel: \(kinds)",
            "Extra wheels: \(settings.wheels.count), app wheels: \(settings.appWheels.count), commands: \(actions), shelf: \(shelfItems)",
            "",
            "Recent events:",
        ]
        let h = Log.history
        lines += h.isEmpty ? ["(none)"] : h
        return lines.joined(separator: "\n")
    }
}
