import Foundation

/// Tuning for the shake gesture. Pure data so traces can be replayed in tests.
public struct ShakeConfig: Equatable, Sendable {
    /// Minimum travel (points) of each stroke between two direction changes.
    public var minStroke: Double
    /// Direction changes needed to count as a shake.
    public var reversals: Int
    /// All reversals must happen inside this time span.
    public var window: TimeInterval
    /// A stroke slower than this breaks the chain (hunting for a target, not shaking).
    public var maxStrokeTime: TimeInterval
    /// How far the pointer must come back from a peak before it counts as a turn (filters jitter).
    public var hysteresis: Double = 8
    /// Quiet time after a detection.
    public var cooldown: TimeInterval = 0.6

    public init(minStroke: Double, reversals: Int, window: TimeInterval, maxStrokeTime: TimeInterval) {
        self.minStroke = minStroke
        self.reversals = reversals
        self.window = window
        self.maxStrokeTime = maxStrokeTime
    }

    /// Sensitivity 1 (hard to trigger) … 5 (easy). 3 is the default.
    public static func sensitivity(_ level: Int) -> ShakeConfig {
        switch min(max(level, 1), 5) {
        case 1: return ShakeConfig(minStroke: 90, reversals: 4, window: 0.9, maxStrokeTime: 0.22)
        case 2: return ShakeConfig(minStroke: 62, reversals: 3, window: 0.9, maxStrokeTime: 0.26)
        case 4: return ShakeConfig(minStroke: 45, reversals: 3, window: 1.0, maxStrokeTime: 0.32)
        case 5: return ShakeConfig(minStroke: 35, reversals: 2, window: 1.0, maxStrokeTime: 0.35)
        default: return ShakeConfig(minStroke: 55, reversals: 3, window: 0.95, maxStrokeTime: 0.3)
        }
    }
}

/// Detects a back-and-forth flick from a stream of pointer samples.
/// Each axis is tracked on its own, so horizontal and vertical shakes both work.
public struct ShakeDetector {
    public var config: ShakeConfig

    private struct Axis {
        var dir: Int = 0
        var started = false
        var startPos = 0.0, startT = 0.0
        var peakPos = 0.0, peakT = 0.0
        var turns: [TimeInterval] = []

        mutating func reset() { self = Axis() }

        /// Returns true when this axis has enough quick reversals.
        mutating func feed(_ p: Double, _ t: TimeInterval, _ c: ShakeConfig) -> Bool {
            if dir == 0 {
                if !started { started = true; startPos = p; startT = t; peakPos = p; peakT = t; return false }
                let d = p - startPos
                if abs(d) >= c.hysteresis { dir = d > 0 ? 1 : -1; peakPos = p; peakT = t }
                else if t - startT > c.maxStrokeTime { startT = t; startPos = p }
                return false
            }
            let forward = (p - peakPos) * Double(dir)
            if forward > 0 {
                peakPos = p; peakT = t
            } else if -forward >= c.hysteresis {
                let length = abs(peakPos - startPos)
                let duration = peakT - startT
                if length >= c.minStroke && duration <= c.maxStrokeTime {
                    turns.append(peakT)
                } else {
                    turns.removeAll()
                }
                dir = -dir
                startPos = peakPos; startT = peakT
                peakPos = p; peakT = t
            }
            // A stroke that has been going on too long can't be part of a shake.
            if t - startT > c.maxStrokeTime * 2 { turns.removeAll() }
            turns.removeAll { t - $0 > c.window }
            return turns.count >= c.reversals
        }
    }

    private var x = Axis(), y = Axis()
    private var quietUntil: TimeInterval = 0

    public init(config: ShakeConfig = .sensitivity(3)) { self.config = config }

    public mutating func reset() { x.reset(); y.reset() }

    /// Feed one sample; returns true exactly once per detected shake.
    public mutating func add(t: TimeInterval, x px: Double, y py: Double) -> Bool {
        if t < quietUntil { return false }
        let hitX = x.feed(px, t, config)
        let hitY = y.feed(py, t, config)
        if hitX || hitY {
            reset()
            quietUntil = t + config.cooldown
            return true
        }
        return false
    }
}

/// A recorded pointer path, stored as JSON in the repo and replayed by tests.
public struct GestureTrace: Codable {
    public var device: String
    public var note: String?
    public var expectShake: Bool
    /// [t, x, y]
    public var samples: [[Double]]

    public init(device: String, note: String? = nil, expectShake: Bool, samples: [[Double]]) {
        self.device = device; self.note = note; self.expectShake = expectShake; self.samples = samples
    }

    /// Number of detections when replayed through a detector.
    public func detections(config: ShakeConfig) -> Int {
        var d = ShakeDetector(config: config)
        return samples.reduce(0) { $0 + (d.add(t: $1[0], x: $1[1], y: $1[2]) ? 1 : 0) }
    }
}
