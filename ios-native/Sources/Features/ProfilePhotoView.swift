import SwiftUI
import PhotosUI
import ImageIO

struct ProfilePhotoSettingsView: View {
    let api: APIClient
    @State private var avatar: UIImage?
    @State private var selected: PhotosPickerItem?
    @State private var chosen: UIImage?
    @State private var crop = false
    @State private var loading = false
    @State private var failure: FeatureFailure?
    @State private var confirmRemove = false
    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    Group {
                        if let avatar { Image(uiImage: avatar).resizable().scaledToFill() }
                        else { Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary) }
                    }.frame(width: 120, height: 120).clipShape(Circle()).padding(16).accessibilityLabel("Your profile photo")
                    Spacer()
                }
                PhotosPicker(selection: $selected, matching: .images) { Label("Choose from Photos", systemImage: "photo") }
                if avatar != nil { Button("Remove profile photo", role: .destructive) { confirmRemove = true } }
            } footer: { Text("You can also set a photo from your Ilyich library using the photo viewer’s menu. Your profile photo is visible to other people on your server.") }
            if loading { ProgressView() }
        }.navigationTitle("Profile photo").disabled(loading)
        .task { await loadAvatar() }
        .task(id: selected) {
            guard let selected else { return }
            loading = true; defer { loading = false }
            do {
                guard let data = try await selected.loadTransferable(type: Data.self) else { throw APIError.invalidResponse("Photos could not provide this image.") }
                let prepared = try await Task.detached(priority: .userInitiated) { try ProfileImageDecoder.decode(data, pixels: 2200) }.value
                try Task.checkCancellation(); chosen = prepared.uiImage; crop = true
            } catch is CancellationError { } catch { failure = .init(error) }
        }
        .sheet(isPresented: $crop, onDismiss: { selected = nil; chosen = nil }) {
            if let chosen { ProfilePhotoCropView(api: api, sourceImage: chosen, onSaved: { Task { await loadAvatar() } }) }
        }
        .confirmationDialog("Remove your profile photo?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove profile photo", role: .destructive) {
                Task {
                    loading = true; defer { loading = false }
                    do { try await api.requestVoid(.delete, path: "users/profile-image"); avatar = nil } catch { failure = .init(error) }
                }
            }
        }
        .alert("Couldn’t update profile photo", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK", role: .cancel) { } } message: { Text(failure?.message ?? "") }
    }
    private func loadAvatar() async {
        guard let id = api.userID else { return }
        do {
            let data = try await api.profileImage(userID: id)
            let image = try await Task.detached(priority: .userInitiated) { try ProfileImageDecoder.decode(data, pixels: 400) }.value
            try Task.checkCancellation(); avatar = image.uiImage
        } catch APIError.notFound { avatar = nil }
        catch is CancellationError { } catch { failure = .init(error) }
    }
}

struct ProfilePhotoCropView: View {
    let api: APIClient
    var pipeline: MediaPipeline? = nil
    var asset: Asset? = nil
    var sourceImage: UIImage? = nil
    var onSaved: () -> Void = { }
    @Environment(\.dismiss) private var dismiss
    @State private var controller = ProfileCropController()
    @State private var image: UIImage?
    @State private var loading = true
    @State private var saving = false
    @State private var failure: FeatureFailure?
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                if let image {
                    GeometryReader { geometry in
                        let side = min(geometry.size.width, geometry.size.height)
                        ZStack {
                            ProfileCropCanvas(image: image, controller: controller)
                            Path { path in
                                path.addRect(CGRect(x: 0, y: 0, width: side, height: side))
                                path.addEllipse(in: CGRect(x: 0, y: 0, width: side, height: side))
                            }.fill(.black.opacity(0.55), style: FillStyle(eoFill: true)).allowsHitTesting(false)
                            Circle().stroke(.white.opacity(0.9), lineWidth: 1).allowsHitTesting(false)
                        }.frame(width: side, height: side).clipped().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }.aspectRatio(1, contentMode: .fit).padding(.horizontal, 20)
                    Text("Move and zoom the photo to fit the circle.").foregroundStyle(.secondary)
                    HStack(spacing: 20) {
                        Button("Zoom out", systemImage: "minus.magnifyingglass") { controller.zoom(0.8) }.buttonStyle(.glass)
                        Button("Zoom in", systemImage: "plus.magnifyingglass") { controller.zoom(1.25) }.buttonStyle(.glass)
                    }
                } else if loading { ProgressView("Loading photo…") }
                else { ContentUnavailableView("Photo unavailable", systemImage: "photo.badge.exclamationmark", description: Text(failure?.message ?? "Choose another photo.")) }
                Spacer()
                Text("Your profile photo is visible to people on this server.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 24)
                if saving { ProgressView("Saving profile photo…") }
            }.padding(.bottom, 20).navigationTitle("Crop profile photo").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(image == nil || saving) }
            }.interactiveDismissDisabled(saving).disabled(saving)
        }.task {
            defer { loading = false }
            do {
                if let sourceImage { image = sourceImage }
                else if let pipeline, let asset {
                    let prepared = try await pipeline.image(for: asset, size: .preview, pixelSize: 2200)
                    try Task.checkCancellation(); image = prepared.uiImage
                } else { throw APIError.invalidResponse("Choose a photo to crop.") }
            } catch is CancellationError { } catch { failure = .init(error) }
        }
        .alert("Couldn’t save profile photo", isPresented: Binding(get: { failure != nil && image != nil }, set: { if !$0 { failure = nil } })) { Button("OK", role: .cancel) { } } message: { Text(failure?.message ?? "") }
    }
    private func save() async {
        saving = true; defer { saving = false }
        do { let data = try controller.jpeg(); try await api.uploadProfileImage(jpeg: data); onSaved(); dismiss() }
        catch { failure = .init(error) }
    }
}

