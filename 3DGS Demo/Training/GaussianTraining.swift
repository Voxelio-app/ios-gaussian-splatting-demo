// Copyright 2026 Voxelio.
// Licensed under the PolyForm Noncommercial License 1.0.0.

import Combine
import Msplat
import SplatIO
import SwiftUI
import UIKit

private struct LocalGaussianTrainingPreviewFrame: @unchecked Sendable {
    let rgba: Data
    let width: Int
    let height: Int

    func makeImage() -> UIImage? {
        guard width > 0,
              height > 0,
              rgba.count == width * height * 4,
              let provider = CGDataProvider(data: rgba as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                    CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            return nil
        }
        return UIImage(cgImage: image)
    }
}

private final class LocalGaussianProgressRelay: @unchecked Sendable {
    nonisolated(unsafe) weak var processor: LocalGaussianProcessor?

    nonisolated init(_ processor: LocalGaussianProcessor) {
        self.processor = processor
    }

    nonisolated func publish(
        iteration: Int,
        splatCount: Int,
        preview: LocalGaussianTrainingPreviewFrame?
    ) {
        Task { @MainActor [weak processor] in
            processor?.acceptProgress(
                iteration: iteration,
                splatCount: splatCount,
                preview: preview
            )
        }
    }
}

enum LocalGaussianQuality: Int, CaseIterable, Identifiable, Codable, Comparable, Sendable {
    case preview = 1_000
    case balanced = 2_000
    case refined = 3_000
    case high = 4_000
    case maximum = 5_000

    nonisolated var id: Int { rawValue }
    nonisolated var iterations: Int { rawValue }

    nonisolated static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    nonisolated static let defaultSelection: Self = .balanced

    nonisolated static var maximumIterations: Int {
        Self.maximum.iterations
    }

    nonisolated static func extensionTargets(after completedIterations: Int) -> [Self] {
        allCases.filter { $0.iterations > completedIterations }
    }

    nonisolated var label: String {
        switch self {
        case .preview: return "1K"
        case .balanced: return "2K"
        case .refined: return "3K"
        case .high: return "4K"
        case .maximum: return "5K"
        }
    }

    nonisolated var detail: String {
        switch self {
        case .preview: return "Quick preview"
        case .balanced: return "Balanced"
        case .refined: return "More detail"
        case .high: return "High detail"
        case .maximum: return "Best local result"
        }
    }

    nonisolated var configuration: TrainingConfig {
        var value = TrainingConfig()
        value.iterations = Int32(iterations)
        value.shDegree = 3
        value.shDegreeInterval = 1_000
        value.ssimWeight = self >= .high ? 0.35 : 0.2
        value.downscaleFactor = 2
        value.numDownscales = self == .preview ? 1 : 2
        value.resolutionSchedule = 600
        value.refineEvery = 100
        value.warmupLength = 300
        value.resetAlphaEvery = 30
        value.densifyGradThresh = self >= .high ? 0.0002 : 0.0003
        value.densifySizeThresh = 0.01
        value.stopScreenSizeAt = 3_000
        value.splitScreenSize = 0.05
        value.bgColor = (0, 0, 0)
        return value
    }
}

