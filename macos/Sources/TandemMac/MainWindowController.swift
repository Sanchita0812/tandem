import AppKit
import CoreBluetooth

public class MainWindowController: NSWindowController {
    
    private var statusDot: NSView!
    private var statusLabel: NSTextField!
    private var subStatusLabel: NSTextField!
    private var advertiseButton: NSButton!
    private var clearFeedButton: NSButton!
    
    private var messagesScrollView: NSScrollView!
    private var messagesStackView: NSStackView!
    private var emptyStateLabel: NSTextField!
    
    private var logTextView: NSTextView!
    private var logScrollView: NSScrollView!
    
    private var receivedMessages: [TandemMessage] = []
    
    public convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 850, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tandem — Bluetooth Bridge (v0.1)"
        window.minSize = NSSize(width: 750, height: 550)
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
        
        let titleLabel = NSTextField(labelWithString: "Tandem BLE Bridge")
        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor = .white
        labelBox.addArrangedSubview(titleLabel)
        
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
        
        // --- 2. Main Split Area: Messages Feed & Diagnostic Logs ---
        let splitView = NSSplitView()
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        
        // Top Pane: Received Messages Feed
        let messagesPane = NSView()
        messagesPane.translatesAutoresizingMaskIntoConstraints = false
        
        let feedHeaderStack = NSStackView()
        feedHeaderStack.orientation = .horizontal
        feedHeaderStack.translatesAutoresizingMaskIntoConstraints = false
        
        let feedTitle = NSTextField(labelWithString: "Received Messages Feed")
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
        
        emptyStateLabel = NSTextField(labelWithString: "No messages received yet.\nConnect from the Android tablet and send a test message.")
        emptyStateLabel.alignment = .center
        emptyStateLabel.textColor = NSColor(white: 0.5, alpha: 1.0)
        emptyStateLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(emptyStateLabel)
        
        NSLayoutConstraint.activate([
            messagesStackView.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 8),
            messagesStackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 8),
            messagesStackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -8),
            messagesStackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -8),
            
            emptyStateLabel.centerXAnchor.constraint(equalTo: documentView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: documentView.centerYAnchor, constant: 30),
            
            feedHeaderStack.topAnchor.constraint(equalTo: messagesPane.topAnchor),
            feedHeaderStack.leadingAnchor.constraint(equalTo: messagesPane.leadingAnchor),
            feedHeaderStack.trailingAnchor.constraint(equalTo: messagesPane.trailingAnchor),
            feedHeaderStack.heightAnchor.constraint(equalToConstant: 24),
            
            messagesScrollView.topAnchor.constraint(equalTo: feedHeaderStack.bottomAnchor, constant: 8),
            messagesScrollView.leadingAnchor.constraint(equalTo: messagesPane.leadingAnchor),
            messagesScrollView.trailingAnchor.constraint(equalTo: messagesPane.trailingAnchor),
            messagesScrollView.bottomAnchor.constraint(equalTo: messagesPane.bottomAnchor)
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
                self?.addMessageCard(message)
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
            statusDot.layer?.backgroundColor = NSColor(red: 0.15, green: 0.78, blue: 0.45, alpha: 1.0).cgColor // Vibrant Green
        case .advertising:
            statusDot.layer?.backgroundColor = NSColor(red: 0.2, green: 0.5, blue: 1.0, alpha: 1.0).cgColor // Blue
        case .poweredOff, .unauthorized, .unsupported, .error:
            statusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
        case .idle, .resetting:
            statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        }
    }
    
    private func addMessageCard(_ message: TandemMessage) {
        emptyStateLabel.isHidden = true
        receivedMessages.append(message)
        
        let card = createCardView()
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
        
        // Card Top Row: Sender Badge + Timestamp
        let topRow = NSStackView()
        topRow.orientation = .horizontal
        topRow.spacing = 8
        
        let senderBadge = NSTextField(labelWithString: " Android Tablet (BLE) ")
        senderBadge.wantsLayer = true
        senderBadge.layer?.backgroundColor = NSColor(red: 0.15, green: 0.35, blue: 0.6, alpha: 0.8).cgColor
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
        receivedMessages.removeAll()
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
