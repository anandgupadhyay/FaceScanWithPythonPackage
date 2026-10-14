import AVFoundation
import UIKit

/// All the logic behind `FaceScanView`: takes frames from `CameraController`, asks
/// `FaceRecognizer` who it is, and publishes what the screen should show.
final class FaceScanViewModel: ObservableObject {
    @Published var recognizedName = "Looking for a face…"
    @Published var people: [Person] = []
    @Published var cameraAvailable = true
    @Published var status: String?
    /// True while a reference photo from a URL is loaded; the camera then checks faces against it.
    @Published var hasReference = false
    @Published var isUnlocked = false
    /// How many scans have matched the URL photo so far, from 0 up to `matchesToVerify`.
    /// The verify popup shows one dot per match.
    @Published var matchCount = 0

    /// Called on the main thread each time a face is matched (a saved person, or the URL image).
    var onSuccess: ((FaceScanSuccess) -> Void)?
    /// Called on the main thread when the user closes the screen.
    var onClose: (() -> Void)?
    /// When true, faces are only ever checked against the URL photo. Until that photo has
    /// loaded nothing is matched, so a saved person can never count as a pass. Set before `start()`.
    var verifyOnly = false

    var session: AVCaptureSession { camera.session }

    private let camera = CameraController()
    private let recognizer = FaceRecognizer.shared
    private let workQueue = DispatchQueue(label: "face.work", qos: .userInitiated)

    /// Samples captured per "Add face" tap.
    private let samplesPerEnroll = 5
    /// A result must win this many of the last `voteWindow` scans before it is shown/printed.
    private let voteWindow = 5
    private let votesNeeded = 3
    /// Total matching scans needed to verify against the URL photo. They do not have to be
    /// in a row: match, no match, match… still counts up. The count restarts when the face leaves.
    let matchesToVerify = 5
    /// A scan scoring below this (0.50 = 50%) looks like a different person, so the count
    /// (and the dots) starts again from zero.
    private let resetBelowConfidence: Float = 0.50

    // Only touched on camera.queue
    private var lastPrinted: String?
    private var recentVotes: [String] = []
    private var reference: [[Float]]?
    private var enrollingName: String?
    private var enrollCaptured = 0
    private var enrollDeadline = Date.distantPast
    // Liveness (anti-photo) state for the URL unlock
    private var recentLive: [Bool] = []
    private var matchTotal = 0
    private var bestScore: Float = 0
    private var missedFaces = 0
    private let blink = BlinkDetector()

    init() {
        camera.onFrame = { [weak self] frame, depth in self?.handle(frame, depth: depth) }
        camera.onUnavailable = { [weak self] reason in
            print("⚠️ \(reason)")
            DispatchQueue.main.async { self?.cameraAvailable = false }
        }
        refreshPeople()
    }

    // MARK: - Lifecycle

    func start() { camera.start() }
    func stop() { camera.stop() }

    /// Stops the camera and tells the host app the user closed the screen.
    func close() {
        stop()
        print("✖️ Face scan closed")
        onClose?()
    }

    // MARK: - Frames

    private func handle(_ frame: CGImage, depth: AVDepthData?) {
        if enrollingName != nil {
            captureEnrollSample(frame)
        } else if let reference {
            reportVerification(recognizer.verify(frame, against: reference), depth: depth)
        } else if verifyOnly {
            setLabel("Loading photo…")
        } else {
            report(recognizer.identify(frame))
        }
    }

