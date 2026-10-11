import Foundation

/// Spots a wave: an open hand swinging side to side a few times. Fed the
/// hand's horizontal position (0–1 across the camera image) several times a
/// second; returns true once per wave.
///
/// Drawing also moves the hand, so a wave needs an open hand (fingers spread,
/// not holding a pencil), wide swings, and several quick changes of direction.
struct WaveDetector {
    struct Options {
        var window: TimeInterval = 1.6  // the swings must all happen within this
        var minSwing: Double = 0.07     // of the image width, per swing
        var swings: Int = 3             // changes of direction (left-right-left-right)
        var cooldown: TimeInterval = 2.0
    }

    var options = Options()
    private var samples: [(t: TimeInterval, x: Double)] = []
    private var lastWave: TimeInterval = -.infinity

    init(options: Options = Options()) { self.options = options }

    /// `x` is nil when there's no open hand in view.
    mutating func update(x: Double?, at t: TimeInterval) -> Bool {
        guard let x else {
            samples.removeAll()
            return false
        }
        samples.append((t, x))
        samples.removeAll { t - $0.t > options.window }
        guard t - lastWave > options.cooldown else { return false }
        if Self.swingCount(samples.map(\.x), minSwing: options.minSwing) >= options.swings {
            lastWave = t
            samples.removeAll()
            return true
        }
        return false
    }

    /// Changes of direction between turning points at least `minSwing` apart.
    static func swingCount(_ xs: [Double], minSwing: Double) -> Int {
        guard var anchor = xs.first else { return 0 }
        var direction = 0 // +1 moving right, -1 moving left, 0 not yet
        var extreme = anchor
        var count = 0
        for x in xs.dropFirst() {
            switch direction {
            case 0:
                if abs(x - anchor) >= minSwing { direction = x > anchor ? 1 : -1; extreme = x }
            case 1:
                if x > extreme { extreme = x } else if extreme - x >= minSwing { count += 1; direction = -1; anchor = extreme; extreme = x }
            default:
                if x < extreme { extreme = x } else if x - extreme >= minSwing { count += 1; direction = 1; anchor = extreme; extreme = x }
            }
        }
        return count
    }
}
