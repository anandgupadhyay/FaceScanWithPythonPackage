import SwiftUI

/// Home screen of this demo app. It shows how another app would open `FaceScanView`
/// and react to its `onSuccess` and `onClose` closures.
struct ContentView: View {
    // Can be pre-filled when launching, e.g. `-demoUserName Dev -demoImageURL https://…`
    @State private var imageURL = UserDefaults.standard.string(forKey: "demoImageURL") ?? ""
    @State private var userName = UserDefaults.standard.string(forKey: "demoUserName") ?? ""
    @State private var showScanner = false
    @State private var lastResult = "No scan yet"

    private var trimmedURL: String { imageURL.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "faceid")
                    .font(.system(size: 72))
                    .foregroundStyle(.tint)

                Text(lastResult)
                    .font(.headline)
                    .multilineTextAlignment(.center)

                TextField("User name (for the verify popup)", text: $userName)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()

                TextField("Image URL to unlock with (optional)", text: $imageURL)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button("Open Face Scan") { showScanner = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                Button("Verify popup (called from Objective-C)") { openVerifyPopup() }
                    .buttonStyle(.bordered)
                    .disabled(trimmedURL.isEmpty || userName.trimmingCharacters(in: .whitespaces).isEmpty)

                Text("With a URL: the scan closes as soon as your face matches that photo.\nWithout a URL: it names saved people until you close it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Spacer()
            }
            .padding()
            .navigationTitle("Face Scan Demo")
            .fullScreenCover(isPresented: $showScanner) {
                let unlockURL = trimmedURL.isEmpty ? nil : trimmedURL
                FaceScanView(
                    referenceImageURL: unlockURL,
                    onSuccess: { result in
                        let percent = String(format: "%.0f%%", result.confidence * 100)
                        lastResult = "Success: \(result.name ?? "matched the URL photo") (\(percent))"
                        print("🎉 onSuccess → \(lastResult)")
                        // Unlock flow: one match is enough, so close the scanner.
                        if unlockURL != nil { showScanner = false }
                    },
                    onClose: {
                        print("👋 onClose → user closed the scanner")
                        if !lastResult.hasPrefix("Success") { lastResult = "Closed without a match" }
                        showScanner = false
                    }
                )
            }
        }
    }

    /// Runs the Objective-C sample (`FaceVerifyObjCDemo`), which calls the `FaceVerification` wrapper.
    private func openVerifyPopup() {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }

        FaceVerifyObjCDemo.run(from: top,
                               userName: userName.trimmingCharacters(in: .whitespaces),
                               imageURL: trimmedURL) { result in
            lastResult = result
        }
    }
}
