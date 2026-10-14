import SwiftUI

/// Popup card: "Verify yourself as <name>". Compares the live face with one photo from a URL.
/// Shown through `FaceVerification` (the Objective-C wrapper), but usable from SwiftUI too.
struct FaceVerifyView: View {
    let userName: String
    let imageURL: String
    let themeColor: Color
    /// Called once, with the match score (0…1), after the face matches the photo.
    let onSuccess: (Float) -> Void
    /// Called when the user taps Cancel.
    let onCancel: () -> Void

    @StateObject private var viewModel = FaceScanViewModel()
    @State private var verified = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()

            VStack(spacing: 16) {
                Text("Verify yourself as \(userName)")
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)

                cameraArea
                matchDots

                if let status = viewModel.status, !verified {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button("Cancel") { viewModel.close() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(verified)
            }
            .padding(20)
            .frame(maxWidth: 340)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
            .padding(24)
        }
        .tint(themeColor)
        .onAppear(perform: setUp)
        .onDisappear { viewModel.stop() }
    }

    /// One dot per matching scan (they need not be in a row); when all are filled the face is accepted.
    private var matchDots: some View {
        let filled = verified ? viewModel.matchesToVerify : viewModel.matchCount
        return HStack(spacing: 12) {
            ForEach(0..<viewModel.matchesToVerify, id: \.self) { index in
                Circle()
                    .fill(index < filled ? themeColor : Color.clear)
                    .overlay(Circle().stroke(index < filled ? themeColor : Color.secondary.opacity(0.5), lineWidth: 2))
                    .frame(width: 16, height: 16)
            }
        }
        .animation(.easeOut(duration: 0.2), value: filled)
        .accessibilityLabel("\(filled) of \(viewModel.matchesToVerify) matches")
    }

    private var cameraArea: some View {
        ZStack(alignment: .bottom) {
            if viewModel.cameraAvailable {
                CameraPreview(session: viewModel.session)
            } else {
                Color.black.overlay {
                    Text("Camera not available")
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            if verified {
                Color.black.opacity(0.35)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 84))
                    .foregroundStyle(.white, themeColor)
                    .frame(maxHeight: .infinity)
            }
            Text(verified ? "Verified" : viewModel.recognizedName)
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(12)
        }
        .frame(height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(themeColor, lineWidth: 3))
    }

    private func setUp() {
        viewModel.verifyOnly = true
        viewModel.onClose = onCancel
        viewModel.onSuccess = { result in
            // Only a match against the URL photo counts (name is nil for those), and only once.
            guard result.name == nil, !verified else { return }
            verified = true
            viewModel.stop()
            // Let the user see the check mark before the popup goes away.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { onSuccess(result.confidence) }
        }
        viewModel.start()
        viewModel.loadReference(from: imageURL)
    }
}
