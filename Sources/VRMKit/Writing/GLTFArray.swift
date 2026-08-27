import Foundation

/// The top-level arrays of a glTF document, which its indices point into. Naming
/// them as a type makes a rebasing rule wrong at compile time, not at load time.
package enum GLTFArray: String, Sendable, CaseIterable {
    case accessors
    case animations
    case buffers
    case bufferViews
    case cameras
    case images
    case materials
    case meshes
    case nodes
    case samplers
    case scenes
    case skins
    case textures
}

package extension JSONObject {
    subscript(array: GLTFArray) -> JSONValue? {
        get { self[array.rawValue] }
        set { self[array.rawValue] = newValue }
    }

    mutating func setObjects(_ elements: [JSONObject], for array: GLTFArray) {
        self[array] = .objects(elements)
    }

    func objects(_ array: GLTFArray) -> [JSONObject] { objects(array.rawValue) }

    func count(_ array: GLTFArray) -> Int { count(array.rawValue) }

    mutating func mapObjects(_ array: GLTFArray, _ transform: (JSONObject) throws -> JSONObject) rethrows {
        try mapObjects(array.rawValue, transform)
    }

    mutating func updateObject(at index: Int,
                               in array: GLTFArray,
                               _ body: (inout JSONObject) throws -> Void) rethrows {
        try updateObject(at: index, in: array.rawValue, body)
    }

    mutating func appendObjects(_ elements: [JSONObject], to array: GLTFArray) {
        appendObjects(elements, to: array.rawValue)
    }

    @discardableResult
    mutating func appendObject(_ element: JSONObject, to array: GLTFArray) -> Int {
        appendObject(element, to: array.rawValue)
    }
}
