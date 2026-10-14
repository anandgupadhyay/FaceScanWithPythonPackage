import AVFoundation
import CoreGraphics

/// Tells a real, three-dimensional face apart from a flat photo or screen, using the
/// TrueDepth (Face ID) camera's depth map.
///
/// A real face is not flat: the nose is closer to the camera than the cheeks, and the sides
/// curve away. A printed photo or a phone screen is a flat surface. We fit a flat plane to the
/// depth values on the face and measure how far the face sticks out from that plane.
enum DepthLiveness {
    enum Result {
        case live(reliefMM: Float, distanceM: Float)
        case flat(reliefMM: Float, distanceM: Float)
        /// Not enough usable depth on the face (too close/far, or a shiny screen with holes).
        case unknown
    }

    /// A face must stick out from a flat plane by at least this much (RMS, millimetres).
    /// A real face measures roughly 6–12 mm; a flat photo roughly 1–2 mm.
    static var minReliefMM: Float = 4

    /// - Parameters:
    ///   - depth: depth data from the same moment as the video frame.
    ///   - faceBox: the face's bounding box from Vision (normalized, origin bottom-left) in the
    ///     upright, mirrored video frame.
    /// How the raw depth map must be turned to line up with the upright, mirrored video frame.
    static var orientation: CGImagePropertyOrientation = .leftMirrored

    static func check(depth: AVDepthData, faceBox: CGRect) -> Result {
        check(depth: depth, faceBox: faceBox, orientation: orientation)
    }

    /// One line comparing every portrait orientation, to confirm `orientation` is the right one.
    static func diagnostics(depth: AVDepthData, faceBox: CGRect) -> String {
        let candidates: [(String, CGImagePropertyOrientation)] = [
            ("leftMirrored", .leftMirrored), ("rightMirrored", .rightMirrored), ("left", .left), ("right", .right)]
        return candidates.map { name, orientation in
            switch check(depth: depth, faceBox: faceBox, orientation: orientation) {
            case .live(let relief, let distance), .flat(let relief, let distance):
                return String(format: "%@ %.1fmm@%.2fm", name, relief, distance)
            case .unknown:
                return "\(name) n/a"
            }
        }.joined(separator: " | ")
    }

    private static func check(depth: AVDepthData, faceBox: CGRect,
                              orientation: CGImagePropertyOrientation) -> Result {
        // Rotate/mirror the depth map the same way the video frames are (portrait, mirrored).
        let map = depth.applyingExifOrientation(orientation)
            .converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
            .depthDataMap

        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return .unknown }
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)

        // Sample a grid over the middle of the face, away from hair and background.
        let area = faceBox.insetBy(dx: faceBox.width * 0.15, dy: faceBox.height * 0.15)
        let grid = 24
        var points: [(x: Float, y: Float, z: Float)] = []
        points.reserveCapacity(grid * grid)
        for iy in 0..<grid {
            for ix in 0..<grid {
                let nx = area.minX + area.width * (CGFloat(ix) + 0.5) / CGFloat(grid)
                let ny = 1 - (area.minY + area.height * (CGFloat(iy) + 0.5) / CGFloat(grid)) // to top-left origin
                let px = Int(nx * CGFloat(width)), py = Int(ny * CGFloat(height))
                guard px >= 0, px < width, py >= 0, py < height else { continue }
                let z = base.advanced(by: py * rowBytes).assumingMemoryBound(to: Float32.self)[px]
                guard z.isFinite, z > 0.1, z < 1.5 else { continue } // metres
                points.append((Float(nx), Float(ny), z))
            }
        }
        guard points.count >= grid * grid * 6 / 10 else { return .unknown }

        // Drop anything far behind/in front of the face (background seen past the cheeks).
        let median = points.map(\.z).sorted()[points.count / 2]
        points.removeAll { abs($0.z - median) > 0.12 }
        guard points.count >= grid * grid / 2 else { return .unknown }

        guard let rms = planeFitResidual(points) else { return .unknown }
        let reliefMM = rms * 1000
        return reliefMM >= minReliefMM ? .live(reliefMM: reliefMM, distanceM: median)
                                       : .flat(reliefMM: reliefMM, distanceM: median)
    }

    /// Least-squares fit of z = a·x + b·y + c; returns the RMS distance of the points from that plane.
    private static func planeFitResidual(_ points: [(x: Float, y: Float, z: Float)]) -> Float? {
        var sxx: Double = 0, sxy: Double = 0, sx: Double = 0, syy: Double = 0, sy: Double = 0
        var sxz: Double = 0, syz: Double = 0, sz: Double = 0
        let n = Double(points.count)
        for p in points {
            let x = Double(p.x), y = Double(p.y), z = Double(p.z)
            sxx += x * x; sxy += x * y; sx += x; syy += y * y; sy += y
            sxz += x * z; syz += y * z; sz += z
        }
        // Solve the 3×3 normal equations with Cramer's rule.
        func det(_ m: [Double]) -> Double {
            m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) + m[2] * (m[3] * m[7] - m[4] * m[6])
        }
        let d = det([sxx, sxy, sx, sxy, syy, sy, sx, sy, n])
        guard abs(d) > 1e-12 else { return nil }
        let a = det([sxz, sxy, sx, syz, syy, sy, sz, sy, n]) / d
        let b = det([sxx, sxz, sx, sxy, syz, sy, sx, sz, n]) / d
        let c = det([sxx, sxy, sxz, sxy, syy, syz, sx, sy, sz]) / d

        let squared = points.reduce(0.0) { sum, p in
            let r = Double(p.z) - (a * Double(p.x) + b * Double(p.y) + c)
            return sum + r * r
        }
        return Float((squared / n).squareRoot())
    }
}

/// Fallback for cameras without depth: the person must close their eyes and open them again.
/// A printed photo cannot do that.
final class BlinkDetector {
    private(set) var hasBlinked = false
    private var openBaseline: Float = 0
    private var sawClosed = false

    /// - Parameter eyeOpenness: eye height ÷ eye width, averaged over both eyes.
    func update(eyeOpenness: Float) {
        guard !hasBlinked else { return }
        openBaseline = max(openBaseline, eyeOpenness)
        guard openBaseline > 0 else { return }
        // "Closed" and "open" are measured against this person's own widest-open value.
        if eyeOpenness < openBaseline * 0.55 {
            sawClosed = true
        } else if sawClosed, eyeOpenness > openBaseline * 0.8 {
            hasBlinked = true
        }
    }

    func reset() {
        hasBlinked = false
        openBaseline = 0
        sawClosed = false
    }
}
