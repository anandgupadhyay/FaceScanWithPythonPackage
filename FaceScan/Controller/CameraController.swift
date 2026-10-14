import AVFoundation
import CoreImage

/// Owns the front camera. Knows nothing about faces: it only hands out frames
/// (plus depth data, when the device has a TrueDepth / Face ID camera).
final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                              AVCaptureDataOutputSynchronizerDelegate {
    let session = AVCaptureSession()
    /// All camera work, and every `onFrame` call, happens on this queue.
    let queue = DispatchQueue(label: "camera.video")

    /// Called on `queue` about every `frameInterval` seconds with an upright, mirrored frame.
    /// `depth` is nil on devices without a TrueDepth camera.
    var onFrame: ((CGImage, AVDepthData?) -> Void)?
    /// Called when there is no camera or permission was denied.
    var onUnavailable: ((String) -> Void)?
    var frameInterval: TimeInterval = 0.4
    /// True once the session is delivering depth data alongside video.
    private(set) var hasDepth = false

    private let ciContext = CIContext()
    private var lastFrameTime = Date.distantPast
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private var synchronizer: AVCaptureDataOutputSynchronizer?

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
            let depthCamera = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front)
            guard let device = depthCamera
                    ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input)
            else {
                onUnavailable?("No camera available (Simulator?). Use “Scan photo” instead.")
                return
            }
            session.beginConfiguration()
            // Depth is only delivered for some video formats; 640×480 always supports it.
            session.sessionPreset = depthCamera != nil ? .vga640x480 : .high
            session.addInput(input)

            videoOutput.alwaysDiscardsLateVideoFrames = true
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
            if let connection = videoOutput.connection(with: .video) {
                // Deliver portrait, mirrored frames so they match what the user sees.
                if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                if connection.isVideoMirroringSupported { connection.isVideoMirrored = true }
            }

            if depthCamera != nil, session.canAddOutput(depthOutput) {
                session.addOutput(depthOutput)
                depthOutput.isFilteringEnabled = true // smooths noise and fills small holes
                depthOutput.alwaysDiscardsLateDepthData = true
                if depthOutput.connection(with: .depthData) != nil {
                    // Delivers each video frame together with the depth captured at the same moment.
                    let sync = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
                    sync.setDelegate(self, queue: queue)
                    synchronizer = sync
                    hasDepth = true
                }
            }
            if !hasDepth {
                videoOutput.setSampleBufferDelegate(self, queue: queue)
                frameInterval = 0.2 // scan faster so a blink isn't missed between frames
            }
            session.commitConfiguration()
            print(hasDepth ? "📷 Camera: TrueDepth (depth liveness check on)"
                           : "📷 Camera: no depth sensor (blink check on)")
        }
        session.startRunning()
    }

    // Video only (no depth camera).
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        deliver(sampleBuffer, depth: nil)
    }

    // Video + depth.
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput collection: AVCaptureSynchronizedDataCollection) {
        guard let video = collection.synchronizedData(for: videoOutput) as? AVCaptureSynchronizedSampleBufferData,
              !video.sampleBufferWasDropped,
              let depth = collection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData,
              !depth.depthDataWasDropped
        else { return }
        deliver(video.sampleBuffer, depth: depth.depthData)
    }

    private func deliver(_ sampleBuffer: CMSampleBuffer, depth: AVDepthData?) {
        guard Date().timeIntervalSince(lastFrameTime) > frameInterval,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let frame = ciContext.createCGImage(image, from: image.extent) else { return }
        lastFrameTime = Date()
        onFrame?(frame, depth)
    }
}
