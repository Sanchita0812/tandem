# Tandem (v0.2) — Offline BLE Bridge with Two-Way Messaging & E2EE

Tandem is a local-first, zero-cloud bridge between an Android 10 tablet (**Lenovo Tab M10 HD**) and a **MacBook**. It enables secure, offline **two-way text messaging** and **End-to-End Encryption (AES-256-GCM + ECDH P-256)** over **Bluetooth Low Energy (BLE GATT)** without requiring Wi-Fi, mobile data, local network routers, or cloud relays.

```
+-------------------------------------------------------------------------------------------------+
|                                 v0.2 BIDIRECTIONAL E2EE BRIDGE                                  |
|                                                                                                 |
|   Lenovo Tab M10 (Android 10)                                          MacBook (macOS 13+)      |
|   +--------------------------+                                        +-----------------------+ |
|   | [Tandem Android App]     |           BLE GATT Over-Air            |   [Tandem Mac App]    | |
|   | - Role: GATT Central     |       (2.4 GHz ISM Spectrum)           | - Role: GATT Server   | |
|   |                          |                                        |                       | |
|   | 1. Auto ECDH Handshake   |<======== Ephemeral Key Exchange ======>| 1. Auto ECDH Handshake| |
|   | 2. E2EE Active Badge     |                                        | 2. E2EE Active Badge  | |
|   |    [Code: 482-195]       |<--- Both screens display matching SAS -|    [Code: 482-195]    | |
|   |                          |                                        |                       | |
|   | 3. Send to Mac           |==== Encrypted Writes (AES-GCM) =======>| 3. Live Messages Feed | |
|   |    (Delivery Ack 200)    |<=== Delivery ACK Notification =========|                       | |
|   |                          |                                        |                       | |
|   | 4. Live Messages Feed    |<=== Encrypted Notifications (AES-GCM) =| 4. Send to Android    | |
|   |                          |==== Delivery ACK Write ===============>|    (Delivery Ack 200) | |
|   +--------------------------+                                        +-----------------------+ |
+-------------------------------------------------------------------------------------------------+
```

---

## 1. Technical Documentation & Specs

