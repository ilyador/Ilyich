import SwiftUI

private struct AssetFace: Decodable, Identifiable, Sendable {
    let id: String
    let imageWidth: Int
    let imageHeight: Int
    let boundingBoxX1: Int
    let boundingBoxX2: Int
    let boundingBoxY1: Int
    let boundingBoxY2: Int
    /// Milliseconds into a video, for a face found further in than its preview: its box is in
    /// that frame, so the server cuts its image.
    let frameTimestamp: Int?
    let person: Person?
}

struct FaceAssignmentView: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let asset: Asset
    let onChanged: () -> Void
    @State private var faces: [AssetFace] = []
    @State private var image: UIImage?
    @State private var frameFaces: [String: UIImage] = [:]
    @State private var selected: AssetFace?
    @State private var deleteFace: AssetFace?
    @State private var error: String?
    @State private var loading = true
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mutations) private var mutations
    var body: some View {
        List {
            if loading { ProgressView("Loading faces") }
            if !loading && faces.isEmpty { ContentUnavailableView("No faces detected", systemImage: "person.crop.rectangle") }
            ForEach(faces) { face in
                Button { selected = face } label: {
                    HStack(spacing: 14) {
                        if let faceImage = faceImage(face) { Image(uiImage: faceImage).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(.rect(cornerRadius: 10)) }
                        else { Image(systemName: "person.crop.rectangle").frame(width: 56, height: 56) }
                        VStack(alignment: .leading) {
                            Text(face.person?.name.isEmpty == false ? face.person!.name : "Unassigned person")
                            Text("Change person").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                }.disabled(saving).requiresWriteAccess()
                    .swipeActions { Button("Remove face", role: .destructive) { deleteFace = face }.requiresWriteAccess() }
            }
        }.navigationTitle("Fix faces").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { await load() }
            .sheet(item: $selected) { face in
                NavigationStack {
                    PeopleView(api: api, pipeline: pipeline) { person in
                        selected = nil
                        change(.reassignFace(face: face.id, person: person.id))
                    }.navigationTitle("Choose the correct person")
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { selected = nil } } }
                }
            }
            .confirmationDialog("Remove this detected face?", isPresented: Binding(get: { deleteFace != nil }, set: { if !$0 { deleteFace = nil } }), titleVisibility: .visible) {
                Button("Remove face", role: .destructive) {
                    guard let face = deleteFace else { return }; deleteFace = nil
                    change(.removeFace(face.id))
                }
            } message: { Text("The photo and other people in it are kept.") }
            .alert("Couldn’t update face", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { } } message: { Text(error ?? "") }
    }
    /// Has the account's mutations change a face; the photo's details and faces are read again
    /// once it is made, and the sync that follows reconciles the people's feeds.
    private func change(_ request: MutationRequest) {
        guard let mutations else { error = APIError.signedOut.localizedDescription; return }
        saving = true
        let handle = mutations.start(request, on: [asset])
        Task {
            defer { saving = false }
            do { _ = try await handle.result; onChanged(); await load() }
            catch { self.error = error.localizedDescription }
        }
    }
    private func load() async {
        loading = true; defer { loading = false }
        do {
            faces = try await api.request(.get, path: "faces", query: [.init(name: "id", value: asset.id)])
            if image == nil { image = try await pipeline.image(for: asset, size: .preview, pixelSize: 1600).uiImage }
            for face in faces where face.frameTimestamp != nil && frameFaces[face.id] == nil {
                frameFaces[face.id] = try? await pipeline.detectedFaceImage(faceID: face.id, pixelSize: 168).uiImage
            }
        } catch is CancellationError { } catch { self.error = error.localizedDescription }
    }
    private func faceImage(_ face: AssetFace) -> UIImage? {
        face.frameTimestamp == nil ? croppedFace(face) : frameFaces[face.id]
    }
    private func croppedFace(_ face: AssetFace) -> UIImage? {
        guard let source = image?.cgImage, face.imageWidth > 0, face.imageHeight > 0 else { return nil }
        let sx = Double(source.width) / Double(face.imageWidth), sy = Double(source.height) / Double(face.imageHeight)
        let width = Double(face.boundingBoxX2 - face.boundingBoxX1), height = Double(face.boundingBoxY2 - face.boundingBoxY1)
        let bounds = CGRect(x: Double(face.boundingBoxX1) * sx, y: Double(face.boundingBoxY1) * sy, width: width * sx, height: height * sy)
            .insetBy(dx: -width * sx * 0.12, dy: -height * sy * 0.12)
            .intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard !bounds.isEmpty, let cropped = source.cropping(to: bounds) else { return nil }
        return UIImage(cgImage: cropped)
    }
}
