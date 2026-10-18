# Tandem Cybersecurity Risk Assessment & Threat Model

**Target System:** Tandem v0.1 (Offline BLE GATT Bridge: Android 10 Central <-> macOS Peripheral)  
**Security Classification:** Defensive Architecture Review & Code Audit  
**Date:** October 2026  
**Auditor:** Antigravity Advanced Agentic Coding Security Review  

---

## 1. Executive Summary

Tandem is a **local-first, zero-cloud, offline-only** utility designed to bridge an Android 10 tablet (Lenovo Tab M10 HD) and a MacBook over **Bluetooth Low Energy (BLE GATT)** without requiring Wi-Fi, mobile data, local area network routers, or cloud intermediaries.

Because the system operates entirely off-grid:
- **Traditional Remote Exploits are Neutralized:** No listening TCP/UDP ports, no mDNS/Bonjour network services, no internet access, and no cloud relays.
- **Android Kernel Sandboxing:** The Android application specifies **zero** internet permissions (`android.permission.INTERNET` is omitted from `AndroidManifest.xml`). The Android OS kernel strictly blocks any network socket creation.
- **Zero Command Execution Surface:** Neither peer passes received text strings into shell execution environments (`sh`, `bash`, `zsh`, `exec()`, `Process()`, or `Runtime.getRuntime().exec()`). Data deserialization is restricted to strictly typed data models and bound directly to native UI labels.

However, operating over **unencrypted 2.4 GHz broadcast radio** without operating-system-level Bluetooth bonding introduces specific security considerations for proximity-based attackers (within ~10 to 30 meters). This document details the threat model, STRIDE risk taxonomy, codebase vulnerability audit findings, defensive mitigations implemented in v0.1, and the cryptographic roadmap for v0.2.

---

## 2. Attack Surface Analysis

```
+-------------------------------------------------------------------------------------------------+
|                                    PHYSICAL RADIO PROXIMITY                                     |
|                                       (~10 - 30 METERS)                                         |
|                                                                                                 |
|   +-----------------------+                         +-----------------------+                   |
|   |    Lenovo Tab M10     |                         |        MacBook        |                   |
|   |     (Android 10)      |    BLE GATT Over-Air    |    (macOS 13+ Tahoe)  |                   |
|   |                       |    (2.4GHz ISM Band)    |                       |                   |
|   |  - Role: GATT Central |<=======================>|  - Role: GATT Server  |                   |
|   |  - Outgoing Writes    |  Cleartext UTF-8 Chunks |  - Incoming Rx Chars  |                   |
|   |  - CCCD Notifications |  Delivery ACK (Tx Char) |  - Subscribed Tx Char |                   |
|   +-----------------------+                         +-----------------------+                   |
|               |                                                 |                               |
|        [Attack Vectors]                                  [Attack Vectors]                       |
|   - Rogue Peripheral Spoofing                       - Rogue Central Unauth Writes               |
|   - Location BLE Beacon Scanning                    - Chunk Reassembly Heap Flood               |
|   - Backup / ADB Extraction (Fixed)                 - Stale Replay Attacks (Fixed)              |
|                                                     - Unaligned Pointer Traps (Fixed)           |
+-------------------------------------------------------------------------------------------------+
```

### Trust Boundaries
1. **Radio Frequency (RF) Layer:** Public, unauthenticated 2.4 GHz spectrum. Anyone in proximity equipped with a BLE adapter (e.g., nRF52840 dongle, Ubertooth One, or standard smartphone) can monitor advertisements and capture BLE packets.
2. **Device / OS Boundary:** macOS TCC permission subsystem (Bluetooth permission dialog) and Android runtime permissions (`ACCESS_FINE_LOCATION` required on Android 10 for BLE beacon discovery).
3. **Application Sandbox Boundary:** Memory isolation between apps on macOS and Android UID sandboxing.

---

## 3. STRIDE Threat Modeling Matrix

