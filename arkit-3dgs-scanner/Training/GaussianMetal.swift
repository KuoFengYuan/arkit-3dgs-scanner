// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
import Foundation
import Metal

/// Metal device, queue and compute pipelines shared by the Gaussian trainer and preview.
///
/// Training needs float atomics in device memory (Metal 3, Apple GPU family 7: A14 and newer).
/// The app loads the kernels from its default library; command-line tools pass a compiled
/// `.metallib` so the same kernels run on a Mac GPU for regression tests.
nonisolated final class GaussianMetal: @unchecked Sendable {
    enum SetupError: LocalizedError {
        case noDevice, unsupportedGPU, missingLibrary, missingKernel(String), allocationFailed(Int)
        var errorDescription: String? {
            switch self {
            case .noDevice: return L10n.text("找不到可用的 GPU")
            case .unsupportedGPU: return L10n.text("這台裝置的 GPU 不支援手機端 3DGS 訓練（需要 A14 或更新的晶片）")
            case .missingLibrary, .missingKernel: return L10n.text("訓練程式元件不完整，請重新安裝 App")
            case .allocationFailed(let bytes):
                return L10n.text("記憶體不足，無法配置 \(max(1, bytes >> 20)) MB 的訓練緩衝區")
            }
        }
    }

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let library: MTLLibrary
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private let lock = NSLock()

    static var isSupported: Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return supports(device)
    }

    static func supports(_ device: MTLDevice) -> Bool {
        #if targetEnvironment(simulator)
        // The Simulator does not report Apple GPU families; pipeline creation decides (UI checks
        // only — Simulator speed and memory say nothing about a phone).
        return true
        #else
        return device.supportsFamily(.apple7) || device.supportsFamily(.mac2)
        #endif
    }

    init(libraryURL: URL? = nil) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw SetupError.noDevice }
        guard Self.supports(device) else { throw SetupError.unsupportedGPU }
        guard let queue = device.makeCommandQueue() else { throw SetupError.noDevice }
        let library: MTLLibrary?
        if let libraryURL { library = try? device.makeLibrary(URL: libraryURL) }
        else { library = device.makeDefaultLibrary() }
        guard let library else { throw SetupError.missingLibrary }
        self.device = device
        self.queue = queue
        self.library = library
        queue.label = "gaussian-training"
    }

    func pipeline(_ name: String) throws -> MTLComputePipelineState {
        lock.lock(); defer { lock.unlock() }
        if let cached = pipelines[name] { return cached }
        guard let function = library.makeFunction(name: name) else { throw SetupError.missingKernel(name) }
        let state = try device.makeComputePipelineState(function: function)
        pipelines[name] = state
        return state
    }

    /// Shared storage: Apple GPUs use unified memory, and checkpoints read parameters directly.
    func buffer(_ length: Int, label: String? = nil) throws -> MTLBuffer {
        guard let buffer = device.makeBuffer(length: max(16, length), options: .storageModeShared) else {
            throw SetupError.allocationFailed(length)
        }
        buffer.label = label
        return buffer
    }

    func buffer<T>(_ values: [T], label: String? = nil) throws -> MTLBuffer {
        let byteCount = values.count * MemoryLayout<T>.stride
        let result = try self.buffer(max(16, byteCount), label: label)
        if byteCount > 0 {
            values.withUnsafeBufferPointer { source in
                result.contents().copyMemory(from: UnsafeRawPointer(source.baseAddress!), byteCount: byteCount)
            }
        }
        return result
    }
}

/// One compute argument; small constants are passed with `setBytes`.
nonisolated enum GPUArg {
    case buffer(MTLBuffer, Int = 0)
    case u32(UInt32)
    case i32(Int32)
    case f32(Float)
    case bytes([UInt8])

    static func value<T>(_ value: T) -> GPUArg {
        withUnsafeBytes(of: value) { .bytes(Array($0)) }
    }
}

nonisolated extension MTLComputeCommandEncoder {
    private func bind(_ args: [GPUArg]) {
        for (index, arg) in args.enumerated() {
            switch arg {
            case .buffer(let buffer, let offset): setBuffer(buffer, offset: offset, index: index)
            case .u32(var v): setBytes(&v, length: 4, index: index)
            case .i32(var v): setBytes(&v, length: 4, index: index)
            case .f32(var v): setBytes(&v, length: 4, index: index)
            case .bytes(let bytes): bytes.withUnsafeBytes { setBytes($0.baseAddress!, length: bytes.count, index: index) }
            }
        }
    }

    /// One thread per element, in threadgroups of `width`.
    func dispatch(_ pipeline: MTLComputePipelineState, threads: Int, width: Int = 256, _ args: [GPUArg]) {
        guard threads > 0 else { return }
        setComputePipelineState(pipeline)
        bind(args)
        let w = min(width, pipeline.maxTotalThreadsPerThreadgroup)
        dispatchThreads(MTLSize(width: threads, height: 1, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
    }

    /// Whole threadgroups (kernels that index by threadgroup position).
    func dispatch(_ pipeline: MTLComputePipelineState, groups: Int, width: Int = 256, _ args: [GPUArg]) {
        guard groups > 0 else { return }
        setComputePipelineState(pipeline)
        bind(args)
        dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1),
                             threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
    }

    /// 2-D grid of threadgroups (image tiles).
    func dispatch(_ pipeline: MTLComputePipelineState, groups: (Int, Int), size: (Int, Int), _ args: [GPUArg]) {
        guard groups.0 > 0, groups.1 > 0 else { return }
        setComputePipelineState(pipeline)
        bind(args)
        dispatchThreadgroups(MTLSize(width: groups.0, height: groups.1, depth: 1),
                             threadsPerThreadgroup: MTLSize(width: size.0, height: size.1, depth: 1))
    }
}
