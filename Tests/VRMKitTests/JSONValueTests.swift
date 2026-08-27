import Foundation
import Testing
@testable import VRMKit

/// The one shape the untyped parts of a glTF travel in: what a load parses, what
/// an edit builds, and what a typed model decodes out of.
@Suite
struct JSONValueTests {
    @Test
    func testParsingReadsEveryJSONShape() throws {
        let value = try JSONValue(parsing: Data("""
            {"n": null, "t": true, "i": 7, "d": 1.5, "s": "x", "a": [1, "two"], "o": {"k": 0}}
            """.utf8))

        let object = try #require(value.objectValue)
        #expect(object["n"] == .null)
        #expect(object["t"] == .bool(true))
        #expect(object["i"] == .int(7))
        #expect(object["d"] == .double(1.5))
        #expect(object["s"] == .string("x"))
        #expect(object["a"] == .array([.int(1), .string("two")]))
        #expect(object["o"] == .object(["k": .int(0)]))
    }

    /// A number written without a fraction is written back out without one, so
    /// an edit does not turn every index of a document into `1.0`.
    @Test
    func testAWholeNumberRoundTripsWithoutAFraction() throws {
        let value = try JSONValue(parsing: Data(#"{"byteOffset": 256, "scale": 0.5}"#.utf8))

        let text = String(decoding: try value.serialized(), as: UTF8.self)
        #expect(text == #"{"byteOffset":256,"scale":0.5}"#)
    }

    /// JSON has one number type, so the two spellings this package keeps apart
    /// are still the same number, and a dictionary has to agree.
    @Test
    func testTheTwoSpellingsOfANumberAreEqualAndHashAlike() {
        #expect(JSONValue.int(1) == .double(1.0))
        #expect(JSONValue.int(1).hashValue == JSONValue.double(1.0).hashValue)
        #expect(Set([JSONValue.int(1), .double(1.0)]).count == 1)
        #expect(JSONValue.int(1) != .string("1"))
        #expect(JSONValue.int(0) != .bool(false))
    }

    /// Past 2^53 a `Double` no longer holds every integer, and two numbers it
    /// rounds together are still two different numbers.
    @Test
    func testAnIntegerTooLargeForADoubleIsNotEqualToTheOneItRoundsTo() {
        let unrepresentable = 1 << 53 + 1

        #expect(JSONValue.int(unrepresentable) != .double(Double(unrepresentable)))
        #expect(Set([JSONValue.int(unrepresentable), .double(Double(unrepresentable))]).count == 2)
        #expect(JSONValue.int(1 << 53) == .double(Double(1 << 53)))
    }

    /// Keys are sorted so that writing the same document twice gives the same
    /// bytes, which is what makes a saved GLB comparable.
    @Test
    func testSerializingSortsKeys() throws {
        let value = JSONValue.object(["b": 1, "a": 2, "c": 3])

        #expect(String(decoding: try value.serialized(), as: UTF8.self) == #"{"a":2,"b":1,"c":3}"#)
    }

    // MARK: - Decoding

    private struct Fixture: Codable, Equatable {
        struct Nested: Codable, Equatable {
            let flag: Bool
            let names: [String]
        }

        let index: Int
        let scale: Float
        let name: String?
        let nested: Nested
        let optionalNested: Nested?
        let values: [Double]
    }

    /// Every typed model a document is read into comes through here, so it has
    /// to agree with `JSONDecoder` on every shape.
    @Test
    func testDecodingMatchesJSONDecoder() throws {
        let text = """
            {"index": 3, "scale": 0.25, "nested": {"flag": true, "names": ["a", "b"]}, \
            "values": [1, 2.5, -3]}
            """
        let data = Data(text.utf8)

        let walked = try JSONValue(parsing: data).decode(Fixture.self)

        #expect(walked == (try JSONDecoder().decode(Fixture.self, from: data)))
        #expect(walked.index == 3)
        #expect(walked.name == nil)
        #expect(walked.optionalNested == nil)
        #expect(walked.nested.names == ["a", "b"])
        #expect(walked.values == [1, 2.5, -3])
    }

    /// An explicit null is a value the document carries, and `decodeIfPresent`
    /// reads it as an omission the way `JSONDecoder` does.
    @Test
    func testAnExplicitNullDecodesAsAnOmission() throws {
        let value = try JSONValue(parsing: Data("""
            {"index": 1, "scale": 1, "name": null, "nested": {"flag": false, "names": []}, "values": []}
            """.utf8))

        #expect(try value.decode(Fixture.self).name == nil)
    }

    @Test
    func testDecodingReportsThePathOfAMismatch() throws {
        let value = try JSONValue(parsing: Data("""
            {"index": 1, "scale": 1, "nested": {"flag": "yes", "names": []}, "values": []}
            """.utf8))

        #expect(throws: DecodingError.self) { try value.decode(Fixture.self) }
    }

    /// A whole number is what a glTF index is, and a fraction or a value past
    /// what the field holds is not one.
    @Test
    func testNumbersReadAsTheKindTheFieldAsksFor() {
        #expect(JSONValue.double(2.0).intValue == 2)
        #expect(JSONValue.double(2.5).intValue == nil)
        #expect(JSONValue.int(-1).indexValue == nil)
        #expect(JSONValue.int(Int(Int32.max)).indexValue == Int(Int32.max))
        #expect(JSONValue.int(Int(Int32.max) + 1).indexValue == nil)
        #expect(JSONValue.string("3").intValue == nil)
        #expect(JSONValue.bool(true).intValue == nil)
        // A `Float` cannot hold 1e100, and an infinity in a renderer is worse
        // than falling back to a default.
        #expect(JSONValue.double(1e100).floatValue == nil)
        #expect(JSONValue.double(1e100).doubleValue == 1e100)
    }

    /// Decoding reads a number the same way, rather than handing a renderer the
    /// infinity the conversion overflows to.
    @Test
    func testANumberTooLargeForTheFieldFailsDecoding() throws {
        let value = try JSONValue(parsing: Data("""
            {"index": 1, "scale": 1e100, "nested": {"flag": true, "names": []}, "values": []}
            """.utf8))

        #expect(throws: DecodingError.self) { try value.decode(Fixture.self) }
        #expect(try JSONValue.double(1e100).decode(Double.self) == 1e100)
    }

    /// A glTF this package can only partly read still has to save unchanged, so
    /// what it carries survives a parse and a rewrite whatever shape it is in.
    @Test
    func testAnUnreadExtensionSurvivesAParseAndARewrite() throws {
        let text = """
            {"extensions":{"ACME_thing":{"deep":[{"flags":[true,false],"n":null}],"ratio":0.125}}}
            """

        let rewritten = try JSONValue(parsing: Data(text.utf8)).serialized()

        #expect(String(decoding: rewritten, as: UTF8.self) == text)
    }
}
