#if canImport(RealityKit)
import Foundation
import RealityKit
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// What the MToon outline actually measures on screen. Both width modes are
/// defined in units the parameter rows cannot show, meters of world space and
/// a fraction of the screen height, so they are asserted against pixels.
@Suite
@MainActor
struct MToonOutlineRenderingTests {
    private static let size = 256
    /// Leaves room around the cube for the outline band to land in.
    private static let cubeScale: Float = 0.3
    private static let width: Float = 0.06

    /// A cube turned 45°, since head-on every normal would point at the camera
    /// and the inverted hull would widen nothing. The fixture's node scales the
    /// mesh by 100, so a width resolved in the mesh's own space comes out a
    /// hundred times too wide, which is the point of measuring.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func cube(outlinedWith mode: MToonOutlineWidthMode?,
                      scale: SIMD3<Float>,
                      x: Float = 0,
                      width: Float = MToonOutlineRenderingTests.width) throws -> Entity {
        let style = MToonConversionStyle(outlineWidthMode: mode ?? .worldCoordinates,
                                         outlineWidthFactor: mode == nil ? 0 : width,
                                         outlineColorFactor: SIMD4<Float>(1, 0, 0, 1))
        let entity = try GLTFEntityLoader(withURL: GLTFSampleAsset.animatedMorphCube.url,
                                          shaders: [MToonShader(source: .convertAll(style))]).loadEntity()
        let root = Entity()
        root.addChild(entity)
        root.scale = scale
        root.orientation = simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 1, 0))
        root.position = SIMD3<Float>(x, 0, 0)
        return root
    }

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func cube(outlinedWith mode: MToonOutlineWidthMode?,
                      scale: Float,
                      x: Float = 0,
                      width: Float = MToonOutlineRenderingTests.width) throws -> Entity {
        try cube(outlinedWith: mode, scale: SIMD3<Float>(repeating: scale), x: x, width: width)
    }

    private func isDrawn(_ pixel: SIMD3<Float>) -> Bool { pixel.max() > 8 }

    /// The drawn pixels across the middle row: the silhouette's width.
    private func silhouetteWidth(_ image: [[SIMD3<Float>]]) -> Int {
        image[image.count / 2].count(where: isDrawn)
    }

    /// How many pixels the outline adds to the silhouette's width, measured with
    /// and without it so the cube's own size cancels out.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func outlineGrowth(mode: MToonOutlineWidthMode,
                               scale: SIMD3<Float> = SIMD3<Float>(repeating: cubeScale),
                               viewport: (width: Int, height: Int) = (size, size)) throws -> Int {
        let bare = try OffscreenRenderer.render(cube(outlinedWith: nil, scale: scale),
                                                width: viewport.width, height: viewport.height)
        let outlined = try OffscreenRenderer.render(cube(outlinedWith: mode, scale: scale),
                                                    width: viewport.width, height: viewport.height)
        return silhouetteWidth(outlined) - silhouetteWidth(bare)
    }

    /// A screen-space width is a fraction of the screen, so it must not inherit
    /// the model-to-world scale: doubling it doubles the cube on screen and
    /// leaves the outline exactly as thick.
    @Test
    func testScreenCoordinateWidthIgnoresEntityScale() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *), OffscreenRenderer.isAvailable,
              TestSupport.isMToonRenderingAvailable else { return }
        let atScale = try outlineGrowth(mode: .screenCoordinates, scale: SIMD3<Float>(repeating: Self.cubeScale))
        let atDoubleScale = try outlineGrowth(mode: .screenCoordinates, scale: SIMD3<Float>(repeating: Self.cubeScale * 2))

        #expect(atScale > 4, "no outline band to measure")
        #expect(abs(atDoubleScale - atScale) <= 2,
                "screen-space outline grew the silhouette by \(atScale)px, then \(atDoubleScale)px at twice the scale")
    }

    /// What separates the two modes: pull the camera back and a screen-space
    /// outline holds its pixels while a world-space one shrinks with the model.
    /// Nothing else here tells them apart, orthographic shrinking neither.
    @Test
    func testScreenCoordinateWidthHoldsItsPixelsAsWorldCoordinateWidthShrinks() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *), OffscreenRenderer.isAvailable,
              TestSupport.isMToonRenderingAvailable else { return }
        let near: Float = 1.2
        let far = near * 3

        func growth(_ mode: MToonOutlineWidthMode, at distance: Float, width: Float) throws -> Int {
            let bare = try OffscreenRenderer.renderPerspective(cube(outlinedWith: nil, scale: Self.cubeScale),
                                                               size: Self.size, distance: distance)
            let outlined = try OffscreenRenderer.renderPerspective(
                cube(outlinedWith: mode, scale: Self.cubeScale, width: width),
                size: Self.size, distance: distance)
            return silhouetteWidth(outlined) - silhouetteWidth(bare)
        }

        let screenNear = try growth(.screenCoordinates, at: near, width: Self.width)
        let screenFar = try growth(.screenCoordinates, at: far, width: Self.width)
        let worldNear = try growth(.worldCoordinates, at: near, width: Self.width)
        let worldFar = try growth(.worldCoordinates, at: far, width: Self.width)

        #expect(screenNear > 8, "no outline band to measure")
        // Held, not fixed: the width comes from a first-order probe of the
        // projection, which reads a few percent wide close to the camera.
        #expect(screenFar * 4 > screenNear * 3,
                "screen-space outline measured \(screenNear)px near and \(screenFar)px far, expected it to hold")
        // A fixed distance in the world, so tripling the distance leaves about
        // a third of the pixels.
        #expect(worldFar * 2 < worldNear,
                "world-space outline measured \(worldNear)px near and \(worldFar)px far, expected it to shrink")
    }

    /// Squashing the model moves the normals the outline is pushed along, but
    /// not the band: a screen-space width is a distance on screen.
    @Test
    func testScreenCoordinateWidthSurvivesNonUniformScale() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *), OffscreenRenderer.isAvailable,
              TestSupport.isMToonRenderingAvailable else { return }
        let uniform = try outlineGrowth(mode: .screenCoordinates,
                                        scale: SIMD3<Float>(repeating: Self.cubeScale))
        let squashed = try outlineGrowth(mode: .screenCoordinates,
                                         scale: SIMD3<Float>(Self.cubeScale * 2,
                                                             Self.cubeScale * 0.5,
                                                             Self.cubeScale))

        #expect(uniform > 4, "no outline band to measure")
        #expect(abs(squashed - uniform) <= 2,
                "screen-space outline grew the silhouette by \(uniform)px uniformly, \(squashed)px squashed")
    }

    /// A world-space width is a distance in meters, so it must not inherit the
    /// entity's scale either.
    @Test
    func testWorldCoordinateWidthIgnoresEntityScale() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *), OffscreenRenderer.isAvailable,
              TestSupport.isMToonRenderingAvailable else { return }
        let atScale = try outlineGrowth(mode: .worldCoordinates, scale: SIMD3<Float>(repeating: Self.cubeScale))
        let atDoubleScale = try outlineGrowth(mode: .worldCoordinates, scale: SIMD3<Float>(repeating: Self.cubeScale * 2))

        #expect(atScale > 4, "no outline band to measure")
        #expect(abs(atDoubleScale - atScale) <= 2,
                "world-space outline grew the silhouette by \(atScale)px, then \(atDoubleScale)px at twice the scale")
    }

    /// The outline is drawn past the mesh's bounding box, so it needs a culling
    /// margin: without one RealityKit drops the pass as soon as that box leaves
    /// the frustum, taking an outline that is still on screen with it.
    @Test
    func testOutlineSurvivesCullingAtTheFrustumEdge() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *), OffscreenRenderer.isAvailable,
              TestSupport.isMToonRenderingAvailable else { return }
        // Far enough right that the cube itself is outside the frustum and only
        // its outline reaches back in.
        let offscreen: Float = 1.45
        let bare = try OffscreenRenderer.render(cube(outlinedWith: nil, scale: Self.cubeScale, x: offscreen),
                                                size: Self.size)
        let outlined = try OffscreenRenderer.render(cube(outlinedWith: .worldCoordinates,
                                                         scale: Self.cubeScale,
                                                         x: offscreen),
                                                    size: Self.size)

        #expect(silhouetteWidth(bare) == 0, "the cube itself must be off screen for this to measure culling")
        #expect(silhouetteWidth(outlined) > 0, "the outline was culled with the bounding box it reaches outside of")
    }

    /// A screen-coordinate width holds its on-screen size at any distance, so
    /// far from a perspective camera its world-space offset grows toward the
    /// mesh radius funding the culling margin. Still within that radius here;
    /// the pass must survive culling at the frustum edge like the world one.
    /// Past the radius the shader clamps the offset instead, see the budget
    /// test below, so the outline can never outrun the box it is culled by.
    @Test
    func testScreenCoordinateOutlineSurvivesCullingAtTheFrustumEdgeFarAway() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *), OffscreenRenderer.isAvailable,
              TestSupport.isMToonRenderingAvailable else { return }
        let distance: Float = 6
        // A 60° vertical field of view on a square viewport frames this
        // half-width at the cube's depth.
        let frameHalfWidth = distance * tan(Float.pi / 6)
        // Far enough right that the cube itself is outside the frustum, near
        // enough that the outline reaches in: 0.06 of the screen height is
        // 0.06 * 2 * distance * tan(30°) ≈ 0.42 in the world here.
        let offscreen = frameHalfWidth + 0.65

        let bare = try OffscreenRenderer.renderPerspective(
            cube(outlinedWith: nil, scale: Self.cubeScale, x: offscreen),
            size: Self.size, distance: distance)
        let outlined = try OffscreenRenderer.renderPerspective(
            cube(outlinedWith: .screenCoordinates, scale: Self.cubeScale, x: offscreen),
            size: Self.size, distance: distance)

        #expect(silhouetteWidth(bare) == 0, "the cube itself must be off screen for this to measure culling")
        #expect(silhouetteWidth(outlined) > 0, "the outline was culled with the bounding box it reaches outside of")
    }

    /// The geometry modifier clamps its offset to the bounds margin the loader
    /// granted the pass, so a screen-space outline far from the camera
    /// saturates at the mesh radius in the world instead of outrunning the box
    /// it is culled by. The saturated band still scales with the entity,
    /// pinning the clamp to that margin rather than to a distance in the world.
    @Test
    func testScreenCoordinateWidthSaturatesAtTheCullingMarginFarAway() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *), OffscreenRenderer.isAvailable,
              TestSupport.isMToonRenderingAvailable else { return }
        func growth(scale: Float, distance: Float) throws -> Int {
            let bare = try OffscreenRenderer.renderPerspective(
                cube(outlinedWith: nil, scale: scale), size: Self.size, distance: distance)
            let outlined = try OffscreenRenderer.renderPerspective(
                cube(outlinedWith: .screenCoordinates, scale: scale), size: Self.size, distance: distance)
            return silhouetteWidth(outlined) - silhouetteWidth(bare)
        }

        // Near the camera the nominal screen width fits inside the margin and
        // is drawn in full; far away it saturates to a fixed world distance, so
        // the band thins with distance instead of holding its pixels.
        let nominal = try growth(scale: Self.cubeScale, distance: 3)
        let saturated = try growth(scale: Self.cubeScale, distance: 30)
        #expect(nominal > 8, "no outline band to measure")
        #expect(saturated * 2 < nominal,
                "expected the far outline to saturate below \(nominal)px, measured \(saturated)px")

        // The margin is measured in mesh space, so scaling the entity scales
        // the saturated band with it.
        let saturatedAtDoubleScale = try growth(scale: Self.cubeScale * 2, distance: 30)
        #expect(abs(saturatedAtDoubleScale - saturated * 2) <= 2,
                "saturated band measured \(saturated)px, then \(saturatedAtDoubleScale)px at twice the scale")
    }

    /// MToon measures a screen-space width against the screen *height*, and the
    /// camera frames the same height either way, so widening the viewport must
    /// not change the sideways band.
    @Test
    func testScreenCoordinateWidthIsMeasuredAgainstScreenHeight() throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *), OffscreenRenderer.isAvailable,
              TestSupport.isMToonRenderingAvailable else { return }
        let square = try outlineGrowth(mode: .screenCoordinates, viewport: (Self.size, Self.size))
        let wide = try outlineGrowth(mode: .screenCoordinates, viewport: (Self.size * 2, Self.size))

        #expect(square > 4, "no outline band to measure")
        #expect(abs(wide - square) <= 2,
                "screen-space outline grew the silhouette by \(square)px on a square viewport, \(wide)px on a 2:1 one")
    }
}
#endif