    /// Shows/prints a name only once it wins most of the recent scans, so one bad frame doesn't flip it.
    private func report(_ result: FaceRecognizer.Result) {
        let vote: String
        let confidence: Float
        switch result {
        case .noFace:
            recentVotes.removeAll()
            lastPrinted = nil
            setLabel("Looking for a face…")
            return
        case .lowQuality:
            setLabel("Look straight at the camera")
            return
        case .unknown(let score, let closest):
            vote = "Unknown"
            confidence = score
            debugLog("unknown, closest \(closest ?? "-") \(percent(score))")
        case .match(let name, let score):
            vote = name
            confidence = score
            debugLog("\(name) \(percent(score))")
        }

        guard let winner = stableVote(adding: vote) else {
            setLabel("Scanning…")
            return
        }
        if winner != lastPrinted {
            if winner == "Unknown" {
                print("❓ Face scanned → Unknown person (below \(percent(recognizer.minConfidence)) match)")
            } else {
                print("✅ Face scanned → \(winner) (\(percent(confidence)) match)")
                notifySuccess(name: winner, confidence: confidence)
            }
            lastPrinted = winner
        }
        setLabel(winner == "Unknown" || vote != winner ? winner : "\(winner) \(percent(confidence))")
    }

    // MARK: - Unlock with a photo from a URL

    /// Downloads a photo (Google Drive share links are supported) and uses it as the face to unlock with.
    func loadReference(from text: String) {
        guard let url = Self.directDownloadURL(from: text) else {
            setStatus("That doesn't look like a valid https link.")
            return
        }
        setStatus("Downloading image…")
        print("🌐 Downloading reference image: \(url.absoluteString)")

        URLSession.shared.dataTask(with: url) { data, _, error in
            guard let data, let cgImage = UIImage(data: data)?.uprightCGImage else {
                print("🚫 Could not load an image from the URL: \(error?.localizedDescription ?? "not an image")")
                self.setStatus("Couldn't load an image. Is the link shared as “Anyone with the link”?")
                return
            }
            guard let embeddings = self.recognizer.referenceEmbeddings(for: cgImage) else {
                print("🚫 No face found in the URL image")
                self.setStatus("No face found in that image.")
                return
            }
            print("🖼️ Reference image loaded. Show your face to the camera to unlock.")
            self.setStatus("Image loaded. Show your face to unlock.")
            self.camera.queue.async {
                self.reference = embeddings
                self.recentVotes.removeAll()
                self.recentLive.removeAll()
                self.resetMatches()
                self.blink.reset()
                self.lastPrinted = nil
            }
            DispatchQueue.main.async {
                self.hasReference = true
                self.isUnlocked = false
            }
        }.resume()
    }

    /// Goes back to the normal "who is this?" scan.
    func clearReference() {
        camera.queue.async {
            self.reference = nil
            self.recentVotes.removeAll()
            self.recentLive.removeAll()
            self.resetMatches()
            self.blink.reset()
            self.lastPrinted = nil
        }
        hasReference = false
        isUnlocked = false
        status = nil
    }

    /// Unlocks once the face has matched the URL image `matchesToVerify` times in total
    /// AND it is a live person, not a photo or a screen held up to the camera.
    private func reportVerification(_ result: FaceRecognizer.Verification, depth: AVDepthData?) {
        let score: Float
        let face: FaceRecognizer.FaceInfo
        switch result {
        case .noFace:
            // A single dropped frame shouldn't wipe the progress; a face that is really gone should.
            missedFaces += 1
            guard missedFaces >= 3 else { return }
            recentLive.removeAll()
            blink.reset()
            if lastPrinted == "Match" { print("🔒 Locked: no face in front of the camera") }
            lastPrinted = nil
            resetMatches()
            setUnlocked(false)
            setLabel("Show your face to unlock")
            return
        case .lowQuality:
            setLabel("Look straight at the camera")
            return
        case .score(let value, let info):
            score = value
            face = info
        }
        missedFaces = 0

        let isLive = updateLiveness(face: face, depth: depth)
        let matched = score >= recognizer.minConfidence
        if matched {
            matchTotal += 1
            bestScore = max(bestScore, score)
        } else if score < resetBelowConfidence, matchTotal > 0, matchTotal < matchesToVerify {
            debugLog("score \(percent(score)) is under \(percent(resetBelowConfidence)); match count reset")
            resetMatches()
        }
        setMatchCount(matchTotal)
        debugLog("url image: \(matched ? "Match" : "No match") \(percent(score)) (\(min(matchTotal, matchesToVerify))/\(matchesToVerify))")

        // Enough matches only count once the face has also passed the liveness check.
        let state: String
        if matchTotal < matchesToVerify {
            state = "Counting"
        } else if !isLive {
            state = camera.hasDepth ? "Photo" : "Blink"
        } else {
            state = "Match"
        }
        if state != lastPrinted {
            switch state {
            case "Match":
                print("🔓 Unlocked: live face matched the URL image \(matchesToVerify) times (best \(percent(bestScore)))")
                notifySuccess(name: nil, confidence: bestScore)
            case "Photo":
                print("🚫 Not unlocked: the face matches but looks flat (photo or screen?)")
            case "Blink":
                print("👁️ Face matched \(matchesToVerify) times; waiting for a blink to confirm a live person")
            default:
                break
            }
            lastPrinted = state
        }
        setUnlocked(state == "Match")
        switch state {
        case "Match": setLabel("Unlocked")
        case "Photo": setLabel("Use your real face, not a photo")
        case "Blink": setLabel("Close your eyes, then open")
        default: setLabel(matched ? "Match \(percent(score))" : "No match \(percent(score))")
        }
    }

