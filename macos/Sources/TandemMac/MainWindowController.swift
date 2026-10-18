import AppKit
import CoreBluetooth

public class MainWindowController: NSWindowController, NSTextFieldDelegate {
    
    private var statusDot: NSView!
    private var statusLabel: NSTextField!
    private var subStatusLabel: NSTextField!
    private var securityBadge: NSTextField!
    private var advertiseButton: NSButton!
    private var clearFeedButton: NSButton!
    
    private var messagesScrollView: NSScrollView!
    private var messagesStackView: NSStackView!
    private var emptyStateLabel: NSTextField!
    
    // Outgoing Message Composer (Two-Way Messaging)
    private var composerCard: NSView!
    private var messageInputField: NSTextField!
    private var sendButton: NSButton!
    private var charCountLabel: NSTextField!
    private var sendStatusLabel: NSTextField!
    
    private var logTextView: NSTextView!
    private var logScrollView: NSScrollView!
    
    private var messageDeliveryLabels: [String: NSTextField] = [:]
    
    public convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 900, height: 750),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tandem — Offline BLE Bridge (v0.2 E2EE)"
        window.minSize = NSSize(width: 800, height: 600)
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        setupUI()
        bindPeripheralManager()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
    
    private func setupUI() {
        guard let window = window, let contentView = window.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1.0).cgColor
        
        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.spacing = 16
        rootStack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        rootStack.alignment = .leading
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rootStack)
        
        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor),
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        
        // --- 1. Header Card ---
        let headerCard = createCardView()
        let headerInner = NSStackView()
        headerInner.orientation = .horizontal
        headerInner.spacing = 16
        headerInner.alignment = .centerY
        headerInner.translatesAutoresizingMaskIntoConstraints = false
        headerCard.addSubview(headerInner)
        
        NSLayoutConstraint.activate([
            headerInner.topAnchor.constraint(equalTo: headerCard.topAnchor, constant: 14),
            headerInner.bottomAnchor.constraint(equalTo: headerCard.bottomAnchor, constant: -14),
            headerInner.leadingAnchor.constraint(equalTo: headerCard.leadingAnchor, constant: 18),
            headerInner.trailingAnchor.constraint(equalTo: headerCard.trailingAnchor, constant: -18)
        ])
        
        // Status Dot
        statusDot = NSView()
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 8
        statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 16),
            statusDot.heightAnchor.constraint(equalToConstant: 16)
        ])
        headerInner.addArrangedSubview(statusDot)
        
        let labelBox = NSStackView()
        labelBox.orientation = .vertical
        labelBox.alignment = .leading
        labelBox.spacing = 3
        
        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.spacing = 10
        titleRow.alignment = .centerY
        
        let titleLabel = NSTextField(labelWithString: "Tandem BLE Bridge (v0.2)")
        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor = .white
        titleRow.addArrangedSubview(titleLabel)
        
        // Security Badge (E2EE)
        securityBadge = NSTextField(labelWithString: " 🔒 End-to-End Encrypted (AES-256-GCM) ")
        securityBadge.wantsLayer = true
        securityBadge.layer?.backgroundColor = NSColor(red: 0.05, green: 0.35, blue: 0.2, alpha: 0.8).cgColor
        securityBadge.layer?.cornerRadius = 6
        securityBadge.layer?.borderWidth = 1
        securityBadge.layer?.borderColor = NSColor(red: 0.2, green: 0.8, blue: 0.5, alpha: 0.6).cgColor
        securityBadge.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        securityBadge.textColor = NSColor(red: 0.4, green: 0.95, blue: 0.6, alpha: 1.0)
        securityBadge.isHidden = true
        titleRow.addArrangedSubview(securityBadge)
        
        labelBox.addArrangedSubview(titleRow)
        
        statusLabel = NSTextField(labelWithString: "Status: Initializing Bluetooth...")
        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        statusLabel.textColor = NSColor(white: 0.85, alpha: 1.0)
        labelBox.addArrangedSubview(statusLabel)
        
        subStatusLabel = NSTextField(labelWithString: "Service: 7A8D0001 • Local Name: TandemMac • Role: GATT Server")
        subStatusLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        subStatusLabel.textColor = NSColor(white: 0.6, alpha: 1.0)
        labelBox.addArrangedSubview(subStatusLabel)
        
        headerInner.addArrangedSubview(labelBox)
        
        // Spacer
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerInner.addArrangedSubview(spacer)
        
        // Toggle Advertising Button
        advertiseButton = NSButton(title: "Restart Advertising", target: self, action: #selector(toggleAdvertising))
        advertiseButton.bezelStyle = .rounded
        advertiseButton.controlSize = .regular
        headerInner.addArrangedSubview(advertiseButton)
        
        rootStack.addArrangedSubview(headerCard)
        headerCard.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        
        // --- 2. Main Split Area: Conversation Feed & Diagnostic Logs ---
        let splitView = NSSplitView()
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        
        // Top Pane: Conversation Feed & Composer
        let messagesPane = NSView()
        messagesPane.translatesAutoresizingMaskIntoConstraints = false
        
        let feedHeaderStack = NSStackView()
        feedHeaderStack.orientation = .horizontal
        feedHeaderStack.translatesAutoresizingMaskIntoConstraints = false
        
        let feedTitle = NSTextField(labelWithString: "Live Conversation Feed (Two-Way)")
        feedTitle.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        feedTitle.textColor = .white
        feedHeaderStack.addArrangedSubview(feedTitle)
        
        let feedSpacer = NSView()
        feedSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        feedHeaderStack.addArrangedSubview(feedSpacer)
        
        clearFeedButton = NSButton(title: "Clear Feed", target: self, action: #selector(clearFeed))
        clearFeedButton.bezelStyle = .inline
        clearFeedButton.font = NSFont.systemFont(ofSize: 11)
        feedHeaderStack.addArrangedSubview(clearFeedButton)
        
        messagesPane.addSubview(feedHeaderStack)
        
        // Messages Scroll View
        messagesScrollView = NSScrollView()
        messagesScrollView.hasVerticalScroller = true
        messagesScrollView.drawsBackground = false
        messagesScrollView.translatesAutoresizingMaskIntoConstraints = false
        messagesPane.addSubview(messagesScrollView)
        
        messagesStackView = NSStackView()
        messagesStackView.orientation = .vertical
        messagesStackView.spacing = 10
        messagesStackView.alignment = .leading
        messagesStackView.translatesAutoresizingMaskIntoConstraints = false
        
        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(messagesStackView)
        messagesScrollView.documentView = documentView
        
        emptyStateLabel = NSTextField(labelWithString: "No messages yet.\nConnect from the Android tablet to exchange end-to-end encrypted messages.")
        emptyStateLabel.alignment = .center
        emptyStateLabel.textColor = NSColor(white: 0.5, alpha: 1.0)
        emptyStateLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(emptyStateLabel)
        
        // Composer Box (Mac -> Android Send)
        composerCard = createCardView()
        composerCard.layer?.backgroundColor = NSColor(red: 0.1, green: 0.12, blue: 0.16, alpha: 1.0).cgColor
        composerCard.translatesAutoresizingMaskIntoConstraints = false
        
        let composerInner = NSStackView()
        composerInner.orientation = .vertical
        composerInner.spacing = 8
        composerInner.translatesAutoresizingMaskIntoConstraints = false
        composerCard.addSubview(composerInner)
        
        NSLayoutConstraint.activate([
            composerInner.topAnchor.constraint(equalTo: composerCard.topAnchor, constant: 10),
            composerInner.bottomAnchor.constraint(equalTo: composerCard.bottomAnchor, constant: -10),
            composerInner.leadingAnchor.constraint(equalTo: composerCard.leadingAnchor, constant: 14),
            composerInner.trailingAnchor.constraint(equalTo: composerCard.trailingAnchor, constant: -14)
        ])
        
        let inputRow = NSStackView()
        inputRow.orientation = .horizontal
        inputRow.spacing = 10
        inputRow.alignment = .centerY
        
        messageInputField = NSTextField()
        messageInputField.placeholderString = "Type a message to send to Android tablet... (Press Return or tap Send)"
        messageInputField.font = NSFont.systemFont(ofSize: 13)
        messageInputField.textColor = .white
        messageInputField.backgroundColor = NSColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1.0)
        messageInputField.isBezeled = true
        messageInputField.bezelStyle = .roundedBezel
        messageInputField.delegate = self
        messageInputField.target = self
        messageInputField.action = #selector(sendTextMessage)
        inputRow.addArrangedSubview(messageInputField)
        
        sendButton = NSButton(title: "Send to Android", target: self, action: #selector(sendTextMessage))
        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"
        sendButton.isEnabled = false
        inputRow.addArrangedSubview(sendButton)
        
        composerInner.addArrangedSubview(inputRow)
        
        let metaRow = NSStackView()
        metaRow.orientation = .horizontal
        metaRow.spacing = 8
        
        charCountLabel = NSTextField(labelWithString: "0 / 4096 bytes")
        charCountLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        charCountLabel.textColor = NSColor(white: 0.5, alpha: 1.0)
        metaRow.addArrangedSubview(charCountLabel)
        
        let metaSpacer = NSView()
        metaSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        metaRow.addArrangedSubview(metaSpacer)
        
        sendStatusLabel = NSTextField(labelWithString: "Waiting for Android tablet connection...")
        sendStatusLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        sendStatusLabel.textColor = NSColor(white: 0.6, alpha: 1.0)
        metaRow.addArrangedSubview(sendStatusLabel)
        
        composerInner.addArrangedSubview(metaRow)
        messagesPane.addSubview(composerCard)
        
        NSLayoutConstraint.activate([
            messagesStackView.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 8),
            messagesStackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 8),
            messagesStackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -8),
            messagesStackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -8),
            
            emptyStateLabel.centerXAnchor.constraint(equalTo: documentView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: documentView.centerYAnchor),
            
            feedHeaderStack.topAnchor.constraint(equalTo: messagesPane.topAnchor),
            feedHeaderStack.leadingAnchor.constraint(equalTo: messagesPane.leadingAnchor),
            feedHeaderStack.trailingAnchor.constraint(equalTo: messagesPane.trailingAnchor),
            feedHeaderStack.heightAnchor.constraint(equalToConstant: 24),
            
            messagesScrollView.topAnchor.constraint(equalTo: feedHeaderStack.bottomAnchor, constant: 8),
            messagesScrollView.leadingAnchor.constraint(equalTo: messagesPane.leadingAnchor),
            messagesScrollView.trailingAnchor.constraint(equalTo: messagesPane.trailingAnchor),
            messagesScrollView.bottomAnchor.constraint(equalTo: composerCard.topAnchor, constant: -10),
            
            composerCard.leadingAnchor.constraint(equalTo: messagesPane.leadingAnchor),
            composerCard.trailingAnchor.constraint(equalTo: messagesPane.trailingAnchor),
            composerCard.bottomAnchor.constraint(equalTo: messagesPane.bottomAnchor),
            composerCard.heightAnchor.constraint(equalToConstant: 76)
        ])
        
        splitView.addSubview(messagesPane)
        
        // Bottom Pane: Diagnostic Event Log
        let logPane = NSView()
        logPane.translatesAutoresizingMaskIntoConstraints = false
        
        let logHeaderStack = NSStackView()
        logHeaderStack.orientation = .horizontal
        logHeaderStack.translatesAutoresizingMaskIntoConstraints = false
        
        let logTitle = NSTextField(labelWithString: "Diagnostic Event Log")
        logTitle.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        logTitle.textColor = NSColor(white: 0.8, alpha: 1.0)
        logHeaderStack.addArrangedSubview(logTitle)
        
        let logSpacer = NSView()
        logSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        logHeaderStack.addArrangedSubview(logSpacer)
        
        let clearLogButton = NSButton(title: "Clear Log", target: self, action: #selector(clearLog))
        clearLogButton.bezelStyle = .inline
        clearLogButton.font = NSFont.systemFont(ofSize: 11)
        logHeaderStack.addArrangedSubview(clearLogButton)
        
        logPane.addSubview(logHeaderStack)
        
        logScrollView = NSScrollView()
        logScrollView.hasVerticalScroller = true
        logScrollView.translatesAutoresizingMaskIntoConstraints = false
        
        logTextView = NSTextView()
        logTextView.isEditable = false
        logTextView.isSelectable = true
        logTextView.backgroundColor = NSColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1.0)
        logTextView.textColor = NSColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 1.0)
        logTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logTextView.autoresizingMask = [.width]
        logScrollView.documentView = logTextView
        
        logPane.addSubview(logScrollView)
        
        NSLayoutConstraint.activate([
            logHeaderStack.topAnchor.constraint(equalTo: logPane.topAnchor, constant: 8),
            logHeaderStack.leadingAnchor.constraint(equalTo: logPane.leadingAnchor),
            logHeaderStack.trailingAnchor.constraint(equalTo: logPane.trailingAnchor),
            logHeaderStack.heightAnchor.constraint(equalToConstant: 20),
            
            logScrollView.topAnchor.constraint(equalTo: logHeaderStack.bottomAnchor, constant: 6),
            logScrollView.leadingAnchor.constraint(equalTo: logPane.leadingAnchor),
            logScrollView.trailingAnchor.constraint(equalTo: logPane.trailingAnchor),
            logScrollView.bottomAnchor.constraint(equalTo: logPane.bottomAnchor)
        ])
        
        splitView.addSubview(logPane)
        
        rootStack.addArrangedSubview(splitView)
        splitView.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        splitView.heightAnchor.constraint(equalTo: rootStack.heightAnchor, constant: -100).isActive = true
    }
    
    private func createCardView() -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 1.0).cgColor
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor(white: 0.2, alpha: 0.5).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        return card
    }
    
    private func bindPeripheralManager() {
        let manager = BlePeripheralManager.shared
        
        manager.onStateChanged = { [weak self] state, detail in
            DispatchQueue.main.async {
                self?.updateStatus(state: state, detail: detail)
            }
        }
        
        manager.onMessageReceived = { [weak self] message in
            DispatchQueue.main.async {
                self?.addMessageCard(message, isOutgoing: false)
            }
        }
        
        manager.onMessageDelivered = { [weak self] messageId, status in
            DispatchQueue.main.async {
                self?.updateDeliveryStatus(messageId: messageId, status: status)
            }
        }
        
        manager.onSecurityCodeChanged = { [weak self] code in
            DispatchQueue.main.async {
                self?.updateSecurityBadge(code: code)
            }
        }
        
        manager.onLog = { [weak self] logLine in
            DispatchQueue.main.async {
                self?.appendLog(logLine)
            }
        }
    }
    
    private func updateStatus(state: BlePeripheralState, detail: String) {
        statusLabel.stringValue = "Status: \(state.rawValue)"
        subStatusLabel.stringValue = detail
        
        switch state {
        case .connected:
            statusDot.layer?.backgroundColor = NSColor(red: 0.15, green: 0.78, blue: 0.45, alpha: 1.0).cgColor
            sendButton.isEnabled = true
            sendStatusLabel.stringValue = "Connected to tablet • Ready to send"
            sendStatusLabel.textColor = NSColor(red: 0.3, green: 0.8, blue: 0.5, alpha: 1.0)
        case .advertising:
            statusDot.layer?.backgroundColor = NSColor(red: 0.2, green: 0.5, blue: 1.0, alpha: 1.0).cgColor
            sendButton.isEnabled = false
            sendStatusLabel.stringValue = "Advertising • Waiting for tablet connection..."
            sendStatusLabel.textColor = NSColor(white: 0.6, alpha: 1.0)
            updateSecurityBadge(code: nil)
        case .poweredOff, .unauthorized, .unsupported, .error:
            statusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
            sendButton.isEnabled = false
            sendStatusLabel.stringValue = "Bluetooth unavailable"
            sendStatusLabel.textColor = NSColor.systemRed
            updateSecurityBadge(code: nil)
        case .idle, .resetting:
            statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            sendButton.isEnabled = false
            updateSecurityBadge(code: nil)
        }
    }
    
    private func updateSecurityBadge(code: String?) {
        if let code = code {
            securityBadge.stringValue = " 🔒 E2EE Active (AES-256-GCM) • Code: \(code) "
            securityBadge.isHidden = false
        } else {
            securityBadge.isHidden = true
        }
    }
    
    private func addMessageCard(_ message: TandemMessage, isOutgoing: Bool) {
        emptyStateLabel.isHidden = true
        
        let card = createCardView()
        if isOutgoing {
            card.layer?.backgroundColor = NSColor(red: 0.10, green: 0.18, blue: 0.14, alpha: 1.0).cgColor
            card.layer?.borderColor = NSColor(red: 0.2, green: 0.6, blue: 0.35, alpha: 0.5).cgColor
        }
        
        let cardStack = NSStackView()
        cardStack.orientation = .vertical
        cardStack.spacing = 8
        cardStack.alignment = .leading
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)
        
        NSLayoutConstraint.activate([
            cardStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16)
        ])
        
        // Card Top Row
        let topRow = NSStackView()
        topRow.orientation = .horizontal
        topRow.spacing = 8
        
        let senderBadge = NSTextField(labelWithString: isOutgoing ? " MacBook (You) " : " Android Tablet (BLE) ")
        senderBadge.wantsLayer = true
        senderBadge.layer?.backgroundColor = isOutgoing ?
            NSColor(red: 0.15, green: 0.5, blue: 0.25, alpha: 0.8).cgColor :
            NSColor(red: 0.15, green: 0.35, blue: 0.6, alpha: 0.8).cgColor
        senderBadge.layer?.cornerRadius = 4
        senderBadge.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        senderBadge.textColor = .white
        topRow.addArrangedSubview(senderBadge)
        
        let timeLabel = NSTextField(labelWithString: message.timestamp)
        timeLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = NSColor(white: 0.6, alpha: 1.0)
        topRow.addArrangedSubview(timeLabel)
        
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        topRow.addArrangedSubview(spacer)
        
        let deliveryBadge = NSTextField(labelWithString: isOutgoing ? "Sending..." : "Received (Verified)")
        deliveryBadge.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        deliveryBadge.textColor = isOutgoing ? NSColor.systemOrange : NSColor(red: 0.3, green: 0.8, blue: 0.5, alpha: 1.0)
        topRow.addArrangedSubview(deliveryBadge)
        
        if isOutgoing {
            messageDeliveryLabels[message.message_id] = deliveryBadge
        }
        
        let idLabel = NSTextField(labelWithString: String(message.message_id.prefix(12)))
        idLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        idLabel.textColor = NSColor(white: 0.45, alpha: 1.0)
        topRow.addArrangedSubview(idLabel)
        
        cardStack.addArrangedSubview(topRow)
        
        // Message Body
        let bodyLabel = NSTextField(wrappingLabelWithString: message.payload)
        bodyLabel.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        bodyLabel.textColor = .white
        bodyLabel.isSelectable = true
        cardStack.addArrangedSubview(bodyLabel)
        
        messagesStackView.insertArrangedSubview(card, at: 0)
        card.widthAnchor.constraint(equalTo: messagesStackView.widthAnchor).isActive = true
    }
    
    private func updateDeliveryStatus(messageId: String, status: String) {
        if let label = messageDeliveryLabels[messageId] {
            label.stringValue = status
            label.textColor = NSColor(red: 0.3, green: 0.85, blue: 0.5, alpha: 1.0)
        }
    }
    
    @objc private func sendTextMessage() {
        let text = messageInputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        
        messageInputField.stringValue = ""
        charCountLabel.stringValue = "0 / 4096 bytes"
        sendButton.isEnabled = false
        sendStatusLabel.stringValue = "Encrypting & dispatching chunks..."
        
        let messageId = "mac-" + UUID().uuidString.prefix(8).lowercased()
        let localMsg = TandemMessage(
            version: BleProtocol.protocolVersion,
            type: "text",
            message_id: messageId,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            sender: "mac",
            payload: text
        )
        addMessageCard(localMsg, isOutgoing: true)
        
        BlePeripheralManager.shared.sendMessage(text: text, messageId: messageId) { [weak self] success, detail in
            DispatchQueue.main.async {
                self?.sendButton.isEnabled = true
                if success {
                    self?.sendStatusLabel.stringValue = "Delivered to Android (Ack 200)"
                    self?.sendStatusLabel.textColor = NSColor(red: 0.3, green: 0.85, blue: 0.5, alpha: 1.0)
                    self?.updateDeliveryStatus(messageId: messageId, status: "Delivered (Ack 200)")
                } else {
                    self?.sendStatusLabel.stringValue = "Delivery failed: \(detail)"
                    self?.sendStatusLabel.textColor = NSColor.systemRed
                    self?.updateDeliveryStatus(messageId: messageId, status: "Failed: \(detail)")
                }
            }
        }
    }
    
    public func controlTextDidChange(_ obj: Notification) {
        let count = messageInputField.stringValue.utf8.count
        charCountLabel.stringValue = "\(count) / 4096 bytes"
    }
    
    private func appendLog(_ line: String) {
        logTextView.textStorage?.append(NSAttributedString(
            string: line + "\n",
            attributes: [
                .foregroundColor: NSColor(red: 0.4, green: 0.85, blue: 0.5, alpha: 1.0),
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            ]
        ))
        logTextView.scrollToEndOfDocument(nil)
    }
    
    @objc private func toggleAdvertising() {
        BlePeripheralManager.shared.startAdvertising()
    }
    
    @objc private func clearFeed() {
        messageDeliveryLabels.removeAll()
        for subview in messagesStackView.arrangedSubviews {
            messagesStackView.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        emptyStateLabel.isHidden = false
    }
    
    @objc private func clearLog() {
        logTextView.string = ""
    }
}
