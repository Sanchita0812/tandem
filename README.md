# Tandem (v0.1) — Offline Bluetooth Low Energy Bridge

Tandem is a local-first, zero-cloud bridge between an Android 10 tablet (**Lenovo Tab M10 HD**) and a **MacBook**. It enables secure, offline text messaging over **Bluetooth Low Energy (BLE GATT)** without requiring Wi-Fi, local area network routers, or cloud relays.

```
+---------------------------+                      +---------------------------+
|      Lenovo Tab M10       |                      |          MacBook          |
|       (Android 10)        |       BLE Link       |       (macOS 13+)         |
|                           |  (GATT Write / Ack)  |                           |
|  [Tandem Android App]     |<====================>|    [Tandem Mac App]       |
|  - Role: GATT Central     |                      |  - Role: GATT Peripheral  |
|  - Scans & Connects       |                      |  - Advertises Service     |
|  - UI: Input + Send + Log |                      |  - UI: Status + Feed + Log|
+---------------------------+                      +---------------------------+
```

---

## 1. Quick Navigation & Technical Documentation

- **[Architecture & BLE Role Analysis](file:///Users/sanchitakiran/Documents/Tandem/docs/architecture.md):** Detailed analysis of BLE hardware constraints, peripheral mode limitations on budget Android tablets, and rationale for Mac-as-Peripheral / Android-as-Central topology.
- **[BLE Protocol Specification](file:///Users/sanchitakiran/Documents/Tandem/docs/ble-protocol.md):** 128-bit Service and Characteristic UUIDs, JSON envelope schemas, chunk-framing binary layout (11-byte header), and delivery ACK definitions.
- **[Cybersecurity Threat Model & Audit](file:///Users/sanchitakiran/Documents/Tandem/docs/security.md):** STRIDE threat assessment, attack surface decomposition, memory alignment and backup vulnerability remediations, and v0.2 cryptographic roadmap.
- **[Hardware Test Plan & Checklist](file:///Users/sanchitakiran/Documents/Tandem/docs/test-plan.md):** 10-step physical hardware verification protocol with Wi-Fi and mobile data OFF.
- **[Troubleshooting Guide](file:///Users/sanchitakiran/Documents/Tandem/docs/troubleshooting.md):** Resolutions for macOS TCC Bluetooth permissions, Android 10 location requirements, and Bluetooth stack resets.

---

## 2. Project Structure

```text
Tandem/
├── .gitignore                # Git exclusion rules for macOS, Android & IDEs
├── README.md                 # Complete system guide & setup instructions
├── Tandem-v0.1.apk           # Pre-compiled standalone Android APK (5.8 MB)
├── docs/
│   ├── architecture.md       # BLE feasibility investigation & role decisions
│   ├── ble-protocol.md       # Fixed UUIDs, JSON envelope schema & chunk framing
│   ├── security.md           # Comprehensive cybersecurity risk assessment & threat model
│   ├── test-plan.md          # 10-step physical hardware verification checklist
│   └── troubleshooting.md   # Android 10 location & macOS TCC Bluetooth guides
├── macos/
│   ├── Package.swift         # Swift Package definition (Swift 5.9 / 6.0+)
│   ├── Info.plist            # macOS bundle metadata & Bluetooth usage descriptions
│   ├── build.sh              # Build and packaging script for TandemMac.app
│   ├── build/TandemMac.app   # Pre-built, codesigned native macOS helper bundle
│   └── Sources/TandemMac/
│       ├── main.swift        # Application entrypoint
│       ├── AppDelegate.swift # AppKit lifecycle & window lifecycle management
│       ├── BlePeripheralManager.swift # CoreBluetooth GATT peripheral server & chunk deframer
│       ├── BleProtocol.swift # Shared constants, data structures & framing magics
│       └── MainWindowController.swift # Native AppKit split-view UI, message cards & log view
└── android/
    ├── Tandem-v0.1.apk       # Module copy of the compiled debug APK
    ├── build.sh              # Single-command APK build script
    ├── build.gradle          # Top-level Gradle configuration
    ├── settings.gradle
    ├── gradle.properties
    └── app/
        ├── build.gradle      # Android 10 (API 29) compatibility & dependencies
        └── src/main/
            ├── AndroidManifest.xml # Zero-internet permission sandbox declaration
            ├── java/com/tandem/app/
            │   ├── MainActivity.kt # Android UI, permissions & user interaction
            │   ├── ble/
            │   │   ├── BleProtocol.kt # UUIDs, framing constants & JSON models
            │   │   ├── BleState.kt    # State enums & data structures
            │   │   ├── ChunkFramer.kt # Byte splitter & framing generator
            │   │   └── TandemBleCentral.kt # BluetoothLeScanner & BluetoothGatt manager
            │   └── ui/
            │       ├── DeviceAdapter.kt  # Discovered device list adapter
            │       └── MessageAdapter.kt # Sent message history feed adapter
            └── res/          # Dark slate theme, vector drawables & responsive layouts
```

---

## 3. macOS Native Helper

### Prerequisites
- macOS 13+ (Ventura, Sonoma, Sequoia / Tahoe).
- Bluetooth enabled.

### Run Pre-built Application
```bash
open macos/build/TandemMac.app
```
*(If prompted on first run, click **Allow** in the macOS Bluetooth permission dialog, or verify under **System Settings > Privacy & Security > Bluetooth**).*

### Rebuild from Source Anytime
```bash
cd macos
./build.sh debug    # Builds debug binary and bundles TandemMac.app
./build.sh release  # Builds optimized release binary with code-signing
```

---

## 4. Android Application (Lenovo Tab M10 HD — Android 10)

### Prerequisites
- Lenovo Tab M10 HD running Android 10 (API 29).
- Developer Options & USB Debugging enabled (for ADB installation).

### Install Pre-built Standalone APK
- **Option A — Fast ADB Install:**
  ```bash
  /opt/homebrew/share/android-commandlinetools/platform-tools/adb install -r Tandem-v0.1.apk
  ```
- **Option B — Direct Transfer:**
  Transfer `Tandem-v0.1.apk` to the tablet via USB cable, SD card, or Bluetooth transfer and tap to install.

### Rebuild APK from Source Anytime
```bash
cd android
./build.sh
```
*The build script automatically runs Gradle via OpenJDK 17 and copies the newly compiled APK to both `android/Tandem-v0.1.apk` and root `Tandem-v0.1.apk`.*

---

## 5. Physical Verification Workflow (Wi-Fi OFF)

To verify the offline bridge across physical hardware:
1. **Disable Network Radios:** Turn **Wi-Fi OFF** and **Mobile Data OFF** on both the MacBook and the Android tablet. Ensure Bluetooth is **ON** on both devices.
2. **Start Mac Peripheral:** Launch `TandemMac.app` on the Mac. The status indicator should turn **Blue** showing:
   `Advertising (Service: 7A8D0001-B5A3-4F39-B948-2E1F4B5C6D01)`.
3. **Start Android Central:** Launch **Tandem** on the tablet. Grant the runtime Location permission when prompted (mandatory on Android 10 for BLE discovery).
4. **Scan & Connect:** Tap **Scan for Mac**. The tablet discovers `TandemMac` and places it at the top of the list. Tap **Connect**.
5. **Verify Connection:** The status indicator turns **Green** (`Connected to Peer / Ready`) on both screens.
6. **Send Message:** On the tablet, type `"Hello from Lenovo Tab M10 over BLE!"` and tap **Send Message**.
7. **Observe Delivery:**
   - On the MacBook: A dark card appears immediately in the **Received Messages Feed** displaying the Android badge, timestamp, message ID, and message text.
   - On the Android tablet: The message status updates from `Pending...` to `Delivered (Ack 200)` with a green badge.

---

## 6. Cybersecurity Posture & Threat Model Summary

A full STRIDE threat analysis and codebase security audit is documented in **[`docs/security.md`](file:///Users/sanchitakiran/Documents/Tandem/docs/security.md)**.

### Architectural Guarantees
- **Zero Network Attack Surface:** The app does not open any TCP/UDP ports, start local web servers, or communicate with the internet. Android manifest contains **no** `INTERNET` permission.
- **Zero Command Execution:** Received payloads are strictly deserialized as plain UTF-8 text strings and bound to native AppKit/Android text views. Payloads are never passed to shell interpreters (`sh`, `bash`, `zsh`, `exec`, or `Runtime.getRuntime().exec()`).
- **Memory Safety & Alignment:** Unaligned memory access hazards on ARM64 have been eliminated in the chunk deframer (`BlePeripheralManager.swift`) using alignment-safe buffer operations.
- **Buffer Exhaustion Defense:** The macOS helper strictly caps chunk reassembly to **16 concurrent pending messages**, enforces a **5.0-second auto-expiration** deadline, and drops payloads exceeding **2,048 bytes**.
- **Anti-Replay Window:** Received messages must fall within a **10-minute freshness window** against system time; a sliding cache of 64 `message_id`s prevents replay attacks.
- **Application Sandbox Hardening:** `android:allowBackup="false"` is enforced to prevent ADB or cloud extraction of app state.

### Planned v0.2 Security Enhancements
- **X25519 Ephemeral Key Agreement & HKDF-SHA256:** Session-based Diffie-Hellman handshake over BLE.
- **AES-256-GCM Authenticated Encryption:** Radio-layer encryption to defeat physical BLE packet sniffers.
- **OS-Level BLE Bonding:** `writeEncryptionRequired` with 6-digit numeric comparison passkeys on both screens.
