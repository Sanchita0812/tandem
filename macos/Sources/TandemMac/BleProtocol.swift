import Foundation
import CoreBluetooth

public struct BleProtocol {
    public static let serviceUUID = CBUUID(string: "7A8D0001-B5A3-4F39-B948-2E1F4B5C6D01")
    public static let rxCharUUID = CBUUID(string: "7A8D0002-B5A3-4F39-B948-2E1F4B5C6D01")
    public static let txCharUUID = CBUUID(string: "7A8D0003-B5A3-4F39-B948-2E1F4B5C6D01")
    public static let deviceInfoCharUUID = CBUUID(string: "7A8D0004-B5A3-4F39-B948-2E1F4B5C6D01")
    
    public static let localDeviceName = "TandemMac"
    public static let protocolVersion = 3
    public static let maxPayloadBytes = 5 * 1024 * 1024 // 5 MB max payload for offline files
}

public struct TandemMessage: Codable, Equatable, Identifiable {
    public var id: String { message_id }
    public let version: Int
    public let type: String // "text", "file", "encrypted", "handshake", "handshake_ack"
    public let message_id: String
    public let timestamp: String
    public let sender: String?
    public let payload: String
    public let file_name: String?
    public let file_size: Int64?
    public let mime_type: String?
    public let sha256: String?
    
    public init(version: Int = BleProtocol.protocolVersion,
                type: String = "text",
                message_id: String = UUID().uuidString,
                timestamp: String = ISO8601DateFormatter().string(from: Date()),
                sender: String? = "mac",
                payload: String,
                file_name: String? = nil,
                file_size: Int64? = nil,
                mime_type: String? = nil,
                sha256: String? = nil) {
        self.version = version
        self.type = type
        self.message_id = message_id
        self.timestamp = timestamp
        self.sender = sender
        self.payload = payload
        self.file_name = file_name
        self.file_size = file_size
        self.mime_type = mime_type
        self.sha256 = sha256
    }
}

public struct TandemAck: Codable {
    public let version: Int
    public let type: String
    public let message_id: String
    public let status: String
    public let code: Int
    public let error: String?
    
    public init(message_id: String, status: String, code: Int, error: String? = nil) {
        self.version = BleProtocol.protocolVersion
        self.type = "ack"
        self.message_id = message_id
        self.status = status
        self.code = code
        self.error = error
    }
}

public enum FramingMagic: UInt8 {
    case singleFrame = 0xAA
    case multiChunk = 0xAB
    case finalChunk = 0xAC
    case extendedMultiChunk = 0xAD
    case extendedFinalChunk = 0xAE
}

public struct ChunkFramerSwift {
    /// Frames a byte payload into chunks respecting maxChunkCapacity
    /// Uses classic 11-byte header for <= 64 chunks, or extended 13-byte header for > 64 chunks
    public static func framePayload(_ data: Data, messageId: String, maxChunkSize: Int) -> [Data] {
        var hashValue: UInt64 = UInt64(bitPattern: Int64(messageId.hashValue))
        var hashBytes = Data(count: 8)
        _ = hashBytes.withUnsafeMutableBytes {
            $0.copyBytes(from: withUnsafeBytes(of: &hashValue) { Data($0) })
        }
        
        let usableClassic = max(10, maxChunkSize - 11)
        if data.count <= usableClassic {
            var packet = Data(count: 11 + data.count)
            packet[0] = FramingMagic.singleFrame.rawValue
            packet[1] = 0 // seq
            packet[2] = 1 // total
            packet.replaceSubrange(3..<11, with: hashBytes)
            packet.replaceSubrange(11..<11+data.count, with: data)
            return [packet]
        }
        
        let classicChunksCount = (data.count + usableClassic - 1) / usableClassic
        if classicChunksCount <= 64 {
            // Classic 11-byte framing
            var chunks: [Data] = []
            var offset = 0
            for i in 0..<classicChunksCount {
                let length = min(data.count - offset, usableClassic)
                let isFinal = (i == classicChunksCount - 1)
                var packet = Data(count: 11 + length)
                packet[0] = isFinal ? FramingMagic.finalChunk.rawValue : FramingMagic.multiChunk.rawValue
                packet[1] = UInt8(i)
                packet[2] = UInt8(classicChunksCount)
                packet.replaceSubrange(3..<11, with: hashBytes)
                packet.replaceSubrange(11..<11+length, with: data.subdata(in: offset..<offset+length))
                chunks.append(packet)
                offset += length
            }
            return chunks
        }
        
        // Extended 13-byte framing for large multi-chunk transfers
        let usableExtended = max(10, maxChunkSize - 13)
        let totalChunks = (data.count + usableExtended - 1) / usableExtended
        var chunks: [Data] = []
        var offset = 0
        
        for i in 0..<totalChunks {
            let length = min(data.count - offset, usableExtended)
            let isFinal = (i == totalChunks - 1)
            var packet = Data(count: 13 + length)
            packet[0] = isFinal ? FramingMagic.extendedFinalChunk.rawValue : FramingMagic.extendedMultiChunk.rawValue
            
            // 16-bit seq (Big Endian)
            packet[1] = UInt8((i >> 8) & 0xFF)
            packet[2] = UInt8(i & 0xFF)
            
            // 16-bit total (Big Endian)
            packet[3] = UInt8((totalChunks >> 8) & 0xFF)
            packet[4] = UInt8(totalChunks & 0xFF)
            
            packet.replaceSubrange(5..<13, with: hashBytes)
            packet.replaceSubrange(13..<13+length, with: data.subdata(in: offset..<offset+length))
            chunks.append(packet)
            offset += length
        }
        
        return chunks
    }
}
