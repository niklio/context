import Foundation

/// Decodes the message string out of a serialized NSAttributedString
/// (Apple typedstream) stored in message.attributedBody. Modern macOS
/// stores message text here; the `text` column is often NULL.
///
/// Layout: after the b"NSString" class marker come 5 bytes ending in '+'
/// (0x2b), then the length — one byte, or 0x81 + uint16-LE, or
/// 0x82 + uint32-LE for long strings — then the UTF-8 bytes.
enum TypedStream {
    static func decodeText(_ blob: Data) -> String? {
        let marker = Data("NSString".utf8)
        guard let range = blob.range(of: marker) else { return nil }
        var i = range.upperBound + 5
        guard i < blob.count else { return nil }

        let lengthByte = blob[blob.startIndex + i]
        var strlen = 0
        switch lengthByte {
        case 0x81:
            guard i + 3 <= blob.count else { return nil }
            strlen = Int(blob[blob.startIndex + i + 1]) | (Int(blob[blob.startIndex + i + 2]) << 8)
            i += 3
        case 0x82:
            guard i + 5 <= blob.count else { return nil }
            strlen = Int(blob[blob.startIndex + i + 1])
                | (Int(blob[blob.startIndex + i + 2]) << 8)
                | (Int(blob[blob.startIndex + i + 3]) << 16)
                | (Int(blob[blob.startIndex + i + 4]) << 24)
            i += 5
        default:
            strlen = Int(lengthByte)
            i += 1
        }
        guard strlen > 0, i + strlen <= blob.count else { return nil }
        let start = blob.index(blob.startIndex, offsetBy: i)
        let end = blob.index(start, offsetBy: strlen)
        return String(data: blob[start..<end], encoding: .utf8)
            ?? String(decoding: blob[start..<end], as: UTF8.self)
    }
}
