import Foundation

/// Pull one complete event at a time. Unlike AsyncBytes.lines, preserve blank lines;
/// unlike a producer task, do not read ahead into an unbounded event queue.
enum SSEDecoder {
    static func events<Bytes: AsyncSequence>(_ bytes: Bytes) -> Events<Bytes> where Bytes.Element == UInt8 {
        Events(bytes: bytes)
    }

    static func jsonObject(_ data: String) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else {
            throw LLMError.apiError(String(localized: "流式响应格式无效，回复可能不完整。"))
        }
        return object
    }

    struct Events<Bytes: AsyncSequence>: AsyncSequence where Bytes.Element == UInt8 {
        typealias Element = String
        let bytes: Bytes
        func makeAsyncIterator() -> Iterator { Iterator(bytes: bytes.makeAsyncIterator()) }

        struct Iterator: AsyncIteratorProtocol {
            var bytes: Bytes.AsyncIterator
            private var line = Data()
            private var fields: [String] = []
            private var eventSize = 0
            private var skipLF = false
            private var firstLine = true
            private var ended = false
            private let maximumBytes = 2 * 1024 * 1024

            init(bytes: Bytes.AsyncIterator) { self.bytes = bytes }

            mutating func next() async throws -> String? {
                guard !ended else { return nil }
                try Task.checkCancellation()
                while let byte = try await bytes.next() {
                    try Task.checkCancellation()
                    if skipLF { skipLF = false; if byte == 10 { continue } }
                    if byte == 13 || byte == 10 {
                        skipLF = byte == 13
                        if let event = try finishLine() { return event }
                    } else {
                        line.append(byte)
                        guard line.count <= maximumBytes else { throw LLMError.interruptedStream }
                    }
                }
                ended = true
                // SSE discards an event not terminated by a blank line.
                return nil
            }

            private mutating func finishLine() throws -> String? {
                defer { line.removeAll(keepingCapacity: true) }
                if firstLine {
                    firstLine = false
                    if line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
                }
                if line.isEmpty {
                    let event = fields.isEmpty ? nil : fields.joined(separator: "\n")
                    fields.removeAll(keepingCapacity: true)
                    eventSize = 0
                    return event
                }
                guard let text = String(data: line, encoding: .utf8) else { throw LLMError.interruptedStream }
                if text == "data" || text.hasPrefix("data:") {
                    var field = text == "data" ? "" : String(text.dropFirst(5))
                    if field.hasPrefix(" ") { field.removeFirst() }
                    eventSize += line.count + 1
                    guard eventSize <= maximumBytes else { throw LLMError.interruptedStream }
                    fields.append(field)
                }
                return nil
            }
        }
    }
}
