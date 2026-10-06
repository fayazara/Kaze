import AppKit

/// The menu bar item: shows status at a glance (red while listening, dimmed
/// when the shortcut isn't active) and a menu rebuilt each time it opens.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let app: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    init(app: AppModel) {
        self.app = app
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        updateIcon()
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = app.dictation.phase
            _ = app.permissions.accessibility
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateIcon()
                self?.observe()
            }
        }
    }

    private func updateIcon() {
        guard let button = item.button else { return }
        let image: NSImage?
        switch app.dictation.phase {
        case .listening:
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
                .applying(.init(pointSize: 14, weight: .semibold))
            image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Kaze is listening")?
                .withSymbolConfiguration(config)
        case .transcribing, .formatting:
            image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Kaze is transcribing")
            image?.isTemplate = true
        default:
            let icon = NSImage(named: "kaze-icon")?.copy() as? NSImage
            icon?.size = NSSize(width: 18, height: 18)
            icon?.isTemplate = true
            image = icon
        }
        button.image = image
        button.alphaValue = app.isShortcutActive || app.dictation.phase != .idle ? 1 : 0.5
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let prefs = app.preferences

        menu.addItem(statusItem())
        menu.addItem(.separator())

        let dictate = NSMenuItem(title: app.dictation.phase.isListening ? "Stop Dictation" : "Start Dictation",
                                 action: #selector(toggleDictation), keyEquivalent: "")
        dictate.target = self
        dictate.isEnabled = app.models.state(of: prefs.speechModel).isInstalled
        menu.addItem(dictate)

        let recent = app.history.items.prefix(5)
        if !recent.isEmpty {
            let header = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(.separator())
            menu.addItem(header)
            for entry in recent {
                let title = entry.text.count > 48 ? String(entry.text.prefix(46)) + "…" : entry.text
                let row = NSMenuItem(title: title, action: #selector(copyRecent(_:)), keyEquivalent: "")
                row.target = self
                row.representedObject = entry.text
                row.toolTip = "Click to copy"
                menu.addItem(row)
            }
        }

        menu.addItem(.separator())
        menu.addItem(modelMenu())
        let cleanUp = NSMenuItem(title: "Clean Up", action: #selector(toggleCleanUp), keyEquivalent: "")
        cleanUp.target = self
        cleanUp.state = prefs.formattingEnabled ? .on : .off
        cleanUp.isEnabled = app.models.formatterState.isInstalled
        menu.addItem(cleanUp)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        if app.updater.isAvailable {
            let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            updates.target = self
            menu.addItem(updates)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Kaze", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func statusItem() -> NSMenuItem {
        let prefs = app.preferences
        let title: String
        let action: Selector?
        if !app.permissions.microphone {
            title = "Allow microphone access…"
            action = #selector(openGeneral)
        } else if !app.isShortcutActive {
            title = "Allow Accessibility to use the shortcut…"
            action = #selector(openGeneral)
        } else if !app.models.state(of: prefs.speechModel).isInstalled {
            title = "Download \(prefs.speechModel.title)…"
            action = #selector(openModels)
        } else {
            title = "Hold \(prefs.shortcut.displayName) to dictate"
            action = nil
        }
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = action != nil
        if action != nil {
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        }
        return item
    }

    private func modelMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Speech Model", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for model in SpeechModel.pickerOrder where app.models.state(of: model).isInstalled {
            let row = NSMenuItem(title: model.title, action: #selector(chooseModel(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = model.rawValue
            row.state = app.preferences.speechModel == model ? .on : .off
            submenu.addItem(row)
        }
        submenu.addItem(.separator())
        let manage = NSMenuItem(title: "Manage Models…", action: #selector(openModels), keyEquivalent: "")
        manage.target = self
        submenu.addItem(manage)
        parent.submenu = submenu
        return parent
    }

    @objc private func toggleDictation() { app.dictation.toggleFromUI() }
    @objc private func toggleCleanUp() { app.preferences.formattingEnabled.toggle() }
    @objc private func openSettings() { WindowManager.shared.showSettings() }
    @objc private func openGeneral() { WindowManager.shared.showSettings(.general) }
    @objc private func openModels() { WindowManager.shared.showSettings(.models) }
    @objc private func checkForUpdates() { app.updater.checkForUpdates() }

    @objc private func chooseModel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let model = SpeechModel(rawValue: raw) else { return }
        app.selectSpeechModel(model)
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
