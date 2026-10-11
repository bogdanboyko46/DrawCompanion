import Foundation

/// The optics of a phone in a head-mounted viewer with simple magnifying
/// lenses (Cardboard-style), and where each eye's picture goes on the screen.
///
/// The lenses stretch the picture more the farther it is from their center
/// (pincushion), so straight lines bow inward. To cancel that, each eye's
/// picture is drawn pre-bent the other way (barrel). Standard radial model,
/// in tangent-of-angle units from the lens axis:
///
///     eyeTan = screenTan · (1 + k1·r² + k2·r⁴),  r = screenTan
///
/// where screenTan is the distance on the screen from the lens center
/// divided by the screen-to-lens distance, and eyeTan is the direction the
/// eye sees that screen point in. The renderer, for every screen pixel, shows
/// the scene at `eyeTan(fromScreenTan:)`.
///
/// Each eye sees a square field of ±`fieldOfViewDegrees` around its lens
/// axis; the scene is rendered once into a square texture covering that
/// field (both eyes see the same image: the camera is a single lens).
struct HeadsetOptics: Equatable {
    /// Radial distortion of the lenses (Cardboard v1: 0.441, 0.156).
    var k1 = 0.441
    var k2 = 0.156
    /// Screen to lens distance (Cardboard v1: 42 mm).
    var screenToLensMM = 42.0
    /// Distance between the two lens centers, i.e. between the two eye
    /// pictures' centers on the screen (Cardboard v1: 60 mm).
    var lensSeparationMM = 60.0
    /// Lens centers above (+) or below (−) the middle of the screen.
    var verticalOffsetMM = 0.0
    /// Half-angle each eye sees, up/down/left/right (Cardboard v1: 40°).
    var fieldOfViewDegrees = 40.0
    /// How much of the camera image each eye shows: the eye's full field
    /// (top to bottom) shows 1/zoom of the camera image's height. 1 = the
    /// image's height just fills the field; bigger = closer.
    var zoom = 1.1
    /// Screen density (iPhone 17 Pro and most recent iPhones: 460).
    var pixelsPerInch = 460.0
    /// Off = no pre-distortion (for comparing through the viewer).
    var correctsDistortion = true

    static let cardboard = HeadsetOptics()

    // MARK: settings

    /// UserDefaults keys. Numbers are Doubles; a missing key means default.
    enum Key {
        static let k1 = "headset.k1"
        static let k2 = "headset.k2"
        static let screenToLensMM = "headset.screenToLensMM"
        static let lensSeparationMM = "headset.lensSeparationMM"
        static let verticalOffsetMM = "headset.verticalOffsetMM"
        static let fieldOfViewDegrees = "headset.fieldOfViewDegrees"
        static let zoom = "headset.zoom"
        static let pixelsPerInch = "headset.pixelsPerInch"
        static let correctsDistortion = "headset.correctsDistortion"
        static let all = [k1, k2, screenToLensMM, lensSeparationMM, verticalOffsetMM,
                          fieldOfViewDegrees, zoom, pixelsPerInch, correctsDistortion]
    }

    /// Allowed range of each setting, so a bad value can't break the view.
    static let limits: [String: ClosedRange<Double>] = [
        Key.k1: -0.5...1.5,
        Key.k2: -0.5...1.5,
        Key.screenToLensMM: 20...80,
        Key.lensSeparationMM: 40...80,
        Key.verticalOffsetMM: -20...20,
        Key.fieldOfViewDegrees: 20...60,
        Key.zoom: 0.5...4,
        Key.pixelsPerInch: 200...700,
    ]

    /// The settings saved in `defaults`, with defaults for anything unset.
    init(defaults: UserDefaults) {
        let base = HeadsetOptics()
        func number(_ key: String, _ fallback: Double) -> Double {
            guard let value = (defaults.object(forKey: key) as? NSNumber)?.doubleValue, value.isFinite else { return fallback }
            guard let range = Self.limits[key] else { return value }
            return min(range.upperBound, max(range.lowerBound, value))
        }
        k1 = number(Key.k1, base.k1)
        k2 = number(Key.k2, base.k2)
        screenToLensMM = number(Key.screenToLensMM, base.screenToLensMM)
        lensSeparationMM = number(Key.lensSeparationMM, base.lensSeparationMM)
        verticalOffsetMM = number(Key.verticalOffsetMM, base.verticalOffsetMM)
        fieldOfViewDegrees = number(Key.fieldOfViewDegrees, base.fieldOfViewDegrees)
        zoom = number(Key.zoom, base.zoom)
        pixelsPerInch = number(Key.pixelsPerInch, base.pixelsPerInch)
        correctsDistortion = (defaults.object(forKey: Key.correctsDistortion) as? NSNumber)?.boolValue ?? base.correctsDistortion
    }

