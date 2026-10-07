import Foundation

/// [Float] ↔ Data 的紧凑编解码（向量持久化到 SwiftDate `Data?` 字段）。
///
/// 采用 Float 二进制直接落字节（1024 维 ≈ 4 KB）；字节序统一为 littleEndian，
/// 解码时长度不符（损坏/换维度）返回 nil，由调用方触发重新嵌入，不做截断猜测。
public enum VectorCoding {

    public static func data(from vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * MemoryLayout<Float>.size)
        for value in vector {
            var little = value.bitPattern.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        return data
    }

    public static func vector(from data: Data) -> [Float]? {
        let byteCount = MemoryLayout<UInt32>.size
        guard data.count % byteCount == 0 else { return nil }
        let count = data.count / byteCount
        var result: [Float] = []
        result.reserveCapacity(count)

        return data.withUnsafeBytes { rawBuffer -> [Float] in
            guard let base = rawBuffer.bindMemory(to: UInt32.self).baseAddress else { return [] }
            for i in 0..<count {
                let bits = base.advanced(by: i).pointee
                result.append(Float(bitPattern: UInt32(littleEndian: bits)))
            }
            return result
        }
    }
}
