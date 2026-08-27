import CoreGraphics
import Foundation
import ImageIO
import Testing
import VRMTestSupport
@testable import VRMKit

/// Rewriting what a model calls itself. The two VRM versions spell all three fields
/// differently, so every test runs over one model of each and asks the reading side
/// what the document now says.
@Suite
struct VRMMetaWritingTests {
    // MARK: - Thumbnail

    /// The image written is the image read back, and it is still an image the platform
    /// decodes rather than bytes filed under the right key.
    @Test(arguments: [VRMSampleAsset.aliciaSolid, .seedSan])
    func testTheThumbnailWrittenIsTheOneReadBack(asset: VRMSampleAsset) throws {
        let image = try thumbnailBytes(of: asset.replacement)
        var document = try GLTFEditableDocument(data: asset.data)

        try document.setVRMThumbnail(image)

        let saved = try VRM(data: try document.serialize())
        #expect(try thumbnailBytes(of: saved) == image)
        #expect(try saved.thumbnail.width > 0)
    }

    @Test(arguments: [VRMSampleAsset.aliciaSolid, .seedSan])
    func testAModelWithNoThumbnailIsGivenOne(asset: VRMSampleAsset) throws {
        let image = try thumbnailBytes(of: asset.replacement)
        var document = try GLTFEditableDocument(data: try asset.withoutAThumbnail())
        #expect(throws: VRMError.self) { try VRM(data: try document.serialize()).thumbnail }

        try document.setVRMThumbnail(image)

        #expect(try thumbnailBytes(of: try VRM(data: try document.serialize())) == image)
    }

    @Test(arguments: [VRMSampleAsset.aliciaSolid, .seedSan])
    func testReplacingTheThumbnailLeavesTheRestOfTheModelWhereItWas(asset: VRMSampleAsset) throws {
        let before = try VRM(data: asset.data)
        var document = try GLTFEditableDocument(data: asset.data)

        try document.setVRMThumbnail(try thumbnailBytes(of: asset.replacement))

        let saved = try VRM(data: try document.serialize())
        #expect(saved.name == before.name)
        #expect(saved.specVersion == before.specVersion)
        #expect(saved.humanoidBoneNodeIndices() == before.humanoidBoneNodeIndices())
        #expect(saved.document.gltf.meshes.count == before.document.gltf.meshes.count)
    }

    /// The replaced thumbnail's bytes stay in the file until pruning finds nothing reads them.
    @Test(arguments: [VRMSampleAsset.aliciaSolid, .seedSan])
    func testPruningReclaimsTheReplacedThumbnail(asset: VRMSampleAsset) throws {
        let replaced = try thumbnailBytes(of: asset)
        let image = try thumbnailBytes(of: asset.replacement)
        var document = try GLTFEditableDocument(data: asset.data)

        try document.setVRMThumbnail(image)
        #expect(try document.serialize().range(of: replaced) != nil)
        try document.prune()

        let saved = try document.serialize()
        #expect(saved.range(of: replaced) == nil)
        #expect(try thumbnailBytes(of: try VRM(data: saved)) == image)
    }

    /// A thumbnail a material samples as well is a texture of the model, so replacing it
    /// takes nothing away from what the model draws.
    @Test(arguments: [VRMSampleAsset.aliciaSolid, .seedSan])
    func testPruningKeepsAReplacedThumbnailAMaterialStillSamples(asset: VRMSampleAsset) throws {
        let shared = try thumbnailBytes(of: asset)
        var document = try GLTFEditableDocument(data: try asset.sharingItsThumbnailWithADrawnTexture())

        try document.setVRMThumbnail(try thumbnailBytes(of: asset.replacement))
        try document.prune()

        #expect(try document.serialize().range(of: shared) != nil)
    }

    /// glTF holds PNG and JPEG and nothing else; transcoding is the caller's to do.
    @Test
    func testAThumbnailThatIsNeitherPNGNorJPEGIsRefusedWithoutChangingTheDocument() throws {
        var document = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        let before = try document.serialize()

        #expect(throws: VRMError.self) { try document.setVRMThumbnail(Data("RIFF____WEBPVP8 ".utf8)) }

        #expect(try document.serialize() == before)
    }

    /// VRM 1.0 asks for a square thumbnail, so one that is not is refused. VRM 0.x asks
    /// for no shape, and takes it.
    @Test
    func testANonSquareThumbnailIsRefusedByVRM1AndTakenByVRM0() throws {
        let wide = try pngData(width: 2, height: 1)

        var vrm1 = try GLTFEditableDocument(data: VRMSampleAsset.seedSan.data)
        let before = try vrm1.serialize()
        #expect(throws: VRMError.self) { try vrm1.setVRMThumbnail(wide) }
        #expect(try vrm1.serialize() == before)

        var vrm0 = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        try vrm0.setVRMThumbnail(wide)
        #expect(try thumbnailBytes(of: try VRM(data: try vrm0.serialize())) == wide)
    }