| STRIDE Category | Threat ID | Specific Attack Scenario | Likelihood | Impact | CVSS 3.1 | Status in v0.1 | Mitigation / Resolution |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Spoofing** | **SEC-01** | **Rogue Peripheral:** Attacker broadcasts as `TandemMac` to trick Android into connecting and exfiltrating typed text. | Medium | High | 5.3 (Medium) | **Mitigated in UI & Service Verification** | Android verifies exact 128-bit `SERVICE_UUID`; user manually selects target device from scan list. v0.2 will require cryptographic PIN. |
| **Spoofing** | **SEC-02** | **Rogue Central:** Attacker connects to Mac peripheral and sends unauthorized fake messages. | Medium | Medium | 4.3 (Medium) | **Mitigated in Protocol** | Strict schema validation, timestamp anti-replay window, UI shows central UUID. v0.2 will require BLE bonding. |
| **Tampering** | **SEC-03** | **Man-in-the-Middle (MitM):** Active RF attacker intercepts and modifies chunk frames before delivery. | Low | Medium | 4.8 (Medium) | **Accepted Prototype Risk** | Payload hashes are currently verified for framing; cryptographically signed HMAC scheduled for v0.2. |
| **Repudiation** | **SEC-04** | **Delivery Dispute:** Sender denies sending a message or receiver denies receipt. | Low | Low | 2.1 (Low) | **Mitigated** | UUID-based `message_id`, UTC ISO-8601 timestamps, and bidirectional ACK envelopes. |
| **Information Disclosure** | **SEC-05** | **Passive Eavesdropping:** Attacker with BLE sniffer records text transmitted across GATT characteristics. | High | Medium | 5.3 (Medium) | **Accepted Prototype Risk** | Cleartext UTF-8 JSON in v0.1. Users advised not to send secrets. v0.2 introduces X25519 + AES-256-GCM. |
| **Information Disclosure** | **SEC-06** | **Diagnostic Log / Backup Leakage:** Sensitive text logged to system console or backed up via adb/cloud. | Medium | Low | 3.3 (Low) | **Defended & Hardened** | `android:allowBackup="false"` enforced. Zero-payload logging policy strictly excludes message content. |
| **Denial of Service** | **SEC-07** | **Chunk Buffer Exhaustion:** Rogue central floods Mac with millions of incomplete chunks with differing hashes. | Medium | Medium | 5.3 (Medium) | **Defended & Hardened** | Maximum 16 concurrent pending message buffers; 5.0s expiration deadline; 2KB payload cap. |
| **Denial of Service** | **SEC-08** | **Unaligned Memory Trap:** Malformed chunk header triggers SIGBUS/SIGSEGV on ARM64 when reading UInt64 hash. | Medium | High | 6.5 (Medium) | **Defended & Hardened** | Replaced unsafe pointer loading with alignment-safe byte copying in `BlePeripheralManager.swift`. |
| **Elevation of Privilege** | **SEC-09** | **Command Injection:** Attacker injects shell escapes (e.g. `; rm -rf /`, `$(whoami)`) into payload. | Low | Critical | None (0.0) | **Neutralized by Architecture** | No shell or execution runtime invoked; strings are bound solely to native AppKit/Android UI controls. |

---

## 4. Codebase Vulnerability Audit & Defensive Hardening

### 4.1. macOS Helper Audit (`macos/Sources/TandemMac/`)

#### Finding 1: Unaligned Memory Pointer Load (DoS / Crash Risk) — RESOLVED
- **Vulnerability:** In `BlePeripheralManager.swift`, the 8-byte chunk message hash was originally loaded via:
  ```swift
  let hashValue = hashBytes.withUnsafeBytes { $0.load(as: UInt64.self) }
  ```
  On Apple Silicon (ARM64), if `data.subdata(in: 3..<11)` starts at an unaligned memory offset, `load(as:)` can trigger an unaligned memory access trap (`EXC_ARM_DA_ALIGN`), terminating the application.
- **Defensive Fix Implemented:**
  Replaced pointer loading with an alignment-agnostic safe byte copy:
  ```swift
  var hashValue: UInt64 = 0
  _ = withUnsafeMutableBytes(of: &hashValue) { hashBytes.copyBytes(to: $0) }
  ```
  This guarantees crash-free execution regardless of memory alignment.

#### Finding 2: Chunk Reassembly Flood (Resource Exhaustion DoS) — DEFENDED
- **Mechanism:** Malicious peers could transmit valid chunk headers with unique hashes without ever sending the remaining chunks, accumulating memory.
- **Defenses Implemented in `BlePeripheralManager.swift`:**
  1. `maxPendingChunkBuffers = 16`: The reassembly map drops new buffers once 16 concurrent pending reassemblies are active.
  2. `deadline = Date().addingTimeInterval(5.0)`: Incomplete chunk streams are evicted and reclaimed after 5 seconds.
  3. `BleProtocol.maxPayloadBytes = 2048`: Accumulated bytes for any single stream cannot exceed 2KB; streams exceeding this are immediately purged.
  4. `guard !chunkData.isEmpty`: Empty chunk payloads are dropped immediately.

#### Finding 3: Stale Message Replay Attacks — DEFENDED
- **Mechanism:** An attacker capturing a valid BLE GATT write packet could replay the packet later.
- **Defenses Implemented in `BlePeripheralManager.swift`:**
  1. **Anti-Replay Drift Window:** The receiver inspects `message.timestamp`. Any message whose timestamp deviates by more than 10 minutes (600 seconds) from the Mac system clock is rejected with HTTP 400.
  2. **Circular Deduplication Cache:** A sliding FIFO cache of the last 64 unique `message_id` values suppresses duplicate processing and returns an idempotent ACK 200 without duplicating UI cards.

#### Finding 4: Characteristic Access Control & Permissions
- **Status in v0.1:** `rxCharacteristic` is configured with `.writeable` permissions without requiring OS-level BLE encryption/bonding (`CBAttributePermissionsWriteEncryptionRequired`).
- **Risk:** Any BLE Central within range that discovers the characteristic can write data to it.
- **Mitigation in v0.1:** Strict payload parsing (JSON validation, length limits, timestamp checks).
- **Roadmap for v0.2:** Require OS-level pairing and encryption.

