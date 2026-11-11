import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import SafeSpaceCore

struct NewAssessmentView: View {
    let roomID: Room.ID
    static let maxPhotos = 1
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var selection: PhotosPickerItem?
    @State private var photo: ImportedPhoto?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var isAnalyzing = false
    @State private var isShowingCamera = false
    @State private var analysisTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if CameraPicker.isAvailable {
                    Button {
                        errorMessage = nil; isShowingCamera = true
                    } label: {
                        Label("Take photo", systemImage: "camera").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(photo != nil || isLoading || isAnalyzing)
                }
                PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .current) {
                    Label("Choose from library", systemImage: "photo").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(photo != nil || isLoading || isAnalyzing)
                Text("One photo per assessment. Analysis runs on this iPhone.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("Detected faces and people are blurred in the saved copy and excluded from color statistics. Detection may miss people. Your original photo is not saved by this app; the source photo in Photos is unchanged.")
                    .font(.footnote).foregroundStyle(.secondary)
                if isLoading { ProgressView("Loading photo…") }
                if isAnalyzing { ProgressView("Analyzing colors…") }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if let photo {
                    Image(uiImage: photo.preview).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("Selected photo")
                    Text(photo.summary).font(.caption).foregroundStyle(.secondary)
                    Button("Remove photo", role: .destructive) {
                        self.photo = nil; selection = nil; errorMessage = nil
                    }.disabled(isAnalyzing)
                }
            }.padding()
        }
        .navigationTitle("New assessment")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isAnalyzing)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Analyze & Save") { analyze() }
                    .disabled(photo == nil || isLoading || isAnalyzing)
            }
            ToolbarItem(placement: .cancellationAction) {
                if isAnalyzing { Button("Cancel") { cancel() } }
            }
        }
        .task(id: selection) {
            guard let selection else { return }
            isLoading = true; errorMessage = nil
            defer { isLoading = false }
            do {
                guard let data = try await selection.loadTransferable(type: Data.self) else {
                    throw PhotoImportError.unreadableImage
                }
                try Task.checkCancellation()
                photo = try ImportedPhoto(data: data, contentType: selection.supportedContentTypes.first)
            } catch is CancellationError { return }
            catch { errorMessage = error.localizedDescription }
        }
        .fullScreenCover(isPresented: $isShowingCamera) {
            CameraPicker { image in
                do {
                    guard let data = image.uprightJPEGData() else { throw PhotoImportError.unreadableImage }
                    photo = try ImportedPhoto(data: data, contentType: .jpeg, source: .camera)
                } catch { errorMessage = error.localizedDescription }
            }.ignoresSafeArea()
        }
        .onDisappear {
            analysisTask?.cancel()
            photo = nil; selection = nil
        }
    }
    @MainActor private func analyze() {
        guard let input = photo, !isAnalyzing else { return }
        isAnalyzing = true; errorMessage = nil
        // The task owns the input only while processing. Drop the view's original preview
        // and PhotosPicker reference immediately, including on errors/cancellation.
        photo = nil; selection = nil
        analysisTask = Task { @MainActor in
            defer { isAnalyzing = false; analysisTask = nil }
            do {
                let id = try await model.analyzeAndSave(to: roomID, photo: input)
                try Task.checkCancellation()
                photo = nil; selection = nil
                router.replaceTop(with: .assessment(roomID: roomID, assessmentID: id))
            } catch is CancellationError {
                photo = nil; selection = nil
            } catch {
                photo = nil; selection = nil
                errorMessage = error.localizedDescription
            }
        }
    }
    @MainActor private func cancel() {
        analysisTask?.cancel()
        photo = nil; selection = nil; errorMessage = nil
    }
}
