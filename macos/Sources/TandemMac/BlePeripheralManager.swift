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
    public var onMessageDelivered: ((String, String) -> Void)?
    public var onSecurityCodeChanged: ((String?) -> Void)?
    public var onLog: ((String) -> Void)?
    
    private(set) public var currentState: BlePeripheralState = .idle
    private(set) public var connectedCentrals: Set<CBCentral> = []
    
    // Chunk reassembly buffer: [messageHash: (chunks: [Int: Data], total: Int, deadline: Date)]
    private var chunkBuffers: [UInt64: (chunks: [Int: Data], total: Int, deadline: Date)] = [:]
    private let maxPendingChunkBuffers = 16
    private var recentMessageIds: [String] = []
    private let maxRecentIds = 64
    
    // Outbound transmission state
    private var outgoingChunkQueue: [Data] = []
    private var isSendingChunks = false
    private var pendingOutboundId: String?
    private var pendingOutboundCallback: ((Bool, String) -> Void)?
    private var ackTimeoutTimer: Timer?
    
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
        
        let infoValue = "TandemMac v0.2; E2EE BLE Bridge".data(using: .utf8)
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
            let infoString = "TandemMac v0.2 (E2EE Active)"
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
        log("Peer connected & subscribed to Tx characteristic: Central UUID \(central.identifier)")
        updateState(.connected, "Connected to Android device (\(central.identifier.uuidString.prefix(8)))")
    }
    
    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        connectedCentrals.remove(central)
        log("Peer unsubscribed from Tx characteristic: Central UUID \(central.identifier)")
        if connectedCentrals.isEmpty {
            TandemCrypto.shared.resetKeypair()
            onSecurityCodeChanged?(nil)
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
    
    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        processNextOutgoingChunk()
    }
    
    // MARK: - Outgoing Message Transmission (Mac -> Android)
    
    public func sendMessage(text: String, completion: @escaping (Bool, String) -> Void) {
        guard !connectedCentrals.isEmpty, let txChar = txCharacteristic else {
            completion(false, "Android tablet is not connected")
            return
        }
        
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(false, "Cannot send empty message")
            return
        }
        
        let messageId = "mac-" + UUID().uuidString.prefix(8).lowercased()
        let timestamp = ISO8601DateFormatter().string(from: Date())
        
        var envelope: TandemMessage
        if TandemCrypto.shared.isEncrypted {
            // Encrypt inner message
            let innerMsg = TandemMessage(
                version: BleProtocol.protocolVersion,
                type: "text",
                message_id: messageId,
                timestamp: timestamp,
                sender: "mac",
                payload: trimmed
            )
            guard let innerData = try? JSONEncoder().encode(innerMsg),
                  let innerJson = String(data: innerData, encoding: .utf8),
                  let ciphertext = try? TandemCrypto.shared.encrypt(plaintext: innerJson) else {
                completion(false, "Failed to encrypt message")
                return
            }
            envelope = TandemMessage(
                version: BleProtocol.protocolVersion,
                type: "encrypted",
                message_id: messageId,
                timestamp: timestamp,
                sender: "mac",
                payload: ciphertext
            )
        } else {
            // Plaintext fallback
            envelope = TandemMessage(
                version: BleProtocol.protocolVersion,
                type: "text",
                message_id: messageId,
                timestamp: timestamp,
                sender: "mac",
                payload: trimmed
            )
        }
        
        guard let jsonData = try? JSONEncoder().encode(envelope) else {
            completion(false, "Failed to encode envelope")
            return
        }
        
        if jsonData.count > BleProtocol.maxPayloadBytes {
            completion(false, "Message exceeds \(BleProtocol.maxPayloadBytes) bytes limit")
            return
        }
        
        let maxUpdateLength = connectedCentrals.first?.maximumUpdateValueLength ?? 180
        let chunks = ChunkFramerSwift.framePayload(jsonData, messageId: messageId, maxChunkSize: maxUpdateLength)
        
        log("Enqueueing outbound message \(messageId) (\(jsonData.count) bytes across \(chunks.count) chunks)...")
        pendingOutboundId = messageId
        pendingOutboundCallback = completion
        
        outgoingChunkQueue.append(contentsOf: chunks)
        startAckTimeout()
        processNextOutgoingChunk()
    }
    
    private func processNextOutgoingChunk() {
        guard let txChar = txCharacteristic, !outgoingChunkQueue.isEmpty else {
            return
        }
        
        while !outgoingChunkQueue.isEmpty {
            let chunk = outgoingChunkQueue[0]
            let success = peripheralManager.updateValue(chunk, for: txChar, onSubscribedCentrals: nil)
            if success {
                outgoingChunkQueue.removeFirst()
            } else {
                // Buffer full, will resume in peripheralManagerIsReady(toUpdateSubscribers:)
                log("Notification buffer full, waiting for peripheralManagerIsReady callback...")
                return
            }
        }
    }
    
    private func startAckTimeout() {
        cancelAckTimeout()
        ackTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if let callback = self.pendingOutboundCallback {
                self.log("Delivery timeout: No ACK received from Android within 5.0 seconds.")
                callback(false, "Delivery timeout (no ACK from Android)")
                self.pendingOutboundCallback = nil
                self.pendingOutboundId = nil
            }
        }
    }
    
    private func cancelAckTimeout() {
        ackTimeoutTimer?.invalidate()
        ackTimeoutTimer = nil
    }
    
    // MARK: - Message Processing & Framing
    
    private func handleIncomingBytes(_ data: Data, from central: CBCentral) {
        guard !data.isEmpty else { return }
        
        let firstByte = data[0]
        if firstByte == UInt8(ascii: "{") {
            processCompletePayload(data, from: central)
            return
        }
        
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
            
            let now = Date()
            chunkBuffers = chunkBuffers.filter { $0.value.deadline > now }
            
            if chunkBuffers[hashValue] == nil && chunkBuffers.count >= maxPendingChunkBuffers {
                log("SECURITY: Dropping chunk; maximum pending reassembly buffers (\(maxPendingChunkBuffers)) reached.")
                return
            }
            
            var entry = chunkBuffers[hashValue] ?? (chunks: [:], total: totalChunks, deadline: now.addingTimeInterval(5.0))
            
            let currentAccumulatedSize = entry.chunks.values.reduce(0) { $0 + $1.count }
            if currentAccumulatedSize + chunkData.count > BleProtocol.maxPayloadBytes {
                log("SECURITY: Accumulated chunks for hash \(hashValue) exceed \(BleProtocol.maxPayloadBytes) bytes; dropping buffer.")
                chunkBuffers.removeValue(forKey: hashValue)
                return
            }
            
            entry.chunks[seqIndex] = chunkData
            chunkBuffers[hashValue] = entry
            
            if entry.chunks.count == totalChunks {
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
        
        processCompletePayload(data, from: central)
    }
    
    private func processCompletePayload(_ data: Data, from central: CBCentral) {
        guard data.count <= BleProtocol.maxPayloadBytes else {
            log("REJECTED: Payload of \(data.count) bytes exceeds limit of \(BleProtocol.maxPayloadBytes) bytes.")
            sendAck(messageId: "unknown", status: "error", code: 413, error: "Payload exceeds limit")
            return
        }
        
        let decoder = JSONDecoder()
        do {
            let message = try decoder.decode(TandemMessage.self, from: data)
            
            // 1. Handle Key Agreement Handshake Request
            if message.type == "handshake" {
                handleHandshakeRequest(message, from: central)
                return
            }
            
            // 2. Handle Delivery ACK from Android (for messages Mac sent)
            if message.type == "ack" {
                handleInboundAck(message)
                return
            }
            
            // 3. Handle Encrypted Message Payload
            if message.type == "encrypted" {
                handleEncryptedMessage(message, from: central)
                return
            }
            
            // 4. Handle Plaintext Message
            handlePlaintextMessage(message, from: central)
            
        } catch {
            let preview = String(data: data.prefix(40), encoding: .utf8) ?? "<binary>"
            log("MALFORMED JSON: Failed to decode envelope: \(error.localizedDescription) (preview: \(preview))")
            sendAck(messageId: "unknown", status: "error", code: 400, error: "Malformed JSON envelope: \(error.localizedDescription)")
        }
    }
    
    private func handleHandshakeRequest(_ message: TandemMessage, from central: CBCentral) {
        log("Received E2EE Handshake Request from Android tablet...")
        guard let clientPubData = Data(base64Encoded: message.payload), clientPubData.count == 64 else {
            log("SECURITY REJECT: Invalid client handshake public key length")
            sendAck(messageId: message.message_id, status: "error", code: 400, error: "Invalid public key")
            return
        }
        
        do {
            let sas = try TandemCrypto.shared.completeKeyExchange(peerRawPub: clientPubData)
            log("🔒 E2EE Established! Shared AES-256-GCM Session Active. Security Code: \(sas)")
            onSecurityCodeChanged?(sas)
            
            // Send Handshake Response with Mac's public key
            if let serverPubData = TandemCrypto.shared.getLocalRawPublicKey(), let txChar = txCharacteristic {
                let hsAck = TandemMessage(
                    version: BleProtocol.protocolVersion,
                    type: "handshake_ack",
                    message_id: "hs-ack-" + UUID().uuidString.prefix(8),
                    timestamp: ISO8601DateFormatter().string(from: Date()),
                    sender: "mac",
                    payload: serverPubData.base64EncodedString()
                )
                if let hsAckData = try? JSONEncoder().encode(hsAck) {
                    _ = peripheralManager.updateValue(hsAckData, for: txChar, onSubscribedCentrals: nil)
                    log("Dispatched Handshake Response with Mac P-256 Public Key.")
                }
            }
        } catch {
            log("Key exchange error: \(error.localizedDescription)")
            sendAck(messageId: message.message_id, status: "error", code: 500, error: "Key exchange failed")
        }
    }
    
    private func handleInboundAck(_ message: TandemMessage) {
        log("Received Delivery ACK from Android for message: \(message.message_id)")
        if message.message_id == pendingOutboundId {
            cancelAckTimeout()
            pendingOutboundCallback?(true, "Delivered (Ack 200)")
            pendingOutboundCallback = nil
            pendingOutboundId = nil
        }
        onMessageDelivered?(message.message_id, "Delivered (Ack 200)")
    }
    
    private func handleEncryptedMessage(_ message: TandemMessage, from central: CBCentral) {
        guard TandemCrypto.shared.isEncrypted else {
            log("SECURITY REJECT: Received encrypted message before E2EE handshake established.")
            sendAck(messageId: message.message_id, status: "error", code: 400, error: "E2EE session not established")
            return
        }
        
        do {
            let decryptedJson = try TandemCrypto.shared.decrypt(base64Ciphertext: message.payload)
            guard let innerData = decryptedJson.data(using: .utf8),
                  let innerMsg = try? JSONDecoder().decode(TandemMessage.self, from: innerData) else {
                log("Failed to parse inner decrypted message")
                sendAck(messageId: message.message_id, status: "error", code: 400, error: "Malformed inner message")
                return
            }
            
            if isDuplicateOrReplay(innerMsg) { return }
            
            log("🔒 VALID ENCRYPTED MESSAGE RECEIVED: id=\(innerMsg.message_id), text='\(innerMsg.payload)'")
            onMessageReceived?(innerMsg)
            sendAck(messageId: innerMsg.message_id, status: "delivered", code: 200, error: nil)
            
        } catch {
            log("SECURITY REJECT: AES-GCM decryption failed / Tag mismatch: \(error.localizedDescription)")
            sendAck(messageId: message.message_id, status: "error", code: 400, error: "Decryption failed")
        }
    }
    
    private func handlePlaintextMessage(_ message: TandemMessage, from central: CBCentral) {
        if isDuplicateOrReplay(message) { return }
        
        log("VALID PLAINTEXT MESSAGE RECEIVED: id=\(message.message_id), bytes=\(message.payload.count)")
        onMessageReceived?(message)
        sendAck(messageId: message.message_id, status: "delivered", code: 200, error: nil)
    }
    
    private func isDuplicateOrReplay(_ message: TandemMessage) -> Bool {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        
        if let msgDate = isoFormatter.date(from: message.timestamp) ?? fallbackFormatter.date(from: message.timestamp) {
            let drift = abs(msgDate.timeIntervalSinceNow)
            if drift > 600.0 {
                log("SECURITY REJECT: Message timestamp drift \(Int(drift))s exceeds 10-minute anti-replay window.")
                sendAck(messageId: message.message_id, status: "error", code: 400, error: "Stale timestamp outside 10-minute anti-replay window")
                return true
            }
        }
        
        if recentMessageIds.contains(message.message_id) {
            log("Ignoring duplicate message_id: \(message.message_id)")
            sendAck(messageId: message.message_id, status: "delivered", code: 200, error: nil)
            return true
        }
        
        recentMessageIds.append(message.message_id)
        if recentMessageIds.count > maxRecentIds {
            recentMessageIds.removeFirst()
        }
        return false
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