- **[BLE Protocol Specification (v0.2)](file:///Users/sanchitakiran/Documents/Tandem/docs/ble-protocol.md):** 128-bit UUID constants, ephemeral P-256 key exchange, AES-256-GCM envelope schema, and symmetrical chunk framing (11-byte header).
- **[Cybersecurity Threat Model & Audit](file:///Users/sanchitakiran/Documents/Tandem/docs/security.md):** STRIDE matrix, attack surface analysis, memory safety remediations, and radio eavesdropping defense.
- **[Architecture & BLE Role Analysis](file:///Users/sanchitakiran/Documents/Tandem/docs/architecture.md):** Android 10 peripheral limitations and GATT Central/Server topology decision.
- **[Hardware Verification Checklist](file:///Users/sanchitakiran/Documents/Tandem/docs/test-plan.md):** Physical test protocol with Wi-Fi and mobile data OFF.
- **[Troubleshooting Guide](file:///Users/sanchitakiran/Documents/Tandem/docs/troubleshooting.md):** macOS TCC Bluetooth permissions and Android 10 location requirements.

---

## 2. Project Structure

```text
Tandem/
├── .gitignore                # Exclusion rules for macOS, Android & IDE caches
├── README.md                 # Complete system guide & setup instructions
├── Tandem-v0.1.apk           # Pre-compiled standalone Android APK (v0.2 features)
├── docs/
│   ├── architecture.md       # BLE feasibility investigation & topology decisions
│   ├── ble-protocol.md       # Fixed UUIDs, ECDH handshake, AES-GCM & chunk framing
│   ├── security.md           # Comprehensive cybersecurity threat model & STRIDE audit
│   ├── test-plan.md          # Hardware verification checklist
│   └── troubleshooting.md   # Android 10 location & macOS Bluetooth permissions
├── macos/
│   ├── Package.swift         # Swift Package definition
│   ├── Info.plist            # macOS bundle metadata & Bluetooth descriptions
│   ├── build.sh              # Build and packaging script for TandemMac.app
│   ├── build/TandemMac.app   # Pre-built, codesigned native macOS helper bundle
│   └── Sources/TandemMac/
│       ├── main.swift        # Application entrypoint
│       ├── AppDelegate.swift # AppKit lifecycle & window management
│       ├── BlePeripheralManager.swift # CoreBluetooth GATT server, chunk framer & deframer
│       ├── BleProtocol.swift # Shared constants, data structures & framing magics
│       ├── TandemCrypto.swift # Apple CryptoKit: P-256 ECDH, HKDF-SHA256 & AES-256-GCM
│       └── MainWindowController.swift # Two-way conversation feed & message composer
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
            │   ├── MainActivity.kt # Android UI, permissions & conversation feed
            │   ├── ble/
            │   │   ├── BleProtocol.kt # UUIDs, envelope models & constants
            │   │   ├── BleState.kt    # State enums & MessageRecord
            │   │   ├── ChunkFramer.kt # Symmetrical byte splitter & reassembly deframer
            │   │   ├── TandemBleCentral.kt # BluetoothLeScanner, GATT client & two-way logic
            │   │   └── TandemCrypto.kt # Android JCE: P-256 ECDH, HKDF-SHA256 & AES-256-GCM
            │   └── ui/
            │       ├── DeviceAdapter.kt  # Discovered device list adapter
            │       └── MessageAdapter.kt # Two-way conversation adapter with sender badges
            └── res/          # Dark slate theme, vector drawables & responsive layouts
```

---

## 3. macOS Native Helper (v0.2)

### Run Pre-built App
```bash
open macos/build/TandemMac.app
```
*(If prompted, grant Bluetooth permission under **System Settings > Privacy & Security > Bluetooth**).*

### Key Features on Mac:
- **Automatic E2EE Handshake:** Upon connection, automatically exchanges P-256 public keys with Android and computes the shared AES-256-GCM session key.
- **Short Authentication String (SAS):** Displays a green badge `🔒 E2EE Active (AES-256-GCM) • Code: XXX-XXX` matching the code on the tablet.
- **Two-Way Message Composer:** Type a message into the composer box at the bottom of the Messages pane and hit **Return** or click **Send to Android**.
- **Live Delivery ACKs:** Cards update to `Delivered (Ack 200)` when confirmed by the tablet.

### Rebuild Anytime
```bash
cd macos
./build.sh debug
```

---

## 4. Android Application (Lenovo Tab M10 HD — Android 10)

### Install Pre-built APK
- **Via ADB:**
  ```bash
  /opt/homebrew/share/android-commandlinetools/platform-tools/adb install -r Tandem-v0.1.apk
  ```
- **Via Direct Transfer:** Transfer `Tandem-v0.1.apk` via USB cable or SD card and install.

### Key Features on Android:
- **Zero Internet Permissions:** Android OS kernel sandboxing guarantees no network access (`android.permission.INTERNET` is omitted).
- **Two-Way Messaging:** View incoming messages sent from the Mac with blue `MacBook (BLE)` badges; send messages to the Mac with green `Tablet (You)` badges.
- **Hardware-Accelerated AES-GCM:** Real-time encryption/decryption using native Android JCE.

### Rebuild Anytime
```bash
cd android
./build.sh
```

---

## 5. Physical Verification Workflow (Wi-Fi OFF)

1. **Disable Network Radios:** Turn **Wi-Fi OFF** and **Mobile Data OFF** on both the MacBook and the tablet.
2. **Start Mac Helper:** Launch `TandemMac.app`. Verify status shows `Advertising (Service: 7A8D0001...)`.
3. **Connect from Tablet:** Launch **Tandem** on Android. Tap **Scan for Mac**, select `TandemMac`, and tap **Connect**.
4. **Verify E2EE Handshake:**
   - Both screens immediately display the green security badge:
     `🔒 E2EE Active (AES-256-GCM) • Code: 482-195` *(example code)*.
   - Confirm the 6 digits match on both screens.
5. **Send Android -> Mac:** Type a message on the tablet and tap **Send Message**.
   - Appears immediately in the Mac feed.
   - Android shows `Delivered (Ack 200)`.
6. **Send Mac -> Android:** Type a message into the Mac composer at the bottom and click **Send to Android** (or press Return).
   - Appears immediately in the Android feed with a blue `MacBook (BLE)` badge.
   - Mac shows `Delivered to Android (Ack 200)`.