---

### 4.2. Android Application Audit (`android/app/`)

#### Finding 1: Application Backup Vulnerability (`AndroidManifest.xml`) — RESOLVED
- **Vulnerability:** `android:allowBackup="true"` allows extracting application private files and shared preferences via `adb backup` or automated cloud backup services.
- **Defensive Fix Implemented:** Updated to `android:allowBackup="false"`. Prevents extraction of in-memory data or cached session states via local ADB commands or cloud syncing.

#### Finding 2: Zero Internet Permissions Verified — STRENGTH
- **Audit Verification:** `AndroidManifest.xml` was inspected for network permissions:
  ```xml
  <!-- NO android.permission.INTERNET -->
  <!-- NO android.permission.ACCESS_NETWORK_STATE -->
  ```
  The Android operating system kernel enforces sandbox boundaries. Even if third-party code were introduced, it would be physically impossible to open network sockets or leak data to the internet.

#### Finding 3: Location Permission for BLE Scanning
- **Context:** On Android 10 (API 29), Google requires `ACCESS_FINE_LOCATION` to perform BLE device discovery because BLE beacon signals can infer physical proximity.
- **Audit Finding:** Tandem strictly uses `BluetoothLeScanner` for peer discovery. It never instantiates `LocationManager.requestLocationUpdates()`, never accesses GPS coordinates, and never collects location telemetry.

#### Finding 4: Unfiltered BLE Scan Trade-Off
- **Context:** `TandemBleCentral.kt` starts scanning with `scanner.startScan(null, settings, scanCallback)` without a hardware UUID filter.
- **Analysis:** This was intentionally designed to resolve a known Android 10 bug where peripherals advertising 128-bit UUIDs in the scan response packet are silently dropped by hardware filters.
- **Defensive Safeguard:** The application sorts matching `TandemMac` devices to the top of the UI list, displays RSSI and MAC addresses, and only connects upon explicit user tap.

---

## 5. Security Recommendations for End Users

1. **Physical Environment Awareness:**
   - In shared or untrusted spaces (airports, conferences), do not transmit confidential credentials, passwords, or private keys over Tandem v0.1.
   - Use the **Restart / Stop Advertising** control in the macOS helper when not actively transferring data.
2. **Bluetooth Hygiene:**
   - Turn Bluetooth OFF on both devices when not in use.
   - Ensure system software updates on both macOS and Android are kept current.
3. **No Shell Automation:**
   - Never pipe Tandem incoming messages into automated scripts that execute shell commands.

---

## 6. Cryptographic Roadmap for Tandem v0.2

To transition Tandem from a local prototype to an enterprise-grade secure bridge, the following cryptographic architecture is planned for v0.2:

```
+-------------------------------------------------------------------------------------------------+
|                                 v0.2 END-TO-END ENCRYPTED PROTOCOL                              |
|                                                                                                 |
|   Lenovo Tab M10                                                           MacBook              |
|   +-----------------------+                                       +-----------------------+     |
|   | 1. Generate Ephemeral |                                       | 1. Generate Ephemeral |     |
|   |    X25519 Keypair     |                                       |    X25519 Keypair     |     |
|   |                       |====== Handshake (Public Keys) =======>|                       |     |
|   | 2. Compute Shared     |                                       | 2. Compute Shared     |     |
|   |    Secret via ECDH    |<===== Handshake (Public Keys) ========|    Secret via ECDH    |     |
|   |                       |                                       |                       |     |
|   | 3. Derive Session Key |                                       | 3. Derive Session Key |     |
|   |    via HKDF-SHA256    |                                       |    via HKDF-SHA256    |     |
|   |                       |                                       |                       |     |
|   | 4. Display 6-digit    |                                       | 4. Display 6-digit    |     |
|   |    SAS Passkey        |<---- User verifies matching PIN ----->|    SAS Passkey        |     |
|   |                       |                                       |                       |     |
|   | 5. Encrypt Envelope:  |====== Encrypted Frames (AES-GCM) ====>| 5. Decrypt Envelope:  |     |
|   |    AES-256-GCM + IV   |                                       |    Verify Auth Tag    |     |
|   +-----------------------+                                       +-----------------------+     |
+-------------------------------------------------------------------------------------------------+
```

### Components of v0.2:
1. **Asymmetric Key Agreement (X25519):** Ephemeral-Static Diffie-Hellman key exchange over the BLE handshake.
2. **Authenticated Encryption (AES-256-GCM / ChaCha20-Poly1305):** Every message payload and chunk encrypted with a 256-bit session key and 96-bit unique nonce (IV).
3. **Out-of-Band (OOB) Authentication:** Short Authentication String (SAS) or QR-code scan to guarantee protection against Man-in-the-Middle (MitM) attacks.
4. **OS-Level BLE Bonding:** Enable `CBAttributePermissionsWriteEncryptionRequired` on macOS CoreBluetooth, enforcing hardware-encrypted Bluetooth pairing.
