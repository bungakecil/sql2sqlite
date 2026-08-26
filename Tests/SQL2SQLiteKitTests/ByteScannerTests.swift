import Testing
@testable import SQL2SQLiteKit

private func scanner(_ text: String, chunkSize: Int) -> ByteScanner {
    ByteScanner(source: ArrayByteSource(Array(text.utf8), chunkSize: chunkSize))
}

@Test(arguments: [1, 2, 3, 7, 4096])
func peeksAcrossChunkBoundaries(chunkSize: Int) throws {
    let s = scanner("SELECT 1", chunkSize: chunkSize)
    #expect(try s.peek() == UInt8(ascii: "S"))
    #expect(try s.peek(6) == UInt8(ascii: " "))
    #expect(try s.peek(7) == UInt8(ascii: "1"))
    #expect(try s.peek(8) == nil)
}

@Test(arguments: [1, 3, 4096])
func matchesKeywordCaseInsensitivelyAcrossChunks(chunkSize: Int) throws {
    let s = scanner("DeLiMiTeR ;;", chunkSize: chunkSize)
    #expect(try s.matches(Array("delimiter".utf8)))
    #expect(try s.matches(Array("delimiter".utf8), caseInsensitive: false) == false)
    #expect(try s.matches(Array("delimiterx".utf8)) == false)
}

@Test func tracksOffsetAndLine() throws {
    let s = scanner("ab\ncd", chunkSize: 2)
    #expect(s.offset == 0 && s.line == 1)
    try s.skip(3)                       // consumes "ab\n"
    #expect(s.offset == 3 && s.line == 2)
    #expect(try s.peek() == UInt8(ascii: "c"))
}

@Test func compactsSoMemoryDoesNotGrowWithInput() throws {
    // 1 MiB of input read one byte at a time must not retain the whole buffer.
    let s = scanner(String(repeating: "x", count: 1 << 20), chunkSize: 1024)
    for _ in 0..<(1 << 20) { _ = try s.advance() }
    #expect(try s.advance() == nil)
    #expect(s.offset == 1 << 20)
}

@Test func arrayByteSourceYieldsChunksThenNil() throws {
    let src = ArrayByteSource(Array("abcde".utf8), chunkSize: 2)
    #expect(try src.nextChunk() == Array("ab".utf8))
    #expect(try src.nextChunk() == Array("cd".utf8))
    #expect(try src.nextChunk() == Array("e".utf8))
    #expect(try src.nextChunk() == nil)
}
