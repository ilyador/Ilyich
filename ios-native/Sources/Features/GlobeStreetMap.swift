import MapKit
import UIKit

/// Apple's map in the dark, flat, without its places, under a night veil and the photo lights:
/// the same night Earth, close enough to see streets. It sits over the Earth and under the pins,
/// comes in as the camera comes down to a city, and follows the Earth's camera on every frame. It
/// never takes a touch; the Earth's gestures move it.
@MainActor final class GlobeStreetMapView: UIView {
    struct Light: Equatable {
        let latitude: Double
        let longitude: Double
        let count: Int
    }

    /// Made the first time the camera comes down to a city, and let go under memory pressure
    /// while the Earth is higher, since most visits to the Earth never come that close.
    private var map: MKMapView?
    /// Night over the whole map: a dark veil over Apple's streets and labels, under the lights.
    private let veil = UIView()
    private let lightLayer = UIView()
    private var lightViews: [UIImageView] = []
    /// MapKit's camera distance for the Earth's height over the ground. Measured from the map's
    /// own scale each time the camera is set, so a kilometer is as many points on both.
    private var distanceFactor = 1.5
    private static var glows: [Int: UIImage] = [:]

    /// The height over the ground, in Earth radii, at which the street map starts to come in, and
    /// at which it is fully in: about 125 km and 55 km up, where a city fills the view.
    nonisolated static let fadesInAt = 0.02
    nonisolated static let fullAt = 0.0085

    nonisolated static func opacity(altitude: Double) -> Double {
        min(1, max(0, (fadesInAt - altitude) / (fadesInAt - fullAt)))
    }

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        veil.backgroundColor = UIColor(red: 0.03, green: 0.03, blue: 0.1, alpha: 0.5)
        for view in [veil, lightLayer] { view.isUserInteractionEnabled = false; addSubview(view) }
        alpha = 0; isHidden = true
        NotificationCenter.default.addObserver(self, selector: #selector(memoryWarning), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        map?.frame = bounds; veil.frame = bounds; lightLayer.frame = bounds
    }

    private func makeMap() -> MKMapView {
        let map = MKMapView(frame: bounds)
        map.isUserInteractionEnabled = false
        map.overrideUserInterfaceStyle = .dark
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = false; map.showsScale = false; map.showsUserLocation = false
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        configuration.showsTraffic = false
        map.preferredConfiguration = configuration
        insertSubview(map, at: 0)
        self.map = map
        return map
    }

    @objc private func memoryWarning() {
        guard isHidden, let map else { return }
        map.removeFromSuperview(); self.map = nil
        distanceFactor = 1.5
    }

    /// Shows the map as the Earth's camera sees the ground: `altitude` meters over `center`,
    /// tilted by `pitch` degrees, with the Earth's scale of `pointsPerMeter` at the middle.
    func show(center: CLLocationCoordinate2D, altitude: Double, pitch: Double, opacity: Double, pointsPerMeter: Double, lights: [Light]) {
        alpha = opacity
        isHidden = opacity <= 0
        guard opacity > 0, bounds.width > 0 else { return }
        let map = self.map ?? makeMap()
        map.camera = MKMapCamera(lookingAtCenter: center, fromDistance: altitude * distanceFactor, pitch: pitch, heading: 0)
        if pointsPerMeter > 0 {
            let north = CLLocationCoordinate2D(latitude: center.latitude + 1000 / 111_320, longitude: center.longitude)
            let a = map.convert(center, toPointTo: map), b = map.convert(north, toPointTo: map)
            let ratio = hypot(b.x - a.x, b.y - a.y) / 1000 / pointsPerMeter
            if ratio.isFinite, ratio > 0, abs(ratio - 1) > 0.01 {
                distanceFactor = min(4, max(0.4, distanceFactor * ratio))
                map.camera = MKMapCamera(lookingAtCenter: center, fromDistance: altitude * distanceFactor, pitch: pitch, heading: 0)
            }
        }
        // The lights in view reach far past the screen (the Earth's own glow keeps a wide set),
        // so only those within the ground the camera can see are projected, and only they get a
        // view, from a pool: a few dozen, not thousands, each frame.
        let reach = 3 * altitude / PlaceGeometry.earthRadius * 180 / .pi
        let stretch = 1 / max(0.1, cos(center.latitude * .pi / 180))
        var used = 0
        for light in lights where abs(light.latitude - center.latitude) <= reach && abs(light.longitude - center.longitude) <= reach * stretch {
            let point = map.convert(CLLocationCoordinate2D(latitude: light.latitude, longitude: light.longitude), toPointTo: map)
            guard bounds.insetBy(dx: -40, dy: -40).contains(point) else { continue }
            if used == lightViews.count {
                let view = UIImageView()
                view.isUserInteractionEnabled = false
                lightLayer.addSubview(view); lightViews.append(view)
            }
            let view = lightViews[used]; used += 1
            let glow = Self.glow(count: light.count)
            if view.image !== glow { view.image = glow; view.sizeToFit() }
            view.center = point
            view.isHidden = false
        }
        for view in lightViews[used...] where !view.isHidden { view.isHidden = true }
    }

    /// The Earth's glow for a light, as a flat image: eight steps of brightness by count.
    private static func glow(count: Int) -> UIImage {
        let step = min(7, Int(log2(Double(max(1, count))).rounded(.down)))
        if let image = glows[step] { return image }
        let radius = 9.0 + 2.5 * Double(step)
        let size = CGSize(width: radius * 2, height: radius * 2)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(red: 1, green: 0.96, blue: 0.9, alpha: 0.95).cgColor,
                          UIColor(red: 1, green: 0.78, blue: 0.5, alpha: 0.5).cgColor,
                          UIColor(red: 1, green: 0.74, blue: 0.42, alpha: 0).cgColor]
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.3, 1]) else { return }
            let center = CGPoint(x: radius, y: radius)
            context.cgContext.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        }
        glows[step] = image
        return image
    }
}
