import SwiftUI

@MainActor
struct PhotoEditor: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let asset: Asset
    @Environment(\.mutations) private var mutations
    @State private var image: UIImage?
    @State private var dimensions: PixelDimensions?
    @State private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var transform = PhotoTransform()
    @State private var initialCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var initialTransform = PhotoTransform()
    @State private var mode = EditorMode.crop
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    @State private var discard = false
    @State private var previewPending = false
    @Environment(\.dismiss) private var dismiss
    private enum EditorMode: String, CaseIterable { case crop = "Crop", transform = "Rotate & flip" }
    private var dirty: Bool { crop != initialCrop || transform != initialTransform }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let image {
                    GeometryReader { geometry in
                        if mode == .crop {
                            CropCanvas(image: image, crop: $crop)
                        } else {
                            TransformedCropPreview(image: image, crop: crop, transform: transform)
                                .frame(width: geometry.size.width, height: geometry.size.height)
                        }
                    }.padding(.horizontal, 12)
                    Picker("Edit tool", selection: $mode) { ForEach(EditorMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).padding(.horizontal, 20)
                    if mode == .crop { cropControls }
                    else { transformControls }
                    Text(asset.isDeveloped ? "Edits apply to the Lightroom-developed image." : "Your original file is kept.")
                        .font(.caption).foregroundStyle(.secondary).padding(.bottom, 12)
                } else if loading { ProgressView("Opening editor").frame(maxHeight: .infinity) }
                else { ContentUnavailableView("Editor unavailable", systemImage: "crop", description: Text(error ?? "The base image could not load.")) }
                if saving { ProgressView("Saving and preparing preview…").padding(.bottom, 12) }
            }
            .background(.black).foregroundStyle(.white)
            .navigationTitle("Edit photo").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if dirty { discard = true } else { dismiss() } }.disabled(saving) }
                ToolbarItem(placement: .topBarTrailing) { Button("Reset") { crop = CGRect(x: 0, y: 0, width: 1, height: 1); transform = .init() }.disabled(loading || saving) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.bold().disabled(loading || saving || !dirty).requiresWriteAccess() }
            }
            .interactiveDismissDisabled(dirty || saving)
            .task { await load() }
            .confirmationDialog("Discard your changes?", isPresented: $discard, titleVisibility: .visible) { Button("Discard changes", role: .destructive) { dismiss() } }
            .alert("Couldn’t edit photo", isPresented: Binding(get: { error != nil && image != nil }, set: { if !$0 { error = nil } })) { Button("OK") { } } message: { Text(error ?? "") }
            .alert("Edits saved", isPresented: $previewPending) { Button("Done") { dismiss() } } message: { Text("The server is still preparing the preview. It will appear when processing finishes.") }
        }.preferredColorScheme(.dark)
    }

    private var cropControls: some View {
        HStack(spacing: 14) {
            Menu("Ratio", systemImage: "aspectratio") {
                Button("Original") { crop = CGRect(x: 0, y: 0, width: 1, height: 1) }
                Button("Square") { setRatio(1) }
                Button("4:3") { setRatio(4.0 / 3) }
                Button("3:4") { setRatio(3.0 / 4) }
                Button("3:2") { setRatio(3.0 / 2) }
                Button("2:3") { setRatio(2.0 / 3) }
                Button("16:9") { setRatio(16.0 / 9) }
                Button("9:16") { setRatio(9.0 / 16) }
            }.buttonStyle(.glass)
            Spacer()
            if let dimensions, let pixelCrop = try? PixelCrop.normalized(x: crop.minX, y: crop.minY, width: crop.width, height: crop.height, in: dimensions) {
                Text("\(pixelCrop.width) × \(pixelCrop.height)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 24).frame(minHeight: 44)
    }
    private var transformControls: some View {
        HStack(spacing: 30) {
            Button("Left", systemImage: "rotate.left") { transform = PhotoTransform(edits: [.rotate(90)]) * transform }.buttonStyle(.glass).accessibilityLabel("Rotate left")
            Button("Right", systemImage: "rotate.right") { transform = PhotoTransform(edits: [.rotate(270)]) * transform }.buttonStyle(.glass).accessibilityLabel("Rotate right")
            Menu("Flip", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                Button("Left to right") { transform = PhotoTransform(edits: [.mirror(.vertical)]) * transform }
                Button("Top to bottom") { transform = PhotoTransform(edits: [.mirror(.horizontal)]) * transform }
            }.buttonStyle(.glass)
        }.frame(minHeight: 44)
    }
    private func setRatio(_ ratio: Double) {
        guard let dimensions else { return }
        let normalizedRatio = ratio * Double(dimensions.height) / Double(dimensions.width)
        let width = min(1, normalizedRatio), height = min(1, 1 / normalizedRatio)
        crop = CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }
    private func load() async {
        loading = true; defer { loading = false }
        do {
            let existing = try await api.assetEdits(id: asset.id)
            let base = try existing.base(of: asset)
            guard base.width > 0, base.height > 0 else { throw APIError.invalidResponse("The photo has no dimensions for cropping.") }
            dimensions = base
            if let cropEdit = existing.edits.compactMap({ edit -> PixelCrop? in if case .crop(let value) = edit { return value }; return nil }).first {
                crop = CGRect(x: Double(cropEdit.x) / Double(base.width), y: Double(cropEdit.y) / Double(base.height),
                              width: Double(cropEdit.width) / Double(base.width), height: Double(cropEdit.height) / Double(base.height))
            }
            transform = .init(edits: existing.edits); initialCrop = crop; initialTransform = transform
            let prepared = try await pipeline.image(for: asset, size: .preview, pixelSize: 2000, edited: false)
            try Task.checkCancellation(); image = prepared.uiImage
        } catch is CancellationError { } catch { self.error = error.localizedDescription }
    }
    /// Saves the edits through the account's mutations, which wait for the server's new preview
    /// (a new media revision, not a made-up cache-buster, proves it exists) and show it in the
    /// viewer and the feed even if the editor has closed by then.
    private func save() async {
        guard let dimensions else { return }; saving = true; defer { saving = false }
        do {
            guard let mutations else { throw APIError.signedOut }
            let pixels = try PixelCrop.normalized(x: crop.minX, y: crop.minY, width: crop.width, height: crop.height, in: dimensions)
            let full = PixelCrop(x: 0, y: 0, width: dimensions.width, height: dimensions.height)
            let edits: [PhotoEdit] = (pixels == full ? [] : [.crop(pixels)]) + transform.edits
            let result = try await mutations.start(.edits(asset: asset.id, edits), on: [asset]).result
            initialCrop = crop; initialTransform = transform
            if result.fresh[asset.id].map({ $0.cacheRevision != asset.cacheRevision }) == true { dismiss() }
            else { previewPending = true }
        } catch is CancellationError { } catch { self.error = error.localizedDescription }
    }
}

private struct CropCanvas: View {
    let image: UIImage
    @Binding var crop: CGRect
    @State private var dragStart: CGRect?
    var body: some View {
        GeometryReader { geometry in
            let fit = fitRect(image.size, in: geometry.size)
            let selection = CGRect(x: fit.minX + crop.minX * fit.width, y: fit.minY + crop.minY * fit.height, width: crop.width * fit.width, height: crop.height * fit.height)
            ZStack(alignment: .topLeading) {
                Image(uiImage: image).resizable().frame(width: fit.width, height: fit.height).position(x: fit.midX, y: fit.midY)
                Path { path in path.addRect(fit); path.addRect(selection) }.fill(.black.opacity(0.55), style: FillStyle(eoFill: true)).allowsHitTesting(false)
                Rectangle().fill(.clear).contentShape(Rectangle()).frame(width: selection.width, height: selection.height).position(x: selection.midX, y: selection.midY)
                    .gesture(DragGesture().onChanged { value in
                        if dragStart == nil { dragStart = crop }; guard let start = dragStart else { return }
                        crop.origin = CGPoint(x: min(1 - start.width, max(0, start.minX + value.translation.width / fit.width)), y: min(1 - start.height, max(0, start.minY + value.translation.height / fit.height)))
                    }.onEnded { _ in dragStart = nil })
                Path { path in
                    path.addRect(selection)
                    for fraction in [1.0 / 3, 2.0 / 3] {
                        path.move(to: CGPoint(x: selection.minX + selection.width * fraction, y: selection.minY)); path.addLine(to: CGPoint(x: selection.minX + selection.width * fraction, y: selection.maxY))
                        path.move(to: CGPoint(x: selection.minX, y: selection.minY + selection.height * fraction)); path.addLine(to: CGPoint(x: selection.maxX, y: selection.minY + selection.height * fraction))
                    }
                }.stroke(.white.opacity(0.8), lineWidth: 1).allowsHitTesting(false)
                ForEach(0..<4) { corner in
                    Circle().fill(.white).frame(width: 12, height: 12).frame(width: 44, height: 44).contentShape(Rectangle())
                        .position(x: corner % 2 == 0 ? selection.minX : selection.maxX, y: corner < 2 ? selection.minY : selection.maxY)
                        .gesture(DragGesture(coordinateSpace: .named("crop-canvas")).onChanged { value in
                            let x = min(1, max(0, (value.location.x - fit.minX) / fit.width))
                            let y = min(1, max(0, (value.location.y - fit.minY) / fit.height))
                            let left = corner % 2 == 0 ? min(x, crop.maxX - 0.02) : crop.minX
                            let right = corner % 2 == 1 ? max(x, crop.minX + 0.02) : crop.maxX
                            let top = corner < 2 ? min(y, crop.maxY - 0.02) : crop.minY
                            let bottom = corner >= 2 ? max(y, crop.minY + 0.02) : crop.maxY
                            crop = CGRect(x: left, y: top, width: right - left, height: bottom - top)
                        })
                        .accessibilityLabel(["Top left crop corner", "Top right crop corner", "Bottom left crop corner", "Bottom right crop corner"][corner])
                        .accessibilityAdjustableAction { direction in
                            let amount = direction == .increment ? 0.02 : -0.02
                            let inset = crop.insetBy(dx: amount, dy: amount)
                            if inset.width >= 0.04 && inset.height >= 0.04 && CGRect(x: 0, y: 0, width: 1, height: 1).contains(inset) { crop = inset }
                        }
                }
            }.coordinateSpace(name: "crop-canvas")
        }
    }
    private func fitRect(_ size: CGSize, in bounds: CGSize) -> CGRect {
        let factor = min(max(1, bounds.width - 24) / size.width, max(1, bounds.height - 24) / size.height)
        let width = size.width * factor, height = size.height * factor
        return CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }
}

private struct TransformedCropPreview: View {
    let image: UIImage
    let crop: CGRect
    let transform: PhotoTransform
    var body: some View {
        GeometryReader { geometry in
            let width = image.size.width * crop.width, height = image.size.height * crop.height
            let matrix = CGAffineTransform(a: CGFloat(transform.a), b: CGFloat(transform.b), c: CGFloat(transform.c), d: CGFloat(transform.d), tx: 0, ty: 0)
            let bounds = CGRect(x: 0, y: 0, width: width, height: height).applying(matrix)
            let scale = min(geometry.size.width / bounds.width, geometry.size.height / bounds.height)
            let position = CGAffineTransform(a: matrix.a, b: matrix.b, c: matrix.c, d: matrix.d, tx: -bounds.minX * scale, ty: -bounds.minY * scale)
            Image(uiImage: image).resizable()
                .frame(width: image.size.width * scale, height: image.size.height * scale)
                .offset(x: -crop.minX * image.size.width * scale, y: -crop.minY * image.size.height * scale)
                .frame(width: width * scale, height: height * scale, alignment: .topLeading).clipped()
                .transformEffect(position)
                .frame(width: bounds.width * scale, height: bounds.height * scale, alignment: .topLeading)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }.accessibilityLabel("Preview of your edits")
    }
}
