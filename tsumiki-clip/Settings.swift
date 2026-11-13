// 設定の窓：キー・残す期間と件数・記録しないアプリ・許可・起動・全部消す。
import AppKit
import ServiceManagement

final class SettingsWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onKeysChanged: (() -> Void)?
    var onRetentionChanged: (() -> Void)?
    var onClearHistory: (() -> Void)?
    private var fields: [UInt32: ShortcutField] = [:]
    private var warns: [UInt32: NSImageView] = [:]
    private let keep = NSPopUpButton()
    private let limit = NSPopUpButton()
    private let table = NSTableView()
    private let login = NSSwitch()
    private let axMark = NSImageView()
    private let pbMark = NSImageView()
    static let keepChoices: [(String, Int)] = [("1日", 1), ("1週間", 7), ("30日", 30), ("1年", 365), ("ずっと", 0)]
    static let limitChoices: [(String, Int)] = [("200件", 200), ("1000件", 1000), ("5000件", 5000), ("上限なし", 0)]

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "設定"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        w.contentView = makeContent()
        w.setContentSize(w.contentView!.fittingSize)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var headers: [NSView] = []
    private func header(_ sym: String, _ text: String) -> NSView {
        let i = NSImageView(image: NSImage(systemSymbolName: sym, accessibilityDescription: text)!)
        i.contentTintColor = .secondaryLabelColor
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12, weight: .semibold); l.textColor = .secondaryLabelColor
        let s = NSStackView(views: [i, l]); s.spacing = 6
        headers.append(s)
        return s
    }

    private func rowView(_ sym: String, _ title: String, _ trailing: [NSView]) -> NSStackView {
        let i = NSImageView(image: NSImage(systemSymbolName: sym, accessibilityDescription: nil)!)
        i.contentTintColor = Palette.accent
        i.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        i.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let l = NSTextField(labelWithString: title); l.font = .systemFont(ofSize: 13)
        let sp = NSView(); sp.setContentHuggingPriority(.init(1), for: .horizontal)
        let s = NSStackView(views: [i, l, sp] + trailing); s.spacing = 10
        return s
    }

    func makeContent() -> NSView {
        var rows: [NSView] = [header("keyboard", "キー")]
        for a in Shortcuts.actions {
            let f = ShortcutField(id: a.id)
            f.onChange = { [weak self] c in
                Shortcuts.set(a.id, c); self?.onKeysChanged?(); self?.refresh()
            }
            fields[a.id] = f
            let warn = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "使用中")!)
            warn.contentTintColor = .systemOrange
            warn.toolTip = "他のアプリが使っているキー＝別のキーにしてください"
            warns[a.id] = warn
            rows.append(rowView(a.symbol, a.name, [warn, f]))
        }

        rows.append(header("clock.arrow.circlepath", "残す"))
        for (t, _) in SettingsWindow.keepChoices { keep.addItem(withTitle: t) }
        keep.target = self; keep.action = #selector(keepChanged)
        rows.append(rowView("calendar", "期間", [keep]))
        for (t, _) in SettingsWindow.limitChoices { limit.addItem(withTitle: t) }
        limit.target = self; limit.action = #selector(limitChanged)
        rows.append(rowView("square.stack", "件数", [limit]))
        let clear = NSButton(title: "履歴を全部消す", target: self, action: #selector(clearAll))
        clear.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil); clear.imagePosition = .imageLeading
        clear.contentTintColor = .systemRed
        rows.append(clear)

        rows.append(header("eye.slash", "記録しないアプリ"))
        let col = NSTableColumn(identifier: .init("app")); col.width = 340
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 26
        table.dataSource = self; table.delegate = self
        table.style = .plain
        let sc = NSScrollView(); sc.documentView = table; sc.hasVerticalScroller = true; sc.borderType = .bezelBorder
        sc.heightAnchor.constraint(equalToConstant: 150).isActive = true
        sc.widthAnchor.constraint(equalToConstant: 376).isActive = true
        rows.append(sc)
        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "アプリを足す")!, target: self, action: #selector(addApp))
        let del = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "外す")!, target: self, action: #selector(removeApp))
        for b in [add, del] { b.bezelStyle = .smallSquare }
        add.toolTip = "アプリを足す"; del.toolTip = "選んだアプリを外す"
        let pm = NSStackView(views: [add, del]); pm.spacing = 0
        rows.append(pm)

        rows.append(header("hand.raised", "許可"))
        let axOpen = NSButton(title: "開く", target: self, action: #selector(openAX)); axOpen.bezelStyle = .rounded
        axOpen.toolTip = "直接貼る・順番に貼るに要る"
        rows.append(rowView("accessibility", "アクセシビリティ", [axMark, axOpen]))
        let pbOpen = NSButton(title: "開く", target: self, action: #selector(openPB)); pbOpen.bezelStyle = .rounded
        pbOpen.toolTip = "コピーを読むのに要る（macOS 15.4 以降）"
        rows.append(rowView("doc.on.clipboard", "貼り付け", [pbMark, pbOpen]))

        rows.append(header("gearshape", "起動"))
        login.target = self; login.action = #selector(loginChanged)
        rows.append(rowView("power", "ログイン時に起動", [login]))

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        for v in rows where v is NSStackView && (v as! NSStackView).arrangedSubviews.count > 2 {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44).isActive = true
        }
        for (i, v) in rows.enumerated() where i > 0 && headers.contains(where: { $0 === v }) {
            stack.setCustomSpacing(22, after: rows[i - 1])
        }
        refresh()
        return stack
    }

    func refresh() {
        for a in Shortcuts.actions {
            fields[a.id]?.refresh()
            warns[a.id]?.isHidden = !HotKeys.failed.contains(a.id)
        }
        keep.selectItem(at: SettingsWindow.keepChoices.firstIndex { $0.1 == Prefs.keepDays } ?? 2)
        limit.selectItem(at: SettingsWindow.limitChoices.firstIndex { $0.1 == Prefs.maxCount } ?? 1)
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let ok = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "許可あり")
        let ng = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "許可が要る")
        let ax = Paster.trusted(prompt: false)
        axMark.image = ax ? ok : ng; axMark.contentTintColor = ax ? .systemGreen : .systemOrange
        let pb = PasteboardAccess.allowed
        pbMark.image = pb ? ok : ng; pbMark.contentTintColor = pb ? .systemGreen : .systemOrange
        table.reloadData()
    }

    func show() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func keepChanged() { Prefs.keepDays = SettingsWindow.keepChoices[keep.indexOfSelectedItem].1; onRetentionChanged?() }
    @objc private func limitChanged() { Prefs.maxCount = SettingsWindow.limitChoices[limit.indexOfSelectedItem].1; onRetentionChanged?() }
    @objc private func clearAll() { onClearHistory?() }
    @objc private func openAX() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    @objc private func openPB() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")!) }

    @objc private func loginChanged() {
        let svc = SMAppService.mainApp
        do {
            if login.state == .on { try svc.register() } else { try svc.unregister() }
        } catch {
            if svc.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        }
        refresh()
    }

    @objc private func addApp() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowsMultipleSelection = true
        guard p.runModal() == .OK else { return }
        var list = Prefs.ignored
        for u in p.urls { if let id = Bundle(url: u)?.bundleIdentifier, !list.contains(id) { list.append(id) } }
        Prefs.ignored = list
        refresh()
    }

    @objc private func removeApp() {
        let r = table.selectedRow
        let list = SettingsWindow.visibleIgnored
        guard list.indices.contains(r) else { NSSound.beep(); return }
        Prefs.ignored.removeAll { $0 == list[r] }
        refresh()
    }

    /// 一覧に出すもの：入っているアプリを先に、入っていないもの（既定の候補）は後ろに
    static var visibleIgnored: [String] {
        let all = Prefs.ignored
        let installed = all.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        return installed + all.filter { !installed.contains($0) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { SettingsWindow.visibleIgnored.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = SettingsWindow.visibleIgnored[row]
        let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        let icon = NSImageView(image: u.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)!)
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let name = u.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
        let l = NSTextField(labelWithString: name)
        l.font = .systemFont(ofSize: 13)
        l.textColor = u == nil ? .tertiaryLabelColor : .labelColor
        l.toolTip = u == nil ? "\(id)（この Mac に無い）" : id
        let s = NSStackView(views: [icon, l]); s.spacing = 8
        return s
    }

    func windowWillClose(_ n: Notification) { fields.values.forEach { $0.stop() } }
}

/// macOS 15.4 以降の「貼り付けの許可」（アプリがコピーを読むときに聞かれる）
enum PasteboardAccess {
    static var allowed: Bool {
        if #available(macOS 15.4, *) { return NSPasteboard.general.accessBehavior != .alwaysDeny }
        return true
    }
    static var state: String {
        if #available(macOS 15.4, *) {
            switch NSPasteboard.general.accessBehavior {
            case .alwaysAllow: return "常に許可"
            case .alwaysDeny: return "許可しない"
            case .ask: return "毎回聞く"
            default: return "既定"
            }
        }
        return "常に許可"
    }
}
