import SwiftUI
import RealityKit
import UIKit
import simd

enum GlobeGeometry {
    static let compactCameraHeight: Float = 0.5
    static let compactCameraDistance: Float = 2.25
    /// About 20 km above the ground, close enough to separate neighboring towns' photo pins.
    static let minimumSurfaceDistance: Float = 0.003
    static let maximumCameraDistance: Float = 5
    static let markerRadius: Float = 1.0006

    static func position(latitude: Double, longitude: Double) -> SIMD3<Float> {
        let lat = Float(latitude * .pi / 180), lon = Float(longitude * .pi / 180)
        return [cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon)]
    }

    static func focusPitch(latitude: Double, compact: Bool) -> Float {
        // Align the marker with the elevated camera's horizontal center ray.
        Float(latitude * .pi / 180) - (compact ? asin(compactCameraHeight / markerRadius) : 0)
    }

    static func clampPitch(_ pitch: Float, compact: Bool) -> Float {
        min(focusPitch(latitude: 90, compact: compact), max(focusPitch(latitude: -90, compact: compact), pitch))
    }

    /// Where the camera's center ray meets the marker shell. Zoom scales the distance to it.
    static func groundZ(compact: Bool) -> Float {
        compact ? (markerRadius * markerRadius - compactCameraHeight * compactCameraHeight).squareRoot() : markerRadius
    }

    /// Screen-space motion follows the surface under the finger at every zoom level.
    static func dragRadiansPerPoint(cameraDistance: Float, viewportHeight: Float, compact: Bool = false) -> Float {
        2 * max(minimumSurfaceDistance, cameraDistance - groundZ(compact: compact)) * tan(22 * .pi / 180) / max(1, viewportHeight)
    }

    static func clampedCameraDistance(_ distance: Float, compact: Bool = false) -> Float {
        min(compact ? 3 : maximumCameraDistance, max(groundZ(compact: compact) + minimumSurfaceDistance, distance))
    }

    /// Choosing a location turns the Earth to it at the current zoom. Only a photo's own
    /// location, opened from the photo, comes in closer.
    static func focusDistance(current: Float, photo: Bool, compact: Bool) -> Float {
        photo && !compact ? 2.35 : current
    }

    static func textureCoordinate(latitude: Float, longitude: Float) -> SIMD2<Float> {
        // Mesh UVs have a lower-left origin; the north-up image starts at its top.
        [longitude / (2 * .pi) + 0.5, latitude / .pi + 0.5]
    }
}

/// A virtual RealityKit scene. No AR session, camera feed, or location permission.
/// The Earth is a schematic night globe: vector land stays sharp at every zoom, and the
/// places photos were taken glow on it like city lights.
struct PlacesGlobeView: View {
    let places: [PlaceCollection]
    var lights: GlobePhotoLights? = nil
    var focus: PlaceFocus? = nil
    var compact = false
    var api: APIClient? = nil
    var pipeline: MediaPipeline? = nil
    let onSelect: (PlaceCollection) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// Builds the Earth's land ahead of showing it.
    static func prepare() async { _ = await GlobeLand.prepare() }

    var body: some View {
        GeometryReader { geometry in
            GlobeSurface(places: places, lights: lights, focus: focus, compact: compact, api: api, pipeline: pipeline,
                         reduceMotion: reduceMotion, active: scenePhase == .active, onSelect: onSelect)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
        }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Interactive Earth")
            .accessibilityHint("Drag to rotate and pinch to zoom. Choose a location from the list to explore its photos.")
    }
}

