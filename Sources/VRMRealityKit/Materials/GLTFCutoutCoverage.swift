#if canImport(RealityKit)
import CoreGraphics
import Foundation
import VRMKit
import simd

/// Whether a MASK material would ever discard a fragment: the base color alpha at every
/// texel its triangles sample, against its cutoff.
///
/// A fragment function that may discard keeps the GPU from rejecting hidden fragments
/// before shading them (see `mtoonAlpha`), which costs a MASK material a full shading of
/// everything behind it. Exporters mark whole models MASK while only the hair and lace
/// carry an alpha below the cutoff, so the skin and clothes of such a model discard
/// nothing and can draw opaque, keeping the rejection. The triangles are rasterized in
/// texel space rather than reading the whole image, since an atlas shared with a cut-out
/// part is transparent outside this material's islands.
enum GLTFCutoutCoverage {
    /// One image's alpha channel, a byte per texel, rows from the top.
    struct AlphaPlane: Sendable {
        let width: Int
        let height: Int
        let alpha: [UInt8]

        /// Nil for an image without an alpha channel, which is opaque everywhere.
        init?(_ image: CGImage) {
            switch image.alphaInfo {
            case .none, .noneSkipFirst, .noneSkipLast:
                return nil
            case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
                break
            @unknown default:
                break
            }
            let width = image.width
            let height = image.height
            // Drawn as RGBA rather than alpha-only, which Core Graphics gives no color
            // space for; premultiplying leaves the alpha itself as written.
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: 0,
                                          space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let pixels = context.data else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytesPerRow = context.bytesPerRow
            var alpha = [UInt8](repeating: 0, count: width * height)
            let bytes = pixels.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let row = bytes + y * bytesPerRow
                for x in 0..<width {
                    alpha[y * width + x] = row[x * 4 + 3]
                }
            }
            self.width = width
            self.height = height
            self.alpha = alpha
        }

