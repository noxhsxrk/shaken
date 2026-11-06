import Foundation
import Testing
@testable import ShakenCore

struct GestureTests {
    static func traces() throws -> [(String, GestureTrace)] {
        let dir = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.map { ($0.deletingPathExtension().lastPathComponent, try JSONDecoder().decode(GestureTrace.self, from: Data(contentsOf: $0))) }
    }

    @Test func fixturesExist() throws {
        let all = try Self.traces()
        #expect(all.contains { $0.1.expectShake && $0.1.device == "mouse" })
        #expect(all.contains { $0.1.expectShake && $0.1.device == "trackpad" })
        #expect(all.contains { !$0.1.expectShake })
    }

    @Test(arguments: [2, 3, 4])
    func everyTraceMatchesExpectation(sensitivity: Int) throws {
        for (name, trace) in try Self.traces() {
            let n = trace.detections(config: .sensitivity(sensitivity))
            if trace.expectShake {
                #expect(n >= 1, "\(name) should open the wheel at sensitivity \(sensitivity)")
            } else {
                #expect(n == 0, "\(name) must not open the wheel at sensitivity \(sensitivity)")
            }
        }
    }

    @Test func shakeFiresOncePerShake() throws {
        for (name, trace) in try Self.traces() where trace.expectShake {
            #expect(trace.detections(config: .sensitivity(3)) == 1, "\(name)")
        }
    }

    @Test func mostSensitiveNeverFiresOnPlainDrags() throws {
        for (name, trace) in try Self.traces() where !trace.expectShake && name.contains("straight") || name.contains("jitter") {
            #expect(trace.detections(config: .sensitivity(5)) == 0, "\(name)")
        }
    }

    @Test func detectsQuicklyEnough() {
        // 5 Hz shake: three turns take ~0.5 s, so the wheel should open well within a second.
        var d = ShakeDetector()
        var firedAt: Double?
        var t = 0.0
        while t < 2, firedAt == nil {
            if d.add(t: t, x: 500 + 70 * sin(2 * .pi * 5 * t), y: 300) { firedAt = t }
            t += 1.0 / 120
        }
        #expect(firedAt != nil)
        #expect(firedAt! < 0.8)
    }

    @Test func resetForgetsPartialShake() {
        var d = ShakeDetector()
        var t = 0.0
        while t < 0.3 { _ = d.add(t: t, x: 500 + 70 * sin(2 * .pi * 5 * t), y: 0); t += 1.0 / 120 }
        d.reset()
        var fired = false
        while t < 0.45 { fired = fired || d.add(t: t, x: 500 + 70 * sin(2 * .pi * 5 * t), y: 0); t += 1.0 / 120 }
        #expect(!fired)
    }
}
