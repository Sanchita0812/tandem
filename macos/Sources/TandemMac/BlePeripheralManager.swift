import Foundation
import CoreBluetooth

public enum BlePeripheralState: String {
    case poweredOff = "Bluetooth Off"
    case unauthorized = "Permission Denied"
    case unsupported = "Hardware Unsupported"
    case resetting = "Resetting..."
    case idle = "Idle"
    case advertising = "Advertising (Ready)"
    case connected = "Connected to Peer"
    case error = "Error"
}

public class BlePeripheralManager: NSObject, CBPeripheralManagerDelegate {
    public static let shared = BlePeripheralManager()
    
    private var peripheralManager: CBPeripheralManager!
    private var rxCharacteristic: CBMutableCharacteristic?
    private var txCharacteristic: CBMutableCharacteristic?
    private var deviceInfoCharacteristic: CBMutableCharacteristic?
    
    public var onStateChanged: ((BlePeripheralState, String) -> Void)?
    public var onMessageReceived: ((TandemMessage) -> Void)?
    public var onLog: ((String) -> Void)?
    
    private(set) public var currentState: BlePeripheralState = .idle
    private(set) public var connectedCentrals: Set<CBCentral> = []
    
    // Chunk reassembly buffer: [messageHash: (chunks: [Int: Data], total: Int, deadline: Date)]
    private var chunkBuffers: [UInt64: (chunks: [Int: Data], total: Int, deadline: Date)] = [:]
    private let maxPendingChunkBuffers = 16
    private var recentMessageIds: [String] = []
    private let maxRecentIds = 64
    
