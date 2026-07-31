import Foundation
import Metal

enum MetalContextError: LocalizedError {
    case unavailable
    case commandQueueCreationFailed
    case shaderFunctionMissing(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Metal is unavailable on this Mac."
        case .commandQueueCreationFailed:
            return "Could not create a Metal command queue."
        case .shaderFunctionMissing(let name):
            return "Metal shader function is missing: \(name)"
        }
    }
}

final class MetalContext {
    static let shared: MetalContext = {
        do {
            return try MetalContext()
        } catch {
            fatalError("Wallflow failed to initialize Metal: \(error.localizedDescription)")
        }
    }()

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let canvasSourcePipeline: MTLRenderPipelineState
    let canvasOverlayPipeline: MTLRenderPipelineState
    let particlePipeline: MTLRenderPipelineState

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalContextError.unavailable
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalContextError.commandQueueCreationFailed
        }

        let library = try device.makeLibrary(source: MetalShader.source, options: nil)
        guard let vertexFunction = library.makeFunction(name: "wallpaperVertex") else {
            throw MetalContextError.shaderFunctionMissing("wallpaperVertex")
        }
        guard let fragmentFunction = library.makeFunction(name: "wallpaperFragment") else {
            throw MetalContextError.shaderFunctionMissing("wallpaperFragment")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Wallflow Pipeline"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        guard let canvasVertex = library.makeFunction(name: "canvasShapeVertex") else {
            throw MetalContextError.shaderFunctionMissing("canvasShapeVertex")
        }
        guard let canvasFragment = library.makeFunction(name: "canvasShapeFragment") else {
            throw MetalContextError.shaderFunctionMissing("canvasShapeFragment")
        }

        let canvasDescriptor = MTLRenderPipelineDescriptor()
        canvasDescriptor.label = "Wallflow Canvas Shapes"
        canvasDescriptor.vertexFunction = canvasVertex
        canvasDescriptor.fragmentFunction = canvasFragment
        canvasDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let attachment = canvasDescriptor.colorAttachments[0]!
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let canvasPipeline = try device.makeRenderPipelineState(descriptor: canvasDescriptor)
        canvasSourcePipeline = canvasPipeline
        canvasOverlayPipeline = canvasPipeline

        guard let particleVertex = library.makeFunction(name: "particleVertex") else {
            throw MetalContextError.shaderFunctionMissing("particleVertex")
        }
        guard let particleFragment = library.makeFunction(name: "particleFragment") else {
            throw MetalContextError.shaderFunctionMissing("particleFragment")
        }
        let particleDescriptor = MTLRenderPipelineDescriptor()
        particleDescriptor.label = "Wallflow Particles"
        particleDescriptor.vertexFunction = particleVertex
        particleDescriptor.fragmentFunction = particleFragment
        particleDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let particleAttachment = particleDescriptor.colorAttachments[0]!
        particleAttachment.isBlendingEnabled = true
        particleAttachment.rgbBlendOperation = .add
        particleAttachment.alphaBlendOperation = .add
        // Premultiplied alpha blending
        particleAttachment.sourceRGBBlendFactor = .one
        particleAttachment.sourceAlphaBlendFactor = .one
        particleAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        particleAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        particlePipeline = try device.makeRenderPipelineState(descriptor: particleDescriptor)
    }
}
