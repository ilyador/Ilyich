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

    private let map = MKMapView()
    /// Night over the whole map: a dark veil over Apple's streets and labels, under the lights.
    private let veil = UIView()
    private let lightLayer = UIView()
    private var lightViews: [UIImageView] = []
    private var shownLights: [Light] = []
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
        map.isUserInteractionEnabled = false
        map.overrideUserInterfaceStyle = .dark
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = false; map.showsScale = false; map.showsUserLocation = false
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        configuration.showsTraffic = false
        map.preferredConfiguration = configuration
        veil.backgroundColor = UIColor(red: 0.03, green: 0.03, blue: 0.1, alpha: 0.5)
        for view in [map, veil, lightLayer] { view.isUserInteractionEnabled = false; addSubview(view) }
        alpha = 0; isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        map.frame = bounds; veil.frame = bounds; lightLayer.frame = bounds
    }

    /// Shows the map as the Earth's camera sees the ground: `altitude` meters over `center`,
    /// tilted by `pitch` degrees, with the Earth's scale of `pointsPerMeter` at the middle.
    func show(center: CLLocationCoordinate2D, altitude: Double, pitch: Double, opacity: Double, pointsPerMeter: Double, lights: [Light]) {
        alpha = opacity
        isHidden = opacity <= 0
        guard opacity > 0, bounds.width > 0 else { return }
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
        while lightViews.count < lights.count {
            let view = UIImageView()
            view.isUserInteractionEnabled = false
            lightLayer.addSubview(view); lightViews.append(view)
        }
        let changed = lights != shownLights
        shownLights = lights
        for (index, view) in lightViews.enumerated() {
            guard index < lights.count else { view.isHidden = true; continue }
            let light = lights[index]
            if changed { view.image = Self.glow(count: light.count); view.sizeToFit() }
            let point = map.convert(CLLocationCoordinate2D(latitude: light.latitude, longitude: light.longitude), toPointTo: map)
            view.center = point
            view.isHidden = !bounds.insetBy(dx: -40, dy: -40).contains(point)
        }
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
