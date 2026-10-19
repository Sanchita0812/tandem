import AppKit
import CoreBluetooth

public class MainWindowController: NSWindowController, NSTextFieldDelegate {
    
    // Top Bar & Status
    private var statusDot: NSView!
    private var statusLabel: NSTextField!
    private var subStatusLabel: NSTextField!
    private var securityBadge: NSTextField!
    private var advertiseButton: NSButton!
    private var clearFeedButton: NSButton!
    private var toggleLogButton: NSButton!
    
    // Conversation Feed
    private var messagesScrollView: NSScrollView!
    private var messagesStackView: NSStackView!
    private var emptyStateContainer: NSView!
    
    // Composer
    private var composerBar: NSView!
    private var messageInputField: NSTextField!
    private var sendButton: NSButton!
    private var charCountLabel: NSTextField!
    private var sendStatusLabel: NSTextField!
    
    // Diagnostic Log Drawer
    private var logContainer: NSView!
    private var logTextView: NSTextView!
    private var logScrollView: NSScrollView!
    private var logHeightConstraint: NSLayoutConstraint!
    private var isLogVisible: Bool = false
    private var logEventCount: Int = 0
    
    // Message state tracking
    private var messageDeliveryLabels: [String: NSTextField] = [:]
    
    public convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 940, height: 750),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Tandem — Offline BLE Bridge"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1.0)
        window.minSize = NSSize(width: 820, height: 580)
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
        
        // Native Frosted Glass Vibrancy
        let visualEffectView = NSVisualEffectView(frame: contentView.bounds)
        visualEffectView.autoresizingMask = [.width, .height]
        visualEffectView.material = .underWindowBackground
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        contentView.addSubview(visualEffectView)
        
        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.spacing = 0
        rootStack.alignment = .leading
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rootStack)
        
        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor),
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        
        // -------------------------------------------------------------
        // 1. Top Header Bar (Unified title bar with traffic light clearance)
        // -------------------------------------------------------------
        let headerBar = NSView()
        headerBar.wantsLayer = true
        headerBar.layer?.backgroundColor = NSColor(red: 0.09, green: 0.11, blue: 0.15, alpha: 0.85).cgColor
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(headerBar)
        
        NSLayoutConstraint.activate([
            headerBar.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: 68)
        ])
        
        let headerInner = NSStackView()
        headerInner.orientation = .horizontal
        headerInner.spacing = 14
        headerInner.alignment = .centerY
        headerInner.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(headerInner)
        
        // Traffic light clearance on left (~78pt)
        NSLayoutConstraint.activate([
            headerInner.topAnchor.constraint(equalTo: headerBar.topAnchor, constant: 10),
            headerInner.bottomAnchor.constraint(equalTo: headerBar.bottomAnchor, constant: -10),
            headerInner.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 78),
            headerInner.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -18)
        ])
        
        // Live status dot
        statusDot = NSView()
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 5
        statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 10),
            statusDot.heightAnchor.constraint(equalToConstant: 10)
        ])
        headerInner.addArrangedSubview(statusDot)
        
        // Title & metadata stack
        let titleBox = NSStackView()
        titleBox.orientation = .vertical
        titleBox.alignment = .leading
        titleBox.spacing = 3
        
        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.spacing = 8
        titleRow.alignment = .centerY
        
        let titleLabel = NSTextField(labelWithString: "Tandem")
        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        titleLabel.textColor = .white
        titleRow.addArrangedSubview(titleLabel)
        
        let verBadge = NSTextField(labelWithString: " v0.2 ")
        verBadge.wantsLayer = true
        verBadge.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.09).cgColor
        verBadge.layer?.cornerRadius = 4
        verBadge.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        verBadge.textColor = NSColor(white: 0.75, alpha: 1.0)
        titleRow.addArrangedSubview(verBadge)
        
        securityBadge = NSTextField(labelWithString: " 🔒 E2EE Active • Code: --- ")
        securityBadge.wantsLayer = true
        securityBadge.layer?.backgroundColor = NSColor(red: 0.06, green: 0.28, blue: 0.17, alpha: 0.9).cgColor
        securityBadge.layer?.cornerRadius = 5
        securityBadge.layer?.borderWidth = 1
        securityBadge.layer?.borderColor = NSColor(red: 0.2, green: 0.7, blue: 0.4, alpha: 0.5).cgColor
        securityBadge.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        securityBadge.textColor = NSColor(red: 0.4, green: 0.95, blue: 0.65, alpha: 1.0)
        securityBadge.isHidden = true
        titleRow.addArrangedSubview(securityBadge)
        
        titleBox.addArrangedSubview(titleRow)
        
        let metaRow = NSStackView()
        metaRow.orientation = .horizontal
        metaRow.spacing = 6
        metaRow.alignment = .centerY
        
        statusLabel = NSTextField(labelWithString: "Status: Initializing...")
        statusLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        statusLabel.textColor = NSColor(white: 0.85, alpha: 1.0)
        metaRow.addArrangedSubview(statusLabel)
        
        let metaDivider = NSTextField(labelWithString: "•")
        metaDivider.font = NSFont.systemFont(ofSize: 11)
        metaDivider.textColor = NSColor(white: 0.35, alpha: 1.0)
        metaRow.addArrangedSubview(metaDivider)
        
        subStatusLabel = NSTextField(labelWithString: "Service: 7A8D0001 • Local Name: TandemMac")
        subStatusLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        subStatusLabel.textColor = NSColor(white: 0.55, alpha: 1.0)
        metaRow.addArrangedSubview(subStatusLabel)
        
        titleBox.addArrangedSubview(metaRow)
        headerInner.addArrangedSubview(titleBox)
        
        // Header spacer
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerInner.addArrangedSubview(headerSpacer)
        
        // Header Action Buttons
        clearFeedButton = NSButton(title: "Clear Feed", target: self, action: #selector(clearFeed))
        clearFeedButton.bezelStyle = .rounded
        clearFeedButton.controlSize = .small
        headerInner.addArrangedSubview(clearFeedButton)
        
        toggleLogButton = NSButton(title: "Show Logs", target: self, action: #selector(toggleLogDrawer))
        toggleLogButton.bezelStyle = .rounded
        toggleLogButton.controlSize = .small
        headerInner.addArrangedSubview(toggleLogButton)
        
        advertiseButton = NSButton(title: "Restart Advertising", target: self, action: #selector(toggleAdvertising))
        advertiseButton.bezelStyle = .rounded
        advertiseButton.controlSize = .regular
        headerInner.addArrangedSubview(advertiseButton)
        
        // Header bottom separator
        let headerBorder = NSView()
        headerBorder.wantsLayer = true
        headerBorder.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        headerBorder.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(headerBorder)
        NSLayoutConstraint.activate([
            headerBorder.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor),
            headerBorder.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor),
            headerBorder.bottomAnchor.constraint(equalTo: headerBar.bottomAnchor),
            headerBorder.heightAnchor.constraint(equalToConstant: 1)
        ])
        
        // -------------------------------------------------------------
        // 2. Middle Area: Live Conversation Feed
        // -------------------------------------------------------------
        let feedContainer = NSView()
        feedContainer.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(feedContainer)
        
        NSLayoutConstraint.activate([
            feedContainer.widthAnchor.constraint(equalTo: rootStack.widthAnchor)
        ])
        feedContainer.setContentHuggingPriority(.defaultLow, for: .vertical)
        
        // Messages Scroll View
        messagesScrollView = NSScrollView()
        messagesScrollView.hasVerticalScroller = true
        messagesScrollView.drawsBackground = false
        messagesScrollView.translatesAutoresizingMaskIntoConstraints = false
        feedContainer.addSubview(messagesScrollView)
        
        let messagesDocView = NSView()
        messagesDocView.translatesAutoresizingMaskIntoConstraints = false
        messagesScrollView.documentView = messagesDocView
        
        messagesStackView = NSStackView()
        messagesStackView.orientation = .vertical
        messagesStackView.spacing = 12
        messagesStackView.alignment = .leading
        messagesStackView.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 14, right: 20)
        messagesStackView.translatesAutoresizingMaskIntoConstraints = false
        messagesDocView.addSubview(messagesStackView)
        
        // Empty State Illustration/Notice
        emptyStateContainer = NSView()
        emptyStateContainer.translatesAutoresizingMaskIntoConstraints = false
        
        let emptyStack = NSStackView()
        emptyStack.orientation = .vertical
        emptyStack.spacing = 8
        emptyStack.alignment = .centerX
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        emptyStateContainer.addSubview(emptyStack)
        
        let emptyIcon = NSTextField(labelWithString: "📡")
        emptyIcon.font = NSFont.systemFont(ofSize: 32)
        emptyIcon.alignment = .center
        emptyStack.addArrangedSubview(emptyIcon)
        
        let emptyTitle = NSTextField(labelWithString: "No Messages Yet")
        emptyTitle.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        emptyTitle.textColor = NSColor(white: 0.75, alpha: 1.0)
        emptyTitle.alignment = .center
        emptyStack.addArrangedSubview(emptyTitle)
        
        let emptySub = NSTextField(labelWithString: "Open Tandem on your Android tablet and tap 'Scan & Connect'.\nMessages exchanged offline via BLE will appear here as directional chat bubbles.")
        emptySub.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        emptySub.textColor = NSColor(white: 0.45, alpha: 1.0)
        emptySub.alignment = .center
        emptyStack.addArrangedSubview(emptySub)
        
        feedContainer.addSubview(emptyStateContainer)
        
        NSLayoutConstraint.activate([
            messagesScrollView.topAnchor.constraint(equalTo: feedContainer.topAnchor),
            messagesScrollView.leadingAnchor.constraint(equalTo: feedContainer.leadingAnchor),
            messagesScrollView.trailingAnchor.constraint(equalTo: feedContainer.trailingAnchor),
            messagesScrollView.bottomAnchor.constraint(equalTo: feedContainer.bottomAnchor),
            
            messagesDocView.topAnchor.constraint(equalTo: messagesScrollView.contentView.topAnchor),
            messagesDocView.leadingAnchor.constraint(equalTo: messagesScrollView.contentView.leadingAnchor),
            messagesDocView.trailingAnchor.constraint(equalTo: messagesScrollView.contentView.trailingAnchor),
            messagesDocView.widthAnchor.constraint(equalTo: messagesScrollView.contentView.widthAnchor),
            
            messagesStackView.topAnchor.constraint(equalTo: messagesDocView.topAnchor),
            messagesStackView.leadingAnchor.constraint(equalTo: messagesDocView.leadingAnchor),
            messagesStackView.trailingAnchor.constraint(equalTo: messagesDocView.trailingAnchor),
            messagesStackView.bottomAnchor.constraint(lessThanOrEqualTo: messagesDocView.bottomAnchor),
            
            emptyStateContainer.centerXAnchor.constraint(equalTo: feedContainer.centerXAnchor),
            emptyStateContainer.centerYAnchor.constraint(equalTo: feedContainer.centerYAnchor),
            emptyStack.centerXAnchor.constraint(equalTo: emptyStateContainer.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: emptyStateContainer.centerYAnchor)
        ])
        
        // -------------------------------------------------------------
        // 3. Docked Message Composer Bar
        // -------------------------------------------------------------
        composerBar = NSView()
        composerBar.wantsLayer = true
        composerBar.layer?.backgroundColor = NSColor(red: 0.08, green: 0.10, blue: 0.14, alpha: 0.95).cgColor
        composerBar.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(composerBar)
        
        NSLayoutConstraint.activate([
            composerBar.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            composerBar.heightAnchor.constraint(equalToConstant: 76)
        ])
        
        let composerTopBorder = NSView()
        composerTopBorder.wantsLayer = true
        composerTopBorder.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        composerTopBorder.translatesAutoresizingMaskIntoConstraints = false
        composerBar.addSubview(composerTopBorder)
        
        NSLayoutConstraint.activate([
            composerTopBorder.leadingAnchor.constraint(equalTo: composerBar.leadingAnchor),
            composerTopBorder.trailingAnchor.constraint(equalTo: composerBar.trailingAnchor),
            composerTopBorder.topAnchor.constraint(equalTo: composerBar.topAnchor),
            composerTopBorder.heightAnchor.constraint(equalToConstant: 1)
        ])
        
        let composerInner = NSStackView()
        composerInner.orientation = .vertical
        composerInner.spacing = 6
        composerInner.alignment = .leading
        composerInner.translatesAutoresizingMaskIntoConstraints = false
        composerBar.addSubview(composerInner)
        
        NSLayoutConstraint.activate([
            composerInner.topAnchor.constraint(equalTo: composerBar.topAnchor, constant: 10),
            composerInner.bottomAnchor.constraint(equalTo: composerBar.bottomAnchor, constant: -10),
            composerInner.leadingAnchor.constraint(equalTo: composerBar.leadingAnchor, constant: 20),
            composerInner.trailingAnchor.constraint(equalTo: composerBar.trailingAnchor, constant: -20)
        ])
        
        let inputRow = NSStackView()
        inputRow.orientation = .horizontal
        inputRow.spacing = 10
        inputRow.alignment = .centerY
        inputRow.translatesAutoresizingMaskIntoConstraints = false
        composerInner.addArrangedSubview(inputRow)
        inputRow.widthAnchor.constraint(equalTo: composerInner.widthAnchor).isActive = true
        
        // Input Capsule Container
        let inputCapsule = NSView()
        inputCapsule.wantsLayer = true
        inputCapsule.layer?.cornerRadius = 18
        inputCapsule.layer?.borderWidth = 1
        inputCapsule.layer?.borderColor = NSColor(white: 1.0, alpha: 0.12).cgColor
        inputCapsule.layer?.backgroundColor = NSColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1.0).cgColor
        inputCapsule.translatesAutoresizingMaskIntoConstraints = false
        inputRow.addArrangedSubview(inputCapsule)
        
        messageInputField = NSTextField()
        messageInputField.isBordered = false
        messageInputField.drawsBackground = false
        messageInputField.focusRingType = .none
        messageInputField.placeholderString = "Type a message to Android tablet... (Press Return to send)"
        messageInputField.font = NSFont.systemFont(ofSize: 13)
        messageInputField.textColor = .white
        messageInputField.delegate = self
        messageInputField.target = self
        messageInputField.action = #selector(sendTextMessage)
        messageInputField.translatesAutoresizingMaskIntoConstraints = false
        inputCapsule.addSubview(messageInputField)
        
        NSLayoutConstraint.activate([
            inputCapsule.heightAnchor.constraint(equalToConstant: 36),
            messageInputField.leadingAnchor.constraint(equalTo: inputCapsule.leadingAnchor, constant: 14),
            messageInputField.trailingAnchor.constraint(equalTo: inputCapsule.trailingAnchor, constant: -14),
            messageInputField.centerYAnchor.constraint(equalTo: inputCapsule.centerYAnchor)
        ])
        
        sendButton = NSButton(title: "Send to Android", target: self, action: #selector(sendTextMessage))
        sendButton.bezelStyle = .rounded
        sendButton.controlSize = .regular
        sendButton.keyEquivalent = "\r"
        sendButton.isEnabled = false
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        inputRow.addArrangedSubview(sendButton)
        
        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.spacing = 8
        statusRow.alignment = .centerY
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        composerInner.addArrangedSubview(statusRow)
        statusRow.widthAnchor.constraint(equalTo: composerInner.widthAnchor).isActive = true
        
        charCountLabel = NSTextField(labelWithString: "0 / 4096 bytes")
        charCountLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        charCountLabel.textColor = NSColor(white: 0.45, alpha: 1.0)
        statusRow.addArrangedSubview(charCountLabel)
        
        let statusSpacer = NSView()
        statusSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusRow.addArrangedSubview(statusSpacer)
        
        sendStatusLabel = NSTextField(labelWithString: "Waiting for Android tablet connection...")
        sendStatusLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        sendStatusLabel.textColor = NSColor(white: 0.50, alpha: 1.0)
        statusRow.addArrangedSubview(sendStatusLabel)
        
        // -------------------------------------------------------------
        // 4. Collapsible Diagnostic Log Console
        // -------------------------------------------------------------
        logContainer = NSView()
        logContainer.wantsLayer = true
        logContainer.layer?.backgroundColor = NSColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1.0).cgColor
        logContainer.translatesAutoresizingMaskIntoConstraints = false
        logContainer.isHidden = true
        rootStack.addArrangedSubview(logContainer)
        
        logHeightConstraint = logContainer.heightAnchor.constraint(equalToConstant: 0)
        logHeightConstraint.isActive = true
        
        NSLayoutConstraint.activate([
            logContainer.widthAnchor.constraint(equalTo: rootStack.widthAnchor)
        ])
        
        let logHeader = NSStackView()
        logHeader.orientation = .horizontal
        logHeader.spacing = 10
        logHeader.alignment = .centerY
        logHeader.translatesAutoresizingMaskIntoConstraints = false
        logContainer.addSubview(logHeader)
        
        let logTitle = NSTextField(labelWithString: "DIAGNOSTIC EVENT LOG")
        logTitle.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        logTitle.textColor = NSColor(white: 0.65, alpha: 1.0)
        logHeader.addArrangedSubview(logTitle)
        
        let logSpacer = NSView()
        logSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        logHeader.addArrangedSubview(logSpacer)
        
        let clearLogBtn = NSButton(title: "Clear", target: self, action: #selector(clearLog))
        clearLogBtn.bezelStyle = .inline
        clearLogBtn.font = NSFont.systemFont(ofSize: 10)
        logHeader.addArrangedSubview(clearLogBtn)
        
        let closeLogBtn = NSButton(title: "Close", target: self, action: #selector(toggleLogDrawer))
        closeLogBtn.bezelStyle = .inline
        closeLogBtn.font = NSFont.systemFont(ofSize: 10)
        logHeader.addArrangedSubview(closeLogBtn)
        
        logScrollView = NSScrollView()
        logScrollView.hasVerticalScroller = true
        logScrollView.drawsBackground = false
        logScrollView.translatesAutoresizingMaskIntoConstraints = false
        logContainer.addSubview(logScrollView)
        
        logTextView = NSTextView()
        logTextView.isEditable = false
        logTextView.isSelectable = true
        logTextView.backgroundColor = NSColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1.0)
        logTextView.textColor = NSColor(red: 0.65, green: 0.75, blue: 0.85, alpha: 1.0)
        logTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logTextView.textContainerInset = NSSize(width: 8, height: 6)
        logTextView.autoresizingMask = [.width]
        logScrollView.documentView = logTextView
        
        NSLayoutConstraint.activate([
            logHeader.topAnchor.constraint(equalTo: logContainer.topAnchor, constant: 6),
            logHeader.leadingAnchor.constraint(equalTo: logContainer.leadingAnchor, constant: 16),
            logHeader.trailingAnchor.constraint(equalTo: logContainer.trailingAnchor, constant: -16),
            logHeader.heightAnchor.constraint(equalToConstant: 22),
            
            logScrollView.topAnchor.constraint(equalTo: logHeader.bottomAnchor, constant: 4),
            logScrollView.leadingAnchor.constraint(equalTo: logContainer.leadingAnchor, constant: 12),
            logScrollView.trailingAnchor.constraint(equalTo: logContainer.trailingAnchor, constant: -12),
            logScrollView.bottomAnchor.constraint(equalTo: logContainer.bottomAnchor, constant: -8)
        ])
    }
    
    @objc private func toggleLogDrawer() {
        isLogVisible.toggle()
        logContainer.isHidden = !isLogVisible
        logHeightConstraint.constant = isLogVisible ? 180 : 0
        toggleLogButton.title = isLogVisible ? "Hide Logs" : (logEventCount > 0 ? "Logs (\(logEventCount))" : "Show Logs")
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            self.window?.contentView?.layoutSubtreeIfNeeded()
        }
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
                self?.addMessageBubble(message, isOutgoing: false)
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
            statusDot.layer?.backgroundColor = NSColor(red: 0.15, green: 0.80, blue: 0.45, alpha: 1.0).cgColor
            sendButton.isEnabled = true
            sendStatusLabel.stringValue = "Connected to tablet • Ready to send"
            sendStatusLabel.textColor = NSColor(red: 0.35, green: 0.85, blue: 0.55, alpha: 1.0)
        case .advertising:
            statusDot.layer?.backgroundColor = NSColor(red: 0.25, green: 0.55, blue: 0.95, alpha: 1.0).cgColor
            sendButton.isEnabled = false
            sendStatusLabel.stringValue = "Advertising • Waiting for tablet connection..."
            sendStatusLabel.textColor = NSColor(white: 0.55, alpha: 1.0)
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
            securityBadge.stringValue = " 🔒 E2EE Active • Code: \(code) "
            securityBadge.isHidden = false
        } else {
            securityBadge.isHidden = true
        }
    }
    
    // -------------------------------------------------------------
    // Directional Chat Bubble Rendering
    // -------------------------------------------------------------
    private func addMessageBubble(_ message: TandemMessage, isOutgoing: Bool) {
        emptyStateContainer.isHidden = true
        
        // Full width row container
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        
        // Bubble container
        let bubble = NSView()
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 14
        bubble.layer?.borderWidth = 1
        bubble.translatesAutoresizingMaskIntoConstraints = false
        
        if isOutgoing {
            // Outgoing: MacBook (Right side, dark cyan/navy tint)
            bubble.layer?.backgroundColor = NSColor(red: 0.10, green: 0.22, blue: 0.35, alpha: 0.95).cgColor
            bubble.layer?.borderColor = NSColor(red: 0.25, green: 0.48, blue: 0.72, alpha: 0.4).cgColor
        } else {
            // Incoming: Android Tablet (Left side, dark graphite/slate)
            bubble.layer?.backgroundColor = NSColor(red: 0.12, green: 0.14, blue: 0.19, alpha: 0.95).cgColor
            bubble.layer?.borderColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        }
        
        row.addSubview(bubble)
        
        // Inside bubble stack
        let bubbleStack = NSStackView()
        bubbleStack.orientation = .vertical
        bubbleStack.spacing = 6
        bubbleStack.alignment = .leading
        bubbleStack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        bubbleStack.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(bubbleStack)
        
        NSLayoutConstraint.activate([
            bubbleStack.topAnchor.constraint(equalTo: bubble.topAnchor),
            bubbleStack.bottomAnchor.constraint(equalTo: bubble.bottomAnchor),
            bubbleStack.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
            bubbleStack.trailingAnchor.constraint(equalTo: bubble.trailingAnchor)
        ])
        
        // Top row: Sender Chip + Delivery Status + Timestamp
        let topRow = NSStackView()
        topRow.orientation = .horizontal
        topRow.spacing = 8
        topRow.alignment = .centerY
        
        let senderBadge = NSTextField(labelWithString: isOutgoing ? " MacBook (You) " : " Android Tablet ")
        senderBadge.wantsLayer = true
        senderBadge.layer?.backgroundColor = isOutgoing ?
            NSColor(red: 0.08, green: 0.30, blue: 0.18, alpha: 0.9).cgColor :
            NSColor(red: 0.10, green: 0.22, blue: 0.42, alpha: 0.9).cgColor
        senderBadge.layer?.cornerRadius = 4
        senderBadge.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        senderBadge.textColor = isOutgoing ?
            NSColor(red: 0.40, green: 0.90, blue: 0.60, alpha: 1.0) :
            NSColor(red: 0.45, green: 0.75, blue: 1.0, alpha: 1.0)
        topRow.addArrangedSubview(senderBadge)
        
        let deliveryBadge = NSTextField(labelWithString: isOutgoing ? "Sending..." : "Received (Verified)")
        deliveryBadge.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        deliveryBadge.textColor = isOutgoing ? NSColor.systemOrange : NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1.0)
        topRow.addArrangedSubview(deliveryBadge)
        
        if isOutgoing {
            messageDeliveryLabels[message.message_id] = deliveryBadge
        }
        
        let cleanTimestamp: String
        if message.timestamp.contains("T") {
            let parts = message.timestamp.split(separator: "T")
            cleanTimestamp = parts.count > 1 ? String(parts[1].prefix(8)) : message.timestamp
        } else {
            cleanTimestamp = message.timestamp
        }
        
        let timeLabel = NSTextField(labelWithString: cleanTimestamp)
        timeLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        timeLabel.textColor = NSColor(white: 0.5, alpha: 1.0)
        topRow.addArrangedSubview(timeLabel)
        
        bubbleStack.addArrangedSubview(topRow)
        
        // Message Body
        let bodyLabel = NSTextField(wrappingLabelWithString: message.payload)
        bodyLabel.font = NSFont.systemFont(ofSize: 13.5, weight: .regular)
        bodyLabel.textColor = NSColor(white: 0.96, alpha: 1.0)
        bodyLabel.lineBreakMode = .byWordWrapping
        bodyLabel.isSelectable = true
        bubbleStack.addArrangedSubview(bodyLabel)
        
        // Footer: Message ID & Payload Byte Size
        let footerRow = NSStackView()
        footerRow.orientation = .horizontal
        footerRow.spacing = 6
        footerRow.alignment = .centerY
        
        let idLabel = NSTextField(labelWithString: "ID: \(String(message.message_id.prefix(12)))")
        idLabel.font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
        idLabel.textColor = NSColor(white: 0.38, alpha: 1.0)
        footerRow.addArrangedSubview(idLabel)
        
        let byteCount = message.payload.utf8.count
        let sizeLabel = NSTextField(labelWithString: "• \(byteCount) B")
        sizeLabel.font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
        sizeLabel.textColor = NSColor(white: 0.38, alpha: 1.0)
        footerRow.addArrangedSubview(sizeLabel)
        
        bubbleStack.addArrangedSubview(footerRow)
        
        // Row AutoLayout Constraints
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: row.topAnchor),
            bubble.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            bubble.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor, multiplier: 0.78),
            bubble.widthAnchor.constraint(greaterThanOrEqualToConstant: 240)
        ])
        
        if isOutgoing {
            bubble.trailingAnchor.constraint(equalTo: row.trailingAnchor).isActive = true
        } else {
            bubble.leadingAnchor.constraint(equalTo: row.leadingAnchor).isActive = true
        }
        
        // Insert newest at top
        messagesStackView.insertArrangedSubview(row, at: 0)
        row.widthAnchor.constraint(equalTo: messagesStackView.widthAnchor).isActive = true
    }
    
    private func updateDeliveryStatus(messageId: String, status: String) {
        if let label = messageDeliveryLabels[messageId] {
            label.stringValue = status
            label.textColor = NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1.0)
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
        addMessageBubble(localMsg, isOutgoing: true)
        
        BlePeripheralManager.shared.sendMessage(text: text, messageId: messageId) { [weak self] success, detail in
            DispatchQueue.main.async {
                self?.sendButton.isEnabled = true
                if success {
                    self?.sendStatusLabel.stringValue = "Delivered to Android (Ack 200)"
                    self?.sendStatusLabel.textColor = NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1.0)
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
        logEventCount += 1
        if !isLogVisible {
            toggleLogButton.title = "Logs (\(logEventCount))"
        }
        
        logTextView.textStorage?.append(NSAttributedString(
            string: line + "\n",
            attributes: [
                .foregroundColor: NSColor(red: 0.65, green: 0.75, blue: 0.85, alpha: 1.0),
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
        emptyStateContainer.isHidden = false
    }
    
    @objc private func clearLog() {
        logTextView.string = ""
        logEventCount = 0
        if !isLogVisible {
            toggleLogButton.title = "Show Logs"
        }
    }
}
