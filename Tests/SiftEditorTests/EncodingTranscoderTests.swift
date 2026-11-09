import XCTest
@testable import SiftEditorCore

/// 验证编码转换和保存的核心（行边界流转换）。
/// 关键在于，即使使用极端的切片（一次处理 1 个字节 = 多字节分割）处理原始数据，字符也不会被分割。
final class EncodingTranscoderTests: XCTestCase {
    /// 执行将字节序列拆分为 `sliceSize` 段并将其转换为 feed 段的转换，然后将输出连接起来并返回。
    private func transcode(_ input: Data, from s: DetectedEncoding, to t: DetectedEncoding,
                           sliceSize: Int) throws -> (Data, Bool) {
        let bytes = [UInt8](input)
        var out = Data()
        let lossy = try EncodingTranscoder.stream(
            from: s, to: t,
            feed: { sink in
                var i = 0
                while i < bytes.count {
                    let j = min(i + sliceSize, bytes.count)
                    try sink(bytes[i..<j])
                    i = j
                }
            },
            emit: { out.append($0) })
        return (out, lossy)
    }

    /// 将  / UTF-8 中的多行日文文本传输到 Shift-JIS。即使一次处理 1 个字节，也不会超过多字节限制。
    func testUTF8ToShiftJISByteByByte() throws {
        let text = "日本語のログ\nエラー: 発生\n最終行"       // 末尾无换行符
        let input = text.data(using: .utf8)!
        for slice in [1, 3, 7, 4096] {                       // 即使分割模式改变，也保持不变。
            let (out, lossy) = try transcode(input, from: .utf8, to: .shiftJIS, sliceSize: slice)
            XCTAssertFalse(lossy)
            XCTAssertEqual(String(data: out, encoding: .shiftJIS), text, "sliceSize=\(slice)")
        }
    }

    /// CRLF 转换后仍为 CRLF（无论编码如何，0x0D 和 0x0A 都会变成 ASCII）。
    func testCRLFPreservedAcrossConversion() throws {
        let input = "あ\r\nい\r\nう".data(using: .utf8)!
        let (out, _) = try transcode(input, from: .utf8, to: .eucJP, sliceSize: 2)
        XCTAssertEqual(String(data: out, encoding: .japaneseEUC), "あ\r\nい\r\nう")
        XCTAssertTrue([UInt8](out).contains(0x0D))            // CR 正在保存。
    }

    /// Shift-JIS → UTF-8 反向匹配也成立。
    func testShiftJISToUTF8RoundTrips() throws {
        let text = "テスト\n二行目"
        let input = text.data(using: .shiftJIS)!
        let (out, lossy) = try transcode(input, from: .shiftJIS, to: .utf8, sliceSize: 3)
        XCTAssertFalse(lossy)
        XCTAssertEqual(String(data: out, encoding: .utf8), text)
    }

    /// 无法用目标编码表示的字符（表情符号 → Shift-JIS）表示为 lossy = true。
    func testUnrepresentableIsLossy() throws {
        let input = "hello 😀 world".data(using: .utf8)!
        let (_, lossy) = try transcode(input, from: .utf8, to: .shiftJIS, sliceSize: 4096)
        XCTAssertTrue(lossy)
    }

    /// 空输入导致空输出 - 不是 lossy。
    func testEmptyInput() throws {
        let (out, lossy) = try transcode(Data(), from: .utf8, to: .shiftJIS, sliceSize: 8)
        XCTAssertTrue(out.isEmpty)
        XCTAssertFalse(lossy)
    }
}