private struct GlobeSurface: UIViewRepresentable {
    let places: [PlaceCollection]
    let lights: GlobePhotoLights?
    let focus: PlaceFocus?
    let compact: Bool
    let api: APIClient?
    let pipeline: MediaPipeline?
    let reduceMotion: Bool
    let active: Bool
    let onSelect: (PlaceCollection) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> GlobeHostView {
        let host = GlobeHostView()
        let view = host.renderer
        view.environment.background = .color(.clear)
        view.isOpaque = false
        view.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disableGroundingShadows, .disableCameraGrain]
        context.coordinator.compact = compact
        context.coordinator.cameraDistance = compact ? GlobeGeometry.compactCameraDistance : 3.2
        context.coordinator.setUp(host)
        host.onLayout = { [weak coordinator = context.coordinator] in coordinator?.updatePhotoMarkers() }
        host.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (host: GlobeHostView, _: UITraitCollection) in host.onLayout?() }
        return host
    }
    func updateUIView(_ view: GlobeHostView, context: Context) {
        context.coordinator.update(places: places, lights: lights, focus: focus, api: api, pipeline: pipeline, reduceMotion: reduceMotion, active: active, onSelect: onSelect)
    }
    static func dismantleUIView(_ view: GlobeHostView, coordinator: Coordinator) { coordinator.stop(); coordinator.landTask?.cancel(); coordinator.photoMarkers.forEach { $0.cancelImage() }; view.renderer.scene.anchors.removeAll(); view.onLayout = nil }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private struct FocusTransition {
            let from: SIMD3<Float>
            let to: SIMD3<Float>
            var elapsed: Float = 0
        }
        weak var view: ARView?
        weak var host: GlobeHostView?
        let anchor = AnchorEntity(world: .zero)
        let globe = Entity()
        let ocean = ModelEntity()
        /// One child per piece of the land mesh.
        let land = Entity()
        let lakes = ModelEntity()
        let photoLights = ModelEntity()
        /// Faint strings arching between the places photos were taken.
        let strings = ModelEntity()
        /// Major highways glowing faintly on the land, as on the night side from orbit.
        let roads = ModelEntity()
        let moon = DirectionalLight()
        /// The atmosphere's glow along the Earth's edge. It faces the camera and does not turn with the Earth.
        let rim = ModelEntity()
        /// The air seen against the Earth: a camera-facing disc just in front of it, clear in the
        /// middle and thickening toward the silhouette.
        let haze = ModelEntity()
        let camera = PerspectiveCamera()
        let markerRoot = Entity()
        var places: [PlaceCollection] = []
        var markers: [(Entity, PlaceCollection)] = []
        private var markerSizes: [String: CGSize] = [:]
        private var markerMetricsContext = ""
        var lastIDs: [String] = []
        var lastFocus: PlaceFocus?
        var focusedPlaceID: String?
        var landTask: Task<Void, Never>?
        private var lightData: GlobePhotoLights?
        private var lightLevel: Int?
        private var lightCenter: SIMD3<Float>?
        private var layerTask: Task<Void, Never>?
        private var layerGeneration = 0
        private var roadData: GlobeRoads?
        private let lightMaterial = GlobeStyle.lightMaterial()
        private let stringMaterial = GlobeStyle.lineMaterial(GlobeStyle.string, opacity: 0.22)
        private let roadMaterial = GlobeStyle.lineMaterial(GlobeStyle.road, opacity: 0.2)
        var selection: ((PlaceCollection) -> Void)?
        var reduceMotion = false
        var active = true
        var yaw: Float = 0
        var pitch: Float = 0.35
        var cameraDistance: Float = 3.2
        var compact = false
        var isPinching = false
        /// Inertia in screen points per second, so a flick feels the same at every zoom level.
        var velocity = SIMD2<Float>.zero
        var api: APIClient?
        var pipeline: MediaPipeline?
        var photoMarkers: [GlobePhotoMarker] = []
        var displayLink: CADisplayLink?
        var lastTimestamp: CFTimeInterval = 0
        private var focusTransition: FocusTransition?

        func setUp(_ host: GlobeHostView) {
            self.host = host
            let view = host.renderer
            self.view = view
            camera.camera.fieldOfViewInDegrees = 44
            camera.camera.far = 20
            camera.position = [0, compact ? GlobeGeometry.compactCameraHeight : 0, cameraDistance]
            anchor.addChild(camera)
            anchor.addChild(rim)
            anchor.addChild(haze)
            anchor.addChild(globe)
            for part in [ocean, land, lakes, roads, strings, photoLights] { globe.addChild(part) }
            globe.addChild(markerRoot)
            ocean.model = ModelComponent(mesh: (try? Self.oceanMesh()) ?? .generateSphere(radius: GlobeStyle.oceanRadius),
                                         materials: [GlobeStyle.sea()])
            // A cool moon from the upper left, fixed to the view, shades the Earth as a sphere.
            moon.light.color = UIColor(red: 0.78, green: 0.84, blue: 1, alpha: 1)
            moon.light.intensity = 4_500
            moon.look(at: .zero, from: [-3, 2.2, 1.8], relativeTo: nil)
            anchor.addChild(moon)
            view.environment.lighting.intensityExponent = -3
            if let rimMaterial = GlobeStyle.rimMaterial(), let hazeMaterial = GlobeStyle.hazeMaterial() {
                Task { [weak self] in
                    guard let ring = await GlobeRibbon.rim(), let disc = await GlobeRibbon.rim(inner: 0, outer: 1) else { return }
                    self?.rim.model = ModelComponent(mesh: ring, materials: [rimMaterial])
                    self?.haze.model = ModelComponent(mesh: disc, materials: [hazeMaterial])
                }
            }
            if let meshes = GlobeLand.loaded {
                applyLand(meshes)
            } else {
                landTask = Task { [weak self] in
                    guard let meshes = await GlobeLand.prepare() else { return }
                    self?.applyLand(meshes)
                }
            }
            view.scene.addAnchor(anchor)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            pan.maximumNumberOfTouches = 1; pan.delegate = self
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
            pinch.delegate = self
            host.addGestureRecognizer(pan); host.addGestureRecognizer(pinch)
            let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
            tap.delegate = self; host.addGestureRecognizer(tap)
            for _ in 0..<8 {
                let marker = GlobePhotoMarker()
                marker.isHidden = true
                marker.addTarget(self, action: #selector(photoMarkerTapped(_:)), for: .touchUpInside)
                host.markerOverlay.addSubview(marker); photoMarkers.append(marker)
            }
            applyTransform()
        }

        func update(places: [PlaceCollection], lights: GlobePhotoLights?, focus: PlaceFocus?, api: APIClient?, pipeline: MediaPipeline?, reduceMotion: Bool, active: Bool, onSelect: @escaping (PlaceCollection) -> Void) {
            self.api = api; self.pipeline = pipeline
            selection = onSelect; self.reduceMotion = reduceMotion; self.active = active
            if !active {
                stop()
            } else if reduceMotion {
                if let target = focusTransition?.to {
                    setPose(target)
                    applyTransform()
                }
                stop()
            }
            if lights !== lightData {
                lightData = lights; lightLevel = nil
                updatePhotoLights()
            }
            let identifiers = places.map { "\($0.id):\($0.assetIDs.count):\($0.latitude):\($0.longitude):\($0.assetIDs.first ?? "")" }
            if identifiers != lastIDs {
                self.places = places; lastIDs = identifiers
                markerRoot.children.removeAll(); markers.removeAll(); markerSizes.removeAll(); lastFocus = nil
                // Keep rendering bounded; the complete accessible list remains available.
                for place in places.prefix(300) { addMarker(place) }
            }
            if let focus, focus != lastFocus, focus.latitude.isFinite, focus.longitude.isFinite {
                lastFocus = focus
                stop()
                let targetPitch = GlobeGeometry.focusPitch(latitude: focus.latitude, compact: compact)
                let requestedYaw = Float(-focus.longitude * .pi / 180)
                let yawDelta = atan2(sin(requestedYaw - yaw), cos(requestedYaw - yaw))
                let target = SIMD3(yaw + yawDelta, targetPitch,
                                   GlobeGeometry.focusDistance(current: cameraDistance, photo: focus.assetID != nil, compact: compact))
                if let assetID = focus.assetID {
                    focusedPlaceID = places.first { $0.assetIDs.contains(assetID) }?.id
                    if focusedPlaceID == nil {
                        let place = PlaceCollection(id: "focused-\(assetID)", title: "Photo location", city: nil, country: nil,
                            latitude: focus.latitude, longitude: focus.longitude, assetIDs: [assetID])
                        focusedPlaceID = place.id
                        if !markers.contains(where: { $0.1.id == place.id }) { addMarker(place, highlighted: true) }
                    }
                } else {
                    focusedPlaceID = nil
                }
                let current = SIMD3(yaw, pitch, cameraDistance)
                if reduceMotion || !active || (abs(yawDelta) < 0.002 && abs(targetPitch - pitch) < 0.002 && abs(target.z - cameraDistance) < 0.005) {
                    setPose(target)
                    applyTransform()
                } else {
                    focusTransition = FocusTransition(from: current, to: target)
                    startDisplayLink()
                }
            }
            updatePhotoMarkers()
        }

        private func applyLand(_ meshes: GlobeLand.Meshes) {
            land.children.removeAll()
            let material = GlobeStyle.lit(GlobeStyle.land, glow: 0.1)
            for piece in meshes.land { land.addChild(ModelEntity(mesh: piece, materials: [material])) }
            lakes.model = meshes.lakes.map { ModelComponent(mesh: $0, materials: [GlobeStyle.sea()]) }
            roadData = meshes.roads; lightLevel = nil
            updatePhotoLights()
        }

        /// Places stay invisible anchors for the photo cards and for taps; the lights show them.
        private func addMarker(_ place: PlaceCollection, highlighted: Bool = false) {
            let marker = Entity()
            marker.position = GlobeGeometry.position(latitude: place.latitude, longitude: place.longitude) * GlobeGeometry.markerRadius
            markerRoot.addChild(marker); markers.append((marker, place))
        }

        private func applyTransform() {
            globe.orientation = simd_quatf(angle: pitch, axis: [1, 0, 0]) * simd_quatf(angle: yaw, axis: [0, 1, 0])
            // Frame the horizon inside the visible viewport, rather than
            // rendering a tall off-screen surface and cropping its controls.
            camera.position = [0, compact ? GlobeGeometry.compactCameraHeight : 0, cameraDistance]
            let altitude = cameraDistance - GlobeGeometry.groundZ(compact: compact)
            camera.camera.near = max(0.0002, min(0.01, altitude * 0.25))
            updateRim()
            updatePhotoLights()
            updatePhotoMarkers()
        }

        /// A camera-facing ring through the Earth's center, sized so its glow starts at the
        /// silhouette, and the haze disc halfway between the ground and the camera, sized to the
        /// silhouette's cone there. The Earth hides the ring's inner edge.
        private func updateRim() {
            let distance = simd_length(camera.position)
            guard distance > 1.0001 else { return }
            let tangent = (distance * distance - 1).squareRoot()
            rim.look(at: camera.position, from: .zero, relativeTo: anchor)
            rim.scale = SIMD3(repeating: distance / tangent)
            let depth = 1 + (distance - 1) * 0.5
            haze.look(at: camera.position, from: camera.position / distance * depth, relativeTo: anchor)
            haze.scale = SIMD3(repeating: (distance - depth) / tangent)
        }

        /// The point of the Earth under the middle of the view, in the Earth's own coordinates.
        private var viewCenter: SIMD3<Float> {
            let ground = SIMD3<Float>(0, compact ? GlobeGeometry.compactCameraHeight : 0, GlobeGeometry.groundZ(compact: compact))
            return simd_normalize(globe.orientation.inverse.act(ground))
        }

        /// Lights are regrouped for each half-octave of altitude, and only the part of the Earth up
        /// to the horizon is drawn, so zooming in separates them without drawing every photo.
        private func updatePhotoLights() {
            guard (lightData?.total ?? 0) > 0 || roadData != nil else {
                layerGeneration += 1; layerTask?.cancel()
                photoLights.model = nil; strings.model = nil; roads.model = nil
                return
            }
            let altitude = max(GlobeGeometry.minimumSurfaceDistance, cameraDistance - GlobeGeometry.groundZ(compact: compact))
            let exact = 2 * log2(altitude)
            // A little hysteresis, so pinching across a step does not regroup on every frame.
            let level = lightLevel.map { abs(exact - Float($0)) < 0.65 ? $0 : GlobePhotoLights.level(altitude: altitude) } ?? GlobePhotoLights.level(altitude: altitude)
            let horizon = min(Float.pi, acos(1 / (1 + altitude)) * 1.4 + 0.02)
            let center = viewCenter
            if level == lightLevel, let lightCenter, acos(min(1, simd_dot(lightCenter, center))) < horizon * 0.25 { return }
            lightLevel = level; lightCenter = center
            let reach = cos(horizon)
            let visible = lightData?.clusters(level: level).filter { simd_dot($0.center, center) > reach } ?? []
            let roadLines = roadData?.visible(around: center, within: horizon) ?? []
            let cell = GlobePhotoLights.cell(level: level)
            // The three layers are built off the main thread and swapped in together; a newer
            // zoom step or view makes an older build stale.
            layerGeneration += 1
            let generation = layerGeneration
            layerTask?.cancel()
            layerTask = Task.detached(priority: .userInitiated) { [weak self] in
                let lights = await GlobeLightMesh.make(visible, cell: cell)
                let strings = await GlobeRibbon.mesh(GlobeRibbon.strings(visible, cell: cell), name: "Strings")
                let roads = await GlobeRibbon.mesh(GlobeRibbon.roads(roadLines, cell: cell), name: "Roads")
                guard !Task.isCancelled else { return }
                await self?.applyLayers(generation, lights: lights, strings: strings, roads: roads)
            }
        }

        private func applyLayers(_ generation: Int, lights: MeshResource?, strings stringMesh: MeshResource?, roads roadMesh: MeshResource?) {
            guard generation == layerGeneration else { return }
            photoLights.model = Self.model(lights, lightMaterial)
            strings.model = Self.model(stringMesh, stringMaterial)
            roads.model = Self.model(roadMesh, roadMaterial)
        }

        private static func model(_ mesh: MeshResource?, _ material: UnlitMaterial?) -> ModelComponent? {
            guard let mesh, let material else { return nil }
            return ModelComponent(mesh: mesh, materials: [material])
        }

        private func setPose(_ pose: SIMD3<Float>) {
            yaw = pose.x; pitch = pose.y; cameraDistance = pose.z
        }
        @objc private func pan(_ recognizer: UIPanGestureRecognizer) {
            guard let view else { return }
            let gain = GlobeGeometry.dragRadiansPerPoint(cameraDistance: cameraDistance, viewportHeight: Float(view.bounds.height), compact: compact)
            switch recognizer.state {
            case .began:
                stop()
                recognizer.setTranslation(.zero, in: view)
            case .changed:
                let delta = recognizer.translation(in: view)
                yaw += Float(delta.x) * gain
                pitch = GlobeGeometry.clampPitch(pitch + Float(delta.y) * gain, compact: compact)
                recognizer.setTranslation(.zero, in: view)
                applyTransform()
            case .ended:
                guard !reduceMotion && active && !isPinching else { return }
                let value = recognizer.velocity(in: view)
                velocity = [Float(value.x), Float(value.y)]
                // Fast flicks stay controllable and decay to rest without snapping.
                let speed = simd_length(velocity)
                if speed > 1600 { velocity *= 1600 / speed }
                if speed > 20 { startInertia() }
            case .cancelled, .failed: break
            default: break
            }
        }
        @objc private func pinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                stop(); isPinching = true
            case .changed:
                // Scale distance from the surface, so zoom speed remains even
                // close to Earth and can reverse naturally at either bound.
                let scale = max(0.01, Float(recognizer.scale))
                let ground = GlobeGeometry.groundZ(compact: compact)
                cameraDistance = GlobeGeometry.clampedCameraDistance(ground + (cameraDistance - ground) / scale, compact: compact)
                recognizer.scale = 1
                applyTransform()
            case .ended, .cancelled, .failed:
                isPinching = false
            default: break
            }
        }
        @objc private func tap(_ recognizer: UITapGestureRecognizer) {
            guard let view else { return }
            let point = recognizer.location(in: view)
            var nearest: (CGFloat, PlaceCollection)?
            for (entity, place) in markers {
                let world = entity.position(relativeTo: nil)
                guard isFacingCamera(world), let projected = view.project(world) else { continue }
                let distance = hypot(point.x - projected.x, point.y - projected.y)
                if distance < 32, nearest == nil || distance < nearest!.0 { nearest = (distance, place) }
            }
            if let place = nearest?.1 { stop(); selection?(place); Haptics.selectionChanged() }
        }
        @objc private func photoMarkerTapped(_ sender: GlobePhotoMarker) {
            guard let place = sender.place else { return }
            stop(); selection?(place); Haptics.selectionChanged()
        }
        func updatePhotoMarkers() {
            guard let view, let api, let pipeline, active, view.bounds.width > 0 else {
                photoMarkers.forEach { $0.isHidden = true }; host?.accessibilityElements = []; return
            }
            var placed: [CGRect] = []
            var visible: [(CGPoint, PlaceCollection)] = []
            let metricsContext = "\(view.traitCollection.preferredContentSizeCategory.rawValue)|\(Int(view.bounds.width))"
            if metricsContext != markerMetricsContext { markerSizes.removeAll(); markerMetricsContext = metricsContext }
            let ordered = markers.sorted { left, right in
                if (left.1.id == focusedPlaceID) != (right.1.id == focusedPlaceID) { return left.1.id == focusedPlaceID }
                return left.1.assetIDs.count > right.1.assetIDs.count
            }
            for (entity, place) in ordered {
                let world = entity.position(relativeTo: nil)
                guard isFacingCamera(world, margin: 0.05), let point = view.project(world) else { continue }
                let key = place.id
                let size = markerSizes[key] ?? GlobePhotoMarker.fittingSize(title: place.title, count: place.assetIDs.count, traits: view.traitCollection, availableWidth: view.bounds.width - 12)
                markerSizes[key] = size
                let frame = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
                guard view.bounds.insetBy(dx: 6, dy: 6).contains(frame), !placed.contains(where: { $0.insetBy(dx: -8, dy: -10).intersects(frame) }) else { continue }
                placed.append(frame); visible.append((point, place))
                if placed.count == photoMarkers.count { break }
            }
            for (index, marker) in photoMarkers.enumerated() {
                guard index < visible.count else { marker.isHidden = true; marker.cancelImage(); continue }
                marker.frame = placed[index]; marker.isHidden = false
                marker.isSelected = visible[index].1.id == focusedPlaceID
                marker.configure(place: visible[index].1, api: api, pipeline: pipeline)
            }
            host?.accessibilityElements = photoMarkers.filter { !$0.isHidden }
        }
        /// On the near side of Earth, away from its rim, and ahead of the camera, which looks down -z.
        private func isFacingCamera(_ world: SIMD3<Float>, margin: Float = 0) -> Bool {
            world.z < camera.position.z
                && simd_dot(simd_normalize(world), simd_normalize(camera.position - world)) > margin
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Dragging from a photo pin should rotate the Earth, not trap the
            // finger in that button. Recognition cancels its pending button tap.
            if gestureRecognizer is UIPanGestureRecognizer || gestureRecognizer is UIPinchGestureRecognizer { return true }
            var current = touch.view
            while let candidate = current, candidate !== host {
                if candidate is UIControl { return false }
                current = candidate.superview
            }
            return true
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        private func startInertia() {
            stop(keepVelocity: true)
            startDisplayLink()
        }
        private func startDisplayLink() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = .init(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common); displayLink = link
        }
        @objc private func tick(_ link: CADisplayLink) {
            guard active && !reduceMotion else { stop(); return }
            let elapsed = Float(lastTimestamp == 0 ? 1 / 60 : min(link.timestamp - lastTimestamp, 0.05))
            lastTimestamp = link.timestamp
            if var transition = focusTransition {
                transition.elapsed = min(0.4, transition.elapsed + elapsed)
                let progress = transition.elapsed / 0.4
                let eased = 1 - pow(1 - progress, 3)
                setPose(transition.from + (transition.to - transition.from) * eased)
                focusTransition = transition.elapsed >= 0.4 ? nil : transition
                if focusTransition == nil { setPose(transition.to) }
            }
            let gain = GlobeGeometry.dragRadiansPerPoint(cameraDistance: cameraDistance, viewportHeight: Float(view?.bounds.height ?? 1), compact: compact)
            yaw += velocity.x * gain * elapsed
            let nextPitch = pitch + velocity.y * gain * elapsed
            pitch = GlobeGeometry.clampPitch(nextPitch, compact: compact)
            if pitch != nextPitch { velocity.y = 0 }
            if focusTransition == nil { velocity *= pow(0.025, elapsed) }
            applyTransform()
            if focusTransition == nil && simd_length(velocity) < 6 { stop() }
        }
        func stop(keepVelocity: Bool = false) {
            displayLink?.invalidate(); displayLink = nil; lastTimestamp = 0
            focusTransition = nil
            if !keepVelocity { velocity = .zero }
        }
        private static func oceanMesh() throws -> MeshResource {
            let rows = 128, columns = 256
            var positions: [SIMD3<Float>] = [], coordinates: [SIMD2<Float>] = [], indices: [UInt32] = []
            for row in 0...rows {
                let v = Float(row) / Float(rows)
                for column in 0...columns {
                    let u = Float(column) / Float(columns)
                    let lat = .pi / 2 - v * .pi, lon = u * 2 * .pi - .pi
                    positions.append(SIMD3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon)) * GlobeStyle.oceanRadius)
                    coordinates.append(GlobeGeometry.textureCoordinate(latitude: lat, longitude: lon))
                }
            }
            for row in 0..<rows { for column in 0..<columns {
                let a = UInt32(row * (columns + 1) + column), b = a + 1, c = a + UInt32(columns + 1), d = c + 1
                indices.append(contentsOf: [a, c, b, b, c, d])
            } }
            var descriptor = MeshDescriptor(name: "Ocean")
            descriptor.positions = MeshBuffer(positions); descriptor.normals = MeshBuffer(positions)
            descriptor.textureCoordinates = MeshBuffer(coordinates); descriptor.primitives = .triangles(indices)
            return try MeshResource.generate(from: [descriptor])
        }
    }
}

