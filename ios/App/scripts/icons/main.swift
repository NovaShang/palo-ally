// Renders the app icons from the avatar itself (TwoDrops.metal +
// TwoDropsState.swift, compiled for the Mac by ../make_icons.sh): the two
// drops about to merge, joined by a liquid bridge, in each theme's pair of
// colors. Full-bleed 1024 squares (iOS applies the mask), with dark and
// tinted appearances.
//
// usage: icons <metallib> <Assets.xcassets> set:#primary:#partner ...
import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import simd

let args = CommandLine.arguments
let dev = MTLCreateSystemDefaultDevice()!
let lib = try! dev.makeLibrary(URL: URL(fileURLWithPath: args[1]))
let pso = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "twoDropsOffline")!)
let queue = dev.makeCommandQueue()!
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ s: Substring) -> SIMD3<Float> {
    let h = UInt32(s.dropFirst(), radix: 16)!
    return SIMD3(Float((h >> 16) & 0xFF) / 255, Float((h >> 8) & 0xFF) / 255, Float(h & 0xFF) / 255)
}

/// RGBA8 pixels of one square render. bg: 2 icon light, 3 icon dark.
func render(_ u: [Float], size: Int, bg: Int, ss: Int) -> [UInt8] {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
    d.usage = [.shaderWrite]
    let tex = dev.makeTexture(descriptor: d)!
    var params = u
    let rows = max(16, 160_000 / (size * ss * ss))
    var y = 0
    while y < size {
        var cfg = SIMD4<Float>(Float(size), Float(bg), Float(ss), Float(y))
        let cb = queue.makeCommandBuffer()!, enc = cb.makeComputeCommandEncoder()!
        enc.setComputePipelineState(pso)
        enc.setTexture(tex, index: 0)
        enc.setBytes(&params, length: params.count * 4, index: 0)
        enc.setBytes(&cfg, length: 16, index: 1)
        enc.dispatchThreads(MTLSize(width: size, height: min(rows, size - y), depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
        enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        y += rows
    }
    var buf = [UInt8](repeating: 0, count: size * size * 4)
    tex.getBytes(&buf, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
    for i in stride(from: 3, to: buf.count, by: 4) { buf[i] = 255 }
    return buf
}

func savePNG(_ buf: [UInt8], _ n: Int, _ path: String) {
    var b = buf
    let ctx = CGContext(data: &b, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: cs,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dst)
}

/// The brand pose: the two drops just about to merge, a liquid bridge between.
func iconUniforms(dark: Bool, primary: SIMD3<Float>, partner: SIMD3<Float>) -> [Float] {
    let st = TwoDropsState(primary: primary, partner: partner)
    st.reduceMotion = true
    st.advance(by: 0.1)
    var u = st.uniforms(dark: dark, scale: 1)
    let rA: Float = 0.52, rB: Float = 0.31
    let az: Float = 0.38, el: Float = 0.52
    let dir = simd_normalize(SIMD3<Float>(cos(el) * cos(az), sin(el), cos(el) * sin(az)))
    let sep: Float = 0.90
    let mA = rA * rA * rA, mB = rB * rB * rB
    let com = SIMD3<Float>(-0.04, -0.12, 0)
    let cA = com - dir * sep * mB / (mA + mB), cB = com + dir * sep * mA / (mA + mB)
    u[3] = 0.95                       // framing: room around the pair
    u[12] = cA.x; u[13] = cA.y; u[14] = cA.z; u[15] = rA
    u[16] = cB.x; u[17] = cB.y; u[18] = cB.z; u[19] = rB
    u[20] = dir.x; u[21] = dir.y; u[22] = dir.z; u[23] = 0.06   // a hint of reach toward 你
    u[26] = 0.26                      // a soft bridge
    u[27] = 0.25; u[28] = 1.3; u[55] = 0.2
    u[39] = -0.86
    return u
}

let assets = args[2]
for spec in args.dropFirst(3) {
    let p = spec.split(separator: ":")
    let folder = "\(assets)/\(p[0]).appiconset"
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let (primary, partner) = (color(p[1]), color(p[2]))
    let n = 1024
    let light = render(iconUniforms(dark: false, primary: primary, partner: partner), size: n, bg: 2, ss: 2)
    let dark = render(iconUniforms(dark: true, primary: primary, partner: partner), size: n, bg: 3, ss: 2)
    // tinted: the system colors a grayscale icon — the dark one's luminance
    var tinted = dark
    for i in stride(from: 0, to: tinted.count, by: 4) {
        let l = 0.2126 * Float(tinted[i]) + 0.7152 * Float(tinted[i + 1]) + 0.0722 * Float(tinted[i + 2])
        let v = UInt8(min(255, l * 1.25))
        tinted[i] = v; tinted[i + 1] = v; tinted[i + 2] = v
    }
    savePNG(light, n, "\(folder)/icon-1024.png")
    savePNG(dark, n, "\(folder)/icon-1024-dark.png")
    savePNG(tinted, n, "\(folder)/icon-1024-tinted.png")
    let json = """
    {
      "images" : [
        { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
        { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ], "filename" : "icon-1024-dark.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
        { "appearances" : [ { "appearance" : "luminosity", "value" : "tinted" } ], "filename" : "icon-1024-tinted.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }

    """
    try! json.write(toFile: "\(folder)/Contents.json", atomically: true, encoding: .utf8)
    print("wrote \(p[0])")
}