        init(width: Int, height: Int, alpha: [UInt8]) {
            precondition(alpha.count == width * height)
            self.width = width
            self.height = height
            self.alpha = alpha
        }
    }

    /// How a material reads its base color: the UV transform it applies and the sampler's
    /// wrapping, which decide which texels a triangle's UVs land on.
    struct Sampling: Sendable {
        var transform = GLTFUVTransform()
        var wrapS = GLTF.Sampler.Wrap.REPEAT
        var wrapT = GLTF.Sampler.Wrap.REPEAT
    }

    /// Whether every texel the triangles sample has an alpha of at least `cutoff` once
    /// `alphaFactor` (the base color factor's alpha) is applied. A triangle's texels are
    /// those whose centers it covers; `nil` for the plane means the image has no alpha.
    ///
    /// `nil` when nothing can be told: no triangles, or a factor that cuts everything out
    /// (the material is then authored to vanish, which only the cutout draw honors).
    static func samplesOnlyOpaqueTexels(of plane: AlphaPlane?,
                                        texcoords: [SIMD2<Float>],
                                        indices: [UInt32],
                                        sampling: Sampling,
                                        alphaFactor: Float,
                                        cutoff: Float) -> Bool? {
        guard indices.count >= 3, alphaFactor >= cutoff else { return nil }
        guard let plane else { return true }
        // Texel alpha is 8-bit, so compare at that precision rather than in floats.
        let threshold = Self.threshold(cutoff: cutoff, alphaFactor: alphaFactor)
        guard threshold > 0 else { return true }
        let transform = sampling.transform
        let rotation = (cos: cos(transform.rotation), sin: sin(transform.rotation))
        let size = SIMD2<Float>(Float(plane.width), Float(plane.height))
        func texel(_ uv: SIMD2<Float>) -> SIMD2<Float> {
            // KHR_texture_transform: rotate, scale, then offset, as the shader does.
            let rotated = SIMD2<Float>(rotation.cos * uv.x + rotation.sin * uv.y,
                                       -rotation.sin * uv.x + rotation.cos * uv.y)
            return (rotated * transform.scale + transform.offset) * size
        }
        let triangleCount = indices.count / 3
        for triangle in 0..<triangleCount {
            let a = texel(texcoords[Int(indices[triangle * 3])])
            let b = texel(texcoords[Int(indices[triangle * 3 + 1])])
            let c = texel(texcoords[Int(indices[triangle * 3 + 2])])
            guard a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite, c.x.isFinite, c.y.isFinite else { continue }
            if !coversOnlyOpaqueTexels(plane, a, b, c, sampling: sampling, threshold: threshold) {
                return false
            }
        }
        return true
    }

    /// Whether every texel of the plane is opaque, for a material whose UVs move over time.
    /// `nil` when the factor cuts everything out.
    static func isOpaqueEverywhere(_ plane: AlphaPlane?, alphaFactor: Float, cutoff: Float) -> Bool? {
        guard alphaFactor >= cutoff else { return nil }
        guard let plane else { return true }
        let threshold = Self.threshold(cutoff: cutoff, alphaFactor: alphaFactor)
        return !plane.alpha.contains { Int($0) < threshold }
    }

    /// The texel alpha below which a sample is cut out, in the plane's 8-bit scale:
    /// `alpha * alphaFactor < cutoff` ⇔ `alpha < cutoff / alphaFactor`.
    static func threshold(cutoff: Float, alphaFactor: Float) -> Int {
        guard alphaFactor > 0 else { return 0 }
        return Int((cutoff / alphaFactor * 255).rounded(.up))
    }

    /// Walks the texels whose centers lie in the triangle, row by row between the edges
    /// the row crosses, wrapping each into the plane. Walking rows rather than the
    /// bounding box keeps a long thin triangle, the shape of a hair strip's UVs, to the
    /// texels it covers.
    private static func coversOnlyOpaqueTexels(_ plane: AlphaPlane,
                                               _ a: SIMD2<Float>,
                                               _ b: SIMD2<Float>,
                                               _ c: SIMD2<Float>,
                                               sampling: Sampling,
                                               threshold: Int) -> Bool {
        let minY = Int(floor(min(a.y, b.y, c.y)))
        let maxY = Int(ceil(max(a.y, b.y, c.y)))
        // A triangle spanning the plane many times over samples it whole.
        guard maxY - minY <= plane.height * 4, max(a.x, b.x, c.x) - min(a.x, b.x, c.x) <= Float(plane.width * 4) else {
            return !plane.alpha.contains { Int($0) < threshold }
        }
        let edges = [(a, b), (b, c), (c, a)]
        for y in minY..<maxY {
            let py = Float(y) + 0.5
            var left = Float.infinity
            var right = -Float.infinity
            for (start, end) in edges {
                // An edge crosses the row when the row's center lies between its ends;
                // one end exactly on it counts once, on the lower side.
                guard (start.y <= py) != (end.y <= py) else { continue }
                let x = start.x + (py - start.y) / (end.y - start.y) * (end.x - start.x)
                left = min(left, x)
                right = max(right, x)
            }
            guard left <= right, let row = wrapped(y, plane.height, sampling.wrapT) else { continue }
            let rowStart = row * plane.width
            // Texels whose centers lie in [left, right].
            let firstX = Int((left - 0.5).rounded(.up))
            let lastX = Int((right - 0.5).rounded(.down))
            guard firstX <= lastX else { continue }
            for x in firstX...lastX {
                guard let column = wrapped(x, plane.width, sampling.wrapS) else { continue }
                if Int(plane.alpha[rowStart + column]) < threshold { return false }
            }
        }
        return true
    }

    /// The texel a coordinate lands on under the sampler's wrapping.
    private static func wrapped(_ value: Int, _ extent: Int, _ wrap: GLTF.Sampler.Wrap) -> Int? {
        switch wrap {
        case .REPEAT:
            let remainder = value % extent
            return remainder < 0 ? remainder + extent : remainder
        case .CLAMP_TO_EDGE:
            return min(max(value, 0), extent - 1)
        case .MIRRORED_REPEAT:
            let period = extent * 2
            var remainder = value % period
            if remainder < 0 { remainder += period }
            return remainder < extent ? remainder : period - 1 - remainder
        }
    }
}
#endif
