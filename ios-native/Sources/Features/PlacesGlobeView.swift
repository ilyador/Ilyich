import SwiftUI
import RealityKit
import UIKit
import simd

/// A virtual RealityKit scene. No AR session, camera feed, or location permission.
struct PlacesGlobeView: View {
    let places: [PlaceCollection]
    var focus: PlaceFocus? = nil
    var compact = false
    var api: APIClient? = nil
    var pipeline: MediaPipeline? = nil
    let onSelect: (PlaceCollection) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        GlobeSurface(places: places, focus: focus, compact: compact, api: api, pipeline: pipeline, dark: colorScheme == .dark,
                     reduceMotion: reduceMotion, active: scenePhase == .active, onSelect: onSelect)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Interactive Earth")
            .accessibilityHint("Drag to rotate and pinch to zoom. Choose a location from the list to explore its photos.")
    }
}

private struct GlobeSurface: UIViewRepresentable {
    let places: [PlaceCollection]
    let focus: PlaceFocus?
    let compact: Bool
    let api: APIClient?
    let pipeline: MediaPipeline?
    let dark: Bool
    let reduceMotion: Bool
    let active: Bool
    let onSelect: (PlaceCollection) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> ARView {
        let view = GlobeARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.environment.background = .color(.clear)
        view.isOpaque = false
        view.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disableGroundingShadows, .disableCameraGrain]
        context.coordinator.cameraDistance = compact ? 2.6 : 3.2
        context.coordinator.setUp(view)
        view.onLayout = { [weak coordinator = context.coordinator] in coordinator?.updatePhotoMarkers() }
        view.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: GlobeARView, _: UITraitCollection) in view.onLayout?() }
        return view
    }
    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.update(places: places, focus: focus, api: api, pipeline: pipeline, dark: dark, reduceMotion: reduceMotion, active: active, onSelect: onSelect)
    }
    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) { coordinator.stop(); coordinator.photoMarkers.forEach { $0.cancelImage() }; view.scene.anchors.removeAll() }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var view: ARView?
        let anchor = AnchorEntity(world: .zero)
        let globe = Entity()
        let earth = ModelEntity()
        let camera = PerspectiveCamera()
        let light = DirectionalLight()
        let markerRoot = Entity()
        var places: [PlaceCollection] = []
        var markers: [(Entity, PlaceCollection)] = []
        private var markerSizes: [String: CGSize] = [:]
        private var markerMetricsContext = ""
        var lastIDs: [String] = []
        var lastFocus: PlaceFocus?
        var night: Bool?
        var dayTexture: TextureResource?
        var nightTexture: TextureResource?
        var selection: ((PlaceCollection) -> Void)?
        var reduceMotion = false
        var active = true
        var yaw: Float = 0
        var pitch: Float = 0.35
        var cameraDistance: Float = 3.2
        var panOrigin = SIMD2<Float>.zero
        var pinchOrigin: Float = 3.2
        var velocity = SIMD2<Float>.zero
        var api: APIClient?
        var pipeline: MediaPipeline?
        var photoMarkers: [GlobePhotoMarker] = []
        let markerImageCache = GlobeMarkerImageCache()
        var displayLink: CADisplayLink?
        var lastTimestamp: CFTimeInterval = 0

        func setUp(_ view: ARView) {
            self.view = view
            camera.camera.fieldOfViewInDegrees = 44
            camera.position = [0, 0, cameraDistance]
            anchor.addChild(camera)
            anchor.addChild(globe)
            globe.addChild(earth)
            globe.addChild(markerRoot)
            do {
                earth.model = ModelComponent(mesh: try Self.earthMesh(), materials: [SimpleMaterial(color: .systemBlue, isMetallic: false)])
                for name in ["EarthDay", "EarthNight"] {
                    guard let image = UIImage(named: name)?.cgImage else { continue }
                    let texture = try TextureResource.generate(from: image, options: .init(semantic: .color))
                    if name == "EarthDay" { dayTexture = texture } else { nightTexture = texture }
                }
            } catch {
                // Keep a navigable solid globe if a bundled texture cannot be decoded.
                earth.model = ModelComponent(mesh: .generateSphere(radius: 1), materials: [SimpleMaterial(color: .systemBlue, isMetallic: false)])
            }
            light.light.color = .white
            light.light.intensity = 2800
            light.look(at: .zero, from: [3, 2, 4], relativeTo: nil)
            anchor.addChild(light)
            addAtmosphere()
            view.scene.addAnchor(anchor)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            pan.maximumNumberOfTouches = 1; pan.delegate = self
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
            pinch.delegate = self
            view.addGestureRecognizer(pan); view.addGestureRecognizer(pinch)
            let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
            tap.delegate = self; view.addGestureRecognizer(tap)
            for _ in 0..<8 {
                let marker = GlobePhotoMarker()
                marker.isHidden = true
                marker.addTarget(self, action: #selector(photoMarkerTapped(_:)), for: .touchUpInside)
                view.addSubview(marker); photoMarkers.append(marker)
            }
            applyTransform()
        }

        func update(places: [PlaceCollection], focus: PlaceFocus?, api: APIClient?, pipeline: MediaPipeline?, dark: Bool, reduceMotion: Bool, active: Bool, onSelect: @escaping (PlaceCollection) -> Void) {
            self.api = api; self.pipeline = pipeline
            selection = onSelect; self.reduceMotion = reduceMotion; self.active = active
            if reduceMotion || !active { stop() }
            if night != dark {
                night = dark
                var material = PhysicallyBasedMaterial()
                material.roughness = .init(floatLiteral: 1)
                if let texture = dark ? nightTexture : dayTexture {
                    material.baseColor = .init(tint: .white, texture: .init(texture))
                    if dark { material.emissiveColor = .init(color: .white, texture: .init(texture)); material.emissiveIntensity = 0.55 }
                } else { material.baseColor = .init(tint: dark ? .init(red: 0.02, green: 0.04, blue: 0.09, alpha: 1) : .systemBlue) }
                earth.model?.materials = [material]
                view?.environment.lighting.intensityExponent = dark ? -2 : 0
            }
            let identifiers = places.map { "\($0.id):\($0.assetIDs.count):\($0.latitude):\($0.longitude):\($0.assetIDs.first ?? "")" }
            if identifiers != lastIDs {
                self.places = places; lastIDs = identifiers
                markerRoot.children.removeAll(); markers.removeAll(); markerSizes.removeAll(); lastFocus = nil
                // Keep rendering bounded; the complete accessible list remains available.
                for place in places.prefix(300) { addMarker(place) }
            }
            if let focus, focus != lastFocus, focus.latitude.isFinite, focus.longitude.isFinite {
                lastFocus = focus; stop()
                pitch = Float(focus.latitude * .pi / 180)
                yaw = Float(-focus.longitude * .pi / 180)
                cameraDistance = focus.assetID == nil ? 3.2 : 2.35
                if let assetID = focus.assetID {
                    let place = PlaceCollection(id: "focused-\(assetID)", title: "Photo location", city: nil, country: nil,
                        latitude: focus.latitude, longitude: focus.longitude, assetIDs: [assetID])
                    if !markers.contains(where: { $0.1.id == place.id }) { addMarker(place, highlighted: true) }
                }
                applyTransform()
            }
            updatePhotoMarkers()
        }

        private func addMarker(_ place: PlaceCollection, highlighted: Bool = false) {
            let marker = ModelEntity(mesh: .generateSphere(radius: highlighted ? 0.025 : 0.014),
                                     materials: [UnlitMaterial(color: highlighted ? .white : .init(red: 1, green: 0.77, blue: 0.33, alpha: 1))])
            marker.position = Self.position(latitude: place.latitude, longitude: place.longitude) * 1.015
            markerRoot.addChild(marker); markers.append((marker, place))
        }

        private func addAtmosphere() {
            // Thin outer shells make a physical limb halo; face culling keeps the land legible.
            let layers: [(Float, Float)] = [(1.012, 0.12), (1.028, 0.055), (1.05, 0.02)]
            for (radius, opacity) in layers {
                var material = UnlitMaterial(color: UIColor(red: 0.23, green: 0.53, blue: 1, alpha: 1))
                material.blending = .transparent(opacity: .init(floatLiteral: opacity))
                material.faceCulling = .front
                let shell = ModelEntity(mesh: .generateSphere(radius: radius), materials: [material])
                globe.addChild(shell)
            }
        }

        private func applyTransform() {
            globe.orientation = simd_quatf(angle: pitch, axis: [1, 0, 0]) * simd_quatf(angle: yaw, axis: [0, 1, 0])
            camera.position = [0, 0, cameraDistance]
            updatePhotoMarkers()
        }
        @objc private func pan(_ recognizer: UIPanGestureRecognizer) {
            guard let view else { return }
            let delta = recognizer.translation(in: view)
            switch recognizer.state {
            case .began: stop(); panOrigin = [yaw, pitch]
            case .changed:
                yaw = panOrigin.x + Float(delta.x) * 0.006
                pitch = min(.pi / 2, max(-.pi / 2, panOrigin.y + Float(delta.y) * 0.006))
                applyTransform()
            case .ended:
                guard !reduceMotion && active else { return }
                let value = recognizer.velocity(in: view)
                velocity = [Float(value.x) * 0.006, Float(value.y) * 0.006]
                if simd_length(velocity) > 0.05 { startInertia() }
            default: break
            }
        }
        @objc private func pinch(_ recognizer: UIPinchGestureRecognizer) {
            if recognizer.state == .began { stop(); pinchOrigin = cameraDistance }
            cameraDistance = min(6, max(1.35, pinchOrigin / Float(recognizer.scale)))
            applyTransform()
        }
        @objc private func tap(_ recognizer: UITapGestureRecognizer) {
            guard let view else { return }
            let point = recognizer.location(in: view)
            var nearest: (CGFloat, PlaceCollection)?
            for (entity, place) in markers {
                let world = entity.position(relativeTo: nil)
                guard simd_dot(world, camera.position - world) > 0, let projected = view.project(world) else { continue }
                let distance = hypot(point.x - projected.x, point.y - projected.y)
                if distance < 32, nearest == nil || distance < nearest!.0 { nearest = (distance, place) }
            }
            if let place = nearest?.1 { stop(); selection?(place); UISelectionFeedbackGenerator().selectionChanged() }
        }
        @objc private func photoMarkerTapped(_ sender: GlobePhotoMarker) {
            guard let place = sender.place else { return }
            stop(); selection?(place); UISelectionFeedbackGenerator().selectionChanged()
        }
        func updatePhotoMarkers() {
            guard let view, let api, let pipeline, active, view.bounds.width > 0 else {
                photoMarkers.forEach { $0.isHidden = true }; return
            }
            var placed: [CGRect] = []
            var visible: [(CGPoint, PlaceCollection)] = []
            let metricsContext = "\(view.traitCollection.preferredContentSizeCategory.rawValue)|\(Int(view.bounds.width))"
            if metricsContext != markerMetricsContext { markerSizes.removeAll(); markerMetricsContext = metricsContext }
            let ordered = markers.sorted { left, right in
                if left.1.id.hasPrefix("focused-") { return true }
                if right.1.id.hasPrefix("focused-") { return false }
                return left.1.assetIDs.count > right.1.assetIDs.count
            }
            for (entity, place) in ordered {
                let world = entity.position(relativeTo: nil)
                guard simd_dot(world, camera.position - world) > 0.12, let point = view.project(world) else { continue }
                let key = place.id
                let size = markerSizes[key] ?? GlobePhotoMarker.fittingSize(title: place.title, traits: view.traitCollection, availableWidth: view.bounds.width - 12)
                markerSizes[key] = size
                let frame = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
                guard view.bounds.insetBy(dx: 6, dy: 6).contains(frame), !placed.contains(where: { $0.insetBy(dx: -8, dy: -10).intersects(frame) }) else { continue }
                placed.append(frame); visible.append((point, place))
                if placed.count == photoMarkers.count { break }
            }
            for (index, marker) in photoMarkers.enumerated() {
                guard index < visible.count else { marker.isHidden = true; marker.cancelImage(); continue }
                marker.frame = placed[index]; marker.isHidden = false
                marker.configure(place: visible[index].1, api: api, pipeline: pipeline, cache: markerImageCache)
            }
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var current = touch.view
            while let candidate = current, candidate !== view {
                if candidate is UIControl { return false }
                current = candidate.superview
            }
            return true
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        private func startInertia() {
            stop(keepVelocity: true)
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = .init(minimum: 30, maximum: 120, preferred: 60)
            link.add(to: .main, forMode: .common); displayLink = link
        }
        @objc private func tick(_ link: CADisplayLink) {
            guard active && !reduceMotion else { stop(); return }
            let elapsed = Float(lastTimestamp == 0 ? 1 / 60 : min(link.timestamp - lastTimestamp, 0.05))
            lastTimestamp = link.timestamp
            yaw += velocity.x * elapsed
            pitch = min(.pi / 2, max(-.pi / 2, pitch + velocity.y * elapsed))
            velocity *= pow(0.08, elapsed)
            applyTransform()
            if simd_length(velocity) < 0.015 { stop() }
        }
        func stop(keepVelocity: Bool = false) {
            displayLink?.invalidate(); displayLink = nil; lastTimestamp = 0
            if !keepVelocity { velocity = .zero }
        }
        private static func position(latitude: Double, longitude: Double) -> SIMD3<Float> {
            let lat = Float(latitude * .pi / 180), lon = Float(longitude * .pi / 180)
            return [cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon)]
        }
        private static func earthMesh() throws -> MeshResource {
            let rows = 64, columns = 128
            var positions: [SIMD3<Float>] = [], coordinates: [SIMD2<Float>] = [], indices: [UInt32] = []
            for row in 0...rows {
                let v = Float(row) / Float(rows)
                for column in 0...columns {
                    let u = Float(column) / Float(columns)
                    let lat = .pi / 2 - v * .pi, lon = u * 2 * .pi - .pi
                    positions.append([cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon)])
                    coordinates.append([u, v])
                }
            }
            for row in 0..<rows { for column in 0..<columns {
                let a = UInt32(row * (columns + 1) + column), b = a + 1, c = a + UInt32(columns + 1), d = c + 1
                indices.append(contentsOf: [a, c, b, b, c, d])
            } }
            var descriptor = MeshDescriptor(name: "Earth")
            descriptor.positions = MeshBuffer(positions); descriptor.normals = MeshBuffer(positions)
            descriptor.textureCoordinates = MeshBuffer(coordinates); descriptor.primitives = .triangles(indices)
            return try MeshResource.generate(from: [descriptor])
        }
    }
}


