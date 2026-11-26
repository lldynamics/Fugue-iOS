import Foundation

/// Pull one complete event at a time. Unlike AsyncBytes.lines, preserve blank lines;
/// unlike a producer task, do not read ahead into an unbounded event queue.
enum SSEDecoder {
    static let defaultMaximumBytes = 2 * 1024 * 1024
    static let maximumStreamBytes = 32 * 1024 * 1024
    static let maximumEvents = 200_000

    static func events<Bytes: AsyncSequence>(
        _ bytes: Bytes,
        maximumBytes: Int = defaultMaximumBytes,
        onActivity: (@Sendable () -> Void)? = nil
    ) -> Events<Bytes> where Bytes.Element == UInt8 {
        Events(bytes: bytes, maximumBytes: maximumBytes, onActivity: onActivity)
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
        let maximumBytes: Int
        let onActivity: (@Sendable () -> Void)?

        init(bytes: Bytes, maximumBytes: Int = defaultMaximumBytes, onActivity: (@Sendable () -> Void)? = nil) {
            self.bytes = bytes
            self.maximumBytes = maximumBytes
            self.onActivity = onActivity
        }

        func makeAsyncIterator() -> Iterator {
            Iterator(bytes: bytes.makeAsyncIterator(), maximumBytes: maximumBytes, onActivity: onActivity)
        }

        struct Iterator: AsyncIteratorProtocol {
            var bytes: Bytes.AsyncIterator
            let maximumBytes: Int
            let onActivity: (@Sendable () -> Void)?
            private var line = Data()
            private var fields: [String] = []
            private var eventSize = 0
            private var bytesSinceTouch = 0
            private var streamBytes = 0
            private var emittedEvents = 0
            private var skipLF = false
            private var firstLine = true
            private var ended = false

            init(bytes: Bytes.AsyncIterator, maximumBytes: Int = defaultMaximumBytes, onActivity: (@Sendable () -> Void)? = nil) {
                self.bytes = bytes
                self.maximumBytes = maximumBytes
                self.onActivity = onActivity
            }

            mutating func next() async throws -> String? {
                guard !ended else { return nil }
                try Task.checkCancellation()
                while let byte = try await bytes.next() {
                    try Task.checkCancellation()
                    streamBytes += 1
                    guard streamBytes <= SSEDecoder.maximumStreamBytes else { throw LLMError.interruptedStream }
                    if skipLF { skipLF = false; if byte == 10 { continue } }
                    if byte == 13 || byte == 10 {
                        bytesSinceTouch = 0
                        onActivity?()
                        skipLF = byte == 13
                        if let event = try finishLine() {
                            emittedEvents += 1
                            guard emittedEvents <= SSEDecoder.maximumEvents else { throw LLMError.interruptedStream }
                            return event
                        }
                    } else {
                        line.append(byte)
                        guard line.count <= maximumBytes else { throw LLMError.interruptedStream }
                        bytesSinceTouch += 1
                        if bytesSinceTouch >= 256 {
                            bytesSinceTouch = 0
                            onActivity?()
                        }
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
