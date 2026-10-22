import Photos
import SwiftUI

/// Free up space. It only renders the account's FreeUpSpaceStore and sends it commands.
struct FreeUpSpaceView: View {
    @Environment(\.freeUpSpace) private var store

    var body: some View {
        if let store { FreeUpSpaceContent(store: store) }
        else { FeatureEmpty(title: "Sign in to free up space", symbol: "internaldrive", description: "Free up space checks your phone’s photos against your server’s backups.") }
    }
}

private struct FreeUpSpaceContent: View {
    @Bindable var store: FreeUpSpaceStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirming = false
    @State private var viewing: LocalPhoto?

    private var readable: Bool { [PHAuthorizationStatus.authorized, .limited].contains(store.permission) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Keep your backup. Clear space in Photos.").font(.title2.bold())
                Text("Only unchanged originals with a verified copy on your current server appear here. Edited photos and formats without a complete backup stay on your phone.").foregroundStyle(.secondary)
                Text("Removing items also removes them from iCloud Photos and other synced devices. They remain in Apple Photos’ Recently Deleted album until you clear it or it expires.").font(.footnote).foregroundStyle(.secondary)
                if let message = store.message { Text(message).font(.subheadline) }
            }.padding(20)
            if !readable {
                VStack(spacing: 12) {
                    Text("Allow Photos access to check originals stored on this phone.").foregroundStyle(.secondary)
                    if store.permission == .notDetermined {
                        Button("Choose Photos access") { Task { await store.requestAccess() } }
                    } else { Button("Open Settings") { openPhotoSettings() } }
                }.padding(20)
            }
            VStack(alignment: .leading, spacing: 18) {
                DatePicker("Remove only before", selection: Binding(get: { store.cutoff }, set: { store.setCutoff($0) }), in: ...Date(), displayedComponents: .date)
                Toggle("Keep favorites", isOn: Binding(get: { store.keepFavorites }, set: { store.setKeepFavorites($0) }))
                Picker("Always keep", selection: Binding(get: { store.keepMediaType }, set: { store.setKeepMediaType($0) })) {
                    Text("Neither media type").tag("none")
                    Text("Photos").tag("photos")
                    Text("Videos").tag("videos")
                }
                NavigationLink("Keep albums (\(store.keptAlbumIDs.count))") {
                    Form {
                        ForEach(store.albums) { album in
                            Toggle(album.title, isOn: Binding(get: { store.keptAlbumIDs.contains(album.id) }, set: { store.setKept(album.id, $0) }))
                        }
                    }.navigationTitle("Keep albums")
                }
                Button("Check eligible backups", systemImage: "checkmark.shield") { store.check() }
                    .disabled(!store.filtersReady || store.checking || store.removing || !readable)
            }.padding(20).disabled(store.checking || store.removing)
            if store.checking { ProgressView("Checking backups with your server…").padding(28) }
            else if store.checked && store.candidates.isEmpty { FeatureEmpty(title: "Nothing ready to remove", symbol: "checkmark.shield", description: "No verified originals match your removal settings. Your phone’s photos have not been changed.") }
            else if store.checked {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(store.candidates.count.formatted()) verified items").font(.subheadline)
                        Text("Originals size: \(store.originalsSize(of: store.selection).map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unavailable")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(store.selection.count == store.candidates.count ? "Deselect all" : "Select all") {
                        store.selection = store.selection.count == store.candidates.count ? [] : Set(store.candidates.map(\.id))
                    }
                }.padding(.horizontal, 20).padding(.vertical, 8)
                LazyVGrid(columns: Array(repeating: .init(.flexible(), spacing: 3), count: 3), spacing: 3) {
                    ForEach(store.candidates) { photo in
                        Button { if !store.selection.insert(photo.id).inserted { store.selection.remove(photo.id) } } label: {
                            ZStack(alignment: .bottomTrailing) {
                                LocalPhotoThumbnail(photo: photo).aspectRatio(1, contentMode: .fit)
                                Image(systemName: store.selection.contains(photo.id) ? "checkmark.circle.fill" : "circle").font(.title3).symbolRenderingMode(.palette).foregroundStyle(store.selection.contains(photo.id) ? Color.accentColor : Color.white, Color.black.opacity(0.4)).padding(7)
                            }
                        }.buttonStyle(.plain).accessibilityLabel(photo.title).accessibilityAddTraits(store.selection.contains(photo.id) ? .isSelected : [])
                        .contextMenu { Button("Preview") { viewing = photo } }
                    }
                }
            }
            if store.checked && !store.exclusions.isEmpty {
                // Why every other backed-up photo stays on the phone.
                VStack(alignment: .leading, spacing: 10) {
                    Text("Kept on this phone").font(.headline)
                    ForEach(store.exclusions) { group in
                        NavigationLink { KeptPhotosView(store: store, group: group) } label: {
                            HStack { Text(group.exclusion.reason); Spacer(); Text(group.ids.count.formatted()).foregroundStyle(.secondary) }
                        }
                    }
                }.padding(20)
            }
        }.navigationTitle("Free up space").disabled(store.removing)
        .safeAreaInset(edge: .bottom) {
            // Unavailable until the owner's device test (CleanupRemovalGate).
            if !store.selection.isEmpty {
                Button("Remove \(store.selection.count) from Photos", role: .destructive) { confirming = true }.buttonStyle(.glassProminent).padding()
                    .disabled(store.checking || store.removing || !store.removeAvailable).requiresWriteAccess()
            }
        }
        .task { await store.appear() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await store.refreshFilters() } } }
        .onDisappear { store.disappear() }
        .fullScreenCover(item: $viewing) { LocalPhotoViewer(photo: $0) }
        .confirmationDialog("Remove \(store.selection.count) items from Apple Photos?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Remove from Photos", role: .destructive) { store.remove() }.requiresWriteAccess()
        } message: { Text("Their verified server copies will be kept. iCloud Photos will remove them from your other synced devices too. Apple will ask you to confirm.") }
        .alert("Couldn’t free up space", isPresented: Binding(get: { store.failure != nil }, set: { if !$0 { store.failure = nil } })) { Button("OK", role: .cancel) { } } message: { Text(store.failure ?? "") }
    }
}

/// The backed-up photos one reason keeps on the phone, the first few hundred of them.
private struct KeptPhotosView: View {
    let store: FreeUpSpaceStore
    let group: FreeUpSpaceStore.ExclusionGroup
    @State private var photos: [LocalPhoto] = []
    private static let shown = 300

    var body: some View {
        ScrollView {
            if group.ids.count > Self.shown {
                Text("Showing \(Self.shown.formatted()) of \(group.ids.count.formatted())").font(.footnote).foregroundStyle(.secondary).padding()
            }
            LazyVGrid(columns: Array(repeating: .init(.flexible(), spacing: 3), count: 3), spacing: 3) {
                ForEach(photos) { photo in
                    LocalPhotoThumbnail(photo: photo).aspectRatio(1, contentMode: .fit).accessibilityLabel(photo.title)
                }
            }
        }.navigationTitle(group.exclusion.reason)
        .task { photos = await store.photos(Array(group.ids.prefix(Self.shown))) }
    }
}