/// The night palette of the design: deep indigo sea, muted violet land, warm lights, blue air.
@MainActor enum GlobeStyle {
    nonisolated static let oceanRadius: Float = 0.9985
    nonisolated static let lakeRadius: Float = 1.0001
    nonisolated static let roadRadius: Float = 1.00012
    nonisolated static let lightRadius: Float = 1.0002
    static let ocean = UIColor(red: 0.075, green: 0.082, blue: 0.2, alpha: 1)
    static let land = UIColor(red: 0.34, green: 0.32, blue: 0.5, alpha: 1)
    static let road = UIColor(red: 1, green: 0.8, blue: 0.55, alpha: 1)
    static let string = UIColor(red: 0.66, green: 0.86, blue: 1, alpha: 1)

    /// Lit by a cool moon from the upper left, so the Earth reads as a sphere, with a faint glow
    /// of its own so the far side never goes black.
    /// Matte: a moonlit sheen on the sea read as a gray smudge.
    static func lit(_ color: UIColor, glow: Float) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.roughness = .init(floatLiteral: 0.9)
        material.metallic = .init(floatLiteral: 0)
        material.specular = .init(floatLiteral: 0.1)
        material.emissiveColor = .init(color: color)
        material.emissiveIntensity = glow
        return material
    }

    static func sea() -> PhysicallyBasedMaterial { lit(ocean, glow: 0.14) }

    static func hazeMaterial() -> UnlitMaterial? {
        transparent(GlobeArt.hazeProfile())
    }

    static func lightMaterial() -> UnlitMaterial? {
        transparent(GlobeArt.glowAtlas())
    }

    static func rimMaterial() -> UnlitMaterial? {
        transparent(GlobeArt.rimProfile())
    }

    static func lineMaterial(_ color: UIColor, opacity: Float) -> UnlitMaterial? {
        transparent(GlobeArt.lineProfile(), tint: color, opacity: opacity)
    }

    private static func transparent(_ image: CGImage?, tint: UIColor = .white, opacity: Float = 1) -> UnlitMaterial? {
        guard let image, let texture = try? TextureResource(image: image, options: .init(semantic: .color)) else { return nil }
        var material = UnlitMaterial()
        material.color = .init(tint: tint, texture: .init(texture))
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        material.faceCulling = .none
        material.writesDepth = false
        return material
    }
}

