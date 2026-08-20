import Foundation

/// The fixtures under `Tests/Assets`, which this target owns as its resources.
///
/// Every test target reaches them through `VRMTestSupport`, so they are copied
/// into one bundle instead of one per test target, and the lookups need no
/// bundle from the caller. Paths are relative to `Tests/Assets`, e.g.
/// `"GLTF/Triangle/Triangle.gltf"`.
enum TestAssetBundle {
    static func url(forFixture path: String) -> URL {
        let directory = (path as NSString).deletingLastPathComponent
        let file = (path as NSString).lastPathComponent as NSString
        guard let url = Bundle.module.url(forResource: file.deletingPathExtension,
                                          withExtension: file.pathExtension,
                                          subdirectory: directory) else {
            fatalError("Failed to locate the \(path) fixture in \(Bundle.module.bundlePath).")
        }
        return url
    }

    /// The fixture's bytes, read once per test process. The VRM fixtures are
    /// ~10 MB each and the tests read them over and over.
    static func data(forFixture path: String) -> Data {
        cache.data(forFixture: path)
    }

    private static let cache = FixtureCache()

    /// Swift Testing runs tests in parallel, so the cache takes a lock.
    private final class FixtureCache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: Data] = [:]

        func data(forFixture path: String) -> Data {
            lock.lock()
            defer { lock.unlock() }
            if let cached = storage[path] {
                return cached
            }
            guard let data = try? Data(contentsOf: url(forFixture: path)) else {
                fatalError("Failed to read the \(path) fixture.")
            }
            storage[path] = data
            return data
        }
    }
}
