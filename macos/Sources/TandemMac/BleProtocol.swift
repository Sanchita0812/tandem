import Foundation
import CoreBluetooth

public struct BleProtocol {
    public static let serviceUUID = CBUUID(string: "7A8D0001-B5A3-4F39-B948-2E1F4B5C6D01")
    public static let rxCharUUID = CBUUID(string: "7A8D0002-B5A3-4F39-B948-2E1F4B5C6D01")
    public static let txCharUUID = CBUUID(string: "7A8D0003-B5A3-4F39-B948-2E1F4B5C6D01")
    public static let deviceInfoCharUUID = CBUUID(string: "7A8D0004-B5A3-4F39-B948-2E1F4B5C6D01")
    
    public static let localDeviceName = "TandemMac"
    public static let protocolVersion = 1
    public static let maxPayloadBytes = 2048
}

public struct TandemMessage: Codable, Equatable, Identifiable {
    public var id: String { message_id }
    public let version: Int
    public let type: String
    public let message_id: String
    public let timestamp: String
    public let payload: String
    
    public init(version: Int = BleProtocol.protocolVersion,
                type: String = "text",
                message_id: String = UUID().uuidString,
                timestamp: String = ISO8601DateFormatter().string(from: Date()),
                payload: String) {
        self.version = version
        self.type = type
        self.message_id = message_id
        self.timestamp = timestamp
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
