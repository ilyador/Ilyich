import SwiftUI
import RealityKit
import UIKit
import simd

/// A virtual RealityKit scene. No AR session, camera feed, or location permission.
struct PlacesGlobeView: View {
    let places: [PlaceCollection]
    var focus: PlaceFocus? = nil
    var compact = false
    let onSelect: (PlaceCollection) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        GlobeSurface(places: places, focus: focus, compact: compact, dark: colorScheme == .dark,
                     reduceMotion: reduceMotion, active: scenePhase == .active, onSelect: onSelect)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Interactive Earth")
            .accessibilityHint("Drag to rotate and pinch to zoom. Choose a location from the list to explore its photos.")
    }
}

private struct GlobeSurface: UIViewRepresentable {
    let places: [PlaceCollection]
    let focus: PlaceFocus?
    let compact: Bool
    let dark: Bool
    let reduceMotion: Bool
    let active: Bool
    let onSelect: (PlaceCollection) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.environment.background = .color(.clear)
        view.isOpaque = false
        view.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disableGroundingShadows, .disableCameraGrain]
        context.coordinator.cameraDistance = compact ? 2.6 : 3.2
        context.coordinator.setUp(view)
        return view
    }
    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.update(places: places, focus: focus, dark: dark, reduceMotion: reduceMotion, active: active, onSelect: onSelect)
    }
    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) { coordinator.stop(); view.scene.anchors.removeAll() }

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
            view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap(_:))))
            applyTransform()
        }

        func update(places: [PlaceCollection], focus: PlaceFocus?, dark: Bool, reduceMotion: Bool, active: Bool, onSelect: @escaping (PlaceCollection) -> Void) {
            selection = onSelect; self.reduceMotion = reduceMotion; self.active = active
            if reduceMotion || !active { stop() }
            if night != dark {
                night = dark
                var material = PhysicallyBasedMaterial()
                material.roughness = 1
                if let texture = dark ? nightTexture : dayTexture {
                    material.baseColor = .init(tint: .white, texture: .init(texture))
                    if dark { material.emissiveColor = .init(color: .white, texture: .init(texture)); material.emissiveIntensity = 0.55 }
                } else { material.baseColor = .init(tint: dark ? .init(red: 0.02, green: 0.04, blue: 0.09, alpha: 1) : .systemBlue) }
                earth.model?.materials = [material]
                view?.environment.lighting.intensityExponent = dark ? -2 : 0
            }
            let identifiers = places.map { "\($0.id):\($0.assetIDs.count)" }
            if identifiers != lastIDs {
                self.places = places; lastIDs = identifiers
                markerRoot.children.removeAll(); markers.removeAll(); lastFocus = nil
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
