// Copyright 2026 Voxelio.
// Licensed under the PolyForm Noncommercial License 1.0.0.

import Metal
import MetalKit
import MetalSplatter
import SplatIO
import SwiftUI
import UIKit
import simd

struct LocalGaussianViewer: UIViewRepresentable {
    let fileURL: URL
    var isNavigationModeEnabled = false
    var navigationInput = CGSize.zero
    var animatesEntrance = true

    func makeCoordinator() -> LocalGaussianViewerCoordinator {
        LocalGaussianViewerCoordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero)
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 1
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false

        if let driver = LocalGaussianMetalDriver(view: view) {
            context.coordinator.driver = driver
            view.delegate = driver
            driver.open(fileURL, animatesEntrance: animatesEntrance)
        }
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.driver?.configureNavigationMode(
            isEnabled: isNavigationModeEnabled,
            controlVector: SIMD2<Float>(
                Float(navigationInput.width),
                Float(navigationInput.height)
            )
        )
        context.coordinator.driver?.open(fileURL, animatesEntrance: animatesEntrance)
    }

    static func dismantleUIView(_ view: MTKView, coordinator: LocalGaussianViewerCoordinator) {
        coordinator.driver?.stop()
        view.delegate = nil
    }
}

final class LocalGaussianViewerCoordinator {
    var driver: LocalGaussianMetalDriver?
}

private final class WeakMetalDriver: @unchecked Sendable {
    weak var value: LocalGaussianMetalDriver?

    init(_ value: LocalGaussianMetalDriver) {
        self.value = value
    }
}

@MainActor
final class LocalGaussianMetalDriver: NSObject, MTKViewDelegate {
    private unowned let view: MTKView
    private let device: MTLDevice
    private let commands: MTLCommandQueue

    private var renderer: SplatRenderer?
    private var openedURL: URL?
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    private var drawableSize: CGSize = .zero

    private var focus = SIMD3<Float>.zero
    private var sceneRadius: Float = 1
    private var yaw: Float = 0
    private var pitch: Float = 0
    private var distance: Float = 2.4
    private var dragStart = SIMD2<Float>.zero
    private var cameraAtDragStart = SIMD2<Float>.zero
    private var automaticallyRotates = true
    private var previousFrameTime = CACurrentMediaTime()
    private var isNavigationModeEnabled = false
    private var navigationInput = SIMD2<Float>.zero
    private var targetSceneOffset = SIMD3<Float>.zero
    private var renderedSceneOffset = SIMD3<Float>.zero
    private var revealAnimationStartTime: CFTimeInterval?
    private var entranceAnimationStartTime: CFTimeInterval?
    private var restingDistance: Float = 2.4

    private let revealAnimationDuration: Float = 1.8
    private let entranceAnimationDuration: Float = 1.6
    private let entranceDistanceScale: Float = 2.2

    init?(view: MTKView) {
        guard let device = view.device, let commands = device.makeCommandQueue() else { return nil }
        self.view = view
        self.device = device
        self.commands = commands
        super.init()
        installGestures()
    }

    func open(_ url: URL, animatesEntrance: Bool) {
        guard openedURL != url else { return }
        openedURL = url
        generation += 1
        let request = generation
        loadTask?.cancel()

        let weakOwner = WeakMetalDriver(self)
        let device = device
        let colorFormat = view.colorPixelFormat
        let depthFormat = view.depthStencilPixelFormat
        let samples = view.sampleCount

        loadTask = Task.detached(priority: .userInitiated) {
            do {
                let points = try await AutodetectSceneReader(url).readAll()
                try Task.checkCancellation()
                guard !points.isEmpty else { throw GaussianViewerError.emptyFile }

                let bounds = Self.measure(points)
                let chunk = try SplatChunk(device: device, from: points)
                let renderer = try SplatRenderer(
                    device: device,
                    colorFormat: colorFormat,
                    depthFormat: depthFormat,
                    sampleCount: samples,
                    maxViewCount: 1,
                    maxSimultaneousRenders: 3,
                    highQualityDepth: false,
                    clearColor: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                )
                await renderer.addChunk(chunk)
                if animatesEntrance {
                    renderer.animation = .pointCloudReveal(
                        center: bounds.center,
                        radius: bounds.radius,
                        progress: 0
                    )
                }
                try Task.checkCancellation()

                await MainActor.run {
                    guard let owner = weakOwner.value, owner.generation == request else { return }
                    owner.renderer = renderer
                    owner.focus = bounds.center
                    owner.sceneRadius = bounds.radius
                    owner.restingDistance = max(bounds.radius * 2.4, 0.15)
                    owner.distance = animatesEntrance
                        ? owner.restingDistance * owner.entranceDistanceScale
                        : owner.restingDistance
                    owner.yaw = 0
                    owner.pitch = 0
                    owner.targetSceneOffset = .zero
                    owner.renderedSceneOffset = .zero
                    let now = CACurrentMediaTime()
                    owner.previousFrameTime = now
                    owner.revealAnimationStartTime = animatesEntrance ? now : nil
                    if owner.isNavigationModeEnabled {
                        owner.automaticallyRotates = false
                        owner.entranceAnimationStartTime = nil
                    } else {
                        owner.automaticallyRotates = true
                        owner.entranceAnimationStartTime = animatesEntrance ? now : nil
                    }
                    owner.loadTask = nil
                }
            } catch {
                await MainActor.run {
                    guard let owner = weakOwner.value, owner.generation == request else { return }
                    owner.renderer = nil
                    owner.loadTask = nil
                }
            }
        }
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        renderer = nil
    }