/// Natural Earth land and lakes (public domain), cut into one-degree cells so the flat
/// triangles follow the sphere. Geometry, unlike a photo texture, stays sharp at every zoom.
@MainActor enum GlobeLand {
    struct Meshes { let land: [MeshResource]; let lakes: MeshResource?; let roads: GlobeRoads? }
    struct Earth: Sendable { let layers: [Layer]; let roads: [[SIMD3<Float>]] }
    struct Layer: Sendable { let positions: [SIMD3<Float>]; let indices: [UInt32] }
    private static var meshes: Meshes?
    private static var loading: Task<Meshes?, Never>?

    static var loaded: Meshes? { meshes }

    /// One shared build; a caller that goes away does not cancel it for the others. Everything
    /// runs off the main thread, in pieces, so a first cold build never freezes the shelves.
    static func prepare() async -> Meshes? {
        if let meshes { return meshes }
        let task = loading ?? Task.detached(priority: .utility) { () -> Meshes? in
            guard let earth = GlobeLand.decode(), let land = earth.layers.first else { return nil }
            let layers = earth.layers
            var pieces: [MeshResource] = []
            for (index, piece) in GlobeLand.pieces(of: land).enumerated() {
                if let mesh = await GlobeLand.mesh(piece, name: "Land \(index)") { pieces.append(mesh) }
                await Task.yield()
            }
            guard !pieces.isEmpty else { return nil }
            return Meshes(land: pieces, lakes: layers.count > 1 ? await GlobeLand.mesh(layers[1], name: "Lakes") : nil,
                          roads: earth.roads.isEmpty ? nil : GlobeRoads(earth.roads))
        }
        loading = task
        let result = await task.value
        if let result { meshes = result } else { loading = nil }
        return result
    }

