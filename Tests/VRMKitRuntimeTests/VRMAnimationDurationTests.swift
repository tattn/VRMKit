import Foundation
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMKitRuntime

@Suite
struct VRMAnimationDurationTests {
    @Test(arguments: VRMASampleAsset.allCases)
    func testTheDurationIsWhatPlayingItWouldTake(asset: VRMASampleAsset) throws {
        let animation = try VRMAnimation(withURL: asset.url)
        let played = try #require(animation.document.gltf.animations.first)

        #expect(animation.duration > 0)
        #expect(animation.duration == GLTFAnimationDecoder(document: animation.document).duration(of: played))
    }

    /// Exporters leave out the time accessor's `max`, which the keyframes make up for
    @Test
    func testTheDurationDoesNotNeedTheTimeAccessorsMaximum() throws {
        let data = try Data(contentsOf: VRMASampleAsset.test.url)
        let expected = try VRMAnimation(data: data).duration
        let stripped = try GLBRewriter.rewritingJSON(of: data) { json in
            guard case .array(let accessors)? = json["accessors"] else { return }
            json["accessors"] = .array(accessors.map { accessor in
                guard case .object(var fields) = accessor else { return accessor }
                fields["max"] = nil
                fields["min"] = nil
                return .object(fields)
            })
        }

        #expect(try VRMAnimation(data: stripped).duration == expected)
    }

    @Test
    func testAPoseKeyedOnlyAtTimeZeroLastsNoTime() throws {
        let data = try Data(contentsOf: VRMASampleAsset.test.url)
        let animation = try VRMAnimation(data: data)
        let inputs = Set(try #require(animation.document.gltf.animations.first).samplers.map(\.input))
        let singleKey = try GLBRewriter.rewritingJSON(of: data) { json in
            guard case .array(let accessors)? = json["accessors"] else { return }
            json["accessors"] = .array(accessors.enumerated().map { index, accessor in
                guard inputs.contains(index), case .object(var fields) = accessor else { return accessor }
                fields["count"] = .int(1)
                return .object(fields)
            })
        }

        #expect(try VRMAnimation(data: singleKey).duration == 0)
    }

    @Test
    func testASamplerWithUnreadableTimesCountsForNothing() throws {
        let data = try Data(contentsOf: VRMASampleAsset.test.url)
        let broken = try GLBRewriter.rewritingJSON(of: data) { json in
            json["accessors"] = .array([])
        }

        #expect(try VRMAnimation(data: broken).duration == 0)
    }

    @Test
    func testAFileWithoutAnimationsLastsNoTime() throws {
        let data = try Data(contentsOf: VRMASampleAsset.test.url)
        let stripped = try GLBRewriter.rewritingJSON(of: data) { json in
            json["animations"] = nil
        }

        #expect(try VRMAnimation(data: stripped).duration == 0)
    }
}