    /// A thumbnail is a picture, so bytes that only open like one are refused rather than
    /// filed away as an image nothing can draw.
    @Test(arguments: [VRMSampleAsset.aliciaSolid, .seedSan])
    func testAThumbnailThatDoesNotDecodeIsRefused(asset: VRMSampleAsset) throws {
        var document = try GLTFEditableDocument(data: asset.data)
        let before = try document.serialize()
        let signatureOnly = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 0, count: 32))

        #expect(throws: VRMError.self) { try document.setVRMThumbnail(signatureOnly) }

        #expect(try document.serialize() == before)
    }

    // MARK: - Name and authors

    @Test(arguments: [VRMSampleAsset.aliciaSolid, .seedSan])
    func testTheNameWrittenIsTheOneReadBack(asset: VRMSampleAsset) throws {
        var document = try GLTFEditableDocument(data: asset.data)

        try document.setVRMName("Composed Avatar")

        #expect(try VRM(data: try document.serialize()).name == "Composed Avatar")
    }

    /// VRM 1.0 keeps the list as a list; VRM 0.x has one line to say it in, so the names
    /// are joined into it.
    @Test(arguments: [VRMSampleAsset.aliciaSolid, .seedSan])
    func testTheAuthorsWrittenAreTheOnesReadBack(asset: VRMSampleAsset) throws {
        var document = try GLTFEditableDocument(data: asset.data)

        try document.setVRMAuthors(["Ada", "Grace"])

        switch try VRM(data: try document.serialize()) {
        case .v0(let vrm0): #expect(vrm0.meta.author == "Ada, Grace")
        case .v1(let vrm1): #expect(vrm1.meta.authors == ["Ada", "Grace"])
        }
    }

    /// The licence a model is distributed under comes through untouched.
    @Test(arguments: [VRMSampleAsset.aliciaSolid, .seedSan])
    func testWritingTheMetaLeavesTheLicenceAsItWasAuthored(asset: VRMSampleAsset) throws {
        let before = try licence(of: try VRM(data: asset.data))
        var document = try GLTFEditableDocument(data: asset.data)

        try document.setVRMName("Composed Avatar")
        try document.setVRMAuthors(["Ada"])
        try document.setVRMThumbnail(try thumbnailBytes(of: asset.replacement))

        #expect(try licence(of: try VRM(data: try document.serialize())) == before)
    }

    /// VRM 1.0 puts a minimum length on the name and the author list, so the writer
    /// refuses what would fail it. VRM 0.x has no such minimum.
    @Test
    func testAnEmptyNameOrAuthorListIsRefusedByVRM1AndTakenByVRM0() throws {
        var vrm1 = try GLTFEditableDocument(data: VRMSampleAsset.seedSan.data)
        let before = try vrm1.serialize()
        #expect(throws: VRMError.self) { try vrm1.setVRMName("") }
        #expect(throws: VRMError.self) { try vrm1.setVRMAuthors([]) }
        #expect(throws: VRMError.self) { try vrm1.setVRMAuthors([""]) }
        #expect(throws: VRMError.self) { try vrm1.setVRMAuthors(["Ada", ""]) }
        #expect(try vrm1.serialize() == before)

        var vrm0 = try GLTFEditableDocument(data: VRMSampleAsset.aliciaSolid.data)
        try vrm0.setVRMName("")
        try vrm0.setVRMAuthors([])
        switch try VRM(data: try vrm0.serialize()) {
        case .v0(let model):
            #expect(model.meta.title == "")
            #expect(model.meta.author == "")
        case .v1: Issue.record("the 0.x fixture is not a 0.x model")
        }
    }

    // MARK: - Documents this cannot write

    /// Reading takes `1.0-beta`, but a beta model does not hold the fields 1.0 writes, so
    /// an edit is refused rather than mixing the two.
    @Test
    func testWritingTheMetaOfABetaVRM1IsRefused() throws {
        let beta = try VRMSampleAsset.seedSan.withVRMCSpecVersion("1.0-beta")
        var document = try GLTFEditableDocument(data: beta)
        let before = try document.serialize()

        #expect(throws: VRMError.self) { try document.setVRMName("Composed Avatar") }

        #expect(try document.serialize() == before)
    }

    /// A meta that is not an object cannot be written through, so it is refused rather
    /// than replaced with a fresh one holding only the new field.
    @Test(arguments: [VRMSampleAsset.aliciaSolid, .seedSan])
    func testWritingThroughAMetaThatIsNotAnObjectIsRefused(asset: VRMSampleAsset) throws {
        let broken = try asset.rewritingJSON { json in
            var extensions = try #require(json.object("extensions"))
            let name = extensions["VRMC_vrm"] != nil ? "VRMC_vrm" : "VRM"
            var vrm = try #require(extensions.object(name))
            vrm["meta"] = "broken"
            extensions[name] = .object(vrm)
            json["extensions"] = .object(extensions)
        }
        var document = try GLTFEditableDocument(data: broken)
        let before = try document.serialize()

        #expect(throws: VRMError.self) { try document.setVRMName("Composed Avatar") }
        #expect(throws: VRMError.self) { try document.setVRMAuthors(["Ada"]) }

        #expect(try document.serialize() == before)
    }

    /// A document saying it is both versions is not one to guess about, and one whose VRM
    /// extension is not an object is not one to write over.
    @Test
    func testWritingTheMetaOfADocumentThatIsNotOneVRMIsRefused() throws {
        let both = try VRMSampleAsset.aliciaSolid.rewritingJSON { json in
            var extensions = json.object("extensions") ?? [:]
            extensions["VRMC_vrm"] = ["specVersion": "1.0"]
            json["extensions"] = .object(extensions)
        }
        let malformed = try VRMSampleAsset.aliciaSolid.rewritingJSON { json in
            var extensions = json.object("extensions") ?? [:]
            extensions["VRM"] = "invalid"
            json["extensions"] = .object(extensions)
        }

        for data in [both, malformed] {
            var document = try GLTFEditableDocument(data: data)
            let before = try document.serialize()
            #expect(throws: VRMError.self) { try document.setVRMName("Composed Avatar") }
            #expect(try document.serialize() == before)
        }
    }

    // MARK: - Documents that are not VRM

    /// A plain glTF is refused rather than given a VRM extension it never claimed.
    @Test
    func testWritingTheMetaOfAGLTFThatIsNotAVRMIsRefused() throws {
        var document = try GLTFEditableDocument(data: GLTFSampleAsset.boxVertexColors.data)
        let before = try document.serialize()

        #expect(throws: VRMError.self) { try document.setVRMName("Not an avatar") }
        #expect(throws: VRMError.self) { try document.setVRMAuthors(["Ada"]) }
        #expect(throws: VRMError.self) {
            try document.setVRMThumbnail(try thumbnailBytes(of: .seedSan))
        }

        #expect(try document.serialize() == before)
    }
}

