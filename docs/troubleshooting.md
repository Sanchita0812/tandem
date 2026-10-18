# Tandem Troubleshooting Guide

## 1. macOS Issues & Resolutions

### "App does not advertise or Bluetooth state is unauthorized"
- **Cause:** macOS requires explicit user permission for Bluetooth access via TCC (Transparency, Consent, and Control). Command-line scripts or binaries outside `.app` bundles cannot properly display permission prompts.
- **Resolution:**
  1. Ensure the app is launched as a `.app` bundle (`TandemMac.app`) with `NSBluetoothAlwaysUsageDescription` in `Info.plist`.
  2. Open **System Settings > Privacy & Security > Bluetooth**.
  3. Ensure `TandemMac` is enabled in the list.
  4. If previously denied, run:
     ```bash
     tccutil reset Bluetooth com.tandem.macos
     ```
     and re-launch `TandemMac.app`.

### "Bluetooth is powered off"
- **Resolution:**
  Toggle macOS Bluetooth on via Control Center or CLI:
  ```bash
  blueutil --power 1
  ```
  Check controller state:
  ```bash
  system_profiler SPBluetoothDataType
  ```

---

## 2. Android 10 (Lenovo Tab M10 HD) Issues & Resolutions

### "Scanning does not discover TandemMac"
- **Cause 1: Location Services disabled.** On Android 10 (API 29), BLE beacon/peripheral discovery is tied to location privacy. Even if the app has `ACCESS_FINE_LOCATION` permission granted, the system-level Location toggle (GPS/Location in quick settings) must be **ON**.
  - **Fix:** Swipe down from the top of the tablet screen and verify the **Location** icon is toggled **ON**.
- **Cause 2: Bluetooth disabled.**
  - **Fix:** Verify Bluetooth is turned ON in Settings.
- **Cause 3: Tablet Bluetooth stack cached old state.**
  - **Fix:** Toggle Bluetooth OFF, wait 3 seconds, and toggle back ON. Force stop the Tandem app and re-open.

### "Connection times out or drops immediately"
- **Cause:** Android BLE GATT cache or connection collision.
- **Resolution:**
  1. Tandem automatically requests `CONNECTION_PRIORITY_HIGH` upon connect.
  2. If the tablet was previously paired to the Mac at the OS level (e.g. standard audio or file transfer), remove/unpair "MacBook" from Android Bluetooth settings to avoid GATT service collision. Tandem uses direct GATT connections over BLE.

### "Peripheral mode unsupported"
- **Note:** If attempting to use Android as a BLE advertiser on Lenovo Tab M10 HD, verify whether the chipset supports it:
  ```kotlin
  val isSupported = bluetoothAdapter.isMultipleAdvertisementSupported
  ```
  If this returns `false`, the tablet cannot advertise as a peripheral; Tandem defaults to **Android as Central / Mac as Peripheral** to ensure 100% compatibility.

---

## 3. Wi-Fi & Offline Operation Verification

- Tandem v0.1 does not use TCP/IP, UDP, HTTP, DNS, or mDNS.
- To verify true offline operation:
  1. Turn Wi-Fi **OFF** on MacBook.
  2. Turn Wi-Fi and Mobile Data **OFF** on Lenovo tablet.
  3. Open Tandem on both devices and connect over BLE.
