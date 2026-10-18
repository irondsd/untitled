import AppKit

struct EditorPreferences: Equatable {
    var opacity: Double = 0.48
    var backgroundBlackLevel: Double = 1
    var brightness: Double = 0.93
    var defaultFontSize: Double = 14
    /// Font family name; empty uses the default monospaced font.
    var fontFamily = ""
    var showsLineNumbers = true

    var backgroundColor: NSColor {
        NSColor(calibratedWhite: CGFloat(1 - backgroundBlackLevel), alpha: CGFloat(opacity))
    }
    static func fontSize(_ value: Double) -> Double {
        guard value.isFinite else { return 14 }
        return (min(36, max(10, value)) * 10).rounded() / 10
    }

    init() {}
    init(defaults: UserDefaults) {
        func number(_ key: String, fallback: Double, range: ClosedRange<Double>) -> Double {
            guard defaults.object(forKey: key) != nil else { return fallback }
            let value = defaults.double(forKey: key)
            return value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        opacity = number("opacity", fallback: opacity, range: 0...1)
        backgroundBlackLevel = number("backgroundBlackLevel", fallback: backgroundBlackLevel, range: 0.5...1)
        brightness = number("fontBrightness", fallback: brightness, range: 0.2...1)
        defaultFontSize = Self.fontSize(number("defaultFontSize", fallback: defaultFontSize, range: 10...36))
        fontFamily = defaults.string(forKey: "fontFamily") ?? fontFamily
        if defaults.object(forKey: "showsLineNumbers") != nil {
            showsLineNumbers = defaults.bool(forKey: "showsLineNumbers")
        }
    }
    func save(to defaults: UserDefaults) {
        defaults.set(opacity, forKey: "opacity")
        defaults.set(backgroundBlackLevel, forKey: "backgroundBlackLevel")
        defaults.set(brightness, forKey: "fontBrightness")
        defaults.set(defaultFontSize, forKey: "defaultFontSize")
        defaults.set(fontFamily, forKey: "fontFamily")
        defaults.set(showsLineNumbers, forKey: "showsLineNumbers")
    }
}

@MainActor
final class SettingsController: NSWindowController, NSTextFieldDelegate {
    private let opacitySlider = NSSlider(value: 48, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let blackLevelSlider = NSSlider(value: 100, minValue: 50, maxValue: 100, target: nil, action: nil)
    private let brightnessSlider = NSSlider(value: 93, minValue: 20, maxValue: 100, target: nil, action: nil)
    private let opacityValue = NSTextField(labelWithString: "")
    private let blackLevelValue = NSTextField(labelWithString: "")
    private let brightnessValue = NSTextField(labelWithString: "")
    private let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fontSizeField = NSTextField()
    private let fontSizeStepper = NSStepper()
    private let lineNumbersButton = NSButton(checkboxWithTitle: "Show line numbers", target: nil, action: nil)
    private var preferences: EditorPreferences
    var onChange: ((EditorPreferences) -> Void)?

    init(preferences: EditorPreferences) {
        self.preferences = preferences
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 345),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        let content = window.contentView!
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24)
        ])
        func row(_ title: String, controls: [NSView]) {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 13)
            label.widthAnchor.constraint(equalToConstant: 156).isActive = true
            let row = NSStackView(views: [label] + controls)
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12
            stack.addArrangedSubview(row)
        }
        for (slider, value, title) in [(opacitySlider, opacityValue, "Background opacity"),
                                       (blackLevelSlider, blackLevelValue, "Background black level"),
                                       (brightnessSlider, brightnessValue, "Font brightness")] {
            slider.target = self
            slider.action = #selector(sliderChanged)
            slider.isContinuous = true
            slider.setAccessibilityLabel(title)
            slider.widthAnchor.constraint(equalToConstant: 180).isActive = true
            value.alignment = .right
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            value.textColor = .secondaryLabelColor
            value.widthAnchor.constraint(equalToConstant: 40).isActive = true
            row(title, controls: [slider, value])
        }
        fontPopup.target = self
        fontPopup.action = #selector(fontFamilyChanged)
        fontPopup.setAccessibilityLabel("Font")
        fontPopup.widthAnchor.constraint(equalToConstant: 232).isActive = true
        buildFontMenu()
        row("Font", controls: [fontPopup])
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        fontSizeField.formatter = formatter
        fontSizeField.alignment = .right
        fontSizeField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        fontSizeField.delegate = self
        fontSizeField.target = self
        fontSizeField.action = #selector(fontSizeChanged)
        fontSizeField.setAccessibilityLabel("Default font size")
        fontSizeField.toolTip = "10.0–36.0 pt, in steps of 0.1"
        fontSizeField.widthAnchor.constraint(equalToConstant: 66).isActive = true
        fontSizeStepper.minValue = 10
        fontSizeStepper.maxValue = 36
        fontSizeStepper.increment = 0.1
        fontSizeStepper.valueWraps = false
        fontSizeStepper.target = self
        fontSizeStepper.action = #selector(fontSizeStepped)
        fontSizeStepper.setAccessibilityLabel("Adjust default font size")
        let points = NSTextField(labelWithString: "pt")
        points.textColor = .secondaryLabelColor
        row("Default font size", controls: [fontSizeField, fontSizeStepper, points])
        lineNumbersButton.target = self
        lineNumbersButton.action = #selector(lineNumbersChanged)
        row("", controls: [lineNumbersButton])
        let hint = NSTextField(labelWithString: "Changes apply immediately. ⌘0 resets to the default size.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)
        refresh(preferences)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh(_ preferences: EditorPreferences) {
        self.preferences = preferences
        opacitySlider.doubleValue = preferences.opacity * 100
        blackLevelSlider.doubleValue = preferences.backgroundBlackLevel * 100
        brightnessSlider.doubleValue = preferences.brightness * 100
        opacityValue.stringValue = "\(Int((preferences.opacity * 100).rounded()))%"
        blackLevelValue.stringValue = "\(Int((preferences.backgroundBlackLevel * 100).rounded()))%"
        brightnessValue.stringValue = "\(Int((preferences.brightness * 100).rounded()))%"
        selectFont(preferences.fontFamily)
        fontSizeField.doubleValue = preferences.defaultFontSize
        fontSizeStepper.doubleValue = preferences.defaultFontSize
        lineNumbersButton.state = preferences.showsLineNumbers ? .on : .off
    }
    @objc private func sliderChanged(_ sender: NSSlider) {
        if sender === opacitySlider { preferences.opacity = sender.doubleValue.rounded() / 100 }
        else if sender === blackLevelSlider { preferences.backgroundBlackLevel = sender.doubleValue.rounded() / 100 }
        else { preferences.brightness = sender.doubleValue.rounded() / 100 }
        changed()
    }
    /// Lists installed monospaced families, each in its own face, after the default font.
    private func buildFontMenu() {
        let defaultFamily = Theme.font(13).familyName ?? ""
        // The system monospaced fallback has a hidden family name; it is SF Mono.
        addFont("\(defaultFamily.hasPrefix(".") || defaultFamily.isEmpty ? "SF Mono" : defaultFamily) (default)", family: "")
        fontPopup.menu?.addItem(.separator())
        for family in Theme.monospacedFamilies() where family != defaultFamily { addFont(family, family: family) }
    }
    private func addFont(_ title: String, family: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.representedObject = family
        item.attributedTitle = NSAttributedString(string: title, attributes: [.font: Theme.font(13, family: family)])
        fontPopup.menu?.addItem(item)
    }
    private func selectFont(_ family: String) {
        func item(_ family: String) -> NSMenuItem? {
            fontPopup.itemArray.first { $0.representedObject as? String == family }
        }
        let target = family == Theme.font(13).familyName ? "" : family
        // Keep a saved family visible after it is uninstalled; the editor falls back to the default.
        if item(target) == nil { addFont("\(target) (not installed)", family: target) }
        fontPopup.select(item(target))
    }
    @objc private func fontFamilyChanged(_ sender: NSPopUpButton) {
        preferences.fontFamily = sender.selectedItem?.representedObject as? String ?? ""
        changed()
    }
    @objc private func fontSizeChanged(_ sender: NSTextField) {
        setFontSize(sender.doubleValue)
    }
    @objc private func fontSizeStepped(_ sender: NSStepper) {
        setFontSize(sender.doubleValue)
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === fontSizeField else { return }
        setFontSize(fontSizeField.doubleValue)
    }
    private func setFontSize(_ value: Double) {
        preferences.defaultFontSize = EditorPreferences.fontSize(value)
        changed()
    }
    @objc private func lineNumbersChanged(_ sender: NSButton) {
        preferences.showsLineNumbers = sender.state == .on
        changed()
    }
    private func changed() { refresh(preferences); onChange?(preferences) }
}