    private func resetMatches() {
        matchTotal = 0
        bestScore = 0
        setMatchCount(0)
    }

    /// Returns true once this face has shown it is a live person.
    /// With a depth camera: the face must be 3-D in most recent scans. Without: it must blink.
    private func updateLiveness(face: FaceRecognizer.FaceInfo, depth: AVDepthData?) -> Bool {
        guard camera.hasDepth else {
            if let openness = face.eyeOpenness { blink.update(eyeOpenness: openness) }
            return blink.hasBlinked
        }

        var live = false
        if let depth {
            #if DEBUG
            let box = face.boundingBox
            debugLog(String(format: "depth check: face box x%.2f y%.2f w%.2f h%.2f | ", box.minX, box.minY, box.width, box.height)
                     + DepthLiveness.diagnostics(depth: depth, faceBox: box))
            #endif
            switch DepthLiveness.check(depth: depth, faceBox: face.boundingBox) {
            case .live(let relief, let distance):
                live = true
                debugLog("liveness: 3-D face, relief \(String(format: "%.1f", relief)) mm at \(String(format: "%.2f", distance)) m")
            case .flat(let relief, let distance):
                debugLog("liveness: FLAT, relief \(String(format: "%.1f", relief)) mm at \(String(format: "%.2f", distance)) m")
            case .unknown:
                debugLog("liveness: no usable depth on the face")
            }
        }
        recentLive.append(live)
        if recentLive.count > voteWindow { recentLive.removeFirst() }
        return recentLive.filter { $0 }.count >= votesNeeded
    }

    /// Turns a Google Drive share link into a direct download link; other https links pass through.
    static func directDownloadURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "https", let host = url.host else { return nil }
        guard host.hasSuffix("drive.google.com") else { return url }

