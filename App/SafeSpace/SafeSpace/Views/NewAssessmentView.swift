import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct NewAssessmentView: View {
    let roomID: Room.ID

    /// Proposed demo limit (1–3 photos), shared by camera and library photos.
    /// Record the tested limit in the README.
    static let maxPhotos = 3

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    @State private var selection: [PhotosPickerItem] = []
    @State private var libraryPhotos: [LibraryPhoto] = []
    @State private var cameraPhotos: [ImportedPhoto] = []
    @State private var libraryProblems: [String] = []
    @State private var cameraProblem: String?
    @State private var isLoading = false
    @State private var isShowingCamera = false

    /// Keeps each loaded photo paired with the picker item it came from,
    /// so removing a photo can also remove it from the picker selection.
    private struct LibraryPhoto {
        let item: PhotosPickerItem
        let photo: ImportedPhoto
    }

    private var allPhotos: [ImportedPhoto] {
        libraryPhotos.map(\.photo) + cameraPhotos
    }

    private var slotsUsed: Int { selection.count + cameraPhotos.count }
    private var librarySlots: Int { Self.maxPhotos - cameraPhotos.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(spacing: 12) {
                    if CameraPicker.isAvailable {
                        Button {
                            cameraProblem = nil
                            isShowingCamera = true
                        } label: {
                            Label("Take photo", systemImage: "camera")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(slotsUsed >= Self.maxPhotos)
                    }

                    // PhotosPicker runs out of process, so no photo-library
                    // permission prompt is needed. `.current` asks Photos for the
                    // original encoding instead of transcoding to JPEG.
                    // max(1, …) because a limit of 0 would mean "unlimited".
                    PhotosPicker(
                        selection: $selection,
                        maxSelectionCount: max(1, librarySlots),
                        selectionBehavior: .ordered,
                        matching: .images,
                        preferredItemEncoding: .current
                    ) {
                        Label(selection.isEmpty ? "Choose from library" : "Change library photos",
                              systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(librarySlots < 1)
                }

                Text("Add up to \(Self.maxPhotos) photos of the same room. \(allPhotos.count) of \(Self.maxPhotos) added.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if isLoading {
                    ProgressView("Loading photos…")
                        .frame(maxWidth: .infinity)
                }

                ForEach(libraryProblems + [cameraProblem].compactMap { $0 }, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }

                ForEach(Array(allPhotos.enumerated()), id: \.element.id) { index, photo in
                    VStack(alignment: .leading, spacing: 6) {
                        Image(uiImage: photo.preview)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel("Photo \(index + 1)")
                        HStack(alignment: .firstTextBaseline) {
                            Text("Photo \(index + 1): \(photo.summary)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Remove", role: .destructive) { remove(photo) }
                                .font(.caption)
                                .accessibilityLabel("Remove photo \(index + 1)")
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("New assessment")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(allPhotos.isEmpty || isLoading)
            }
        }
        // Restarts (and cancels the previous load) whenever the selection changes.
        .task(id: selection) {
            await loadLibraryPhotos(selection)
        }
        .fullScreenCover(isPresented: $isShowingCamera) {
            CameraPicker { image in addCameraPhoto(image) }
                .ignoresSafeArea()
        }
    }

    // MARK: - Library

    private func loadLibraryPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else {
            libraryPhotos = []
            libraryProblems = []
            isLoading = false
            return
        }

        isLoading = true
        var loaded: [LibraryPhoto] = []
        var messages: [String] = []

        for (index, item) in items.enumerated() {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    messages.append("Library photo \(index + 1) couldn't be opened. Choose it again or pick another photo.")
                    continue
                }
                let photo = try ImportedPhoto(
                    data: data,
                    contentType: item.supportedContentTypes.first,
                    source: .library
                )
                loaded.append(LibraryPhoto(item: item, photo: photo))
            } catch is CancellationError {
                return
            } catch {
                messages.append("Library photo \(index + 1) couldn't be loaded. If it's stored in iCloud, check your connection and try again.")
            }
        }

        // A newer selection replaced this one; let that load update the screen.
        guard !Task.isCancelled else { return }
        libraryPhotos = loaded
        libraryProblems = messages
        isLoading = false
    }

    // MARK: - Camera

    private func addCameraPhoto(_ image: UIImage) {
        guard slotsUsed < Self.maxPhotos else { return }
        do {
            guard let data = image.uprightJPEGData() else { throw PhotoImportError.unreadableImage }
            cameraPhotos.append(try ImportedPhoto(data: data, contentType: .jpeg, source: .camera))
        } catch {
            cameraProblem = "The photo couldn't be added. Take it again."
        }
    }

    // MARK: - Actions

    private func remove(_ photo: ImportedPhoto) {
        if let index = cameraPhotos.firstIndex(where: { $0.id == photo.id }) {
            cameraPhotos.remove(at: index)
        } else if let entry = libraryPhotos.first(where: { $0.photo.id == photo.id }) {
            libraryPhotos.removeAll { $0.photo.id == photo.id }
            selection.removeAll { $0 == entry.item }   // reloads the rest via .task(id:)
        }
    }

    private func save() {
        guard let assessmentID = model.addAssessment(to: roomID, photos: allPhotos) else { return }
        router.replaceTop(with: .assessment(roomID: roomID, assessmentID: assessmentID))
    }
}
