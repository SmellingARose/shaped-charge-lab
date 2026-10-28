import Foundation
import MetalKit
import simd

struct SceneInfo {
    var axi = true
    var L: Float = 55
    var zFace: Float = 175
    var zBack: Float = 455
    var R: Float = 20
    var RT: Float = 16
    var CD: Float = 40
    var tipZ: Float = 55
    var linerKind: Float = 0
    var targetKind: Float = 0
    var count = 0
}

/// Latest particle state handed from the simulation thread to the renderer.
final class RenderFeed {
    private let lock = NSLock()
    private var data: UnsafeMutablePointer<RenderParticle>
    private var capacity = 1
    private var info = SceneInfo()

    init() { data = .allocate(capacity: 1) }

    func publish(_ sim: Simulation) {
        lock.lock(); defer { lock.unlock() }
        if capacity < sim.n {
            data.deallocate()
            capacity = sim.n
            data = .allocate(capacity: capacity)
        }
        let c = sim.fillRender(data)
        info = SceneInfo(axi: sim.axi, L: sim.L, zFace: sim.zFace, zBack: sim.zBack, R: sim.R, RT: sim.RT,
                         CD: sim.CD, tipZ: sim.tipZ,
                         linerKind: Float(LinerMaterial.allCases.firstIndex(of: sim.cfg.liner) ?? 0),
                         targetKind: Float(TargetMaterial.allCases.firstIndex(of: sim.cfg.target) ?? 0),
                         count: c)
    }

    var neededCapacity: Int { lock.lock(); defer { lock.unlock() }; return capacity }

    func copy(into buffer: MTLBuffer) -> SceneInfo {
        lock.lock(); defer { lock.unlock() }
        let stride = MemoryLayout<RenderParticle>.stride
        let n = min(info.count, buffer.length / stride)
        memcpy(buffer.contents(), data, n * stride)
        var i = info
        i.count = n
        return i
    }
}

/// Visual options, changed from the UI.
final class ViewSettings {
    var colorMode: UInt32 = 0          // 0 material, 1 speed, 2 pressure, 3 temperature, 4 plastic strain
    var cutawayDeg: Float = 90
    var showGas = true
    var showExplosive = true
    var showTarget = true
    var showGround = true
    var bloom = true
    var follow = false
    var extrudeCD: Float = 1.2
    var mode3D = false
    var sliceOnly = false
}

final class OrbitCamera {
    var yaw: Float = -0.5
    var pitch: Float = 0.28
    var distance: Float = 8
    var target = SIMD3<Float>(0, 0, 0)
    var fovY: Float = 0.6
    var userMoved = false

    var eye: SIMD3<Float> {
        target + distance * SIMD3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
    }
}

private struct Uniforms {
    var view: simd_float4x4
    var proj: simd_float4x4
    var invView: simd_float4x4
    var a: SIMD4<Float>
    var b: SIMD4<Float>
    var c: SIMD4<UInt32>
    var d: SIMD4<Float>
    var e: SIMD4<Float>
    var f: SIMD4<Float>
    var g: SIMD4<Float>
    var h: SIMD4<Float>
}

private func lookAt(_ eye: SIMD3<Float>, _ center: SIMD3<Float>, _ up: SIMD3<Float>) -> simd_float4x4 {
    let f = normalize(center - eye)
    let s = normalize(cross(f, up))
    let u = cross(s, f)
    return simd_float4x4(columns: (
        SIMD4(s.x, u.x, -f.x, 0),
        SIMD4(s.y, u.y, -f.y, 0),
        SIMD4(s.z, u.z, -f.z, 0),
        SIMD4(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)))
}

private func perspective(_ fovY: Float, _ aspect: Float, _ near: Float, _ far: Float) -> simd_float4x4 {
    let ys = 1 / tan(fovY / 2), xs = ys / aspect, zs = far / (near - far)
    return simd_float4x4(columns: (
        SIMD4(xs, 0, 0, 0), SIMD4(0, ys, 0, 0), SIMD4(0, 0, zs, -1), SIMD4(0, 0, zs * near, 0)))
}

