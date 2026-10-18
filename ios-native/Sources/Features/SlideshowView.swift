import SwiftUI

struct SlideshowSettingsView: View {
    @AppStorage("slideshowDuration") private var duration = 5
    @AppStorage("slideshowDirection") private var direction = "forward"
    @AppStorage("slideshowLook") private var look = "blurredBackground"
    @AppStorage("slideshowLoop") private var loop = true
    var body: some View {
        Form {
            Section {
                Picker("Photo duration", selection: $duration) { ForEach([5, 10, 15, 20, 25, 30], id: \.self) { Text("\($0) seconds").tag($0) } }
                Toggle("Repeat slideshow", isOn: $loop)
            } footer: { Text("Videos play to the end before the next item appears.") }
            Section("Order") {
                Picker("Direction", selection: $direction) { Text("Forward").tag("forward"); Text("Backward").tag("backward"); Text("Shuffle").tag("shuffle") }.pickerStyle(.inline)
            }
            Section("Photo display") {
                Picker("Look", selection: $look) { Text("Fit entire photo").tag("contain"); Text("Fill screen").tag("cover"); Text("Blurred background").tag("blurredBackground") }.pickerStyle(.inline)
            }
        }.navigationTitle("Slideshow")
    }
}

struct SlideshowView: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let assets: [Asset]
    var initial: Asset? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("slideshowDuration") private var duration = 5
    @AppStorage("slideshowDirection") private var direction = "forward"
    @AppStorage("slideshowLook") private var look = "blurredBackground"
    @AppStorage("slideshowLoop") private var loop = true
    @State private var order: [Int] = []
    @State private var position = 0
    @State private var playing = true
    @State private var finished = false
    @State private var controls = true
    @State private var settings = false
    @State private var ready = false
    @State private var elapsed: TimeInterval = 0
    @State private var resumedAt: Date?
    @State private var savedIdleTimer = false
    @State private var slideGeneration = UUID()
    private var current: Asset? { order.indices.contains(position) && assets.indices.contains(order[position]) ? assets[order[position]] : nil }
    private var seconds: Double { Double(max(5, min(30, duration))) }
    private var timerID: String { "\(current?.id ?? "")|\(playing)|\(ready)|\(duration)|\(settings)" }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let asset = current {
                if asset.isVideo {
                    AuthenticatedVideo(api: api, assetID: asset.id, active: playing && !settings && scenePhase == .active, onEnded: { if playing { advance() } })
                        .id(asset.id + slideGeneration.uuidString).ignoresSafeArea()
                } else {
                    SlideshowStill(pipeline: pipeline, asset: asset, look: look, onReady: { ready = true }, onFailure: { pause() })
                        .id(asset.id + slideGeneration.uuidString).ignoresSafeArea().onTapGesture { controls.toggle() }
                }
                if controls {
                    VStack {
                        HStack {
                            Button("Close slideshow", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                            Spacer()
                            Text("\(position + 1) of \(order.count)").font(.subheadline.monospacedDigit())
                            Spacer()
                            Button("Slideshow settings", systemImage: "slider.horizontal.3") { pause(); settings = true }.labelStyle(.iconOnly)
                        }.padding().buttonStyle(.glass)
                        Spacer()
                        VStack(spacing: 18) {
                            if !asset.isVideo {
                                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                                    let total = elapsed + (resumedAt.map { max(0, context.date.timeIntervalSince($0)) } ?? 0)
                                    ProgressView(value: min(1, max(0, total / seconds))).tint(.white)
                                }.accessibilityHidden(true)
                            }
                            HStack(spacing: 38) {
                                Button("Previous", systemImage: "backward.end.fill") { retreat() }.labelStyle(.iconOnly).disabled(position == 0 && !loop)
                                Button(playing ? "Pause" : (finished ? "Replay" : "Play"), systemImage: playing ? "pause.fill" : "play.fill") { togglePlayback() }.labelStyle(.iconOnly)
                                Button("Next", systemImage: "forward.end.fill") { advance() }.labelStyle(.iconOnly).disabled(finished && !loop)
                            }.font(.title2).buttonStyle(.glass).padding(.bottom, 12)
                        }.padding(.horizontal, 24)
                    }.foregroundStyle(.white)
                }
            } else { VStack { ContentUnavailableView("No photos to play", systemImage: "play.slash", description: Text("Choose a collection or some photos first.")); Button("Close") { dismiss() } }.foregroundStyle(.white) }
        }.preferredColorScheme(.dark).statusBarHidden(!controls)
        .onAppear {
            savedIdleTimer = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            rebuildOrder(startID: initial?.id)
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = savedIdleTimer }
        .onChange(of: direction) { _, _ in rebuildOrder(startID: current?.id) }
        .onChange(of: scenePhase) { _, phase in if phase != .active { pause() } }
        .task(id: timerID) {
            guard playing, ready, current?.isVideo == false, !settings else { return }
            resumedAt = Date()
            do {
                try await Task.sleep(for: .seconds(max(0, seconds - elapsed)))
                try Task.checkCancellation(); resumedAt = nil; advance()
            } catch { }
        }
        .sheet(isPresented: $settings) { NavigationStack { SlideshowSettingsView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { settings = false } } } } }
    }
    private func rebuildOrder(startID: String?) {
        let currentIndex = startID.flatMap { id in assets.firstIndex { $0.id == id } } ?? (direction == "backward" ? max(0, assets.count - 1) : 0)
        order = Array(assets.indices)
        if direction == "backward" { order.reverse() }
        if direction == "shuffle", !assets.isEmpty { order = [currentIndex] + order.filter { $0 != currentIndex }.shuffled() }
        position = order.firstIndex(of: currentIndex) ?? 0
        elapsed = 0; resumedAt = nil; ready = false; finished = false; slideGeneration = UUID()
    }
    private func pause() {
        if let resumedAt { elapsed += max(0, Date().timeIntervalSince(resumedAt)) }
        resumedAt = nil; playing = false
    }
    private func togglePlayback() {
        if playing { pause() }
        else {
            if finished { position = 0; elapsed = 0; ready = false; finished = false; slideGeneration = UUID() }
            playing = true
        }
    }
    private func advance() {
        guard !order.isEmpty else { return }
        if position + 1 < order.count { position += 1 }
        else if loop { position = 0 }
        else { elapsed = seconds; resumedAt = nil; playing = false; finished = true; controls = true; return }
        elapsed = 0; resumedAt = nil; ready = false; finished = false; slideGeneration = UUID()
    }
    private func retreat() {
        guard !order.isEmpty else { return }
        position = position > 0 ? position - 1 : (loop ? order.count - 1 : 0)
        elapsed = 0; resumedAt = nil; ready = false; finished = false; slideGeneration = UUID()
    }
}

private struct SlideshowStill: View {
    let pipeline: MediaPipeline
    let asset: Asset
    let look: String
    let onReady: () -> Void
    let onFailure: () -> Void
    @State private var image: UIImage?
    @State private var error: String?
    @State private var retry = 0
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image {
                    if look == "blurredBackground" {
                        Image(uiImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).blur(radius: 24).opacity(0.6).clipped()
                    }
                    Image(uiImage: image).resizable().aspectRatio(contentMode: look == "cover" ? .fill : .fit).frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else if let error {
                    VStack(spacing: 16) { Text(error).multilineTextAlignment(.center); Button("Retry") { retry += 1 } }.padding(32).foregroundStyle(.white)
                } else { ProgressView().tint(.white) }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }.task(id: retry) {
            error = nil
            do {
                let prepared = try await pipeline.image(for: asset, size: .preview, pixelSize: 2200)
                try Task.checkCancellation(); image = prepared.uiImage; onReady()
            } catch is CancellationError { } catch { self.error = error.localizedDescription; onFailure() }
        }.accessibilityLabel(asset.displayName)
    }
}