    init() {}

    // MARK: distortion

    /// The coefficients actually applied (zero when correction is off).
    var appliedK1: Double { correctsDistortion ? k1 : 0 }
    var appliedK2: Double { correctsDistortion ? k2 : 0 }

    /// tan of the half field of view.
    var fieldTan: Double { tan(fieldOfViewDegrees * .pi / 180) }

    /// Distance from the lens center on the screen (tan units) → direction
    /// the eye sees it in (tan units).
    func eyeTan(fromScreenTan r: Double) -> Double {
        let r2 = r * r
        return r * (1 + appliedK1 * r2 + appliedK2 * r2 * r2)
    }

    /// Inverse of `eyeTan(fromScreenTan:)`.
    func screenTan(fromEyeTan e: Double) -> Double {
        guard e != 0 else { return 0 }
        var r = e
        for _ in 0..<20 { // Newton; converges in a few steps for real lenses
            let r2 = r * r
            let f = r * (1 + appliedK1 * r2 + appliedK2 * r2 * r2) - e
            let slope = 1 + 3 * appliedK1 * r2 + 5 * appliedK2 * r2 * r2
            guard slope > 1e-9 else { break }
            let step = f / slope
            r -= step
            if abs(step) < 1e-12 { break }
        }
        return r
    }

    // MARK: screen layout

    struct Eye: Equatable {
        /// This eye's half of the screen, in pixels, y down.
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        /// Where the lens axis meets the screen, in screen pixels.
        var centerX: Double
        var centerY: Double
    }

    struct Layout: Equatable {
        /// Left eye, then right eye.
        var eyes: [Eye]
        /// Screen pixels per tan unit (at the lens center).
        var pixelsPerTan: Double
        /// Side of the square texture the scene is rendered into, in pixels:
        /// as sharp as the screen at the lens center.
        var eyeTextureSize: Int
    }

    var pixelsPerMM: Double { pixelsPerInch / 25.4 }

    func layout(screenWidth: Double, screenHeight: Double) -> Layout {
        let half = screenWidth / 2
        let offset = lensSeparationMM / 2 * pixelsPerMM
        let centerY = screenHeight / 2 - verticalOffsetMM * pixelsPerMM
        let eyes = [
            Eye(x: 0, y: 0, width: half, height: screenHeight, centerX: half - offset, centerY: centerY),
            Eye(x: half, y: 0, width: screenWidth - half, height: screenHeight, centerX: half + offset, centerY: centerY),
        ]
        let pixelsPerTan = pixelsPerMM * screenToLensMM
        let size = Int((2 * fieldTan * pixelsPerTan / 16).rounded()) * 16
        return Layout(eyes: eyes, pixelsPerTan: pixelsPerTan, eyeTextureSize: min(2048, max(256, size)))
    }

    /// Where a direction seen by the eye (tan units, x right, y down) lands on
    /// the screen, in screen pixels.
    func screenPoint(eye: Eye, layout: Layout, eyeTanX x: Double, eyeTanY y: Double) -> (x: Double, y: Double) {
        let e = (x * x + y * y).squareRoot()
        let k = e > 0 ? screenTan(fromEyeTan: e) / e : 1
        return (eye.centerX + x * k * layout.pixelsPerTan, eye.centerY + y * k * layout.pixelsPerTan)
    }

    /// Whether the eye sees a screen point (in screen pixels) through its lens.
    func isVisible(eye: Eye, layout: Layout, screenX: Double, screenY: Double) -> Bool {
        let tx = (screenX - eye.centerX) / layout.pixelsPerTan, ty = (screenY - eye.centerY) / layout.pixelsPerTan
        let r = (tx * tx + ty * ty).squareRoot()
        let k = r > 0 ? eyeTan(fromScreenTan: r) / r : 1
        return abs(tx * k) <= fieldTan && abs(ty * k) <= fieldTan
    }

    // MARK: camera image

    /// The part of the camera image the eye texture shows, in normalized
    /// image coordinates (may reach past 0…1; that part is black). Centered.
    /// imageAspect = camera image width / height.
    func cameraCrop(imageAspect: Double) -> (x: Double, y: Double, width: Double, height: Double) {
        let h = 1 / zoom
        let w = h / imageAspect // the eye texture is square
        return ((1 - w) / 2, (1 - h) / 2, w, h)
    }
}
