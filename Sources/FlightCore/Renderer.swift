import MetalKit
import simd
import AppKit

struct FrameUniforms {
    var viewProj = M4.identity, invViewProj = M4.identity, shadow0 = M4.identity, shadow1 = M4.identity
    var camPos = V4.zero, sunDir = V4.zero, sunColor = V4.zero, zenith = V4.zero, horizon = V4.zero, runway = V4.zero, ambient = V4.zero
}
struct DrawUniforms { var model = M4.identity; var tint = V4(1, 1, 1, 1); var params = V4.zero }

struct DrawItem { var mesh: GPUMesh; var model: M4; var tint = V4(1, 1, 1, 1); var material: Float = 0; var spec: Float = 0 }

final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let game: Game
    private var scenePSO: MTLRenderPipelineState!
    private var skyPSO: MTLRenderPipelineState!
    private var shadowPSO: MTLRenderPipelineState!
    private var depthMain: MTLDepthStencilState!
    private var depthOff: MTLDepthStencilState!
    private var depthShadow: MTLDepthStencilState!
    private var sampler: MTLSamplerState!
    private var shadowTex: [MTLTexture] = []
    private var panoPSO: MTLRenderPipelineState!
    private var panoSampler: MTLSamplerState!
    private var panoTex: MTLTexture?
    private var catcherMesh: GPUMesh?

    private var terrainMesh: GPUMesh?
    private var sceneryMesh: GPUMesh?
    private var windsockMesh: GPUMesh?
    private var balloonMesh: GPUMesh?
    private var partMeshes: [GPUMesh?] = []
    private var siteVersion = -1, aircraftVersion = -1
    private var lastTime = CACurrentMediaTime()

    // screenshot support (used for automated verification)
    var shotPath: String?
    var shotAfter: Double = 2
    private var startTime = CACurrentMediaTime()

    init?(view: MTKView, game: Game) {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return nil }
        device = dev; queue = q; self.game = game
        super.init()
        view.device = dev
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 4
        view.clearDepth = 0
        view.clearColor = MTLClearColor(red: 0.5, green: 0.65, blue: 0.85, alpha: 1)
        view.preferredFramesPerSecond = 120
        do { try build(view) } catch { NSLog("Metal setup failed: \(error)"); return nil }
        balloonMesh = { var b = MeshBuilder(); b.ellipsoid(center: .zero, radii: V3(0.6, 0.72, 0.6), color: rgb(1, 1, 1), seg: 12, rings: 8)
            b.cylinder(from: V3(0, -0.7, 0), to: V3(0, -0.82, 0), r0: 0.03, r1: 0.07, seg: 6, color: rgb(1, 1, 1)); return GPUMesh(dev, b) }()
        windsockMesh = GPUMesh(dev, buildWindsock())
    }

    private func build(_ view: MTKView) throws {
        let lib = try device.makeLibrary(source: shaderSource, options: nil)
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float3; vd.attributes[1].offset = 12; vd.attributes[1].bufferIndex = 0
        vd.attributes[2].format = .float4; vd.attributes[2].offset = 24; vd.attributes[2].bufferIndex = 0
        vd.layouts[0].stride = 40

        let sd = MTLRenderPipelineDescriptor()
        sd.vertexFunction = lib.makeFunction(name: "sceneVS"); sd.fragmentFunction = lib.makeFunction(name: "sceneFS")
        sd.vertexDescriptor = vd
        sd.colorAttachments[0].pixelFormat = view.colorPixelFormat
        sd.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        sd.rasterSampleCount = view.sampleCount
        sd.colorAttachments[0].isBlendingEnabled = true
        sd.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        sd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        sd.colorAttachments[0].sourceAlphaBlendFactor = .one
        sd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        scenePSO = try device.makeRenderPipelineState(descriptor: sd)

        let kd = MTLRenderPipelineDescriptor()
        kd.vertexFunction = lib.makeFunction(name: "skyVS"); kd.fragmentFunction = lib.makeFunction(name: "skyFS")
        kd.colorAttachments[0].pixelFormat = view.colorPixelFormat
        kd.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        kd.rasterSampleCount = view.sampleCount
        skyPSO = try device.makeRenderPipelineState(descriptor: kd)
        kd.fragmentFunction = lib.makeFunction(name: "panoFS")
        panoPSO = try device.makeRenderPipelineState(descriptor: kd)
        let pd = MTLSamplerDescriptor()
        pd.minFilter = .linear; pd.magFilter = .linear; pd.mipFilter = .linear; pd.maxAnisotropy = 8
        pd.sAddressMode = .repeat; pd.tAddressMode = .clampToEdge
        panoSampler = device.makeSamplerState(descriptor: pd)
        var cm = MeshBuilder()
        cm.quad(V3(-600, 0, 600), V3(600, 0, 600), V3(600, 0, -600), V3(-600, 0, -600), rgb(1, 1, 1))
        catcherMesh = GPUMesh(device, cm)

        let hd = MTLRenderPipelineDescriptor()
        hd.vertexFunction = lib.makeFunction(name: "shadowVS")
        hd.vertexDescriptor = vd
        hd.depthAttachmentPixelFormat = .depth32Float
        shadowPSO = try device.makeRenderPipelineState(descriptor: hd)

        func depth(_ f: MTLCompareFunction, _ write: Bool) -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor(); d.depthCompareFunction = f; d.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: d)!
        }
        depthMain = depth(.greaterEqual, true)       // reverse-Z
        depthOff = depth(.always, false)
        depthShadow = depth(.lessEqual, true)

        let smp = MTLSamplerDescriptor()
        smp.minFilter = .linear; smp.magFilter = .linear; smp.compareFunction = .lessEqual
        smp.sAddressMode = .clampToEdge; smp.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: smp)

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 2048, height: 2048, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
        shadowTex = [device.makeTexture(descriptor: td)!, device.makeTexture(descriptor: td)!]
    }

    private func syncMeshes() {
        if siteVersion != game.siteVersion {
            siteVersion = game.siteVersion
            panoTex = nil
            if let url = game.site.panorama {
                terrainMesh = nil; sceneryMesh = nil
                if let img = Panoramas.image(url, maxSize: 8192) { panoTex = makeTexture(img) }
                if panoTex == nil { game.say("Could not load panorama image", 6) }
            } else {
                terrainMesh = GPUMesh(device, game.terrain.buildMesh())
                sceneryMesh = GPUMesh(device, game.terrain.buildScenery())
            }
        }
        if aircraftVersion != game.aircraftVersion {
            aircraftVersion = game.aircraftVersion
            partMeshes = game.aircraft.spec.parts.map { GPUMesh(device, $0.mesh) }
        }
    }

    /// Upload an image as an sRGB texture with a full mip chain.
    private func makeTexture(_ img: CGImage) -> MTLTexture? {
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: w, height: h, mipmapped: true)
        d.usage = [.shaderRead, .renderTarget]
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: px, bytesPerRow: w * 4)
        if let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: tex); blit.endEncoding(); cb.commit()
        }
        return tex
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        game.frame(dt: Float(now - lastTime))
        lastTime = now
        syncMeshes()
        guard let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }

        // ---- draw lists
        let ac = game.aircraft
        var acItems: [DrawItem] = []
        let base = M4.translation(ac.pos) * M4(ac.q)
        for (i, part) in ac.spec.parts.enumerated() {
            guard i < partMeshes.count, let mesh = partMeshes[i] else { continue }
            var local = M4.identity
            switch part.anim {
            case .fixed: break
            case .spin(let k): local = M4.translation(part.pivot) * M4.rotation(ac.spin[k], part.axis)
            case .hinge(let ch, let maxA): local = M4.translation(part.pivot) * M4.rotation(ac.servo[ch] * maxA, part.axis)
            }
            acItems.append(DrawItem(mesh: mesh, model: base * local, spec: 0.5))
        }
        var world: [DrawItem] = []
        if let m = sceneryMesh { world.append(DrawItem(mesh: m, model: .identity)) }
        if let m = windsockMesh, game.site.panorama == nil {
            let w = game.env.windVec
            let sp = game.env.windSpeed
            let yaw = sp > 0.05 ? atan2(w.x, w.z) : 0
            let droop = (1 - clampf(sp / 7, 0, 1)) * 78 * deg + sin(game.env.time * 5) * 0.04 * min(sp, 3)
            world.append(DrawItem(mesh: m, model: M4.translation(game.terrain.windsockBase + V3(0, 4.8, 0)) * M4.rotation(yaw, V3(0, 1, 0)) * M4.rotation(droop, V3(1, 0, 0))))
        }
        if let m = balloonMesh {
            for b in game.balloons where b.alive { world.append(DrawItem(mesh: m, model: M4.translation(b.pos), tint: b.color, spec: 0.8)) }
        }

        // ---- uniforms
        let light = game.lighting
        let L = light.sunDir
        func lightVP(_ center: V3, _ size: Float) -> M4 {
            let up: V3 = abs(L.y) > 0.95 ? V3(0, 0, 1) : V3(0, 1, 0)
            return M4.ortho(halfSize: size, near: 1, far: 1500) * M4.lookAt(eye: center + L * 700, target: center, up: up)
        }
        let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
        let proj = M4.perspective(fovY: game.fov, aspect: aspect, near: 20000, far: 0.08)   // reverse-Z
        let viewM = M4.lookAt(eye: game.eye, target: game.target, up: game.upVec)
        var fu = FrameUniforms()
        fu.viewProj = proj * viewM
        fu.invViewProj = fu.viewProj.inverse
        fu.shadow0 = lightVP(ac.pos, max(ac.spec.span * 0.9, 1.2))
        fu.shadow1 = lightVP(V3(0, 0, game.site.flatCenterZ), 260)
        fu.camPos = V4(game.eye.x, game.eye.y, game.eye.z, game.env.time)
        fu.sunDir = V4(L.x, L.y, L.z, Float(game.site.runwayType))
        fu.sunColor = V4(light.sun.x, light.sun.y, light.sun.z, game.site.fog)
        fu.zenith = V4(light.zenith.x, light.zenith.y, light.zenith.z, game.site.north / 360)
        fu.horizon = V4(light.horizon.x, light.horizon.y, light.horizon.z, game.site.horizon * deg)
        fu.runway = V4(game.site.runwayLen / 2, game.site.runwayWid / 2, Float(game.site.style), game.site.cloud)
        fu.ambient = V4(light.ambient.x, light.ambient.y, light.ambient.z, 0)

        func drawItems(_ enc: MTLRenderCommandEncoder, _ items: [DrawItem], fragment: Bool) {
            for it in items {
                var du = DrawUniforms(model: it.model, tint: it.tint, params: V4(it.material, it.spec, 0, 0))
                enc.setVertexBytes(&du, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                if fragment { enc.setFragmentBytes(&du, length: MemoryLayout<DrawUniforms>.stride, index: 2) }
                enc.setVertexBuffer(it.mesh.buffer, offset: 0, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: it.mesh.count)
            }
        }

        // ---- shadow passes: 0 = tight around the aircraft, 1 = the airfield
        for i in 0..<2 {
            let sp = MTLRenderPassDescriptor()
            sp.depthAttachment.texture = shadowTex[i]
            sp.depthAttachment.loadAction = .clear; sp.depthAttachment.clearDepth = 1; sp.depthAttachment.storeAction = .store
            guard let enc = cb.makeRenderCommandEncoder(descriptor: sp) else { continue }
            enc.setRenderPipelineState(shadowPSO)
            enc.setDepthStencilState(depthShadow)
            enc.setCullMode(.none)
            enc.setDepthBias(0, slopeScale: 2.0, clamp: 0)
            var vp = i == 0 ? fu.shadow0 : fu.shadow1
            enc.setVertexBytes(&vp, length: 64, index: 1)
            drawItems(enc, i == 0 ? acItems : world, fragment: false)
            enc.endEncoding()
        }

        // ---- main pass
        if let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
            enc.setCullMode(.none)
            enc.setVertexBytes(&fu, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            enc.setFragmentBytes(&fu, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            if let pt = panoTex {
                enc.setRenderPipelineState(panoPSO)
                enc.setFragmentTexture(pt, index: 0)
                enc.setFragmentSamplerState(panoSampler, index: 1)
            } else {
                enc.setRenderPipelineState(skyPSO)
            }
            enc.setDepthStencilState(depthOff)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

            enc.setRenderPipelineState(scenePSO)
            enc.setDepthStencilState(depthMain)
            enc.setFragmentTexture(shadowTex[0], index: 0)
            enc.setFragmentTexture(shadowTex[1], index: 1)
            enc.setFragmentSamplerState(sampler, index: 0)
            if let t = terrainMesh { drawItems(enc, [DrawItem(mesh: t, model: .identity, material: 1)], fragment: true) }
            if game.site.panorama != nil, let c = catcherMesh { drawItems(enc, [DrawItem(mesh: c, model: .identity, material: 2)], fragment: true) }
            drawItems(enc, world, fragment: true)
            drawItems(enc, acItems, fragment: true)
            enc.endEncoding()
        }

        var capture: MTLTexture?
        if let _ = shotPath, now - startTime >= shotAfter {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: drawable.texture.pixelFormat, width: drawable.texture.width, height: drawable.texture.height, mipmapped: false)
            d.storageMode = .shared
            if let tex = device.makeTexture(descriptor: d), let blit = cb.makeBlitCommandEncoder() {
                blit.copy(from: drawable.texture, to: tex)
                blit.endEncoding()
                capture = tex
            }
        }
        cb.present(drawable)
        cb.commit()
        if let tex = capture, let path = shotPath {
            cb.waitUntilCompleted()
            savePNG(tex, path)
            exit(0)
        }
    }

    private func savePNG(_ tex: MTLTexture, _ path: String) {
        let w = tex.width, h = tex.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info),
              let img = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
