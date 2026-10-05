import Foundation

final class FrameParser {
    private var buffer: [UInt8] = []
    private let maxBacklog = 16 * 1024 * 1024

    func append(_ data: Data) -> [(MessageHeader, Data)] {
        if buffer.count + data.count > maxBacklog { buffer.removeAll() }
        buffer.append(contentsOf: data)
        var messages: [(MessageHeader, Data)] = []
        var offset = 0
        while buffer.count - offset >= MessageHeader.size {
            let headerBytes = Data(buffer[offset..<(offset + MessageHeader.size)])
            guard let header = MessageHeader.decode(headerBytes) else {
                offset += 1 // resync: skip a corrupt byte instead of wedging forever
                continue
            }
            let total = MessageHeader.size + Int(header.length)
            guard buffer.count - offset >= total else { break }
            let payload = Data(buffer[(offset + MessageHeader.size)..<(offset + total)])
            messages.append((header, payload))
            offset += total
        }
        if offset > 0 { buffer.removeFirst(offset) }
        return messages
    }
}
