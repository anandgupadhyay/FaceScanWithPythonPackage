import Vision
import UIKit
import CoreImage

/// Recognizes people using only Apple's Vision framework (no third-party model).
///
/// Each face is checked for quality, rotated so the eyes are level, cropped, made grayscale and
/// turned into a "feature print" (a list of numbers describing the image). Prints of the same
/// person are usually closer together than prints of different people. A new face is compared
/// with every saved (old) photo, and a match is only reported at `minConfidence` (80%) or more.
///
/// Note: Vision's feature print describes images in general, not faces specifically, so it is
/// less reliable than a dedicated face model. Lighting, angle and glasses affect it more.
final class FaceRecognizer {
    enum Result {
        case noFace
        case lowQuality(quality: Float)
        case unknown(confidence: Float, closest: String?)
        case match(name: String, confidence: Float)
    }

    enum EnrollError: LocalizedError {
        case noFace, lowQuality
        var errorDescription: String? {
            switch self {
            case .noFace: "No face found in the image."
            case .lowQuality: "Face is blurry, dark or turned away. Look straight at the camera."
            }
        }
    }

    static let shared = FaceRecognizer()

    /// A face counts as a match only when the score is at least this high (0.80 = 80%).
    /// Raise it to be stricter (fewer wrong people accepted, more right people rejected).
    var minConfidence: Float = 0.95
    /// Vision's face capture quality (0…1). Faces below this are ignored by the live camera.
    var minQuality: Float = 0.25

    private var known: [String: [[Float]]] = [:]
    private let lock = NSLock()
    private let ciContext = CIContext()
    private let inputSize: CGFloat = 224
    // Prints from different engines can't be compared, so each engine keeps its own file.
    private let storeURL = URL.documentsDirectory.appending(path: "faces_vision.json")

    private init() { load() }

    /// Names with how many face samples each one has (the mirrored copy is not counted).
    var people: [(name: String, samples: Int)] {
        lock.withLock { known.map { ($0.key, $0.value.count / 2) }.sorted { $0.name < $1.name } }
    }

    func enroll(name: String, image: CGImage, checkQuality: Bool = true) throws {
        guard let sample = alignedFace(in: image) else { throw EnrollError.noFace }
        if checkQuality, sample.quality < minQuality { throw EnrollError.lowQuality }
        guard let original = embedding(of: sample.face),
              let mirrored = embedding(of: mirror(sample.face))
        else { throw EnrollError.noFace }
        lock.withLock { known[name, default: []].append(contentsOf: [original, mirrored]) }
        save()
    }

    func remove(name: String) {
        lock.withLock { _ = known.removeValue(forKey: name) }
        save()
    }

    func identify(_ image: CGImage, checkQuality: Bool = true) -> Result {
        guard let sample = alignedFace(in: image) else { return .noFace }
        if checkQuality, sample.quality < minQuality { return .lowQuality(quality: sample.quality) }
        guard let probe = embedding(of: sample.face) else { return .noFace }

        // Score each person by the average distance to their 3 closest saved photos.
        let scores: [(name: String, distance: Float)] = lock.withLock {
            known.compactMap { name, saved in
                let closest = saved.map { distance(probe, $0) }.sorted().prefix(3)
                guard !closest.isEmpty else { return nil }
                return (name, closest.reduce(0, +) / Float(closest.count))
            }
        }.sorted { $0.distance < $1.distance }

        guard let best = scores.first else { return .unknown(confidence: 0, closest: nil) }
        let confidence = Self.confidence(forDistance: best.distance)
        guard confidence >= minConfidence else {
            return .unknown(confidence: confidence, closest: best.name)
        }
        return .match(name: best.name, confidence: confidence)
    }

    // MARK: - One-to-one check against a reference photo (e.g. downloaded from a URL)

    /// Where the face is and how open the eyes are; used for the liveness (anti-photo) check.
    struct FaceInfo {
        /// Vision bounding box: normalized 0…1, origin bottom-left.
        let boundingBox: CGRect
        /// Eye height ÷ eye width averaged over both eyes, or nil if the eyes weren't found.
        let eyeOpenness: Float?
    }

    enum Verification {
        case noFace
        case lowQuality(quality: Float)
        case score(Float, face: FaceInfo)
    }

    /// Embeddings (original + mirrored) of the face in a reference photo, or nil if it has no face.
    func referenceEmbeddings(for image: CGImage) -> [[Float]]? {
        guard let sample = alignedFace(in: image),
              let original = embedding(of: sample.face),
              let mirrored = embedding(of: mirror(sample.face))
        else { return nil }
        return [original, mirrored]
    }

    /// How sure we are (0…1) that the face in `image` is the same person as the reference photo.
    func verify(_ image: CGImage, against reference: [[Float]], checkQuality: Bool = true) -> Verification {
        guard let sample = alignedFace(in: image) else { return .noFace }
        if checkQuality, sample.quality < minQuality { return .lowQuality(quality: sample.quality) }
        guard let probe = embedding(of: sample.face),
              let closest = reference.map({ distance(probe, $0) }).min()
        else { return .noFace }
        return .score(Self.confidence(forDistance: closest), face: sample.info)
    }

    /// The distance treated as a 50/50 match. Lower = stricter.
    /// Calibrated from real scans on an iPhone 12: the right person against a clear, front-facing
    /// photo scored 0.54–0.70 (mostly under 0.62); a poor match scored around 0.80.
    static var midpointDistance: Float = 0.80
    /// How sharply confidence falls off around the midpoint.
    static var steepness: Float = 20