    nonisolated private static func mesh(_ layer: Layer, name: String) async -> MeshResource? {
        guard !layer.indices.isEmpty else { return nil }
        var descriptor = MeshDescriptor(name: name)
        descriptor.positions = MeshBuffer(layer.positions)
        // On a sphere the normal is the direction from the center, which shades it smoothly.
        descriptor.normals = MeshBuffer(layer.positions.map(simd_normalize))
        descriptor.primitives = .triangles(layer.indices)
        return try? await MeshResource(from: [descriptor])
    }

    /// Splits the land into pieces of about 24,000 triangles, each with only its own vertices.
    /// Cells are stored band by band, so a piece is a compact stretch of the Earth.
    nonisolated static func pieces(of layer: Layer, triangles: Int = 24_000) -> [Layer] {
        var result: [Layer] = []
        var remap = [UInt32](repeating: .max, count: layer.positions.count)
        var start = 0
        while start < layer.indices.count {
            let end = min(layer.indices.count, start + triangles * 3)
            var positions: [SIMD3<Float>] = [], indices: [UInt32] = []
            indices.reserveCapacity(end - start)
            for index in layer.indices[start..<end] {
                if remap[Int(index)] == .max {
                    remap[Int(index)] = UInt32(positions.count)
                    positions.append(layer.positions[Int(index)])
                }
                indices.append(remap[Int(index)])
            }
            for index in layer.indices[start..<end] { remap[Int(index)] = .max }
            result.append(Layer(positions: positions, indices: indices))
            start = end
        }
        return result
    }

