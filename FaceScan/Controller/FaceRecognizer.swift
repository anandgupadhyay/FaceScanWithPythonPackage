import Vision
import CoreML
import UIKit
import CoreImage

/// Recognizes people with FaceNet, a neural network trained specifically to tell faces apart.
///
/// Each face is checked for quality, rotated so the eyes are level, cropped, and turned into a
/// 512-number "embedding". Embeddings of the same person are close together; different people
/// are far apart. A new face is compared with every saved (old) photo of each person, and the
/// name is only reported when the match is at least `minConfidence` (95%).
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

    /// The name is shown only when the match is at least this sure (0.95 = 95%).
    var minConfidence: Float = 0.95
    /// Vision's face capture quality (0…1). Faces below this are ignored by the live camera.
    var minQuality: Float = 0.25

    private var known: [String: [[Float]]] = [:]
    private let lock = NSLock()
    private let ciContext = CIContext()
    private let model: VNCoreMLModel
    private let inputSize: CGFloat = 160
    private let storeURL = URL.documentsDirectory.appending(path: "faces_facenet.json")

    private init() {
        let config = MLModelConfiguration()
        #if targetEnvironment(simulator)
        config.computeUnits = .cpuOnly // the Simulator can't run the model on the GPU / Neural Engine
        #else
        config.computeUnits = .all
        #endif
        model = try! VNCoreMLModel(for: FaceNet(configuration: config).model)
        load()
    }

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

    enum Verification {
        case noFace
        case lowQuality(quality: Float)
        case score(Float)
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
        return .score(Self.confidence(forDistance: closest))
    }

    /// Turns an embedding distance into a 0…1 match score.
    /// FaceNet (VGGFace2) treats ~1.05 as the 50/50 point; 95% needs a distance of about 0.8 or less.
    static func confidence(forDistance d: Float) -> Float {
        1 / (1 + exp(12 * (d - 1.05)))
    }

    // MARK: - Face pipeline

    private struct FaceSample {
        let face: CIImage   // aligned, square, inputSize × inputSize, origin at (0, 0)
        let quality: Float
    }

    /// Finds the largest face, levels the eyes and crops a square face image for FaceNet.
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
        if let left = face.landmarks?.leftEye?.pointsInImage(imageSize: size), !left.isEmpty,
           let right = face.landmarks?.rightEye?.pointsInImage(imageSize: size), !right.isEmpty {
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

        return FaceSample(face: aligned, quality: quality)
    }

    private func mirror(_ face: CIImage) -> CIImage {
        face.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -inputSize, y: 0))
    }

    /// Runs FaceNet and returns a unit-length 512-number embedding.
    private func embedding(of face: CIImage) -> [Float]? {
        guard let cgImage = ciContext.createCGImage(face, from: face.extent) else { return nil }
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        do {
            try VNImageRequestHandler(cgImage: cgImage).perform([request])
        } catch {
            print("⚠️ FaceNet model failed to run: \(error.localizedDescription)")
            return nil
        }
        guard let array = (request.results?.first as? VNCoreMLFeatureValueObservation)?
            .featureValue.multiArrayValue else {
            print("⚠️ FaceNet model returned no result")
            return nil
        }

        let values = (0..<array.count).map { array[$0].floatValue }
        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? values.map { $0 / norm } : nil
    }

    private func distance(_ a: [Float], _ b: [Float]) -> Float {
        sqrt(zip(a, b).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) })
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