        var fileID: String?
        let parts = url.pathComponents
        if let index = parts.firstIndex(of: "d"), index + 1 < parts.count {
            fileID = parts[index + 1] // …/file/d/<id>/view
        } else {
            fileID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "id" }?.value // …/open?id=<id>
        }
        guard let fileID else { return url }
        var direct = URLComponents(string: "https://drive.google.com/uc")!
        direct.queryItems = [URLQueryItem(name: "export", value: "download"),
                             URLQueryItem(name: "id", value: fileID)]
        return direct.url
    }

    // MARK: - Enroll / scan

    /// Captures several good-quality frames over a few seconds for one person.
    func enrollFromCamera(name: String) {
        camera.queue.async {
            self.enrollingName = name
            self.enrollCaptured = 0
            self.enrollDeadline = Date().addingTimeInterval(10)
            self.setStatus("Hold still, \(name)… 0/\(self.samplesPerEnroll)")
            print("📸 Capturing \(self.samplesPerEnroll) samples for \(name)…")
        }
    }

    private func captureEnrollSample(_ frame: CGImage) {
        guard let name = enrollingName else { return }
        do {
            try recognizer.enroll(name: name, image: frame)
            enrollCaptured += 1
            setStatus("Hold still, \(name)… \(enrollCaptured)/\(samplesPerEnroll) (turn your head slightly)")
        } catch {
            setStatus(error.localizedDescription)
        }

        if enrollCaptured >= samplesPerEnroll || Date() > enrollDeadline {
            print("➕ Added \(enrollCaptured) face samples for \(name)")
            setStatus(enrollCaptured > 0 ? "Added \(enrollCaptured) samples for \(name)"
                                         : "Couldn't get a clear face. Try better light.")
            enrollingName = nil
            recentVotes.removeAll()
            // Don't report the person who was just added as a new "success".
            lastPrinted = enrollCaptured > 0 && reference == nil ? name : nil
            refreshPeople()
        }
    }

    func enroll(image: UIImage, name: String) {
        workQueue.async {
            guard let cgImage = image.uprightCGImage else { return }
            do {
                // Photos are usually fine even if Vision rates them lower, so skip the quality gate.
                try self.recognizer.enroll(name: name, image: cgImage, checkQuality: false)
                print("➕ Added face sample for \(name) from photo")
                self.setStatus("Added face for \(name)")
                self.refreshPeople()
            } catch {
                print("🚫 Could not add \(name): \(error.localizedDescription)")
                self.setStatus(error.localizedDescription)
            }
        }
    }

    func scan(image: UIImage) {
        workQueue.async {
            guard let cgImage = image.uprightCGImage else { return }
            let label: String
            switch self.recognizer.identify(cgImage, checkQuality: false) {
            case .noFace, .lowQuality:
                print("🚫 No face found in photo")
                label = "No face"
            case .unknown(let score, let closest):
                let hint = closest.map { " (closest: \($0) \(self.percent(score)))" } ?? ""
                print("❓ Face scanned → Unknown person\(hint)")
                label = "Unknown"
            case .match(let name, let score):
                print("✅ Face scanned → \(name) (\(self.percent(score)) match)")
                label = "\(name) \(self.percent(score))"
                self.notifySuccess(name: name, confidence: score)
            }
            self.setLabel(label)
        }
    }

    func remove(name: String) {
        recognizer.remove(name: name)
        print("🗑️ Removed \(name)")
        refreshPeople()
    }

    // MARK: - Helpers

    private func notifySuccess(name: String?, confidence: Float) {
        DispatchQueue.main.async { self.onSuccess?(FaceScanSuccess(name: name, confidence: confidence)) }
    }

    /// Adds a scan result and returns the one that wins most of the recent scans, if any does yet.
    private func stableVote(adding vote: String) -> String? {
        recentVotes.append(vote)
        if recentVotes.count > voteWindow { recentVotes.removeFirst() }
        let counts = Dictionary(recentVotes.map { ($0, 1) }, uniquingKeysWith: +)
        guard let (winner, votes) = counts.max(by: { $0.value < $1.value }), votes >= votesNeeded else {
            return nil
        }
        return winner
    }

    private func refreshPeople() {
        let list = recognizer.people.map { Person(name: $0.name, samples: $0.samples) }
        DispatchQueue.main.async { self.people = list }
    }

    private func setMatchCount(_ value: Int) {
        let count = min(value, matchesToVerify)
        DispatchQueue.main.async { if self.matchCount != count { self.matchCount = count } }
    }

    private func setUnlocked(_ value: Bool) {
        DispatchQueue.main.async { if self.isUnlocked != value { self.isUnlocked = value } }
    }

    private func setLabel(_ text: String) {
        DispatchQueue.main.async { if self.recognizedName != text { self.recognizedName = text } }
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { self.status = text }
    }

    /// Per-scan scores, handy for tuning `FaceRecognizer.minConfidence`. Debug builds only.
    private func debugLog(_ text: String) {
        #if DEBUG
        print("   · scan: \(text)")
        #endif
    }

    private func percent(_ value: Float) -> String {
        String(format: "%.0f%%", value * 100)
    }
}
