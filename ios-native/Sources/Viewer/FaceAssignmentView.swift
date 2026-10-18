import SwiftUI

private struct AssetFace: Decodable, Identifiable, Sendable {
    let id: String
    let imageWidth: Int
    let imageHeight: Int
    let boundingBoxX1: Int
    let boundingBoxX2: Int
    let boundingBoxY1: Int
    let boundingBoxY2: Int
    let person: Person?
}

struct FaceAssignmentView: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let asset: Asset
    let onChanged: () -> Void
    @State private var faces: [AssetFace] = []
    @State private var image: UIImage?
    @State private var selected: AssetFace?
    @State private var deleteFace: AssetFace?
    @State private var error: String?
    @State private var loading = true
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            if loading { ProgressView("Loading faces") }
            if !loading && faces.isEmpty { ContentUnavailableView("No faces detected", systemImage: "person.crop.rectangle") }
            ForEach(faces) { face in
                Button { selected = face } label: {
                    HStack(spacing: 14) {
                        if let faceImage = croppedFace(face) { Image(uiImage: faceImage).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(.rect(cornerRadius: 10)) }
                        else { Image(systemName: "person.crop.rectangle").frame(width: 56, height: 56) }
                        VStack(alignment: .leading) {
                            Text(face.person?.name.isEmpty == false ? face.person!.name : "Unassigned person")
                            Text("Change person").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                }.disabled(saving).requiresWriteAccess(api)
                    .swipeActions { Button("Remove face", role: .destructive) { deleteFace = face }.requiresWriteAccess(api) }
            }
        }.navigationTitle("Fix faces").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { await load() }
            .sheet(item: $selected) { face in
                NavigationStack {
                    PeopleView(api: api, pipeline: pipeline) { person in
                        selected = nil; saving = true
                        Task {
                            defer { saving = false }
                            do {
                                let _: Person = try await api.request(.put, path: "faces/\(person.id)", body: ["id": face.id])
                                onChanged(); await load()
                            } catch { self.error = error.localizedDescription }
                        }
                    }.navigationTitle("Choose the correct person")
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { selected = nil } } }
                }
            }
            .confirmationDialog("Remove this detected face?", isPresented: Binding(get: { deleteFace != nil }, set: { if !$0 { deleteFace = nil } }), titleVisibility: .visible) {
                Button("Remove face", role: .destructive) {
                    guard let face = deleteFace else { return }; deleteFace = nil; saving = true
                    Task {
                        defer { saving = false }
                        do { try await api.requestVoid(.delete, path: "faces/\(face.id)", body: ["force": false]); onChanged(); await load() }
                        catch { self.error = error.localizedDescription }
                    }
                }
            } message: { Text("The photo and other people in it are kept.") }
            .alert("Couldn’t update face", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { } } message: { Text(error ?? "") }
    }
    private func load() async {
        loading = true; defer { loading = false }
        do {
            faces = try await api.request(.get, path: "faces", query: [.init(name: "id", value: asset.id)])
            if image == nil { image = try await pipeline.image(for: asset, size: .preview, pixelSize: 1600).uiImage }
        } catch is CancellationError { } catch { self.error = error.localizedDescription }
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
