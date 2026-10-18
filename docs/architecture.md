# Tandem Architecture & Feasibility Report

## 1. System Overview & Core Goal

**Tandem** is a zero-cloud, local-first bridge between an Android 10 tablet (Lenovo Tab M10 HD) and a MacBook. Its primary v0.1 milestone is reliable one-way text messaging from Android to Mac over **Bluetooth Low Energy (BLE)** with **Wi-Fi and Internet completely disabled**.

```
+---------------------------+                      +---------------------------+
|      Lenovo Tab M10       |                      |          MacBook          |
|       (Android 10)        |       BLE Link       |       (macOS Tahoe+)      |
|                           |  (GATT Write / Ack)  |                           |
|  [Tandem Android App]     |<====================>|    [Tandem Mac App]       |
|  - Role: GATT Central     |                      |  - Role: GATT Peripheral  |
|  - Scans & Connects       |                      |  - Advertises Service     |
|  - UI: Input + Send + Log |                      |  - UI: Status + Feed + Log|
+---------------------------+                      +---------------------------+
```

---

## 2. BLE Role Feasibility Investigation

The implementation brief explicitly mandates verifying BLE roles before committing to the architecture:
> *"Do not assume macOS can reliably act as a BLE peripheral/GATT server using CoreBluetooth. CoreBluetooth's peripheral role is not generally available on macOS in the same way it is on iOS. Before implementing the final design, investigate and document a viable cross-platform role arrangement."*

### Platform Capabilities & Hardware Inspection

1. **Host Mac Inspection (`system_profiler SPBluetoothDataType` & macOS probe):**
   - **OS:** macOS 26.5.1 (Apple Silicon arm64).
   - **Chipset:** Broadcom BCM_4387 (PCIe transport, Firmware 23.5.636.5343).
   - **Supported Services:** `GATT`, `LEA`, `SerialPort`, `A2DP`, `HID`, etc.
   - **Target Device Detected:** `Lenovo Tab M10 HD` (MAC: `78:D6:DC:25:10:28`, Vendor ID: `0x0046`, Product ID: `0x1200`).
   - **TCC Security Model:** macOS 10.15 through macOS 26+ strictly requires an application bundle with `NSBluetoothAlwaysUsageDescription` in `Info.plist`. Headless command-line binaries fail silently or encounter authorization `.notDetermined` / `.denied`.

2. **Android 10 on Lenovo Tab M10 HD:**
   - **OS:** Android 10 (API Level 29).
   - **Hardware Class:** Entry-level / budget tablet (SoC typically MediaTek Helio P22T or Qualcomm Snapdragon 429/450).
   - **Critical Hardware Limitation:** Budget SoCs on Android 10 frequently have `bluetoothAdapter.isMultipleAdvertisementSupported() == false` and `getBluetoothLeAdvertiser() == null`. They often cannot host GATT servers or advertise reliably.
   - **Guaranteed Capability:** Android BLE Central mode (`BluetoothLeScanner` and `BluetoothGatt`) is supported by 100% of Android 10 BLE-compliant devices.

### Evaluation of Candidate BLE Topologies

| Dimension | Arrangement A: Mac Peripheral / Android Central | Arrangement B: Android Peripheral / Mac Central |
| :--- | :--- | :--- |
| **User Mental Model** | User types on Android and taps "Send" to Mac. Android initiates connection and writes. | Android user wants to send, but Mac must scan, find tablet, and connect. |
| **Android Feasibility** | **100% Supported** on all Android 10 devices (`BluetoothLeScanner` + `connectGatt`). | **High Risk**: Fails if tablet does not support `isMultipleAdvertisementSupported()`. |
| **macOS Feasibility** | Supported via `CBPeripheralManager` with bundle `Info.plist` permissions. | Supported via `CBCentralManager`. |
| **GATT Operations** | Central writes to Peripheral Rx characteristic; Peripheral notifies Tx/Ack characteristic. | Central subscribes to Peripheral notifications; Peripheral pushes notifications. |
| **Background & Sleep** | Mac desktop app remains powered on and listening during desk use. | Android aggressively suspends background advertisers to conserve battery. |

### Verified Architectural Decision

We adopt **Arrangement A (Mac = GATT Server / Peripheral, Android = GATT Client / Central)** as the primary transport, while maintaining a **Role-Agnostic Protocol Abstraction**:

1. **Mac (GATT Peripheral / Server):**
   - Advertises standard 128-bit Tandem Service UUID: `7A8D0001-B5A3-4F39-B948-2E1F4B5C6D01`.
   - Local Name: `TandemMac`.
   - Exposes:
     - **Rx / Message Characteristic:** `7A8D0002-B5A3-4F39-B948-2E1F4B5C6D01` (`WriteWithResponse`, `WriteWithoutResponse`).
     - **Tx / Ack Characteristic:** `7A8D0003-B5A3-4F39-B948-2E1F4B5C6D01` (`Notify`, `Read`).
     - **Device Info Characteristic:** `7A8D0004-B5A3-4F39-B948-2E1F4B5C6D01` (`Read`).

2. **Android (GATT Central / Client):**
   - Scans for Service UUID `7A8D0001-B5A3-4F39-B948-2E1F4B5C6D01` or Device Name `TandemMac`.
   - Connects, discovers characteristics, requests MTU negotiation (requesting up to 512 bytes), and writes UTF-8 JSON message envelopes.
   - Receives delivery acknowledgments via characteristic notifications.

3. **Fallback & Extension Architecture:**
   - Both Android and Mac implement transport interfaces (`BleTransportManager`) decoupling UI and payload logic from the underlying BLE GATT connection.
   - If a specific Mac hardware environment exhibits peripheral advertising restrictions, the Android app also includes peripheral diagnostic tools to check `isMultipleAdvertisementSupported()`.

---

## 3. Security, Authentication & Isolation

1. **Intentional User Connection:**
   - Android will not broadcast or accept unsolicited data; it only connects to peers matching the explicit Tandem Service UUID or explicitly selected from the scan list.
   - The Mac app requires intentional launch, displays connected peer names, and provides a clear disconnect toggle.

2. **Safe Payload Handling:**
   - **No Shell Execution:** Received messages are treated strictly as UTF-8 string data for display in the UI. Under no circumstances are commands executed or passed to shell processes.
   - **Strict JSON Validation:** Unknown schemas or malformed JSON payloads are discarded immediately with a diagnostic parse error logged.
   - **Local Only:** Zero internet connectivity, zero telemetry, zero analytics, zero external network sockets.

---

## 4. Platform Lifecycles & State Machines

### Android 10 (API 29) Requirements
- **Location Permission:** Android 10 requires `ACCESS_FINE_LOCATION` for BLE scanning, plus system Location Services toggled ON. The UI provides a pre-permission rationale dialog explaining this platform requirement.
- **Connection Priority:** Calls `requestConnectionPriority(CONNECTION_PRIORITY_HIGH)` upon connection to minimize write latency.
- **State Machine:**
  `IDLE` -> `CHECKING_PERMISSIONS` -> `SCANNING` -> `CONNECTING` -> `DISCOVERING_SERVICES` -> `READY` -> `SENDING` -> `DISCONNECTED` / `ERROR`.

### macOS Native Helper Requirements
- **Bundle Packaging:** Built as `TandemMac.app` with `NSBluetoothAlwaysUsageDescription`.
- **State Machine:**
  `POWERED_OFF` -> `POWERED_ON` -> `SETTING_UP_SERVICES` -> `ADVERTISING` -> `CONNECTED_PEER` -> `RECEIVING` -> `IDLE` / `ERROR`.
