import Foundation
import CoreBluetooth
import CryptoKit
import UniformTypeIdentifiers

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
    public var onFileReceived: ((TandemMessage, URL) -> Void)?
    public var onMessageDelivered: ((String, String) -> Void)?
    public var onTransferProgress: ((String, Float) -> Void)?
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
    private var pendingOutboundId: String?
    private var pendingOutboundCallback: ((Bool, String) -> Void)?
    private var pendingProgressCallback: ((Float) -> Void)?
    private var totalOutboundChunks: Int = 0
    private var sentOutboundChunks: Int = 0
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
            log("Cannot advertise: Bluetooth state is \(peripheralManager.state.rawValue)")
            return
        }
        
        peripheralManager.stopAdvertising()
        setupGattServices()
        
        let advertisementData: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [BleProtocol.serviceUUID],
            CBAdvertisementDataLocalNameKey: BleProtocol.localDeviceName
        ]
        
        peripheralManager.startAdvertising(advertisementData)
        updateState(.advertising, "Advertising service \(BleProtocol.serviceUUID.uuidString.prefix(8))...")
        log("Started advertising as '\(BleProtocol.localDeviceName)' with Service UUID \(BleProtocol.serviceUUID)...")
    }
    
    public func stopAdvertising() {
        peripheralManager.stopAdvertising()
        updateState(.idle, "Advertising stopped")
        log("Stopped advertising.")
    }
    
    private func setupGattServices() {
        peripheralManager.removeAllServices()
        
        let rxChar = CBMutableCharacteristic(
            type: BleProtocol.rxCharUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        self.rxCharacteristic = rxChar
        
        let txChar = CBMutableCharacteristic(
            type: BleProtocol.txCharUUID,
            properties: [.notify, .read],
            value: nil,
            permissions: [.readable]
        )
        self.txCharacteristic = txChar
        
        let deviceInfoData = "TandemMac/1.0 macOS/\(ProcessInfo.processInfo.operatingSystemVersionString)".data(using: .utf8)
        let devInfoChar = CBMutableCharacteristic(
            type: BleProtocol.deviceInfoCharUUID,
            properties: [.read],
            value: deviceInfoData,
            permissions: [.readable]
        )
        self.deviceInfoCharacteristic = devInfoChar
        
        let tandemService = CBMutableService(type: BleProtocol.serviceUUID, primary: true)
        tandemService.characteristics = [rxChar, txChar, devInfoChar]
        
        peripheralManager.add(tandemService)
        log("Added Tandem GATT Service with Rx, Tx, and DeviceInfo characteristics.")
    }
    
    private func updateState(_ state: BlePeripheralState, _ detail: String) {
        currentState = state
        log("State changed: \(state.rawValue) - \(detail)")
        onStateChanged?(state, detail)
    }
    
    // MARK: - CBPeripheralManagerDelegate
    
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            log("CoreBluetooth state: poweredOn")
            startAdvertising()
        case .poweredOff:
            log("CoreBluetooth state: poweredOff. Please turn Bluetooth ON.")
            updateState(.poweredOff, "Bluetooth is disabled in System Settings")
        case .unauthorized:
            log("CoreBluetooth state: unauthorized. Permission required in System Settings > Privacy > Bluetooth.")
            updateState(.unauthorized, "Bluetooth permission denied")
        case .unsupported:
            log("CoreBluetooth state: unsupported.")
            updateState(.unsupported, "BLE Peripheral role unsupported on this hardware")
        case .resetting:
            log("CoreBluetooth state: resetting...")
            updateState(.resetting, "Bluetooth stack resetting...")
        case .unknown:
            log("CoreBluetooth state: unknown")
            updateState(.idle, "Bluetooth status unknown")
        @unknown default:
            log("CoreBluetooth state: unknown default")
            updateState(.idle, "Unknown state")
        }
    }
    
    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error = error {
            log("Advertising failed with error: \(error.localizedDescription)")
            updateState(.error, "Advertising error: \(error.localizedDescription)")
        } else {
            log("GATT Server advertising confirmed active.")
        }
    }
    
    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        log("Central subscribed to Tx notifications: \(central.identifier)")
        connectedCentrals.insert(central)
        updateState(.connected, "Connected to: \(central.identifier.uuidString.prefix(8)) (MTU: \(central.maximumUpdateValueLength))")
    }
    
    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        log("Central unsubscribed from Tx: \(central.identifier)")
        connectedCentrals.remove(central)
        if connectedCentrals.isEmpty {
            log("All centrals disconnected. Resetting E2EE session keys and buffers.")
            TandemCrypto.shared.resetKeypair()
            onSecurityCodeChanged?(nil)
            chunkBuffers.removeAll()
            recentMessageIds.removeAll()
            updateState(.advertising, "Peer disconnected. Advertising...")
            startAdvertising()
        }
    }
    
    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        processNextOutgoingChunk()
    }
    
    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            if request.characteristic.uuid == BleProtocol.rxCharUUID {
                if let data = request.value {
                    handleIncomingBytes(data, from: request.central)
                }
                peripheralManager.respond(to: request, withResult: .success)
            } else {
                peripheralManager.respond(to: request, withResult: .requestNotSupported)
            }
        }
    }
    
    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        if request.characteristic.uuid == BleProtocol.deviceInfoCharUUID {
            request.value = deviceInfoCharacteristic?.value
            peripheralManager.respond(to: request, withResult: .success)
        } else {
            peripheralManager.respond(to: request, withResult: .requestNotSupported)
        }
    }
    
    // MARK: - Outgoing Message Transmission
    
    public func sendMessage(text: String, messageId: String? = nil, completion: @escaping (Bool, String) -> Void) {
        guard currentState == .connected else {
            completion(false, "Not connected to Android tablet")
            return
        }
        
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(false, "Cannot send empty message")
            return
        }
        
        let messageId = messageId ?? ("mac-" + UUID().uuidString.prefix(8).lowercased())
        let timestamp = ISO8601DateFormatter().string(from: Date())
        
        var envelope: TandemMessage
        if TandemCrypto.shared.isEncrypted {
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
        
        guard jsonData.count <= BleProtocol.maxPayloadBytes else {
            completion(false, "Message exceeds \(BleProtocol.maxPayloadBytes) bytes limit")
            return
        }
        
        let maxUpdateLength = connectedCentrals.first?.maximumUpdateValueLength ?? 180
        let chunks = ChunkFramerSwift.framePayload(jsonData, messageId: messageId, maxChunkSize: maxUpdateLength)
        
        log("Enqueueing outbound message \(messageId) (\(jsonData.count) bytes across \(chunks.count) chunks)...")
        pendingOutboundId = messageId
        pendingOutboundCallback = completion
        pendingProgressCallback = nil
        totalOutboundChunks = chunks.count
        sentOutboundChunks = 0
        
        outgoingChunkQueue.append(contentsOf: chunks)
        processNextOutgoingChunk()
    }
    
    // MARK: - Outgoing File & Attachment Transmission (v0.3)
    
    public func sendFile(url: URL, progress: ((Float) -> Void)? = nil, completion: @escaping (Bool, String) -> Void) {
        guard currentState == .connected else {
            completion(false, "Not connected to Android tablet")
            return
        }
        
        do {
            let fileData = try Data(contentsOf: url)
            guard !fileData.isEmpty else {
                completion(false, "Cannot send empty file")
                return
            }
            guard fileData.count <= BleProtocol.maxPayloadBytes else {
                let mb = BleProtocol.maxPayloadBytes / (1024 * 1024)
                completion(false, "File exceeds \(mb) MB size limit")
                return
            }
            
            let messageId = "file-mac-" + UUID().uuidString.prefix(8).lowercased()
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let sha256Hex = SHA256.hash(data: fileData).compactMap { String(format: "%02x", $0) }.joined()
            let filename = url.lastPathComponent
            let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let b64Payload = fileData.base64EncodedString()
            
            let innerMsg = TandemMessage(
                version: BleProtocol.protocolVersion,
                type: "file",
                message_id: messageId,
                timestamp: timestamp,
                sender: "mac",
                payload: b64Payload,
                file_name: filename,
                file_size: Int64(fileData.count),
                mime_type: mimeType,
                sha256: sha256Hex
            )
            
            let envelope: TandemMessage
            if TandemCrypto.shared.isEncrypted {
                guard let innerData = try? JSONEncoder().encode(innerMsg),
                      let innerJson = String(data: innerData, encoding: .utf8),
                      let ciphertext = try? TandemCrypto.shared.encrypt(plaintext: innerJson) else {
                    completion(false, "Failed to encrypt file envelope")
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
                envelope = innerMsg
            }
            
            guard let jsonData = try? JSONEncoder().encode(envelope) else {
                completion(false, "Failed to encode file envelope JSON")
                return
            }
            
            let maxUpdateLength = connectedCentrals.first?.maximumUpdateValueLength ?? 180
            let chunks = ChunkFramerSwift.framePayload(jsonData, messageId: messageId, maxChunkSize: maxUpdateLength)
            
            log("Enqueueing outbound file '\(filename)' (\(fileData.count) bytes across \(chunks.count) chunks)...")
            pendingOutboundId = messageId
            pendingOutboundCallback = completion
            pendingProgressCallback = progress
            totalOutboundChunks = chunks.count
            sentOutboundChunks = 0
            
            outgoingChunkQueue.append(contentsOf: chunks)
            processNextOutgoingChunk()
            
        } catch {
            completion(false, "Failed to read file: \(error.localizedDescription)")
        }
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
                sentOutboundChunks += 1
                if totalOutboundChunks > 0 {
                    let pct = Float(sentOutboundChunks) / Float(totalOutboundChunks)
                    pendingProgressCallback?(pct)
                    if let msgId = pendingOutboundId {
                        onTransferProgress?(msgId, pct)
                    }
                }
            } else {
                // Buffer full, will resume in peripheralManagerIsReady(toUpdateSubscribers:)
                return
            }
        }
        
        if outgoingChunkQueue.isEmpty {
            log("All \(totalOutboundChunks) chunks dispatched to BLE stack. Awaiting delivery ACK from Android...")
            startAckTimeout(seconds: 15.0)
        }
    }
    
    private func startAckTimeout(seconds: TimeInterval = 10.0) {
        cancelAckTimeout()
        ackTimeoutTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if let callback = self.pendingOutboundCallback {
                self.log("Delivery timeout: No ACK received from Android within \(seconds) seconds.")
                callback(false, "Delivery timeout (no ACK from Android)")
                self.pendingOutboundCallback = nil
                self.pendingOutboundId = nil
                self.pendingProgressCallback = nil
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
        
        let isClassic = (firstByte == FramingMagic.multiChunk.rawValue || firstByte == FramingMagic.finalChunk.rawValue)
        let isExtended = (firstByte == FramingMagic.extendedMultiChunk.rawValue || firstByte == FramingMagic.extendedFinalChunk.rawValue)
        
        if isClassic || isExtended {
            let seqIndex: Int
            let totalChunks: Int
            let hashValue: UInt64
            let chunkData: Data
            
            if isClassic {
                guard data.count >= 11 else { return }
                seqIndex = Int(data[1])
                totalChunks = Int(data[2])
                let hashBytes = data.subdata(in: 3..<11)
                var h: UInt64 = 0
                _ = withUnsafeMutableBytes(of: &h) { hashBytes.copyBytes(to: $0) }
                hashValue = h
                chunkData = data.subdata(in: 11..<data.count)
            } else {
                guard data.count >= 13 else { return }
                seqIndex = (Int(data[1]) << 8) | Int(data[2])
                totalChunks = (Int(data[3]) << 8) | Int(data[4])
                let hashBytes = data.subdata(in: 5..<13)
                var h: UInt64 = 0
                _ = withUnsafeMutableBytes(of: &h) { hashBytes.copyBytes(to: $0) }
                hashValue = h
                chunkData = data.subdata(in: 13..<data.count)
            }
            
            guard totalChunks > 0 && totalChunks <= 65535, seqIndex >= 0 && seqIndex < totalChunks else {
                log("SECURITY: Dropping invalid chunk framing (seq=\(seqIndex), total=\(totalChunks))")
                return
            }
            
            guard !chunkData.isEmpty else {
                log("SECURITY: Dropping empty chunk payload (seq=\(seqIndex))")
                return
            }
            
            let now = Date()
            chunkBuffers = chunkBuffers.filter { $0.value.deadline > now }
            
            if let existing = chunkBuffers[hashValue] {
                guard existing.total == totalChunks else {
                    log("SECURITY: Dropping chunk with conflicting totalChunks (\(totalChunks) != \(existing.total))")
                    return
                }
            } else if chunkBuffers.count >= maxPendingChunkBuffers {
                log("SECURITY: Dropping chunk; maximum pending reassembly buffers (\(maxPendingChunkBuffers)) reached.")
                return
            }
            
            var entry = chunkBuffers[hashValue] ?? (chunks: [:], total: totalChunks, deadline: now.addingTimeInterval(15.0))
            entry.deadline = now.addingTimeInterval(15.0)
            
            let currentAccumulatedSize = entry.chunks.values.reduce(0) { $0 + $1.count }
            if currentAccumulatedSize + chunkData.count > BleProtocol.maxPayloadBytes {
                log("SECURITY: Accumulated chunks for hash \(hashValue) exceed \(BleProtocol.maxPayloadBytes) bytes; dropping buffer.")
                chunkBuffers.removeValue(forKey: hashValue)
                return
            }
            
            entry.chunks[seqIndex] = chunkData
            chunkBuffers[hashValue] = entry
            
            if totalChunks > 10 && seqIndex % 10 == 0 {
                let pct = Int(Double(entry.chunks.count) / Double(totalChunks) * 100.0)
                log("Receiving stream chunks: \(entry.chunks.count)/\(totalChunks) (\(pct)%)...")
            }
            
            if entry.chunks.count == totalChunks {
                var fullData = Data()
                for i in 0..<totalChunks {
                    if let c = entry.chunks[i] {
                        fullData.append(c)
                    }
                }
                chunkBuffers.removeValue(forKey: hashValue)
                log("Reassembly complete for hash \(hashValue): \(fullData.count) bytes across \(totalChunks) chunks")
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
        
        if let ack = try? decoder.decode(TandemAck.self, from: data), ack.type == "ack" {
            handleInboundAck(ack)
            return
        }
        
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = obj["type"] as? String, type == "ack" {
            let msgId = obj["message_id"] as? String ?? obj["messageId"] as? String ?? ""
            let status = obj["status"] as? String ?? "delivered"
            let code = obj["code"] as? Int ?? 200
            let ack = TandemAck(message_id: msgId, status: status, code: code, error: nil)
            handleInboundAck(ack)
            return
        }
        
        do {
            let message = try decoder.decode(TandemMessage.self, from: data)
            
            if message.type == "handshake" {
                handleHandshakeRequest(message, from: central)
                return
            }
            
            if message.type == "encrypted" {
                handleEncryptedMessage(message, from: central)
                return
            }
            
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
                    log("Dispatched Handshake ACK response with server public key.")
                }
            }
        } catch {
            log("SECURITY REJECT: Failed ECDH key exchange: \(error.localizedDescription)")
            sendAck(messageId: message.message_id, status: "error", code: 500, error: "Handshake failed")
        }
    }
    
    private func handleInboundAck(_ ack: TandemAck) {
        log("Received Delivery ACK from Android for message: \(ack.message_id) (status=\(ack.status), code=\(ack.code))")
        if ack.message_id == pendingOutboundId {
            cancelAckTimeout()
            pendingProgressCallback?(1.0)
            pendingOutboundCallback?(true, "Delivered (Ack 200)")
            pendingOutboundCallback = nil
            pendingOutboundId = nil
            pendingProgressCallback = nil
        }
        onMessageDelivered?(ack.message_id, "Delivered (Ack 200)")
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
            
            if innerMsg.type == "file" {
                handleIncomingFile(innerMsg)
            } else {
                log("🔒 VALID ENCRYPTED MESSAGE RECEIVED: id=\(innerMsg.message_id), bytes=\(innerMsg.payload.utf8.count)")
                onMessageReceived?(innerMsg)
                sendAck(messageId: innerMsg.message_id, status: "delivered", code: 200, error: nil)
            }
            
        } catch {
            log("SECURITY REJECT: AES-GCM decryption failed / Tag mismatch: \(error.localizedDescription)")
            sendAck(messageId: message.message_id, status: "error", code: 400, error: "Decryption failed")
        }
    }
    
    private func handleIncomingFile(_ message: TandemMessage) {
        guard let rawData = Data(base64Encoded: message.payload) else {
            log("FILE REJECT: Invalid Base64 payload for file message \(message.message_id)")
            sendAck(messageId: message.message_id, status: "error", code: 400, error: "Invalid Base64 payload")
            return
        }
        
        // Checksum verification
        let computedSha = SHA256.hash(data: rawData).compactMap { String(format: "%02x", $0) }.joined()
        if let expectedSha = message.sha256?.lowercased(), !expectedSha.isEmpty {
            guard computedSha.lowercased() == expectedSha else {
                log("SECURITY REJECT: SHA-256 checksum mismatch! Computed: \(computedSha), Expected: \(expectedSha)")
                sendAck(messageId: message.message_id, status: "error", code: 400, error: "SHA-256 verification failed")
                return
            }
            log("✓ SHA-256 Verified for incoming file: \(computedSha)")
        }
        
        // Path traversal and overwrite defense
        let rawFilename = message.file_name ?? "tandem_\(message.message_id)"
        let safeFilename = sanitizeFilename(rawFilename, fallbackId: String(message.message_id.prefix(8)))
        
        let downloadsUrl = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let tandemFolder = downloadsUrl.appendingPathComponent("Tandem", isDirectory: true)
        try? FileManager.default.createDirectory(at: tandemFolder, withIntermediateDirectories: true)
        
        let destUrl = uniqueDestinationUrl(in: tandemFolder, filename: safeFilename)
        do {
            try rawData.write(to: destUrl, options: .atomic)
            log("📁 File saved safely to: \(destUrl.path) (\(rawData.count) bytes)")
            
            onFileReceived?(message, destUrl)
            onMessageReceived?(message)
            sendAck(messageId: message.message_id, status: "delivered", code: 200, error: nil)
        } catch {
            log("FILE ERROR: Failed to save file to disk: \(error.localizedDescription)")
            sendAck(messageId: message.message_id, status: "error", code: 500, error: "Failed to save file: \(error.localizedDescription)")
        }
    }
    
    private func sanitizeFilename(_ raw: String, fallbackId: String) -> String {
        let baseName = URL(fileURLWithPath: raw).lastPathComponent
        let safeChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var cleaned = baseName.unicodeScalars.filter { safeChars.contains($0) }.map { String($0) }.joined()
        
        while cleaned.hasPrefix(".") {
            cleaned.removeFirst()
        }
        
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            cleaned = "tandem_\(fallbackId).bin"
        }
        
        if cleaned.count > 120 {
            let ext = (cleaned as NSString).pathExtension
            let name = (cleaned as NSString).deletingPathExtension
            if !ext.isEmpty {
                cleaned = "\(String(name.prefix(110))).\(ext)"
            } else {
                cleaned = String(cleaned.prefix(120))
            }
        }
        return cleaned
    }
    
    private func uniqueDestinationUrl(in folder: URL, filename: String) -> URL {
        var targetUrl = folder.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: targetUrl.path) {
            return targetUrl
        }
        
        let ext = (filename as NSString).pathExtension
        let base = (filename as NSString).deletingPathExtension
        let extSuffix = ext.isEmpty ? "" : ".\(ext)"
        
        var counter = 1
        while FileManager.default.fileExists(atPath: targetUrl.path) && counter < 1000 {
            targetUrl = folder.appendingPathComponent("\(base)_\(counter)\(extSuffix)")
            counter += 1
        }
        return targetUrl
    }
    
    private func handlePlaintextMessage(_ message: TandemMessage, from central: CBCentral) {
        guard !TandemCrypto.shared.isEncrypted else {
            log("SECURITY REJECT: Received unencrypted plaintext message while E2EE session is active.")
            sendAck(messageId: message.message_id, status: "error", code: 403, error: "Plaintext rejected: E2EE session is active")
            return
        }
        
        if isDuplicateOrReplay(message) { return }
        
        if message.type == "file" {
            handleIncomingFile(message)
        } else {
            log("VALID PLAINTEXT MESSAGE RECEIVED: id=\(message.message_id), bytes=\(message.payload.count)")
            onMessageReceived?(message)
            sendAck(messageId: message.message_id, status: "delivered", code: 200, error: nil)
        }
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