    func draw(in view: MTKView) {
        guard let renderer, renderer.isReadyToRender,
              let drawable = view.currentDrawable,
              let commandBuffer = commands.makeCommandBuffer()
        else {
            return
        }

        let now = CACurrentMediaTime()
        let delta = min(Float(now - previousFrameTime), 0.1)
        previousFrameTime = now
        if automaticallyRotates {
            yaw += delta * 0.28
        }
        if isNavigationModeEnabled {
            updateSceneNavigation(deltaTime: delta)
        }
        updateEntranceAnimation(now: now)
        let smoothing = 1 - expf(-14 * delta)
        renderedSceneOffset = simd_mix(
            renderedSceneOffset,
            targetSceneOffset,
            SIMD3<Float>(repeating: smoothing)
        )

        let descriptor = viewportDescriptor()
        let rendered = (try? renderer.render(
            viewports: [descriptor],
            colorTexture: view.multisampleColorTexture ?? drawable.texture,
            colorStoreAction: view.multisampleColorTexture == nil ? .store : .multisampleResolve,
            depthTexture: view.depthStencilTexture,
            rasterizationRateMap: nil,
            renderTargetArrayLength: 0,
            accessTimeout: 0,
            sortTimeout: 0.02,
            to: commandBuffer
        )) ?? false

        if rendered {
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSize = size
    }

    private func viewportDescriptor() -> SplatRenderer.ViewportDescriptor {
        let width = max(Float(drawableSize.width), 1)
        let height = max(Float(drawableSize.height), 1)
        let nearPlane = max(distance * 0.002, 0.0005)
        let farPlane = max(distance + sceneRadius * 8, 50)
        let projection = Self.perspective(
            verticalFieldOfView: .pi / 3,
            aspect: width / height,
            near: nearPlane,
            far: farPlane
        )
        let cameraRotation = Self.rotation(pitch, axis: SIMD3<Float>(1, 0, 0))
            * Self.rotation(yaw, axis: SIMD3<Float>(0, 1, 0))
        let translatedFocus = focus + renderedSceneOffset
        // Voxelio captures and msplat trains in the same OpenGL world basis
        // (Y-up, Z-back), so no generic PLY "up" calibration is needed here.
        let sceneTransform = Self.translation(
            -translatedFocus.x,
            -translatedFocus.y,
            -translatedFocus.z
        )
        let viewMatrix = Self.translation(0, 0, -distance)
            * cameraRotation
            * sceneTransform

        return SplatRenderer.ViewportDescriptor(
            viewport: MTLViewport(
                originX: 0,
                originY: 0,
                width: Double(width),
                height: Double(height),
                znear: 0,
                zfar: 1
            ),
            projectionMatrix: projection,
            viewMatrix: viewMatrix,
            screenSize: SIMD2(Int(width), Int(height))
        )
    }

    private func installGestures() {
        view.isMultipleTouchEnabled = true
        view.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(drag(_:))))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(zoom(_:))))
        let reset = UITapGestureRecognizer(target: self, action: #selector(resetCamera))
        reset.numberOfTapsRequired = 2
        view.addGestureRecognizer(reset)
    }

    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.translation(in: view)
        switch gesture.state {
        case .began:
            automaticallyRotates = false
            entranceAnimationStartTime = nil
            dragStart = SIMD2(Float(location.x), Float(location.y))
            cameraAtDragStart = SIMD2(yaw, pitch)
        case .changed:
            let movement = SIMD2(Float(location.x), Float(location.y)) - dragStart
            yaw = cameraAtDragStart.x + movement.x * 0.007
            pitch = simd_clamp(cameraAtDragStart.y + movement.y * 0.007, -.pi * 0.48, .pi * 0.48)
        default:
            break
        }
    }

    @objc private func zoom(_ gesture: UIPinchGestureRecognizer) {
        automaticallyRotates = false
        entranceAnimationStartTime = nil
        guard gesture.scale > 0 else { return }
        distance = simd_clamp(
            distance / Float(gesture.scale),
            max(sceneRadius * 0.08, 0.02),
            max(sceneRadius * 12, 2)
        )
        gesture.scale = 1
    }

    @objc private func resetCamera() {
        yaw = 0
        pitch = 0
        distance = restingDistance
        targetSceneOffset = .zero
        renderedSceneOffset = .zero
        entranceAnimationStartTime = nil
        automaticallyRotates = !isNavigationModeEnabled
    }

    func configureNavigationMode(isEnabled: Bool, controlVector: SIMD2<Float>) {
        if isEnabled, !isNavigationModeEnabled {
            automaticallyRotates = false
            entranceAnimationStartTime = nil
        }
        isNavigationModeEnabled = isEnabled
        navigationInput = isEnabled ? controlVector : .zero
    }

    private func updateSceneNavigation(deltaTime: Float) {
        let input = SIMD2<Float>(
            simd_clamp(navigationInput.x, -1, 1),
            simd_clamp(navigationInput.y, -1, 1)
        )
        guard simd_length(input) > 0.02 else { return }

        let viewRotation = Self.rotation(pitch, axis: SIMD3<Float>(1, 0, 0))
            * Self.rotation(yaw, axis: SIMD3<Float>(0, 1, 0))
        let cameraToScene = simd_inverse(viewRotation)
        let localDirection = SIMD4<Float>(input.x, 0, input.y, 0)
        let transformed = cameraToScene * localDirection
        let sceneDirection = SIMD3<Float>(transformed.x, transformed.y, transformed.z)
        let speed = max(sceneRadius * 0.58, 0.2)
        targetSceneOffset += sceneDirection * speed * deltaTime
    }

    private func updateEntranceAnimation(now: CFTimeInterval) {
        if let start = entranceAnimationStartTime {
            let linearProgress = simd_clamp(
                Float(now - start) / entranceAnimationDuration,
                0,
                1
            )
            let progress = Self.smoothProgress(linearProgress)
            distance = restingDistance * (entranceDistanceScale - (entranceDistanceScale - 1) * progress)
            if linearProgress >= 1 {
                entranceAnimationStartTime = nil
            }
        }

        guard let renderer, let start = revealAnimationStartTime else { return }
        let linearProgress = simd_clamp(
            Float(now - start) / revealAnimationDuration,
            0,
            1
        )
        renderer.animation = .pointCloudReveal(
            center: focus,
            radius: sceneRadius,
            progress: Self.smoothProgress(linearProgress)
        )
        if linearProgress >= 1 {
            revealAnimationStartTime = nil
        }
    }

    nonisolated private static func smoothProgress(_ value: Float) -> Float {
        value * value * (3 - 2 * value)
    }

    nonisolated private static func measure(_ points: [SplatPoint]) -> (center: SIMD3<Float>, radius: Float) {
        var lower = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var upper = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for point in points {
            lower = simd_min(lower, point.position)
            upper = simd_max(upper, point.position)
        }
        let center = (lower + upper) * 0.5
        let radius = max(simd_length(upper - lower) * 0.5, 0.05)
        return (center, radius)
    }

    nonisolated private static func translation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        simd_float4x4(
            SIMD4(1, 0, 0, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(x, y, z, 1)
        )
    }

    nonisolated private static func rotation(_ angle: Float, axis: SIMD3<Float>) -> simd_float4x4 {
        let unit = simd_normalize(axis)
        let c = cosf(angle)
        let s = sinf(angle)
        let t = 1 - c
        let x = unit.x, y = unit.y, z = unit.z
        return simd_float4x4(
            SIMD4(t * x * x + c, t * x * y + s * z, t * x * z - s * y, 0),
            SIMD4(t * x * y - s * z, t * y * y + c, t * y * z + s * x, 0),
            SIMD4(t * x * z + s * y, t * y * z - s * x, t * z * z + c, 0),
            SIMD4(0, 0, 0, 1)
        )
    }

    nonisolated private static func perspective(
        verticalFieldOfView: Float,
        aspect: Float,
        near: Float,
        far: Float
    ) -> simd_float4x4 {
        let y = 1 / tanf(verticalFieldOfView * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(
            SIMD4(x, 0, 0, 0),
            SIMD4(0, y, 0, 0),
            SIMD4(0, 0, z, -1),
            SIMD4(0, 0, near * z, 0)
        )
    }
}

private enum GaussianViewerError: Error {
    case emptyFile
}