    public override init() {
        super.init()
        log("Initializing CoreBluetooth Peripheral Manager...")
        peripheralManager = CBPeripheralManager(delegate: self, queue: DispatchQueue.main)
    }
    
    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let formatted = "[\(timestamp)] \(message)"
        print(formatted)
        fflush(stdout)
        onLog?(formatted)
    }
    
    public func startAdvertising() {
        guard peripheralManager.state == .poweredOn else {
            log("Cannot start advertising: Bluetooth state is \(peripheralManager.state.rawValue)")
            return
        }
        setupGattServices()
    }
    
    public func stopAdvertising() {
        if peripheralManager.isAdvertising {
            peripheralManager.stopAdvertising()
            log("BLE advertisement stopped.")
            updateState(.idle, "Advertising stopped")
        }
    }
    
    private func updateState(_ state: BlePeripheralState, _ detail: String) {
        currentState = state
        onStateChanged?(state, detail)
    }
    
    private func setupGattServices() {
        if peripheralManager.isAdvertising {
            peripheralManager.stopAdvertising()
        }
        peripheralManager.removeAllServices()
        
        let rxChar = CBMutableCharacteristic(
            type: BleProtocol.rxCharUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        
        let txChar = CBMutableCharacteristic(
            type: BleProtocol.txCharUUID,
            properties: [.notify, .read],
            value: nil,
            permissions: [.readable]
        )
        
        let infoValue = "TandemMac v0.1; macOS Native Helper".data(using: .utf8)
        let infoChar = CBMutableCharacteristic(
            type: BleProtocol.deviceInfoCharUUID,
            properties: [.read],
            value: infoValue,
            permissions: [.readable]
        )
        
        let service = CBMutableService(type: BleProtocol.serviceUUID, primary: true)
        service.characteristics = [rxChar, txChar, infoChar]
        
        self.rxCharacteristic = rxChar
        self.txCharacteristic = txChar
        self.deviceInfoCharacteristic = infoChar
        
        log("Registering GATT Service with CoreBluetooth...")
        peripheralManager.add(service)
    }
    
    private func startBroadcast() {
        let adData: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [BleProtocol.serviceUUID],
            CBAdvertisementDataLocalNameKey: BleProtocol.localDeviceName
        ]
        log("Broadcasting BLE advertisement for service \(BleProtocol.serviceUUID.uuidString) as '\(BleProtocol.localDeviceName)'...")
        peripheralManager.startAdvertising(adData)
    }
    
    // MARK: - CBPeripheralManagerDelegate
    
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            log("Bluetooth controller is Powered ON and ready.")
            updateState(.idle, "Bluetooth powered on")
            setupGattServices()
        case .poweredOff:
            log("Bluetooth controller is Powered OFF.")
            updateState(.poweredOff, "Bluetooth is disabled in System Settings")
        case .unauthorized:
            log("Bluetooth access unauthorized by macOS TCC.")
            updateState(.unauthorized, "Grant Bluetooth permission in Privacy & Security")
        case .unsupported:
            log("Bluetooth Low Energy Peripheral role unsupported on this Mac.")
            updateState(.unsupported, "BLE peripheral mode unsupported")
        case .resetting:
            log("Bluetooth stack is resetting...")
            updateState(.resetting, "Bluetooth stack resetting")
        case .unknown:
            log("Bluetooth state unknown.")
            updateState(.idle, "State unknown")
        @unknown default:
            log("Unknown Bluetooth state: \(peripheral.state.rawValue)")
        }
    }
    
    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error = error {
            log("Failed to add GATT service: \(error.localizedDescription)")
            updateState(.error, error.localizedDescription)
            return
        }
        log("GATT Service registered successfully in local database. Starting advertisement...")
        startBroadcast()
    }
    
    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error = error {
            log("Failed to start advertising: \(error.localizedDescription)")
            updateState(.error, error.localizedDescription)
        } else {
            log("SUCCESS: Advertising Tandem GATT service as '\(BleProtocol.localDeviceName)'")
            updateState(.advertising, "Waiting for Android tablet connection...")
        }
    }
    
    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        log("Received read request for characteristic: \(request.characteristic.uuid.uuidString)")
        if request.characteristic.uuid == BleProtocol.deviceInfoCharUUID {
            let infoString = "TandemMac v0.1 (macOS Tahoe)"
            let data = infoString.data(using: .utf8) ?? Data()
            if request.offset > data.count {
                peripheralManager.respond(to: request, withResult: .invalidOffset)
                return
            }
            request.value = data.subdata(in: request.offset..<data.count)
            peripheralManager.respond(to: request, withResult: .success)
        } else if request.characteristic.uuid == BleProtocol.txCharUUID {
            request.value = Data()
            peripheralManager.respond(to: request, withResult: .success)
        } else {
            peripheralManager.respond(to: request, withResult: .attributeNotFound)
        }
    }
    
    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        connectedCentrals.insert(central)
        log("Peer connected & subscribed to Tx (Ack) characteristic: Central UUID \(central.identifier)")
        updateState(.connected, "Connected to Android device (\(central.identifier.uuidString.prefix(8)))")
    }
    
    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        connectedCentrals.remove(central)
        log("Peer unsubscribed from Tx characteristic: Central UUID \(central.identifier)")
        if connectedCentrals.isEmpty {
            updateState(.advertising, "Peer disconnected; advertising for reconnect...")
        }
    }
    
    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard let data = request.value, !data.isEmpty else {
                if request.characteristic.properties.contains(.write) {
                    peripheralManager.respond(to: request, withResult: .invalidAttributeValueLength)
                }
                continue
            }
            
            log("Received write request: \(data.count) bytes on char \(request.characteristic.uuid.uuidString)")
            handleIncomingBytes(data, from: request.central)
            
            if request.characteristic.properties.contains(.write) {
                peripheralManager.respond(to: request, withResult: .success)
            }
        }
    }
    
    // MARK: - Message Processing & Framing
    
    private func handleIncomingBytes(_ data: Data, from central: CBCentral) {
        guard !data.isEmpty else { return }
        
        let firstByte = data[0]
        if firstByte == UInt8(ascii: "{") {
            // Direct JSON payload (single frame without custom binary framing)
            processCompletePayload(data, from: central)
            return
        }
        
        // Binary framing mode
        if firstByte == FramingMagic.singleFrame.rawValue && data.count > 11 {
            let payloadData = data.subdata(in: 11..<data.count)
            processCompletePayload(payloadData, from: central)
            return
        }
        
        if (firstByte == FramingMagic.multiChunk.rawValue || firstByte == FramingMagic.finalChunk.rawValue) && data.count >= 11 {
            let seqIndex = Int(data[1])
            let totalChunks = Int(data[2])
            guard totalChunks > 0 && totalChunks <= 64, seqIndex >= 0 && seqIndex < totalChunks else {
                log("SECURITY: Dropping invalid chunk framing (seq=\(seqIndex), total=\(totalChunks))")
                return
            }
            
            let hashBytes = data.subdata(in: 3..<11)
            var hashValue: UInt64 = 0
            _ = withUnsafeMutableBytes(of: &hashValue) { hashBytes.copyBytes(to: $0) }
            let chunkData = data.subdata(in: 11..<data.count)
            guard !chunkData.isEmpty else {
                log("SECURITY: Dropping empty chunk payload (seq=\(seqIndex))")
                return
            }
            
            // Clean up expired chunk buffers
            let now = Date()
            chunkBuffers = chunkBuffers.filter { $0.value.deadline > now }
            
            // Guard against memory exhaustion DoS: max 16 concurrent pending message buffers
            if chunkBuffers[hashValue] == nil && chunkBuffers.count >= maxPendingChunkBuffers {
                log("SECURITY: Dropping chunk; maximum pending reassembly buffers (\(maxPendingChunkBuffers)) reached.")
                return
            }
            
            var entry = chunkBuffers[hashValue] ?? (chunks: [:], total: totalChunks, deadline: now.addingTimeInterval(5.0))
            
            // Guard against oversized reassembly
            let currentAccumulatedSize = entry.chunks.values.reduce(0) { $0 + $1.count }
            if currentAccumulatedSize + chunkData.count > BleProtocol.maxPayloadBytes {
                log("SECURITY: Accumulated chunks for hash \(hashValue) exceed \(BleProtocol.maxPayloadBytes) bytes; dropping buffer.")
                chunkBuffers.removeValue(forKey: hashValue)
                return
            }
            
            entry.chunks[seqIndex] = chunkData
            chunkBuffers[hashValue] = entry
            
            log("Processed chunk \(seqIndex + 1)/\(totalChunks) for hash \(hashValue) (\(chunkData.count) bytes)")
            
            if entry.chunks.count == totalChunks {
                // Reassemble
                var fullData = Data()
                for i in 0..<totalChunks {
                    if let c = entry.chunks[i] {
                        fullData.append(c)
                    }
                }
                chunkBuffers.removeValue(forKey: hashValue)
                log("Reassembly complete for hash \(hashValue): \(fullData.count) bytes")
                processCompletePayload(fullData, from: central)
            }
            return
        }
        
        // Attempt UTF-8 fallback
        processCompletePayload(data, from: central)
    }
    
    private func processCompletePayload(_ data: Data, from central: CBCentral) {
        guard data.count <= BleProtocol.maxPayloadBytes else {
            log("REJECTED: Payload of \(data.count) bytes exceeds limit of \(BleProtocol.maxPayloadBytes) bytes.")
            sendAck(messageId: "unknown", status: "error", code: 413, error: "Payload exceeds 2048 bytes limit")
            return
        }
        
        let decoder = JSONDecoder()
        do {
            let message = try decoder.decode(TandemMessage.self, from: data)
            
            // Timestamp Freshness Check (Anti-Replay Window: 10 minutes)
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fallbackFormatter = ISO8601DateFormatter()
            
            if let msgDate = isoFormatter.date(from: message.timestamp) ?? fallbackFormatter.date(from: message.timestamp) {
                let drift = abs(msgDate.timeIntervalSinceNow)
                if drift > 600.0 { // 10 minutes
                    log("SECURITY REJECT: Message timestamp drift \(Int(drift))s exceeds 10-minute anti-replay window.")
                    sendAck(messageId: message.message_id, status: "error", code: 400, error: "Stale timestamp outside 10-minute anti-replay window")
                    return
                }
            }
            
            // Deduplication check
            if recentMessageIds.contains(message.message_id) {
                log("Ignoring duplicate message_id: \(message.message_id)")
                sendAck(messageId: message.message_id, status: "delivered", code: 200, error: nil)
                return
            }
            
            recentMessageIds.append(message.message_id)
            if recentMessageIds.count > maxRecentIds {
                recentMessageIds.removeFirst()
            }
            
            log("VALID MESSAGE RECEIVED: id=\(message.message_id), bytes=\(data.count)")
            onMessageReceived?(message)
            
            // Send delivery acknowledgment
            sendAck(messageId: message.message_id, status: "delivered", code: 200, error: nil)
            
        } catch {
            let preview = String(data: data.prefix(40), encoding: .utf8) ?? "<binary>"
            log("MALFORMED JSON: Failed to decode envelope: \(error.localizedDescription) (preview: \(preview))")
            sendAck(messageId: "unknown", status: "error", code: 400, error: "Malformed JSON envelope: \(error.localizedDescription)")
        }
    }
    
    private func sendAck(messageId: String, status: String, code: Int, error: String?) {
        guard let txChar = txCharacteristic else { return }
        let ack = TandemAck(message_id: messageId, status: status, code: code, error: error)
        guard let ackData = try? JSONEncoder().encode(ack) else { return }
        
        let sent = peripheralManager.updateValue(ackData, for: txChar, onSubscribedCentrals: nil)
        if sent {
            log("ACK notification dispatched for message \(messageId) (status: \(status))")
        } else {
            log("ACK notification queued / pending buffer space for message \(messageId)")
        }
    }
}
