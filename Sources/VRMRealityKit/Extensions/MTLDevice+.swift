#if canImport(RealityKit)
import Metal

extension MTLDevice {
    /// A shared-storage buffer holding `values`, or nil for an empty array.
    func makeBuffer<Element>(_ values: [Element]) -> MTLBuffer? {
        guard !values.isEmpty else { return nil }
        return values.withUnsafeBytes { bytes in
            makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        }
    }
}
#endif
