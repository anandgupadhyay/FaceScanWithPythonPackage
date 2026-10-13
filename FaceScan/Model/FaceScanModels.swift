import Foundation

/// A saved person and how many face samples they have.
struct Person: Identifiable {
    let name: String
    let samples: Int
    var id: String { name }
}

/// Passed to `onSuccess` when a face is matched.
struct FaceScanSuccess {
    /// The saved person's name, or nil when the face matched the reference image from a URL.
    let name: String?
    /// How sure the match is, 0…1 (0.95 = 95%).
    let confidence: Float
}