    /// `EarthLand` is raw DEFLATE of: "ILYE", UInt32 version, then for land and lakes a vertex
    /// count, an index count, longitude/latitude pairs in radians and triangle indices. Version 2
    /// adds major highways: a line count, a point count, each line's first point, and the points.
    nonisolated static func decode(_ asset: Data? = NSDataAsset(name: "EarthLand")?.data) -> Earth? {
        guard let asset, let raw = try? (asset as NSData).decompressed(using: .zlib) as Data,
              raw.count >= 8, raw.prefix(4) == Data("ILYE".utf8) else { return nil }
        return raw.withUnsafeBytes { bytes -> Earth? in
            let version = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            func point(_ at: Int) -> SIMD3<Float> {
                let longitude = Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: at, as: UInt32.self)))
                let latitude = Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: at + 4, as: UInt32.self)))
                return SIMD3(cos(latitude) * sin(longitude), sin(latitude), cos(latitude) * cos(longitude))
            }
            var offset = 8
            func count() -> Int? {
                guard offset + 4 <= bytes.count else { return nil }
                defer { offset += 4 }
                return Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }
            var layers: [Layer] = []
            for radius: Float in [1, GlobeStyle.lakeRadius] {
                guard let vertices = count(), let indices = count(),
                      offset + vertices * 8 + indices * 4 <= bytes.count else { return nil }
                var positions: [SIMD3<Float>] = []
                positions.reserveCapacity(vertices)
                for index in 0..<vertices { positions.append(point(offset + index * 8) * radius) }
                offset += vertices * 8
                var triangles: [UInt32] = []
                triangles.reserveCapacity(indices)
                for index in 0..<indices {
                    let value = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + index * 4, as: UInt32.self))
                    guard Int(value) < vertices else { return nil }
                    triangles.append(value)
                }
                offset += indices * 4
                layers.append(Layer(positions: positions, indices: triangles))
            }
            var roads: [[SIMD3<Float>]] = []
            if version >= 2 {
                guard let lines = count(), let points = count(),
                      offset + lines * 4 + points * 8 <= bytes.count else { return nil }
                let starts = (0..<lines).map { Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + $0 * 4, as: UInt32.self))) }
                offset += lines * 4
                for (index, start) in starts.enumerated() {
                    let end = index + 1 < starts.count ? starts[index + 1] : points
                    guard start <= end, end <= points else { return nil }
                    roads.append((start..<end).map { point(offset + $0 * 8) })
                }
            }
            return Earth(layers: layers, roads: roads)
        }
    }
}

/// Where photos were taken, grouped once for every zoom step so zooming only redraws them.
/// More photos make a brighter, larger light; zooming in splits a light into its separate spots.
final class GlobePhotoLights: Sendable {
    struct Cluster: Sendable, Equatable {
        let center: SIMD3<Float>
        let count: Int
    }
    /// Half-octaves of camera altitude above the ground, from about 20 km to beyond the whole Earth.
    static let levels = -17...4
    let total: Int
    private let groups: [[Cluster]]

    init(locations: [SIMD3<Float>]) {
        total = locations.count
        groups = Self.levels.map { Self.cluster(locations, cell: Self.cell(level: $0)) }
    }

    convenience init(markers: [MapMarker]) {
        self.init(locations: markers.compactMap { marker in
            guard marker.lat.isFinite, marker.lon.isFinite, (-90...90).contains(marker.lat), (-180...180).contains(marker.lon) else { return nil }
            return GlobeGeometry.position(latitude: marker.lat, longitude: marker.lon)
        })
    }

    func clusters(level: Int) -> [Cluster] {
        groups[min(max(level, Self.levels.lowerBound), Self.levels.upperBound) - Self.levels.lowerBound]
    }

    /// The ground size, in radians, that one light covers at a zoom step: about 14 points on screen.
    static func cell(level: Int) -> Float { 0.028 * pow(2, Float(level) / 2) }

    static func level(altitude: Float) -> Int {
        min(levels.upperBound, max(levels.lowerBound, Int((2 * log2(max(altitude, 1e-6))).rounded())))
    }

