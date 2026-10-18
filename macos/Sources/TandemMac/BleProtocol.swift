import Foundation
import CoreBluetooth

public struct BleProtocol {
    public static let serviceUUID = CBUUID(string: "7A8D0001-B5A3-4F39-B948-2E1F4B5C6D01")
    public static let rxCharUUID = CBUUID(string: "7A8D0002-B5A3-4F39-B948-2E1F4B5C6D01")
    public static let txCharUUID = CBUUID(string: "7A8D0003-B5A3-4F39-B948-2E1F4B5C6D01")
    public static let deviceInfoCharUUID = CBUUID(string: "7A8D0004-B5A3-4F39-B948-2E1F4B5C6D01")
    
    public static let localDeviceName = "TandemMac"
    public static let protocolVersion = 2
    public static let maxPayloadBytes = 4096
}

public struct TandemMessage: Codable, Equatable, Identifiable {
    public var id: String { message_id }
    public let version: Int
    public let type: String
    public let message_id: String
    public let timestamp: String
    public let sender: String?
    public let payload: String
    
    public init(version: Int = BleProtocol.protocolVersion,
                type: String = "text",
                message_id: String = UUID().uuidString,
                timestamp: String = ISO8601DateFormatter().string(from: Date()),
                sender: String? = "mac",
                payload: String) {
        self.version = version
        self.type = type
        self.message_id = message_id
        self.timestamp = timestamp
        self.sender = sender
        self.payload = payload
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
}

public struct ChunkFramerSwift {
    /// Frames a byte payload into 11-byte header chunks respecting maxChunkCapacity
    public static func framePayload(_ data: Data, messageId: String, maxChunkSize: Int) -> [Data] {
        let usableChunkCapacity = max(10, maxChunkSize - 11)
        
        var hashValue: UInt64 = UInt64(bitPattern: Int64(messageId.hashValue))
        var hashBytes = Data(count: 8)
        _ = hashBytes.withUnsafeMutableBytes {
            $0.copyBytes(from: withUnsafeBytes(of: &hashValue) { Data($0) })
        }
        
        if data.count <= usableChunkCapacity {
            var packet = Data(count: 11 + data.count)
            packet[0] = FramingMagic.singleFrame.rawValue
            packet[1] = 0 // seq
            packet[2] = 1 // total
            packet.replaceSubrange(3..<11, with: hashBytes)
            packet.replaceSubrange(11..<11+data.count, with: data)
            return [packet]
        }
        
        let totalChunks = (data.count + usableChunkCapacity - 1) / usableChunkCapacity
        var chunks: [Data] = []
        var offset = 0
        
        for i in 0..<totalChunks {
            let length = min(data.count - offset, usableChunkCapacity)
            let isFinal = (i == totalChunks - 1)
            var packet = Data(count: 11 + length)
            packet[0] = isFinal ? FramingMagic.finalChunk.rawValue : FramingMagic.multiChunk.rawValue
            packet[1] = UInt8(i)
            packet[2] = UInt8(totalChunks)
            packet.replaceSubrange(3..<11, with: hashBytes)
            packet.replaceSubrange(11..<11+length, with: data.subdata(in: offset..<offset+length))
            chunks.append(packet)
            offset += length
        }
        
        return chunks
    }
}