final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let feed: RenderFeed
    let feed3D: Feed3D
    private var seen3D = -1
    private var frameBuf: MTLBuffer
    let settings: ViewSettings
    let camera = OrbitCamera()
    let mmToWorld: Float = 0.02

    private var resetPSO, expandPSO, expand3DPSO, clampPSO: MTLComputePipelineState
    private var bgPSO, groundPSO, spherePSO, gasPSO, prefilterPSO, downPSO, upPSO, compositePSO: MTLRenderPipelineState
    private var depthWrite, depthReadOnly, depthAlways: MTLDepthStencilState
    private var particleBuf: MTLBuffer
    private let instBuf, gasBuf, argsBuf, gasArgsBuf: MTLBuffer
    private var hdrTex: MTLTexture?
    private var depthTex: MTLTexture?
    private var bloomTex: [MTLTexture] = []
    private let inFlight = DispatchSemaphore(value: 1)
    private var start = Date()
    private var lastInfo = SceneInfo()
    private var framedFor = ""

    static let instCap = 3_000_000
    static let gasCap = 1_200_000

    init?(view: MTKView, feed: RenderFeed, feed3D: Feed3D, settings: ViewSettings) {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return nil }
        device = dev; queue = q
        self.feed = feed; self.feed3D = feed3D; self.settings = settings
        view.device = dev
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        let lib: MTLLibrary
        do { lib = try dev.makeLibrary(source: shaderSource, options: nil) } catch {
            print("Shader compile failed: \(error)"); return nil
        }
        func fn(_ n: String) -> MTLFunction { lib.makeFunction(name: n)! }
        do {
            resetPSO = try dev.makeComputePipelineState(function: fn("resetArgs"))
            expandPSO = try dev.makeComputePipelineState(function: fn("expand"))
            expand3DPSO = try dev.makeComputePipelineState(function: fn("expand3D"))
            clampPSO = try dev.makeComputePipelineState(function: fn("clampArgs"))

            func pso(_ v: String, _ f: String, _ fmt: MTLPixelFormat, depth: Bool, blend: Int = 0) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = fn(v); d.fragmentFunction = fn(f)
                d.colorAttachments[0].pixelFormat = fmt
                if depth { d.depthAttachmentPixelFormat = .depth32Float }
                if blend == 1 {
                    let c = d.colorAttachments[0]!
                    c.isBlendingEnabled = true
                    c.rgbBlendOperation = .add; c.alphaBlendOperation = .add
                    c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .one
                    c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .one
                }
                return try dev.makeRenderPipelineState(descriptor: d)
            }
            bgPSO = try pso("fullscreenV", "backgroundF", .rgba16Float, depth: true)
            groundPSO = try pso("groundV", "groundF", .rgba16Float, depth: true)
            spherePSO = try pso("sphereV", "sphereF", .rgba16Float, depth: true)
            gasPSO = try pso("gasV", "gasF", .rgba16Float, depth: true, blend: 1)
            prefilterPSO = try pso("fullscreenV", "bloomPrefilter", .rgba16Float, depth: false)
            downPSO = try pso("fullscreenV", "bloomDown", .rgba16Float, depth: false)
            upPSO = try pso("fullscreenV", "bloomUp", .rgba16Float, depth: false, blend: 1)
            compositePSO = try pso("fullscreenV", "compositeF", .bgra8Unorm_srgb, depth: false)
        } catch {
            print("Pipeline creation failed: \(error)"); return nil
        }
        func ds(_ cmp: MTLCompareFunction, _ write: Bool) -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = cmp; d.isDepthWriteEnabled = write
            return dev.makeDepthStencilState(descriptor: d)!
        }
        depthWrite = ds(.less, true); depthReadOnly = ds(.less, false); depthAlways = ds(.always, false)
        particleBuf = dev.makeBuffer(length: 36 * 1024, options: .storageModeShared)!
        frameBuf = dev.makeBuffer(length: 12 * 1024, options: .storageModeShared)!
        instBuf = dev.makeBuffer(length: 32 * Renderer.instCap, options: .storageModePrivate)!
        gasBuf = dev.makeBuffer(length: 32 * Renderer.gasCap, options: .storageModePrivate)!
        argsBuf = dev.makeBuffer(length: 16, options: .storageModePrivate)!
        gasArgsBuf = dev.makeBuffer(length: 16, options: .storageModePrivate)!
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        buildTargets(size)
    }

    private func buildTargets(_ size: CGSize) {
        let w = max(Int(size.width), 8), h = max(Int(size.height), 8)
        func tex(_ w: Int, _ h: Int, _ fmt: MTLPixelFormat) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        hdrTex = tex(w, h, .rgba16Float)
        depthTex = tex(w, h, .depth32Float)
        bloomTex = (1...5).map { tex(max(w >> $0, 2), max(h >> $0, 2), .rgba16Float) }
    }

    /// Re-aim the camera when the scene geometry changes.
    private func frame(_ info: SceneInfo) {
        let key = "\(info.axi)|\(info.L)|\(info.zFace)|\(info.zBack)"
        guard key != framedFor else { return }
        framedFor = key
        let s = mmToWorld
        let left = -info.L * s, right = (info.zFace - info.L) * s + 0.6 * info.CD * s
        camera.target = SIMD3((left + right) / 2, 0, 0)
        if !camera.userMoved {
            camera.distance = max((right - left) * 1.15, 3)
        }
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable else { return }
        if hdrTex == nil || hdrTex!.width != Int(view.drawableSize.width) || hdrTex!.height != Int(view.drawableSize.height) {
            buildTargets(view.drawableSize)
        }
        inFlight.wait()
        let need = feed.neededCapacity * MemoryLayout<RenderParticle>.stride
        if particleBuf.length < need {
            particleBuf = device.makeBuffer(length: need, options: .storageModeShared)!
        }
        var info: SceneInfo
        var f3 = Frame3DInfo()
        let use3D = settings.mode3D && feed3D.byteCount > 0
        if use3D {
            if frameBuf.length < feed3D.byteCount {
                frameBuf = device.makeBuffer(length: feed3D.byteCount, options: .storageModeShared)!
                seen3D = -1
            }
            let (count, fi, tipZ) = feed3D.copy(into: frameBuf, seen: &seen3D)
            f3 = fi
            info = fi.scene
            info.count = count
            info.tipZ = tipZ
        } else {
            info = feed.copy(into: particleBuf)
            if !settings.showExplosive || !settings.showTarget { info.count = filterHidden(info.count) }
        }
        lastInfo = info
        frame(info)

        let s = mmToWorld
        if settings.follow {
            let tipX = (info.tipZ - info.L) * s
            camera.target.x += (tipX - camera.target.x) * 0.08
        }
        let size = view.drawableSize
        let aspect = Float(size.width / max(size.height, 1))
        let eye = camera.eye
        let viewM = lookAt(eye, camera.target, SIMD3(0, 1, 0))
        let projM = perspective(camera.fovY, aspect, 0.02, 200)
        let dir = eye - camera.target
        let cutCenter = atan2(dir.z, dir.y)
        let groundY = -max(info.R, info.RT) * 1.7 * s
        let pMax: Float = 60
        var u = Uniforms(
            view: viewM, proj: projM, invView: viewM.inverse,
            a: SIMD4(Float(size.width), Float(size.height), Float(Date().timeIntervalSince(start)), s),
            b: SIMD4(cutCenter, settings.cutawayDeg * .pi / 360, settings.extrudeCD * info.CD, groundY),
            c: SIMD4(settings.colorMode, info.axi ? 1 : 0, settings.showGas ? 1 : 0, UInt32(info.count)),
            d: SIMD4(8.5, info.R, info.L, info.zFace),
            e: SIMD4(info.RT, info.zBack, info.CD, (info.tipZ - info.L) * s),
            f: SIMD4(info.linerKind, info.targetKind, pMax, 3),
            g: SIMD4(f3.quantMin.x, f3.quantMin.y, f3.quantMin.z, f3.quantXY),
            h: SIMD4(f3.quantZ, f3.dpFine, f3.dpCoarse, Float((settings.showExplosive ? 1 : 0) | (settings.showTarget ? 2 : 0) | (settings.sliceOnly && !use3D ? 4 : 0))))

        guard let cb = queue.makeCommandBuffer() else { inFlight.signal(); return }
        cb.addCompletedHandler { [weak self] _ in self?.inFlight.signal() }

        if let ce = cb.makeComputeCommandEncoder() {
            ce.setComputePipelineState(resetPSO)
            ce.setBuffer(argsBuf, offset: 0, index: 0); ce.setBuffer(gasArgsBuf, offset: 0, index: 1)
            ce.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            if info.count > 0 {
                ce.setComputePipelineState(use3D ? expand3DPSO : expandPSO)
                ce.setBuffer(use3D ? frameBuf : particleBuf, offset: 0, index: 0)
                ce.setBuffer(instBuf, offset: 0, index: 1)
                ce.setBuffer(argsBuf, offset: 0, index: 2)
                ce.setBuffer(gasBuf, offset: 0, index: 3)
                ce.setBuffer(gasArgsBuf, offset: 0, index: 4)
                ce.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 5)
                ce.dispatchThreads(MTLSize(width: info.count, height: 1, depth: 1),
                                   threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
            }
            ce.setComputePipelineState(clampPSO)
            ce.setBuffer(argsBuf, offset: 0, index: 0); ce.setBuffer(gasArgsBuf, offset: 0, index: 1)
            ce.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            ce.endEncoding()
        }

        guard let hdr = hdrTex, let depth = depthTex else { cb.commit(); return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = hdr
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rp.depthAttachment.texture = depth
        rp.depthAttachment.loadAction = .clear
        rp.depthAttachment.storeAction = .dontCare
        rp.depthAttachment.clearDepth = 1
        if let re = cb.makeRenderCommandEncoder(descriptor: rp) {
            re.setDepthStencilState(depthAlways)
            re.setRenderPipelineState(bgPSO)
            re.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            re.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

            re.setDepthStencilState(depthWrite)
            if settings.showGround {
                re.setRenderPipelineState(groundPSO)
                re.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                re.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                re.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            re.setRenderPipelineState(spherePSO)
            re.setVertexBuffer(instBuf, offset: 0, index: 0)
            re.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            re.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            re.drawPrimitives(type: .triangleStrip, indirectBuffer: argsBuf, indirectBufferOffset: 0)

            if settings.showGas {
                re.setDepthStencilState(depthReadOnly)
                re.setRenderPipelineState(gasPSO)
                re.setVertexBuffer(gasBuf, offset: 0, index: 0)
                re.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                re.drawPrimitives(type: .triangleStrip, indirectBuffer: gasArgsBuf, indirectBufferOffset: 0)
            }
            re.endEncoding()
        }

        func pass(_ target: MTLTexture, _ pso: MTLRenderPipelineState, _ src: MTLTexture, load: Bool = false) {
            let d = MTLRenderPassDescriptor()
            d.colorAttachments[0].texture = target
            d.colorAttachments[0].loadAction = load ? .load : .dontCare
            d.colorAttachments[0].storeAction = .store
            guard let e = cb.makeRenderCommandEncoder(descriptor: d) else { return }
            e.setRenderPipelineState(pso)
            e.setFragmentTexture(src, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }
        if settings.bloom && bloomTex.count == 5 {
            pass(bloomTex[0], prefilterPSO, hdr)
            for i in 1..<5 { pass(bloomTex[i], downPSO, bloomTex[i - 1]) }
            for i in stride(from: 3, through: 0, by: -1) { pass(bloomTex[i], upPSO, bloomTex[i + 1], load: true) }
        } else if bloomTex.count == 5 {
            let d = MTLRenderPassDescriptor()
            d.colorAttachments[0].texture = bloomTex[0]
            d.colorAttachments[0].loadAction = .clear
            d.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            d.colorAttachments[0].storeAction = .store
            cb.makeRenderCommandEncoder(descriptor: d)?.endEncoding()
        }

        let fp = MTLRenderPassDescriptor()
        fp.colorAttachments[0].texture = drawable.texture
        fp.colorAttachments[0].loadAction = .dontCare
        fp.colorAttachments[0].storeAction = .store
        if let e = cb.makeRenderCommandEncoder(descriptor: fp) {
            e.setRenderPipelineState(compositePSO)
            e.setFragmentTexture(hdr, index: 0)
            e.setFragmentTexture(bloomTex.first ?? hdr, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }
        cb.present(drawable)
        cb.commit()
    }

    /// Drops hidden materials from the shared buffer (CPU side, before upload is consumed).
    private func filterHidden(_ count: Int) -> Int {
        let p = particleBuf.contents().bindMemory(to: RenderParticle.self, capacity: count)
        var k = 0
        for i in 0..<count {
            let m = p[i].matFlags & 0xff
            let gas = (p[i].matFlags >> 8) & RF.gas != 0
            if m == 0 && !gas && !settings.showExplosive { continue }
            if m == 2 && !settings.showTarget { continue }
            p[k] = p[i]; k += 1
        }
        return k
    }
}

/// MTKView with orbit (drag), pan (right-drag or ⌥-drag), zoom (scroll / pinch).
final class InteractiveMTKView: MTKView {
    weak var renderer: Renderer?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDragged(with e: NSEvent) {
        guard let c = renderer?.camera else { return }
        c.userMoved = true
        if e.modifierFlags.contains(.option) { pan(e); return }
        c.yaw -= Float(e.deltaX) * 0.006
        c.pitch = min(max(c.pitch + Float(e.deltaY) * 0.006, -1.4), 1.4)
    }

    override func rightMouseDragged(with e: NSEvent) { pan(e) }

    private func pan(_ e: NSEvent) {
        guard let c = renderer?.camera else { return }
        c.userMoved = true
        let k = c.distance * 0.0016
        let right = SIMD3<Float>(cos(c.yaw), 0, -sin(c.yaw))
        c.target -= right * Float(e.deltaX) * k
        c.target.y += Float(e.deltaY) * k
    }

    override func scrollWheel(with e: NSEvent) {
        guard let c = renderer?.camera else { return }
        c.userMoved = true
        if e.hasPreciseScrollingDeltas {
            c.yaw -= Float(e.scrollingDeltaX) * 0.004
            c.pitch = min(max(c.pitch + Float(e.scrollingDeltaY) * 0.004, -1.4), 1.4)
        } else {
            c.distance = min(max(c.distance * (1 - Float(e.scrollingDeltaY) * 0.05), 0.4), 60)
        }
    }

    override func magnify(with e: NSEvent) {
        guard let c = renderer?.camera else { return }
        c.userMoved = true
        c.distance = min(max(c.distance * (1 - Float(e.magnification)), 0.4), 60)
    }
}
