# Tandem v0.1 Hardware Test Plan

## 1. Test Environment

- **Mac Device:** Apple MacBook (macOS 26.5.1, Apple Silicon BCM_4387 Bluetooth 5.3 Controller).
- **Tablet Device:** Lenovo Tab M10 HD (Android 10 / API 29, Bluetooth 5.0 LE).
- **Physical Link:** Direct 2.4 GHz Bluetooth Low Energy (No Wi-Fi, No Internet, No Cables).

---

## 2. Test Execution Checklist

### Test 1: Offline Baseline Verification
- [ ] Turn Wi-Fi **OFF** on MacBook.
- [ ] Turn Wi-Fi, Mobile Data, and Airplane Mode toggles to ensure **NO Internet** on the Lenovo tablet.
- [ ] Ensure Bluetooth is enabled on both devices.

### Test 2: Mac Launch & BLE Peripheral Advertisement
- [ ] Launch `TandemMac.app`.
- [ ] Verify macOS prompts for Bluetooth permission if not previously granted.
- [ ] Verify Mac UI displays state: `Advertising (Service: 7A8D0001...)`.
- [ ] Diagnostic log shows: `GATT Service added with Rx and Tx characteristics`.

### Test 3: Android Launch & Discovery
- [ ] Launch Tandem Android app on Lenovo Tab M10 HD.
- [ ] If prompted, approve Location permission (`ACCESS_FINE_LOCATION`) with clear rationale.
- [ ] Ensure system Location toggle is ON.
- [ ] Tap **Scan for Mac**.
- [ ] Verify `TandemMac` appears in the discovery list with RSSI value and Service UUID.

### Test 4: Connection & GATT Service Discovery
- [ ] Tap **Connect** on Android.
- [ ] Android status transitions: `SCANNING` -> `CONNECTING` -> `CONNECTED`.
- [ ] Mac UI updates to show: `Connected to peer: Lenovo Tab M10 HD`.
- [ ] Android requests MTU update (512 bytes) and subscribes to Tx / Ack characteristic notifications.

### Test 5: First Message Transmission (Android -> Mac)
- [ ] Type short message: `"Hello from Lenovo Tab M10!"` into Android input field.
- [ ] Tap **Send**.
- [ ] Observe Mac UI: Message appears instantly in the received messages feed with timestamp and sender ID.
- [ ] Observe Android UI: Delivery indicator changes from `Sending...` to `Delivered (Ack 200)`.

### Test 6: Special Characters, Unicode & Emoji
- [ ] Type message with emoji and non-ASCII text: `"Tandem 🚀 Bluetooth Test — こんにちは / नमस्ते"`.
- [ ] Tap **Send**.
- [ ] Verify text is rendered accurately on Mac without encoding artifacts or truncation.

### Test 7: Maximum Length & Chunk Framing
- [ ] Send payload near maximum safe length (2,000 characters).
- [ ] If chunk framing is triggered, verify all frames arrive and are reassembled into the complete JSON envelope.
- [ ] Verify Mac parses JSON successfully and acknowledges.

### Test 8: Rapid Consecutive Sends
- [ ] Send 5 messages in quick succession (under 2 seconds).
- [ ] Verify all 5 messages appear in sequential order without drops or app crashes.
- [ ] Verify `message_id` deduplication prevents duplicated records.

### Test 9: Disconnect & Recovery Gracefulness
- [ ] Tap **Disconnect** on Android or quit `TandemMac.app`.
- [ ] Verify the other device updates status to `Disconnected` without crashing.
- [ ] Incomplete buffers or pending packets are discarded cleanly.
- [ ] Restart app and re-connect; verify connection is re-established seamlessly.

### Test 10: Bluetooth Off / Permission Denied Handling
- [ ] Toggle Bluetooth OFF on Mac while app is running. UI displays `Bluetooth Unavailable / Off`.
- [ ] Toggle Bluetooth back ON; verify service advertising resumes or recovers cleanly.
- [ ] Repeat on Android; verify Android presents actionable guidance to turn Bluetooth on.