// MARK: - Reading back

/// The bytes the model's thumbnail is stored as, so a write can be compared without
/// decoding an image on either side.
private func thumbnailBytes(of vrm: VRM) throws -> Data {
    let image = try vrm.document.gltf.load(\.images, at: try vrm.thumbnailImageIndex.rawValue)
    return try vrm.document.bufferViewData(at: try #require(image.bufferView)).data
}

private func thumbnailBytes(of asset: VRMSampleAsset) throws -> Data {
    try thumbnailBytes(of: try VRM(data: asset.data))
}

/// What the model is licensed as, which no editing API of this package writes.
private func licence(of vrm: VRM) throws -> [String] {
    switch vrm {
    case .v0(let vrm0):
        [vrm0.meta.licenseName, vrm0.meta.allowedUserName, vrm0.meta.otherLicenseUrl].map { $0 ?? "" }
    case .v1(let vrm1):
        [vrm1.meta.licenseUrl, vrm1.meta.avatarPermission?.rawValue, vrm1.meta.otherLicenseUrl].map { $0 ?? "" }
    }
}

private extension VRM {
    /// The nodes the humanoid is built out of, standing for every index the VRM
    /// extensions hold.
    func humanoidBoneNodeIndices() -> [Int] {
        HumanoidBone.allCases.compactMap { nodeIndex(of: $0) }.sorted()
    }
}

// MARK: - Fixtures

/// A real PNG of the given size, for the checks the writer makes on a thumbnail.
private func pngData(width: Int, height: Int) throws -> Data {
    let context = try #require(CGContext(data: nil,
                                         width: width,
                                         height: height,
                                         bitsPerComponent: 8,
                                         bytesPerRow: width * 4,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let encoded = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return encoded as Data
}

private extension VRMSampleAsset {
    /// The model whose thumbnail stands in for a freshly rendered one: a real image, so
    /// the round trip can be decoded rather than only compared.
    var replacement: VRMSampleAsset {
        self == .seedSan ? .aliciaSolid : .seedSan
    }

    /// The fixture with the thumbnail taken out of its meta, as a model that never had
    /// one reads.
    func withoutAThumbnail() throws -> Data {
        try rewritingJSON { json in
            var extensions = json.object("extensions") ?? [:]
            for (name, key) in [(GLTFExtension.vrm0.rawValue, "texture"),
                                (GLTFExtension.vrm1.rawValue, "thumbnailImage")] {
                guard var vrm = extensions.object(name),
                      var meta = vrm.object("meta") else { continue }
                meta.removeValue(forKey: key)
                vrm["meta"] = .object(meta)
                extensions[name] = .object(vrm)
            }
            json["extensions"] = .object(extensions)
        }
    }

    /// The fixture with its thumbnail image sampled by a texture the model draws with,
    /// which is what makes a replaced thumbnail worth keeping.
    func sharingItsThumbnailWithADrawnTexture() throws -> Data {
        let thumbnail = try VRM(data: data).thumbnailImageIndex.rawValue
        return try rewritingJSON { json in
            var textures = json.objects("textures")
            textures[0]["source"] = .int(thumbnail)
            json["textures"] = .objects(textures)
        }
    }
}