@MainActor private final class GlobeARView: ARView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() { super.layoutSubviews(); onLayout?() }
}

@MainActor private final class GlobePhotoMarker: UIControl {
    private let backdrop = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let thumbnail = UIImageView()
    private let nameLabel = UILabel()
    private let countLabel = UILabel()
    private var imageTask: Task<Void, Never>?
    private var imageID: String?
    var place: PlaceCollection?

    init() {
        super.init(frame: .zero)
        isAccessibilityElement = true; accessibilityTraits = .button
        backdrop.isUserInteractionEnabled = false
        backdrop.layer.cornerRadius = 27; backdrop.clipsToBounds = true
        addSubview(backdrop)
        thumbnail.contentMode = .scaleAspectFill; thumbnail.clipsToBounds = true; thumbnail.layer.cornerRadius = 10
        thumbnail.backgroundColor = .secondarySystemFill
        nameLabel.font = .preferredFont(forTextStyle: .subheadline); nameLabel.textColor = .label
        countLabel.font = .preferredFont(forTextStyle: .caption2); countLabel.textColor = .secondaryLabel
        nameLabel.adjustsFontForContentSizeCategory = true; countLabel.adjustsFontForContentSizeCategory = true
        nameLabel.lineBreakMode = .byTruncatingTail
        for view in [thumbnail, nameLabel, countLabel] { view.isUserInteractionEnabled = false; addSubview(view) }
        layer.shadowColor = UIColor.black.cgColor; layer.shadowOpacity = 0.18; layer.shadowRadius = 8; layer.shadowOffset = CGSize(width: 0, height: 4)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layoutSubviews() {
        super.layoutSubviews(); backdrop.frame = bounds
        nameLabel.numberOfLines = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 2 : 1
        let edge = min(52, bounds.height - 18), textX = edge + 18
        thumbnail.frame = CGRect(x: 9, y: (bounds.height - edge) / 2, width: edge, height: edge)
        let countHeight = ceil(countLabel.font.lineHeight)
        nameLabel.frame = CGRect(x: textX, y: 8, width: bounds.width - textX - 12, height: bounds.height - countHeight - 18)
        countLabel.frame = CGRect(x: textX, y: bounds.height - countHeight - 8, width: bounds.width - textX - 12, height: countHeight)
        backdrop.layer.cornerRadius = min(30, bounds.height / 2)
    }
    static func fittingSize(title: String, traits: UITraitCollection, availableWidth: CGFloat) -> CGSize {
        let name = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits)
        let count = UIFont.preferredFont(forTextStyle: .caption2, compatibleWith: traits)
        let lines: CGFloat = traits.preferredContentSizeCategory.isAccessibilityCategory ? 2 : 1
        let height = max(54, ceil(name.lineHeight * lines + count.lineHeight + 18))
        let textWidth = (title as NSString).size(withAttributes: [.font: name]).width
        let width = min(availableWidth, min(lines == 2 ? 340 : 240, max(142, textWidth + min(52, height - 18) + 30)))
        return .init(width: width, height: height)
    }
    func configure(place: PlaceCollection, api: APIClient, pipeline: MediaPipeline, cache: GlobeMarkerImageCache) {
        self.place = place; nameLabel.text = place.title; countLabel.text = place.assetIDs.count.formatted()
        accessibilityLabel = "\(place.title), \(place.assetIDs.count) items"
        guard let id = place.assetIDs.first, id != imageID else { return }
        imageTask?.cancel(); imageID = id; thumbnail.image = nil
        if let image = cache.images[id] { thumbnail.image = image; return }
        imageTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
                let asset = try await api.asset(id: id)
                let image = try await pipeline.image(for: asset, size: .thumbnail, pixelSize: 120)
                try Task.checkCancellation()
                guard let self, self.imageID == id else { return }
                let uiImage = image.uiImage
                self.thumbnail.image = uiImage; cache.insert(uiImage, id: id)
            } catch { }
        }
    }
    func cancelImage() { imageTask?.cancel(); imageTask = nil; imageID = nil }
}


@MainActor private final class GlobeMarkerImageCache {
    var images: [String: UIImage] = [:]
    private var order: [String] = []
    func insert(_ image: UIImage, id: String) {
        if images[id] == nil { order.append(id) }
        images[id] = image
        if order.count > 64 { images.removeValue(forKey: order.removeFirst()) }
    }
}
