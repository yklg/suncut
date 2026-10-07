import Testing
import Foundation
@testable import MixCutCore

@Test func vectorCoding_roundTripPreservesValues() {
    let vector: [Float] = [0.1, -1.5, 42.0, 0.0]
    let data = VectorCoding.data(from: vector)
    let decoded = try! #require(VectorCoding.vector(from: data))
    #expect(decoded.count == 4)
    for (a, b) in zip(vector, decoded) {
        #expect(abs(a - b) < 1e-6)
    }
}

@Test func vectorCoding_emptyVectorRoundTrips() {
    let data = VectorCoding.data(from: [])
    #expect(data.isEmpty)
    #expect(VectorCoding.vector(from: data) == [])
}

@Test func vectorCoding_corruptedOddLengthReturnsNil() {
    // 3 字节不是 4 的倍数 ⇒ 判损坏，不截断猜测
    #expect(VectorCoding.vector(from: Data([1, 2, 3])) == nil)
}

@Test func vectorCoding_1024DimensionsSizeIsFourKB() {
    let vector = [Float](repeating: 0.5, count: 1024)
    #expect(VectorCoding.data(from: vector).count == 4096)
}