    /// Rows of equal latitude, each split into columns of about the same ground width.
    static func cluster(_ points: [SIMD3<Float>], cell: Float) -> [Cluster] {
        var sums: [SIMD2<Int32>: (sum: SIMD3<Float>, count: Int)] = [:]
        for point in points {
            let latitude = asin(min(1, max(-1, point.y)))
            let row = Int32((latitude / cell).rounded(.down))
            let rowLatitude = (Float(row) + 0.5) * cell
            let columns = max(1, Int32((2 * .pi * max(0, cos(rowLatitude)) / cell).rounded(.down)))
            let longitude = atan2(point.x, point.z)
            let column = min(columns - 1, max(0, Int32(((longitude + .pi) / (2 * .pi) * Float(columns)).rounded(.down))))
            let key = SIMD2(row, column)
            let current = sums[key] ?? (.zero, 0)
            sums[key] = (current.sum + point, current.count + 1)
        }
        return sums.values.map { Cluster(center: simd_normalize($0.sum), count: $0.count) }
    }
}

/// One flat glow per light, lying on the ground like a city seen from orbit.
enum GlobeLightMesh {
    /// The glow atlas holds eight brightness steps side by side.
    static let steps = 8

    static func step(count: Int) -> Int { min(steps - 1, Int(log2(Float(max(1, count))).rounded(.down))) }

    static func make(_ clusters: [GlobePhotoLights.Cluster], cell: Float) async -> MeshResource? {
        guard !clusters.isEmpty else { return nil }
        var positions: [SIMD3<Float>] = [], coordinates: [SIMD2<Float>] = [], indices: [UInt32] = []
        positions.reserveCapacity(clusters.count * 4); coordinates.reserveCapacity(clusters.count * 4); indices.reserveCapacity(clusters.count * 6)
        for cluster in clusters {
            let step = step(count: cluster.count)
            let half = cell * (0.5 + 0.11 * Float(step))
            let normal = cluster.center
            let up: SIMD3<Float> = abs(normal.y) > 0.98 ? [1, 0, 0] : [0, 1, 0]
            let east = simd_normalize(simd_cross(up, normal)), north = simd_cross(normal, east)
            let center = normal * GlobeStyle.lightRadius
            let base = UInt32(positions.count)
            positions += [center - (east + north) * half, center + (east - north) * half, center + (east + north) * half, center - (east - north) * half]
            let left = Float(step) / Float(steps), right = Float(step + 1) / Float(steps)
            coordinates += [[left, 0], [right, 0], [right, 1], [left, 1]]
            indices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        var descriptor = MeshDescriptor(name: "PhotoLights")
        descriptor.positions = MeshBuffer(positions)
        descriptor.textureCoordinates = MeshBuffer(coordinates)
        descriptor.primitives = .triangles(indices)
        return try? await MeshResource(from: [descriptor])
    }
}

/// Textures drawn in code: glows for the photo lights and the atmosphere's rim.
enum GlobeArt {
    /// The rim ring spans these radii, in units of the Earth's silhouette.
    static let rimInner: Float = 0.97
    static let rimOuter: Float = 1.12

    /// Eight glows from dim to bright, each a near-white core in a warm halo.
    static func glowAtlas(cell: Int = 64) -> CGImage? {
        let steps = 8
        return image(width: cell * steps, height: cell) { x, y in
            let step = x / cell
            let strength = 0.78 + 0.22 * Float(step) / Float(steps - 1)
            let dx = (Float(x % cell) + 0.5) / Float(cell) * 2 - 1, dy = (Float(y) + 0.5) / Float(cell) * 2 - 1
            let r = (dx * dx + dy * dy).squareRoot()
            let core = exp(-pow(r / (0.15 + 0.07 * Float(step) / Float(steps - 1)), 2))
            let halo = 0.6 * exp(-pow(r / 0.5, 2))
            let alpha = min(1, (core + halo) * strength) * max(0, 1 - r * r)
            let white = core / max(0.0001, core + halo)
            return (1, 0.74 + 0.24 * white, 0.42 + 0.5 * white, alpha)
        }
    }

    /// The rim's glow across the ring, from its inner to its outer edge: a thin bright line on
    /// the silhouette with a soft haze outside it. Mapped across a ring mesh, it stays crisp at
    /// any size, where a stretched square texture turned blocky.
    static func rimProfile(width: Int = 512) -> CGImage? {
        image(width: width, height: 4) { x, _ in
            let r = rimInner + (rimOuter - rimInner) * (Float(x) + 0.5) / Float(width)
            guard r > 1 else { return (0, 0, 0, 0) }
            let alpha = 0.6 * exp(-pow((r - 1) / 0.012, 2)) + 0.18 * exp(-pow((r - 1) / 0.05, 2))
            return (0.42, 0.66, 1, min(1, alpha))
        }
    }

    /// The haze across its disc, from the middle to the silhouette.
    static func hazeProfile(width: Int = 256) -> CGImage? {
        image(width: width, height: 4) { x, _ in
            let r = (Float(x) + 0.5) / Float(width)
            return (0.45, 0.65, 1, 0.42 * pow(r, 7))
        }
    }

    /// The cross-section of a soft, thin line.
    static func lineProfile(width: Int = 64) -> CGImage? {
        image(width: width, height: 4) { x, _ in
            let u = (Float(x) + 0.5) / Float(width) * 2 - 1
            return (1, 1, 1, exp(-pow(u / 0.45, 2)) * max(0, 1 - u * u))
        }
    }

    private static func image(width: Int, height: Int, pixel: (Int, Int) -> (Float, Float, Float, Float)) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = pixel(x, y)
                let i = (y * width + x) * 4
                bytes[i] = UInt8(max(0, min(255, r * a * 255)))
                bytes[i + 1] = UInt8(max(0, min(255, g * a * 255)))
                bytes[i + 2] = UInt8(max(0, min(255, b * a * 255)))
                bytes[i + 3] = UInt8(max(0, min(255, a * 255)))
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}


/// UIKit owns the interactive surface; RealityKit only renders the Earth.
@MainActor private final class GlobeHostView: UIView {
    let renderer = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
    let markerOverlay = GlobeMarkerOverlay()
    var onLayout: (() -> Void)?

