import AVFoundation
import CoreImage

/// Owns the front camera. Knows nothing about faces: it only hands out frames.
final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    /// All camera work, and every `onFrame` call, happens on this queue.
    let queue = DispatchQueue(label: "camera.video")

    /// Called on `queue` about every `frameInterval` seconds with an upright, mirrored frame.
    var onFrame: ((CGImage) -> Void)?
    /// Called when there is no camera or permission was denied.
    var onUnavailable: ((String) -> Void)?
    var frameInterval: TimeInterval = 0.4

    private let ciContext = CIContext()
    private var lastFrameTime = Date.distantPast

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else {
                self.onUnavailable?("Camera permission denied.")
                return
            }
            self.queue.async { self.configureAndRun() }
        }
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    private func configureAndRun() {
        if session.inputs.isEmpty {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input)
            else {
                onUnavailable?("No camera available (Simulator?). Use “Scan photo” instead.")
                return
            }
            session.beginConfiguration()
            session.sessionPreset = .high
            session.addInput(input)

            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
            if let connection = output.connection(with: .video) {
                // Deliver portrait, mirrored frames so they match what the user sees.
                if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                if connection.isVideoMirroringSupported { connection.isVideoMirrored = true }
            }
            session.commitConfiguration()
        }
        session.startRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard Date().timeIntervalSince(lastFrameTime) > frameInterval,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let frame = ciContext.createCGImage(image, from: image.extent) else { return }
        lastFrameTime = Date()
        onFrame?(frame)
    }
}