@MainActor
final class LocalGaussianProcessor: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var completedIterations = 0
    @Published private(set) var splatCount = 0
    @Published private(set) var trainingPreviewImage: UIImage?
    @Published var quality: LocalGaussianQuality = .defaultSelection

    private var job: Task<Void, Never>?

    var isRunning: Bool {
        phase == .running
    }

    func synchronize(with asset: LocalGaussianAsset) {
        guard !isRunning else { return }
        if asset.stage == .failed, let failure = asset.failure {
            phase = .failed(failure)
        } else {
            phase = asset.hasSplat ? .ready : .idle
        }
        completedIterations = asset.completedSteps ?? 0
        trainingPreviewImage = nil

        if quality.iterations <= completedIterations {
            quality = LocalGaussianQuality.extensionTargets(after: completedIterations).first ?? .maximum
        }
    }

    fileprivate func acceptProgress(
        iteration: Int,
        splatCount: Int,
        preview: LocalGaussianTrainingPreviewFrame?
    ) {
        completedIterations = iteration
        self.splatCount = splatCount
        if let image = preview?.makeImage() {
            trainingPreviewImage = image
        }
    }

    func process(_ asset: LocalGaussianAsset, library: LocalGaussianLibrary) {
        guard !isRunning else { return }
        guard asset.hasSourceDataset else {
            phase = .failed("The original camera dataset is unavailable.")
            return
        }

        let selectedQuality = quality
        let startingIterations = asset.completedSteps ?? 0
        guard selectedQuality.iterations > startingIterations else {
            phase = .failed("Choose a target above the completed iteration count.")
            return
        }
        guard startingIterations == 0 || asset.hasTrainingCheckpoint else {
            phase = .failed("The saved training checkpoint is unavailable, so this result cannot be extended.")
            return
        }

        let previousOutputURL = asset.hasSplat ? asset.splatURL : nil
        let resumeCheckpointURL = startingIterations > 0 ? asset.checkpointURL : nil
        let outputURL = asset.splatURL(for: selectedQuality.iterations)
        let checkpointURL = asset.checkpointURL(for: selectedQuality.iterations)
        let inputURL = asset.folderURL
        library.beginProcessing(id: asset.id)
        phase = .running
        completedIterations = startingIterations
        splatCount = 0
        trainingPreviewImage = nil

        job?.cancel()
        let progressRelay = LocalGaussianProgressRelay(self)
        job = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                try await Self.runTraining(
                    datasetURL: inputURL,
                    outputURL: outputURL,
                    resumeCheckpointURL: resumeCheckpointURL,
                    outputCheckpointURL: checkpointURL,
                    quality: selectedQuality
                ) { iteration, count, preview in
                    progressRelay.publish(
                        iteration: iteration,
                        splatCount: count,
                        preview: preview
                    )
                }
            }
            let result = await withTaskCancellationHandler {
                await worker.result
            } onCancel: {
                worker.cancel()
            }

            guard let self, !Task.isCancelled else { return }
            switch result {
            case .success(let finalIteration):
                completedIterations = finalIteration
                phase = .ready
                if library.finishProcessing(id: asset.id, steps: finalIteration) {
                    Self.removeSupersededArtifact(previousOutputURL, replacingWith: outputURL)
                    Self.removeSupersededArtifact(resumeCheckpointURL, replacingWith: checkpointURL)
                } else {
                    phase = .failed("Training finished, but the updated result metadata could not be saved.")
                }
            case .failure(let error):
                phase = .failed(error.localizedDescription)
                trainingPreviewImage = nil
                library.failProcessing(id: asset.id, message: error.localizedDescription)
            }
            job = nil
        }
    }

    deinit {
        job?.cancel()
    }

    nonisolated private static func runTraining(
        datasetURL: URL,
        outputURL: URL,
        resumeCheckpointURL: URL?,
        outputCheckpointURL: URL,
        quality: LocalGaussianQuality,
        progress: @escaping @Sendable (Int, Int, LocalGaussianTrainingPreviewFrame?) -> Void
    ) async throws -> Int {
        let dataset = GaussianDataset(path: datasetURL.path, downscaleFactor: 2)
        guard dataset.numTrain >= GaussianCapturePolicy.minimumFrames else {
            throw LocalGaussianProcessingError.insufficientViews(dataset.numTrain)
        }

        let trainer = GaussianTrainer(dataset: dataset, config: quality.configuration)
        let startingIteration: Int
        if let resumeCheckpointURL {
            let savedIteration = try checkpointIteration(at: resumeCheckpointURL)
            guard savedIteration <= quality.iterations else {
                throw LocalGaussianProcessingError.checkpointAheadOfTarget(
                    checkpoint: savedIteration,
                    target: quality.iterations
                )
            }
            guard let loadedIteration = trainer.loadCheckpoint(from: resumeCheckpointURL.path),
                  loadedIteration == savedIteration else {
                throw LocalGaussianProcessingError.invalidCheckpoint
            }
            startingIteration = loadedIteration
        } else {
            startingIteration = 0
        }

        let previewCameraIndex = dataset.numTrain / 2
        var lastPreviewTime = -Double.infinity
        for index in startingIteration..<quality.iterations {
            if Task.isCancelled { throw CancellationError() }
            let stats = trainer.step()
            let isFinalIteration = index + 1 == quality.iterations
            let currentTime = ProcessInfo.processInfo.systemUptime
            let shouldRenderPreview = index == 0
                || isFinalIteration
                || currentTime - lastPreviewTime >= 0.8
            var preview: LocalGaussianTrainingPreviewFrame?
            if shouldRenderPreview {
                lastPreviewTime = currentTime
                preview = makePreviewFrame(from: trainer.render(cameraIndex: previewCameraIndex))
            }
            if index == 0
                || stats.iteration.isMultiple(of: 20)
                || isFinalIteration
                || preview != nil {
                progress(stats.iteration, stats.splatCount, preview)
            }
        }

        let temporaryURL = outputURL.appendingPathExtension("writing")
        let temporaryCheckpointURL = outputCheckpointURL.appendingPathExtension("writing")
        let intermediatePLYURL = outputURL.appendingPathExtension("intermediate.ply")
        try removeFileIfPresent(at: outputURL)
        try removeFileIfPresent(at: outputCheckpointURL)
        try? FileManager.default.removeItem(at: temporaryURL)
        try? FileManager.default.removeItem(at: temporaryCheckpointURL)
        try? FileManager.default.removeItem(at: intermediatePLYURL)
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
            try? FileManager.default.removeItem(at: temporaryCheckpointURL)
            try? FileManager.default.removeItem(at: intermediatePLYURL)
        }

        trainer.exportPly(to: intermediatePLYURL.path)
        msplatSync()
        try await convertPLYToSPZ(from: intermediatePLYURL, to: temporaryURL)
        guard FileManager.default.fileExists(atPath: temporaryURL.path) else {
            throw LocalGaussianProcessingError.exportFailed
        }

        guard trainer.saveCheckpoint(to: temporaryCheckpointURL.path),
              try fileSize(at: temporaryCheckpointURL) > 0 else {
            throw LocalGaussianProcessingError.checkpointSaveFailed
        }

        try FileManager.default.moveItem(at: temporaryCheckpointURL, to: outputCheckpointURL)
        try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
        return trainer.iteration
    }

    nonisolated private static func checkpointIteration(at url: URL) throws -> Int {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 12), header.count == 12 else {
            throw LocalGaussianProcessingError.invalidCheckpoint
        }

        func uint32(at offset: Int) -> UInt32 {
            header[offset..<(offset + 4)].enumerated().reduce(into: UInt32(0)) { value, byte in
                value |= UInt32(byte.element) << UInt32(byte.offset * 8)
            }
        }

        guard uint32(at: 0) == 0x4C50_534D,
              uint32(at: 4) == 1 else {
            throw LocalGaussianProcessingError.invalidCheckpoint
        }

        let iteration = Int(uint32(at: 8))
        guard iteration <= LocalGaussianQuality.maximumIterations else {
            throw LocalGaussianProcessingError.invalidCheckpoint
        }
        return iteration
    }

    nonisolated private static func fileSize(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    nonisolated private static func removeFileIfPresent(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    nonisolated private static func removeSupersededArtifact(_ previousURL: URL?, replacingWith currentURL: URL) {
        guard let previousURL,
              previousURL.standardizedFileURL != currentURL.standardizedFileURL else {
            return
        }
        try? FileManager.default.removeItem(at: previousURL)
    }

    nonisolated private static func makePreviewFrame(
        from rendered: PixelData
    ) -> LocalGaussianTrainingPreviewFrame? {
        guard rendered.width > 0,
              rendered.height > 0,
              rendered.width <= Int.max / rendered.height else {
            return nil
        }
        let pixelCount = rendered.width * rendered.height
        guard pixelCount <= Int.max / 4,
              rendered.pixels.count >= pixelCount * 3 else {
            return nil
        }

        var rgba = Data(count: pixelCount * 4)
        rgba.withUnsafeMutableBytes { destination in
            guard let bytes = destination.bindMemory(to: UInt8.self).baseAddress else { return }
            rendered.pixels.withUnsafeBufferPointer { source in
                for pixel in 0..<pixelCount {
                    let sourceOffset = pixel * 3
                    let destinationOffset = pixel * 4
                    bytes[destinationOffset] = previewByte(source[sourceOffset])
                    bytes[destinationOffset + 1] = previewByte(source[sourceOffset + 1])
                    bytes[destinationOffset + 2] = previewByte(source[sourceOffset + 2])
                    bytes[destinationOffset + 3] = 255
                }
            }
        }
        return LocalGaussianTrainingPreviewFrame(
            rgba: rgba,
            width: rendered.width,
            height: rendered.height
        )
    }

    nonisolated private static func previewByte(_ value: Float) -> UInt8 {
        guard value.isFinite else { return 0 }
        return UInt8((min(max(value, 0), 1) * 255).rounded())
    }

    nonisolated private static func convertPLYToSPZ(from sourceURL: URL, to destinationURL: URL) async throws {
        let pointCount = try plyVertexCount(at: sourceURL)
        guard pointCount > 0 else { throw LocalGaussianProcessingError.exportFailed }

        let reader = try SplatPLYSceneReader(sourceURL)
        let writer = try SPZSceneWriter(toFileAtPath: destinationURL.path)
        try await writer.start(numPoints: pointCount)
        for try await points in try await reader.read() {
            try Task.checkCancellation()
            try await writer.write(points)
        }
        try await writer.close()
    }

    nonisolated private static func plyVertexCount(at url: URL) throws -> Int {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let headerTerminator = Data("end_header\n".utf8)
        guard let data = try handle.read(upToCount: 1_048_576),
              let terminatorRange = data.range(of: headerTerminator),
              let header = String(data: data[..<terminatorRange.upperBound], encoding: .utf8) else {
            throw LocalGaussianProcessingError.exportFailed
        }
        for line in header.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ")
            if fields.count == 3,
               fields[0] == "element",
               fields[1] == "vertex",
               let count = Int(fields[2]) {
                return count
            }
        }
        throw LocalGaussianProcessingError.exportFailed
    }
}

enum GaussianCapturePolicy {
    nonisolated static let minimumFrames = 5
}

private enum LocalGaussianProcessingError: LocalizedError {
    case insufficientViews(Int)
    case exportFailed
    case invalidCheckpoint
    case checkpointAheadOfTarget(checkpoint: Int, target: Int)
    case checkpointSaveFailed

    var errorDescription: String? {
        switch self {
        case .insufficientViews(let count):
            return "At least \(GaussianCapturePolicy.minimumFrames) camera views are required. \(count) were found."
        case .exportFailed:
            return "Local processing finished without producing an SPZ file."
        case .invalidCheckpoint:
            return "The saved training checkpoint is invalid."
        case .checkpointAheadOfTarget(let checkpoint, let target):
            return "The saved checkpoint is already at iteration \(checkpoint), above the selected \(target) target."
        case .checkpointSaveFailed:
            return "Training finished, but its resume checkpoint could not be saved."
        }
    }
}