    /// Turns a feature-print distance into a 0…1 match score.
    /// With the defaults, 80% needs a distance of about 0.73 or less (95% needs about 0.65).
    static func confidence(forDistance d: Float) -> Float {
        #if DEBUG
        print("   · distance \(String(format: "%.3f", d))")
        #endif
        return 1 / (1 + exp(steepness * (d - midpointDistance)))
    }

    // MARK: - Face pipeline

    private struct FaceSample {
        let face: CIImage   // aligned, square, inputSize × inputSize, origin at (0, 0)
        let quality: Float
        let info: FaceInfo
    }

    /// Finds the largest face, levels the eyes and crops a square grayscale face image.
    private func alignedFace(in image: CGImage) -> FaceSample? {
        let handler = VNImageRequestHandler(cgImage: image)
        let landmarksRequest = VNDetectFaceLandmarksRequest()
        #if targetEnvironment(simulator)
        landmarksRequest.usesCPUOnly = true // the Simulator has no Neural Engine
        #endif
        do {
            try handler.perform([landmarksRequest])
        } catch {
            print("⚠️ Face detection failed: \(error.localizedDescription)")
            return nil
        }
        guard let face = landmarksRequest.results?.max(by: {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }) else { return nil }

        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        qualityRequest.inputFaceObservations = [face]
        try? handler.perform([qualityRequest])
        let quality = qualityRequest.results?.first?.faceCaptureQuality ?? 0

        // Vision and Core Image both use a bottom-left origin, so no flipping is needed.
        let size = CGSize(width: image.width, height: image.height)
        let box = VNImageRectForNormalizedRect(face.boundingBox, image.width, image.height)

        var angle: CGFloat = 0
        var eyeOpenness: Float?
        if let left = face.landmarks?.leftEye?.pointsInImage(imageSize: size), !left.isEmpty,
           let right = face.landmarks?.rightEye?.pointsInImage(imageSize: size), !right.isEmpty {
            eyeOpenness = (openness(left) + openness(right)) / 2
            let a = centroid(left), b = centroid(right)
            var dx = b.x - a.x, dy = b.y - a.y
            if dx < 0 { dx = -dx; dy = -dy } // always measure left-to-right in the image
            angle = atan2(dy, dx)
        }

        let side = max(box.width, box.height) * 1.15
        let scale = inputSize / side
        let transform = CGAffineTransform(translationX: -box.midX, y: -box.midY)
            .concatenating(CGAffineTransform(rotationAngle: -angle))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: inputSize / 2, y: inputSize / 2))
        let aligned = CIImage(cgImage: image)
            .clampedToExtent() // fill any area outside the photo with edge pixels, not black
            .transformed(by: transform)
            .cropped(to: CGRect(x: 0, y: 0, width: inputSize, height: inputSize))
            // Grayscale, so skin tone under different lighting matters less.
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])

        return FaceSample(face: aligned, quality: quality,
                          info: FaceInfo(boundingBox: face.boundingBox, eyeOpenness: eyeOpenness))
    }

    private func mirror(_ face: CIImage) -> CIImage {
        face.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -inputSize, y: 0))
    }

    /// Runs Apple's image feature print on the face and returns it as a unit-length list of numbers.
    private func embedding(of face: CIImage) -> [Float]? {
        guard let cgImage = ciContext.createCGImage(face, from: face.extent) else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        #if targetEnvironment(simulator)
        request.usesCPUOnly = true // the Simulator has no Neural Engine
        #endif
        do {
            try VNImageRequestHandler(cgImage: cgImage).perform([request])
        } catch {
            print("⚠️ Feature print failed: \(error.localizedDescription)")
            return nil
        }
        guard let observation = request.results?.first, observation.elementType == .float else {
            print("⚠️ Feature print returned no result")
            return nil
        }

        let values = observation.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? values.map { $0 / norm } : nil
    }

    private func distance(_ a: [Float], _ b: [Float]) -> Float {
        sqrt(zip(a, b).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) })
    }

    /// Eye outline height ÷ width: about 0.3 when open, close to 0.1 when shut.
    private func openness(_ eye: [CGPoint]) -> Float {
        let xs = eye.map(\.x), ys = eye.map(\.y)
        let width = (xs.max() ?? 0) - (xs.min() ?? 0)
        let height = (ys.max() ?? 0) - (ys.min() ?? 0)
        return width > 0 ? Float(height / width) : 0
    }

    private func centroid(_ points: [CGPoint]) -> CGPoint {
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    // MARK: - Persistence

    private func save() {
        let snapshot = lock.withLock { known }
        do {
            try JSONEncoder().encode(snapshot).write(to: storeURL, options: .atomic)
        } catch {
            print("⚠️ Could not save faces: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let stored = try? JSONDecoder().decode([String: [[Float]]].self, from: data)
        else {
            print("📂 No saved faces yet. Add each person (tap “Add face” 1–2 times each).")
            return
        }
        known = stored
        print("📂 Loaded \(stored.count) known people: \(stored.keys.sorted().joined(separator: ", "))")
    }
}

extension UIImage {
    /// A CGImage with the orientation baked in, so Vision sees the face upright.
    var uprightCGImage: CGImage? {
        if imageOrientation == .up, let cgImage { return cgImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in draw(at: .zero) }.cgImage
    }
}
