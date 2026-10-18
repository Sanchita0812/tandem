# Tandem BLE Protocol Specification (v0.2)

## 1. Service & Characteristic UUID Constants

All implementations must use the following constant 128-bit UUIDs. These UUIDs are fixed and must never be randomly generated at runtime.

| Identifier | UUID String | Properties | Purpose |
| :--- | :--- | :--- | :--- |
| **Tandem Service** | `7A8D0001-B5A3-4F39-B948-2E1F4B5C6D01` | Primary Service | Identifies the Tandem GATT service |
| **Rx Characteristic** | `7A8D0002-B5A3-4F39-B948-2E1F4B5C6D01` | `WRITE`, `WRITE_NO_RESPONSE` | Central (Android) writes message envelopes, ACKs, or handshake packets to Peripheral (Mac) |
| **Tx Characteristic** | `7A8D0003-B5A3-4F39-B948-2E1F4B5C6D01` | `NOTIFY`, `READ` | Peripheral (Mac) notifies Central (Android) of messages, ACKs, or handshake responses |
| **Device Info Characteristic** | `7A8D0004-B5A3-4F39-B948-2E1F4B5C6D01` | `READ` | Peripheral exposes protocol version (`v0.2`) and device name string |

---

## 2. Bidirectional Messaging & E2EE Handshake Architecture

```
+-------------------------------------------------------------------------------------------------+
|                                 v0.2 BIDIRECTIONAL E2EE LIFECYCLE                               |
|                                                                                                 |
|   Lenovo Tab M10 (Central)                                             MacBook (Peripheral)     |
|   +-----------------------+                                           +-----------------------+ |
|   | 1. Generate Ephemeral |                                           |                       | |
|   |    P-256 Keypair      |                                           |                       | |
|   |                       |=== Handshake Request (Android Pub) ======>| 2. Generate Ephemeral | |
|   |                       |    (Write on RX Characteristic)           |    P-256 Keypair      | |
|   |                       |                                           | 3. Compute ECDH Secret| |
|   |                       |                                           | 4. Derive AES-256 Key | |
|   | 6. Compute ECDH Secret|<== Handshake Response (Mac Pub) ==========| 5. Compute SAS Code   | |
|   | 7. Derive AES-256 Key |    (Notify on TX Characteristic)          |                       | |
|   | 8. Verify SAS Code    |                                           |                       | |
|   |    [Code: 482-195]    |<--------- Both screens display matching SAS -------> [Code: 482-195]| |
|   |                       |                                           |                       | |
|   | 9. Encrypt & Send     |=== Encrypted Envelope (Android -> Mac) ==>| 10. Decrypt & Render  | |
|   |    (AES-256-GCM)      |    (Write on RX Characteristic)           | 11. Send Delivery ACK | |
|   |                       |                                           |                       | |
|   | 14. Decrypt & Render  |<== Encrypted Envelope (Mac -> Android) ===| 12. Encrypt & Send    | |
|   | 15. Send Delivery ACK |    (Notify on TX Characteristic)          |     (AES-256-GCM)     | |
|   +-----------------------+                                           +-----------------------+ |
+-------------------------------------------------------------------------------------------------+
```

---

## 3. Cryptographic Key Agreement & Handshake

### Ephemeral P-256 Curve Parameters
- **Curve:** NIST P-256 (`secp256r1` / `prime256v1`).
- **Raw Public Key Format:** Uncompressed 64 bytes (`X` [32 bytes] || `Y` [32 bytes]).

### Handshake Request (Android -> Mac)
```json
{
  "version": 2,
  "type": "handshake",
  "message_id": "hs-cli-9f3a12b4",
  "timestamp": "2026-10-18T19:30:00.000Z",
  "sender": "android",
  "payload": "<Base64_Android_Raw_64Bytes>"
}
```

### Handshake Response (Mac -> Android)
```json
{
  "version": 2,
  "type": "handshake_ack",
  "message_id": "hs-ack-4e2b81d7",
  "timestamp": "2026-10-18T19:30:00.050Z",
  "sender": "mac",
  "payload": "<Base64_Mac_Raw_64Bytes>"
}
```

### Key Derivation (HKDF-SHA256)
- **Input Keying Material (IKM):** 32-byte ECDH shared secret point coordinate.
- **Salt:** `"Tandem-v0.2-Salt"`.
- **Info:** `"AES-256-GCM"`.
- **Output Key Material (OKM):** 32 bytes (256-bit symmetric session key).

### Short Authentication String (SAS Verification Code)
Both devices independently compute a 6-digit verification code to protect against active Man-in-the-Middle (MitM) attacks:
```
SortedKeys = sort_lexicographical(LocalPubRaw, PeerPubRaw)
Digest = SHA-256(SortedKeys[0] || SortedKeys[1])
CodeNumber = (Digest[0..3] as BigEndian UInt32) % 1,000,000
SAS = Format("%03d-%03d", CodeNumber / 1000, CodeNumber % 1000)
```
Both devices display `🔒 E2EE Active • Code: 482-195`.

---

## 4. Encrypted Envelope & Payload Schema

### Outer Envelope (Over the Air)
```json
{
  "version": 2,
  "type": "encrypted",
  "message_id": "msg-8f12a3e0-634a",
  "timestamp": "2026-10-18T19:30:05.120Z",
  "sender": "android",
  "payload": "<Base64_Combined_Ciphertext>"
}
```

### Ciphertext Binary Format (AES-256-GCM)
`payload` contains Base64-encoded combined bytes:
- **IV (Nonce):** 12 bytes (cryptographically random per message).
- **Ciphertext:** Variable length (UTF-8 bytes of Inner Message).
- **Authentication Tag:** 16 bytes (128-bit Poly1305 / GCM tag).

### Inner Message (Decrypted Plaintext)
```json
{
  "version": 2,
  "type": "text",
  "message_id": "msg-8f12a3e0-634a",
  "timestamp": "2026-10-18T19:30:05.120Z",
  "sender": "android",
  "payload": "Hello from Lenovo Tab M10!"
}
```

---

## 5. Acknowledgement Envelope

Sent symmetrically by whichever device receives a message:
```json
{
  "version": 2,
  "type": "ack",
  "message_id": "msg-8f12a3e0-634a",
  "status": "delivered",
  "code": 200,
  "error": null
}
```

---

## 6. Symmetrical Chunk Framing Specification

When encoded envelopes exceed `negotiated_mtu - 3`, both Android and macOS use identical 11-byte header chunk framing:

| Byte Offset | Size | Type | Field Description |
| :--- | :--- | :--- | :--- |
| `0` | 1 byte | uint8 | **Framing Magic / Flags**: `0xAA` (Single frame), `0xAB` (Multi-chunk start/continue), `0xAC` (Final chunk) |
| `1` | 1 byte | uint8 | **Sequence Index** (0, 1, 2, ...) |
| `2` | 1 byte | uint8 | **Total Chunks** (1 to 64) |
| `3..10` | 8 bytes | uint64 | **Message Hash / ID Prefix** (8-byte hash of `message_id`) |
| `11..N` | Variable | bytes | **Chunk Payload Bytes** |

### Framing & Reassembly Rules
- **Maximum Chunks:** 64 chunks.
- **Maximum Assembled Payload:** 4,096 bytes.
- **Reassembly Buffer Ceiling:** Maximum 16 concurrent pending message streams.
- **Reassembly Timeout:** 5.0 seconds auto-purge deadline.