private enum ProfileImageDecoder {
    static func decode(_ data: Data, pixels: Int) throws -> PreparedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels, kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw APIError.invalidResponse("This photo could not be opened.") }
        return PreparedImage(cgImage: image)
    }
}

@MainActor private final class ProfileCropController {
    weak var view: ProfileCropScrollView?
    func zoom(_ factor: CGFloat) {
        guard let view else { return }
        view.setZoomScale(min(view.maximumZoomScale, max(view.minimumZoomScale, view.zoomScale * factor)), animated: !UIAccessibility.isReduceMotionEnabled)
    }
    func jpeg() throws -> Data {
        guard let view, let image = view.imageView.image, view.bounds.width > 0, image.size.width > 0 else { throw APIError.invalidResponse("Wait for the photo to load before saving.") }
        let crop = view.convert(view.bounds, to: view.imageView).intersection(view.imageView.bounds)
        guard crop.width > 0, crop.height > 0 else { throw APIError.invalidResponse("The selected crop is empty.") }
        let side: CGFloat = 1024, scale = side / crop.width
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let output = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            UIColor.black.setFill(); context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            image.draw(in: CGRect(x: -crop.minX * scale, y: -crop.minY * scale, width: image.size.width * scale, height: image.size.height * scale))
        }
        guard let data = output.jpegData(compressionQuality: 0.9) else { throw APIError.invalidResponse("The profile photo could not be prepared.") }
        return data
    }
}

private struct ProfileCropCanvas: UIViewRepresentable {
    let image: UIImage
    let controller: ProfileCropController
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> ProfileCropScrollView {
        let view = ProfileCropScrollView(); view.imageView.image = image; view.delegate = context.coordinator
        controller.view = view; return view
    }
    func updateUIView(_ view: ProfileCropScrollView, context: Context) { }
    @MainActor final class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? ProfileCropScrollView)?.imageView }
    }
}

@MainActor private final class ProfileCropScrollView: UIScrollView {
    let imageView = UIImageView()
    private var lastSize = CGSize.zero
    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(imageView); showsVerticalScrollIndicator = false; showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never; bounces = false; bouncesZoom = false
        isAccessibilityElement = true; accessibilityLabel = "Profile photo crop"
        accessibilityHint = "Drag to position the photo. Pinch or use the zoom buttons to change its size."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastSize, bounds.width > 0, bounds.height > 0, let image = imageView.image, image.size.width > 0, image.size.height > 0 else { return }
        lastSize = bounds.size; zoomScale = 1; imageView.frame = CGRect(origin: .zero, size: image.size)
        minimumZoomScale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        maximumZoomScale = minimumZoomScale * 5; zoomScale = minimumZoomScale
        contentSize = CGSize(width: image.size.width * zoomScale, height: image.size.height * zoomScale)
        contentOffset = CGPoint(x: max(0, (contentSize.width - bounds.width) / 2), y: max(0, (contentSize.height - bounds.height) / 2))
    }
}
