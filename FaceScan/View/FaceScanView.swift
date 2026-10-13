import SwiftUI
import PhotosUI

/// The reusable face scan screen. Present it from any app:
///
///     FaceScanView(referenceImageURL: "https://…/photo.jpg",
///                  onSuccess: { result in print(result.name ?? "matched", result.confidence) },
///                  onClose: { showScanner = false })
///
/// - `referenceImageURL`: optional photo to unlock with. Without it, the screen names saved people.
/// - `onSuccess`: called each time a face is matched.
/// - `onClose`: called when the user taps the close button.
struct FaceScanView: View {
    var referenceImageURL: String?
    var onSuccess: (FaceScanSuccess) -> Void = { _ in }
    var onClose: () -> Void = {}

    @StateObject private var viewModel = FaceScanViewModel()
    @State private var newName = ""
    @State private var imageURL = ""
    @State private var didLoadInitialURL = false
    @State private var enrollItem: PhotosPickerItem?
    @State private var scanItem: PhotosPickerItem?

    private var trimmedName: String { newName.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    cameraArea
                    addFaceRow
                    photoRow
                    urlRow

                    if let status = viewModel.status {
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                    }

                    knownPeople
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Face Scan")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { viewModel.close() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
            .onAppear(perform: setUp)
            .onDisappear { viewModel.stop() }
            .onChange(of: enrollItem) { _, item in
                guard let item else { return }
                let name = trimmedName
                loadImage(item) { viewModel.enroll(image: $0, name: name) }
                enrollItem = nil
            }
            .onChange(of: scanItem) { _, item in
                guard let item else { return }
                loadImage(item) { viewModel.scan(image: $0) }
                scanItem = nil
            }
        }
    }

    // MARK: - Sections

    private var cameraArea: some View {
        ZStack(alignment: .bottom) {
            if viewModel.cameraAvailable {
                CameraPreview(session: viewModel.session)
            } else {
                Color.black.overlay {
                    Text("Camera not available\nUse “Scan photo” below")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            if viewModel.hasReference {
                Image(systemName: viewModel.isUnlocked ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(viewModel.isUnlocked ? .green : .red)
                    .padding(14)
                    .background(.ultraThinMaterial, in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(12)
            }
            Text(viewModel.recognizedName)
                .font(.title2.bold())
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding()
        }
        .frame(height: 340)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var addFaceRow: some View {
        HStack {
            TextField("Name (e.g. Tirth)", text: $newName)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            Button("Add face") { viewModel.enrollFromCamera(name: trimmedName) }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedName.isEmpty || !viewModel.cameraAvailable)
        }
    }

    private var photoRow: some View {
        HStack {
            PhotosPicker("Add from photo", selection: $enrollItem, matching: .images)
                .disabled(trimmedName.isEmpty)
            Spacer()
            PhotosPicker("Scan photo", selection: $scanItem, matching: .images)
        }
    }

    private var urlRow: some View {
        HStack {
            TextField("Image URL to unlock with", text: $imageURL)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if viewModel.hasReference {
                Button("Clear") { viewModel.clearReference() }
                    .buttonStyle(.bordered)
            } else {
                Button("Check") { viewModel.loadReference(from: imageURL) }
                    .buttonStyle(.borderedProminent)
                    .disabled(imageURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var knownPeople: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Known people")
                .font(.headline)
                .padding(.bottom, 8)
            if viewModel.people.isEmpty {
                Text("Type a name and tap “Add face”. It captures 5 samples. Tap it twice per person for best results.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.people) { person in
                HStack {
                    Text(person.name)
                    Spacer()
                    Text("\(person.samples) sample\(person.samples == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                    Button(role: .destructive) { viewModel.remove(name: person.name) } label: {
                        Image(systemName: "trash")
                    }
                    .padding(.leading, 8)
                }
                .padding(.vertical, 10)
                Divider()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Actions

    private func setUp() {
        viewModel.onSuccess = onSuccess
        viewModel.onClose = onClose
        viewModel.start()

        // Load the photo passed in by the host app, once.
        if !didLoadInitialURL, let url = referenceImageURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !url.isEmpty {
            didLoadInitialURL = true
            imageURL = url
            viewModel.loadReference(from: url)
        }
    }

    private func loadImage(_ item: PhotosPickerItem, then handle: @escaping (UIImage) -> Void) {
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                handle(image)
            }
        }
    }
}
