// Copyright 2026 Voxelio.
// Licensed under the PolyForm Noncommercial License 1.0.0.

import ARKit
import CoreImage
import ImageIO
import RealityKit
import SwiftUI
import UIKit
import simd

struct GaussianCaptureView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var library: LocalGaussianLibrary
    let onComplete: (LocalGaussianAsset) -> Void

    @State private var isRecording = false
    @State private var isFinishing = false
    @State private var frameCount = 0
    @State private var pointCount = 0
    @State private var status = "Move around the subject and keep it in view."
    @State private var errorMessage: String?
    @State private var asksToDiscard = false

    var body: some View {
        Group {
            if ARWorldTrackingConfiguration.isSupported {
                camera
            } else {
                ContentUnavailableView(
                    "ARKit unavailable",
                    systemImage: "arkit",
                    description: Text("Run this capture flow on a supported physical iPhone or iPad.")
                )
            }
        }
        .background(Color.black)
        .alert("Discard capture?", isPresented: $asksToDiscard) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep capturing", role: .cancel) {}
        } message: {
            Text("The captured camera views will be deleted.")
        }
        .alert("Capture failed", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "The capture could not be saved.")
        }
    }

    private var camera: some View {
        ZStack {
            LocalGaussianCameraSurface(
                shouldRecord: isRecording,
                seedDensity: 100,
                minimumConfidence: 1,
                maximumDepth: 5,
                onProgress: receive,
                onFinish: finish
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                captureHeader
                Spacer()
                captureControls
            }
        }
        .persistentSystemOverlays(.hidden)
    }

    private var captureHeader: some View {
        HStack(spacing: 12) {
            Button {
                if isRecording {
                    asksToDiscard = true
                } else if !isFinishing {
                    dismiss()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .disabled(isFinishing)

            VStack(alignment: .leading, spacing: 2) {
                Text("Gaussian capture")
                    .font(.headline)
                Text(captureStateLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isRecording || isFinishing {
                Label(frameCount.formatted(), systemImage: "photo.stack.fill")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var captureControls: some View {
        VStack(spacing: 14) {
            if isRecording || isFinishing {
                ProgressView(
                    value: Double(min(frameCount, GaussianCaptureWriter.minimumFrames)),
                    total: Double(GaussianCaptureWriter.minimumFrames)
                )
                .tint(canFinish ? .green : .white)

                HStack {
                    Label("\(frameCount) views", systemImage: "camera.fill")
                    Spacer()
                    Label("\(pointCount) seeds", systemImage: "circle.grid.3x3.fill")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Text(status)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(action: toggleCapture) {
                ZStack {
                    Circle()
                        .stroke(.white, lineWidth: 4)
                        .frame(width: 72, height: 72)

                    if isFinishing {
                        ProgressView()
                            .tint(.white)
                    } else if isRecording {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(.red)
                            .frame(width: 30, height: 30)
                    } else {
                        Circle()
                            .fill(.red)
                            .frame(width: 58, height: 58)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isFinishing || (isRecording && !canFinish))
            .opacity(isRecording && !canFinish ? 0.55 : 1)
            .accessibilityLabel(isRecording ? "Finish capture" : "Start capture")
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

    private var canFinish: Bool {
        frameCount >= GaussianCaptureWriter.minimumFrames
    }

    private var captureStateLabel: String {
        if isFinishing { return "Saving dataset" }
        if isRecording { return "Recording views" }
        return "Ready"
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func toggleCapture() {
        if isRecording {
            guard canFinish else { return }
            status = "Writing transforms and seed cloud…"
            isFinishing = true
            isRecording = false
        } else {
            frameCount = 0
            pointCount = 0
            status = "Move steadily around the subject."
            isRecording = true
        }
    }

    private func receive(_ progress: GaussianCaptureProgress) {
        frameCount = progress.frameCount
        pointCount = progress.pointCount
        status = progress.message
    }

    private func finish(_ result: Result<LocalGaussianCapturePackage, Error>) {
        isRecording = false
        isFinishing = false

        switch result {
        case .success(let package):
            do {
                let asset = try library.importCapture(package)
                onComplete(asset)
            } catch {
                status = "Ready to try again."
                errorMessage = error.localizedDescription
            }
        case .failure(let error):
            status = "Ready to try again."
            errorMessage = error.localizedDescription
        }
    }
}

private struct LocalGaussianCameraSurface: UIViewRepresentable {
    let shouldRecord: Bool
    let seedDensity: Float
    let minimumConfidence: Int
    let maximumDepth: Float
    let onProgress: (GaussianCaptureProgress) -> Void
    let onFinish: (Result<LocalGaussianCapturePackage, Error>) -> Void

    func makeCoordinator() -> GaussianARCaptureCoordinator {
        GaussianARCaptureCoordinator(onProgress: onProgress, onFinish: onFinish)
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        context.coordinator.attach(to: view.session)

        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.isAutoFocusEnabled = true
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        view.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.onProgress = onProgress
        context.coordinator.onFinish = onFinish
        context.coordinator.configureSeedCloud(
            density: seedDensity,
            minimumConfidence: minimumConfidence,
            maximumDepth: maximumDepth
        )
        context.coordinator.setRecording(shouldRecord)
    }

    static func dismantleUIView(_ view: ARView, coordinator: GaussianARCaptureCoordinator) {
        coordinator.cancel()
        view.session.pause()
        view.session.delegate = nil
    }
}

private nonisolated struct GaussianCaptureProgress: Sendable {
    let frameCount: Int
    let pointCount: Int
    let message: String
}

private nonisolated final class GaussianARCaptureCoordinator: NSObject, ARSessionDelegate, @unchecked Sendable {
    var onProgress: (GaussianCaptureProgress) -> Void
    var onFinish: (Result<LocalGaussianCapturePackage, Error>) -> Void

    private enum Mode {
        case idle
        case recording
        case finishing
    }

    private let cameraQueue = DispatchQueue(label: "com.voxelio.gaussian.camera", qos: .userInitiated)
    private let writerQueue = DispatchQueue(label: "com.voxelio.gaussian.writer", qos: .userInitiated)
    private let snapshotBuilder = GaussianFrameSnapshotBuilder()

    private var mode: Mode = .idle
    private var writer: GaussianCaptureWriter?
    private var writePending = false
    private var previousPose: simd_float4x4?
    private var previousTimestamp: TimeInterval = 0
    private var acceptedFrames = 0
    private var acceptedPoints = 0
    private var seedDensity: Float = 100
    private var minimumConfidence = 2
    private var maximumDepth: Float = 5

    init(
        onProgress: @escaping (GaussianCaptureProgress) -> Void,
        onFinish: @escaping (Result<LocalGaussianCapturePackage, Error>) -> Void
    ) {
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    func attach(to session: ARSession) {
        session.delegate = self
        session.delegateQueue = cameraQueue
    }

    func setRecording(_ shouldRecord: Bool) {
        cameraQueue.async { [weak self] in
            guard let self else { return }
            switch (mode, shouldRecord) {
            case (.idle, true):
                start()
            case (.recording, false):
                finish()
            default:
                break
            }
        }
    }

    func configureSeedCloud(density: Float, minimumConfidence: Int, maximumDepth: Float) {
        cameraQueue.async { [weak self] in
            self?.seedDensity = min(max(density, 10), 500)
            self?.minimumConfidence = min(max(minimumConfidence, 0), 2)
            self?.maximumDepth = min(max(maximumDepth, 0.5), 10)
        }
    }

    func cancel() {
        cameraQueue.async { [weak self] in
            guard let self else { return }
            let abandoned = writer
            mode = .idle
            writer = nil
            writerQueue.async {
                abandoned?.discard()
            }
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        autoreleasepool {
            guard mode == .recording,
                  !writePending,
                  frame.camera.trackingState.isCaptureReady,
                  shouldAccept(frame)
            else {
                return
            }

            guard let snapshot = snapshotBuilder.copySnapshot(
                from: frame,
                seedDensity: seedDensity,
                minimumConfidence: minimumConfidence,
                maximumDepth: maximumDepth
            ) else {
                report("Waiting for a stable camera image.")
                return
            }

            // Only value data leaves this delegate callback. Neither ARFrame nor its
            // camera CVPixelBuffers are retained by the writer queue.
            previousPose = frame.camera.transform
            previousTimestamp = frame.timestamp
            writePending = true
            let nextIndex = acceptedFrames
            let destination = writer

            writerQueue.async { [weak self] in
                do {
                    try destination?.append(snapshot, index: nextIndex)
                    self?.cameraQueue.async { [weak self] in
                        guard let self, mode == .recording else { return }
                        acceptedFrames += 1
                        acceptedPoints += snapshot.points.count
                        writePending = false
                        report("View \(acceptedFrames) saved. Keep moving steadily.")
                    }
                } catch {
                    self?.cameraQueue.async { [weak self] in
                        self?.writePending = false
                        self?.abort(with: error)
                    }
                }
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        cameraQueue.async { [weak self] in
            guard self?.mode == .recording else { return }
            self?.abort(with: error)
        }
    }

    private func start() {
        do {
            writer = try GaussianCaptureWriter(seedDensity: seedDensity)
            previousPose = nil
            previousTimestamp = 0
            acceptedFrames = 0
            acceptedPoints = 0
            writePending = false
            mode = .recording
            report("Move steadily around the subject.")
        } catch {
            abort(with: error)
        }
    }

    private func finish() {
        guard let writer else { return }
        mode = .finishing
        self.writer = nil

        writerQueue.async { [weak self] in
            do {
                let package = try writer.finish()
                self?.cameraQueue.async { [weak self] in
                    self?.mode = .idle
                    self?.deliver(.success(package))
                }
            } catch {
                writer.discard()
                self?.cameraQueue.async { [weak self] in
                    self?.mode = .idle
                    self?.deliver(.failure(error))
                }
            }
        }
    }

    private func abort(with error: Error) {
        let abandoned = writer
        writer = nil
        mode = .idle
        writerQueue.async {
            abandoned?.discard()
        }
        deliver(.failure(error))
    }

    private func shouldAccept(_ frame: ARFrame) -> Bool {
        guard let previousPose else { return true }
        guard frame.timestamp - previousTimestamp >= 0.32 else { return false }

        let oldPosition = SIMD3<Float>(previousPose.columns.3.x, previousPose.columns.3.y, previousPose.columns.3.z)
        let newPosition = SIMD3<Float>(frame.camera.transform.columns.3.x, frame.camera.transform.columns.3.y, frame.camera.transform.columns.3.z)
        let translation = simd_distance(oldPosition, newPosition)

        let oldForward = -SIMD3<Float>(previousPose.columns.2.x, previousPose.columns.2.y, previousPose.columns.2.z)
        let newForward = -SIMD3<Float>(frame.camera.transform.columns.2.x, frame.camera.transform.columns.2.y, frame.camera.transform.columns.2.z)
        let cosine = simd_clamp(simd_dot(simd_normalize(oldForward), simd_normalize(newForward)), -1, 1)
        let angle = acosf(cosine)
        return translation >= 0.055 || angle >= 0.09
    }

    private func report(_ message: String) {
        let progress = GaussianCaptureProgress(
            frameCount: acceptedFrames,
            pointCount: acceptedPoints,
            message: message
        )
        DispatchQueue.main.async { [weak self] in
            self?.onProgress(progress)
        }
    }

    private func deliver(_ result: Result<LocalGaussianCapturePackage, Error>) {
        DispatchQueue.main.async { [weak self] in
            self?.onFinish(result)
        }
    }
}

private nonisolated struct GaussianFrameSnapshot: Sendable {
    let jpeg: Data
    let width: Int
    let height: Int
    let fx: Float
    let fy: Float
    let cx: Float
    let cy: Float
    let cameraToWorldRows: [[Float]]
    let points: [GaussianSeedPoint]
}

private nonisolated struct GaussianSeedPoint: Sendable {
    let position: SIMD3<Float>
    let luminance: UInt8
}

private nonisolated final class GaussianFrameSnapshotBuilder: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func copySnapshot(
        from frame: ARFrame,
        seedDensity: Float,
        minimumConfidence: Int,
        maximumDepth: Float
    ) -> GaussianFrameSnapshot? {
        let pixelBuffer = frame.capturedImage
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let jpeg = context.jpegRepresentation(
            of: image,
            colorSpace: colorSpace,
            options: [
                CIImageRepresentationOption(
                    rawValue: kCGImageDestinationLossyCompressionQuality as String
                ): 0.88
            ]
        ) else {
            return nil
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let intrinsics = frame.camera.intrinsics
        let pose = frame.camera.transform
        return GaussianFrameSnapshot(
            jpeg: jpeg,
            width: width,
            height: height,
            fx: intrinsics.columns.0.x,
            fy: intrinsics.columns.1.y,
            cx: intrinsics.columns.2.x,
            cy: intrinsics.columns.2.y,
            cameraToWorldRows: pose.rowMajorValues,
            points: copySeedPoints(
                depth: frame.smoothedSceneDepth ?? frame.sceneDepth,
                image: pixelBuffer,
                intrinsics: intrinsics,
                cameraToWorld: pose,
                seedDensity: seedDensity,
                minimumConfidence: minimumConfidence,
                maximumDepth: maximumDepth
            )
        )
    }

    private func copySeedPoints(
        depth: ARDepthData?,
        image: CVPixelBuffer,
        intrinsics: simd_float3x3,
        cameraToWorld: simd_float4x4,
        seedDensity: Float,
        minimumConfidence: Int,
        maximumDepth: Float
    ) -> [GaussianSeedPoint] {
        guard let depth else { return [] }
        let map = depth.depthMap
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32 else {
            return []
        }

        CVPixelBufferLockBaseAddress(map, .readOnly)
        CVPixelBufferLockBaseAddress(image, .readOnly)
        if let confidence = depth.confidenceMap {
            CVPixelBufferLockBaseAddress(confidence, .readOnly)
        }
        defer {
            if let confidence = depth.confidenceMap {
                CVPixelBufferUnlockBaseAddress(confidence, .readOnly)
            }
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
            CVPixelBufferUnlockBaseAddress(map, .readOnly)
        }

        guard let depthBase = CVPixelBufferGetBaseAddress(map)?.assumingMemoryBound(to: Float32.self) else {
            return []
        }

        let depthWidth = CVPixelBufferGetWidth(map)
        let depthHeight = CVPixelBufferGetHeight(map)
        let depthStride = CVPixelBufferGetBytesPerRow(map) / MemoryLayout<Float32>.stride
        let imageWidth = CVPixelBufferGetWidth(image)
        let imageHeight = CVPixelBufferGetHeight(image)
        let densityScale = Double(min(max(seedDensity, 10), 500)) / 100
        let targetSamples = min(max(Int(900 * densityScale), 225), 4_500)
        let step = max(2, Int(sqrt(Double(depthWidth * depthHeight) / Double(targetSamples))))
        let confidenceThreshold = UInt8(min(max(minimumConfidence, 0), 2))
        let depthLimit = min(max(maximumDepth, 0.5), 10)

        let confidenceBase = depth.confidenceMap.flatMap {
            CVPixelBufferGetBaseAddress($0)?.assumingMemoryBound(to: UInt8.self)
        }
        let confidenceStride = depth.confidenceMap.map(CVPixelBufferGetBytesPerRow) ?? 0

        let lumaBase: UnsafeMutablePointer<UInt8>? = {
            guard CVPixelBufferGetPlaneCount(image) > 0 else { return nil }
            return CVPixelBufferGetBaseAddressOfPlane(image, 0)?.assumingMemoryBound(to: UInt8.self)
        }()
        let lumaStride = CVPixelBufferGetPlaneCount(image) > 0 ? CVPixelBufferGetBytesPerRowOfPlane(image, 0) : 0

        var result: [GaussianSeedPoint] = []
        result.reserveCapacity(targetSamples)
        for y in stride(from: step / 2, to: depthHeight, by: step) {
            for x in stride(from: step / 2, to: depthWidth, by: step) {
                if let confidenceBase,
                   confidenceBase[y * confidenceStride + x] < confidenceThreshold {
                    continue
                }
                let z = depthBase[y * depthStride + x]
                guard z.isFinite, z >= 0.18, z <= depthLimit else { continue }

                let imageX = Float(x) * Float(imageWidth) / Float(depthWidth)
                let imageY = Float(y) * Float(imageHeight) / Float(depthHeight)
                let cameraX = (imageX - intrinsics.columns.2.x) * z / intrinsics.columns.0.x
                let cameraY = (intrinsics.columns.2.y - imageY) * z / intrinsics.columns.1.y
                let world = cameraToWorld * SIMD4<Float>(cameraX, cameraY, -z, 1)

                let sampleX = min(max(Int(imageX), 0), imageWidth - 1)
                let sampleY = min(max(Int(imageY), 0), imageHeight - 1)
                let luminance = lumaBase.map { $0[sampleY * lumaStride + sampleX] } ?? 160
                result.append(
                    GaussianSeedPoint(
                        position: SIMD3<Float>(world.x, world.y, world.z),
                        luminance: luminance
                    )
                )
            }
        }
        return result
    }
}

private nonisolated final class GaussianCaptureWriter: @unchecked Sendable {
    nonisolated static let minimumFrames = 5

    private struct Voxel: Hashable {
        let x: Int
        let y: Int
        let z: Int

        init(_ point: SIMD3<Float>, density: Float) {
            let scale = min(max(density, 10), 500)
            x = Int(floor(point.x * scale))
            y = Int(floor(point.y * scale))
            z = Int(floor(point.z * scale))
        }
    }

    private struct DatasetFrame: Encodable {
        let filePath: String
        let transformMatrix: [[Float]]

        enum CodingKeys: String, CodingKey {
            case filePath = "file_path"
            case transformMatrix = "transform_matrix"
        }
    }

    private struct DatasetManifest: Encodable {
        let cameraModel = "OPENCV"
        let flX: Float
        let flY: Float
        let cx: Float
        let cy: Float
        let width: Int
        let height: Int
        let plyFilePath: String?
        let frames: [DatasetFrame]

        enum CodingKeys: String, CodingKey {
            case cameraModel = "camera_model"
            case flX = "fl_x"
            case flY = "fl_y"
            case cx
            case cy
            case width = "w"
            case height = "h"
            case plyFilePath = "ply_file_path"
            case frames
        }
    }

    private let rootURL: URL
    private let imagesURL: URL
    private let seedDensity: Float
    private var frames: [DatasetFrame] = []
    private var seedPoints: [Voxel: GaussianSeedPoint] = [:]
    private var reference: GaussianFrameSnapshot?

    init(seedDensity: Float) throws {
        self.seedDensity = min(max(seedDensity, 10), 500)
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Voxelio-Gaussian-\(UUID().uuidString)", isDirectory: true)
        imagesURL = rootURL.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)
    }

    func append(_ snapshot: GaussianFrameSnapshot, index: Int) throws {
        let name = String(format: "frame_%05d.jpg", index)
        try snapshot.jpeg.write(to: imagesURL.appendingPathComponent(name), options: .atomic)
        if reference == nil {
            reference = snapshot
            try snapshot.jpeg.write(to: rootURL.appendingPathComponent("thumbnail.jpg"), options: .atomic)
        }
        frames.append(
            DatasetFrame(
                filePath: "images/\(name)",
                transformMatrix: snapshot.cameraToWorldRows
            )
        )
        for point in snapshot.points {
            seedPoints[Voxel(point.position, density: seedDensity)] = point
        }
    }

    func finish() throws -> LocalGaussianCapturePackage {
        guard frames.count >= Self.minimumFrames else {
            throw GaussianCaptureError.notEnoughFrames(captured: frames.count)
        }
        guard let reference else { throw GaussianCaptureError.emptyCapture }

        let hasSeeds = !seedPoints.isEmpty
        if hasSeeds {
            try writePLY(Array(seedPoints.values), to: rootURL.appendingPathComponent("points3D.ply"))
        }
        let manifest = DatasetManifest(
            flX: reference.fx,
            flY: reference.fy,
            cx: reference.cx,
            cy: reference.cy,
            width: reference.width,
            height: reference.height,
            plyFilePath: hasSeeds ? "points3D.ply" : nil,
            frames: frames
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: rootURL.appendingPathComponent("transforms.json"),
            options: .atomic
        )
        return LocalGaussianCapturePackage(
            temporaryURL: rootURL,
            sampleCount: frames.count,
            seedPointCount: seedPoints.count
        )
    }

    func discard() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func writePLY(_ points: [GaussianSeedPoint], to url: URL) throws {
        var text = "ply\nformat ascii 1.0\nelement vertex \(points.count)\n"
        text += "property float x\nproperty float y\nproperty float z\n"
        text += "property uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n"
        text.reserveCapacity(text.count + points.count * 52)
        for point in points {
            let p = point.position
            let c = point.luminance
            text += "\(p.x) \(p.y) \(p.z) \(c) \(c) \(c)\n"
        }
        guard let data = text.data(using: .utf8) else { throw GaussianCaptureError.cannotEncodePointCloud }
        try data.write(to: url, options: .atomic)
    }
}

private nonisolated enum GaussianCaptureError: LocalizedError {
    case emptyCapture
    case notEnoughFrames(captured: Int)
    case cannotEncodePointCloud

    var errorDescription: String? {
        switch self {
        case .emptyCapture:
            return "No camera views were saved."
        case .notEnoughFrames(let captured):
            return "Capture at least \(GaussianCaptureWriter.minimumFrames) views before finishing. \(captured) captured."
        case .cannotEncodePointCloud:
            return "The LiDAR seed cloud could not be encoded."
        }
    }
}

private extension ARCamera.TrackingState {
    nonisolated var isCaptureReady: Bool {
        if case .normal = self { return true }
        return false
    }
}

private extension simd_float4x4 {
    nonisolated var rowMajorValues: [[Float]] {
        (0..<4).map { row in
            (0..<4).map { column in self[column][row] }
        }
    }
}