    init() {
        super.init(frame: .zero)
        isOpaque = false
        isAccessibilityElement = false
        accessibilityElements = []
        renderer.isUserInteractionEnabled = false
        renderer.isAccessibilityElement = false
        renderer.accessibilityElementsHidden = true
        markerOverlay.isAccessibilityElement = false
        addSubview(renderer)
        addSubview(markerOverlay)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Render at the screen's full resolution; a smaller drawable makes coastlines jagged.
        let scale = window?.screen.scale ?? traitCollection.displayScale
        if renderer.contentScaleFactor != scale { renderer.contentScaleFactor = scale }
        renderer.frame = bounds
        markerOverlay.frame = bounds
        onLayout?()
    }
}

/// Empty parts of the overlay pass touches to the host's globe gestures.
@MainActor private final class GlobeMarkerOverlay: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let target = super.hitTest(point, with: event)
        return target === self ? nil : target
    }
}

@MainActor private final class GlobePhotoMarker: UIControl {
    private let backdrop = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let thumbnail = UIImageView()
    private let nameLabel = UILabel()
    private let countLabel = UILabel()
    private var imageTask: Task<Void, Never>?
    private var imageID: String?
    var place: PlaceCollection?
    override var isSelected: Bool {
        didSet { thumbnail.layer.borderColor = (isSelected ? UIColor.systemCyan : UIColor.white.withAlphaComponent(0.9)).cgColor }
    }

    init() {
        super.init(frame: .zero)
        isAccessibilityElement = true; accessibilityTraits = .button
        backdrop.isUserInteractionEnabled = false
        backdrop.layer.cornerRadius = 27; backdrop.clipsToBounds = true
        addSubview(backdrop)
        thumbnail.contentMode = .scaleAspectFill; thumbnail.clipsToBounds = true
        thumbnail.layer.borderWidth = 1.5; thumbnail.layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
        thumbnail.backgroundColor = .secondarySystemFill
        nameLabel.font = .preferredFont(forTextStyle: .caption1); nameLabel.textColor = .label
        countLabel.font = .preferredFont(forTextStyle: .caption2); countLabel.textColor = .secondaryLabel
        nameLabel.adjustsFontForContentSizeCategory = true; countLabel.adjustsFontForContentSizeCategory = true
        nameLabel.lineBreakMode = .byTruncatingTail
        for view in [thumbnail, nameLabel, countLabel] { view.isUserInteractionEnabled = false; addSubview(view) }
        layer.shadowColor = UIColor.black.cgColor; layer.shadowOpacity = 0.18; layer.shadowRadius = 8; layer.shadowOffset = CGSize(width: 0, height: 4)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layoutSubviews() {
        super.layoutSubviews()
        nameLabel.numberOfLines = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 2 : 1
        let edge = min(52, bounds.height - 18), textX = edge + 18
        thumbnail.frame = CGRect(x: 9, y: (bounds.height - edge) / 2, width: edge, height: edge)
        thumbnail.layer.cornerRadius = edge / 2
        let labelHeight = min(bounds.height, max(28, ceil(nameLabel.font.lineHeight * CGFloat(nameLabel.numberOfLines) + 10)))
        let labelY = (bounds.height - labelHeight) / 2
        backdrop.frame = CGRect(x: edge + 5, y: labelY, width: bounds.width - edge - 5, height: labelHeight)
        backdrop.layer.cornerRadius = labelHeight / 2
        let countWidth = min(bounds.width * 0.24, ceil(countLabel.sizeThatFits(bounds.size).width))
        countLabel.frame = CGRect(x: bounds.width - countWidth - 10, y: labelY, width: countWidth, height: labelHeight)
        nameLabel.frame = CGRect(x: textX, y: labelY, width: max(0, countLabel.frame.minX - textX - 6), height: labelHeight)
    }
    static func fittingSize(title: String, count itemCount: Int, traits: UITraitCollection, availableWidth: CGFloat) -> CGSize {
        let name = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traits)
        let count = UIFont.preferredFont(forTextStyle: .caption2, compatibleWith: traits)
        let lines: CGFloat = traits.preferredContentSizeCategory.isAccessibilityCategory ? 2 : 1
        let height = max(54, ceil(name.lineHeight * lines + count.lineHeight + 18))
        let textWidth = (title as NSString).size(withAttributes: [.font: name]).width
        let countWidth = (itemCount.formatted() as NSString).size(withAttributes: [.font: count]).width
        let width = min(availableWidth, min(lines == 2 ? 340 : 240, max(132, ceil(textWidth + countWidth) + min(52, height - 18) + 46)))
        return .init(width: width, height: height)
    }
    /// The marker's thumbnail comes through the thumbnail service, which keeps it in memory with
    /// the grid's: a photo seen before draws in this frame, and the library names the photo and
    /// its revision, so a new one needs no asset round trip (T6).
    func configure(place: PlaceCollection, api: APIClient, pipeline: MediaPipeline) {
        self.place = place; nameLabel.text = place.title; countLabel.text = place.assetIDs.count.formatted()
        accessibilityLabel = "\(place.title), \(place.assetIDs.count) items"
        guard let id = place.assetIDs.first, id != imageID else { return }
        imageTask?.cancel(); imageID = id
        thumbnail.image = pipeline.latestImage(assetID: id, size: .thumbnail)?.uiImage
        guard thumbnail.image == nil else { return }
        let pixels = max(128, Int(Self.thumbnailEdge * traitCollection.displayScale))
        imageTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
                let image = try await pipeline.thumbnail(assetID: id, shortSide: pixels, fetch: { try await api.asset(id: $0) })
                try Task.checkCancellation()
                guard let self, self.imageID == id else { return }
                self.thumbnail.image = image.uiImage
            } catch { }
        }
    }
    func cancelImage() { imageTask?.cancel(); imageTask = nil; imageID = nil }
    /// The round thumbnail's largest edge, in points.
    private static let thumbnailEdge: CGFloat = 52
}
