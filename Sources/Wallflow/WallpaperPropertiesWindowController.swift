import AppKit

final class WallpaperPropertiesWindowController: NSWindowController {
    private final class ActionTarget: NSObject {
        let handler: (Any?) -> Void

        init(handler: @escaping (Any?) -> Void) {
            self.handler = handler
        }

        @objc func invoke(_ sender: Any?) {
            handler(sender)
        }
    }

    private var actionTargets: [ActionTarget] = []
    private var notificationTokens: [NSObjectProtocol] = []
    private let onChange: (String, JSONValue) -> Void
    private let onReset: () -> Void

    init(
        title: String,
        properties: JSONValue,
        onChange: @escaping (String, JSONValue) -> Void,
        onReset: @escaping () -> Void
    ) {
        self.onChange = onChange
        self.onReset = onReset

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(title) Properties"
        window.minSize = NSSize(width: 440, height: 320)
        super.init(window: window)
        window.contentView = makeContentView(properties: properties)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
    }

    private func makeContentView(properties: JSONValue) -> NSView {
        let contentView = NSView()
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10

        let sortedProperties = (properties.objectValue ?? [:]).sorted { left, right in
            let leftOrder = left.value.objectValue?["order"]?.numberValue ?? .greatestFiniteMagnitude
            let rightOrder = right.value.objectValue?["order"]?.numberValue ?? .greatestFiniteMagnitude
            if leftOrder == rightOrder { return left.key < right.key }
            return leftOrder < rightOrder
        }
        for (key, definition) in sortedProperties {
            stack.addArrangedSubview(makeRow(key: key, definition: definition))
        }

        documentView.addSubview(stack)
        scrollView.documentView = documentView

        let resetButton = NSButton(title: "Reset Defaults", target: nil, action: nil)
        resetButton.bezelStyle = .rounded
        let resetTarget = ActionTarget { [weak self] _ in self?.onReset() }
        resetButton.target = resetTarget
        resetButton.action = #selector(ActionTarget.invoke(_:))
        actionTargets.append(resetTarget)

        contentView.addSubview(scrollView)
        contentView.addSubview(resetButton)
        resetButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: resetButton.topAnchor, constant: -12),
            resetButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            resetButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),

            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -4)
        ])
        return contentView
    }

    private func makeRow(key: String, definition: JSONValue) -> NSView {
        let values = definition.objectValue ?? [:]
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false

        let rawTitle = values["text"]?.stringValue
        let title = rawTitle?.hasPrefix("ui_") == false ? rawTitle ?? key : key
        let label = NSTextField(labelWithString: title)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = key
        label.widthAnchor.constraint(equalToConstant: 170).isActive = true

        let control = makeControl(key: key, values: values)
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(label)
        row.addArrangedSubview(control)
        row.widthAnchor.constraint(greaterThanOrEqualToConstant: 440).isActive = true
        return row
    }

    private func makeControl(key: String, values: [String: JSONValue]) -> NSView {
        let type = values["type"]?.stringValue?.lowercased() ?? "textinput"
        let value = values["value"] ?? .null
        switch type {
        case "bool", "boolean":
            return makeCheckbox(key: key, value: value.boolValue ?? false)
        case "slider":
            return makeSlider(key: key, values: values)
        case "color":
            return makeColorWell(key: key, value: value.stringValue ?? "1 1 1")
        case "combo":
            return makePopup(key: key, values: values)
        case "file":
            return makePathPicker(key: key, value: value.stringValue ?? "", directories: false)
        case "directory":
            return makePathPicker(key: key, value: value.stringValue ?? "", directories: true)
        default:
            return makeTextField(key: key, value: value.stringValue ?? "")
        }
    }

    private func makeCheckbox(key: String, value: Bool) -> NSView {
        let button = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        button.state = value ? .on : .off
        let target = ActionTarget { [weak self, weak button] _ in
            self?.onChange(key, .bool(button?.state == .on))
        }
        button.target = target
        button.action = #selector(ActionTarget.invoke(_:))
        actionTargets.append(target)
        return button
    }

    private func makeSlider(key: String, values: [String: JSONValue]) -> NSView {
        let container = NSStackView()
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = 8

        let minimum = values["min"]?.numberValue ?? 0
        let maximum = values["max"]?.numberValue ?? 100
        let current = values["value"]?.numberValue ?? minimum
        let slider = NSSlider(value: current, minValue: minimum, maxValue: maximum, target: nil, action: nil)
        slider.isContinuous = true
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true

        let valueLabel = NSTextField(labelWithString: formattedNumber(current))
        valueLabel.alignment = .right
        valueLabel.widthAnchor.constraint(equalToConstant: 56).isActive = true

        let target = ActionTarget { [weak self, weak slider, weak valueLabel] _ in
            guard let slider else { return }
            valueLabel?.stringValue = self?.formattedNumber(slider.doubleValue) ?? ""
            self?.onChange(key, .number(slider.doubleValue))
        }
        slider.target = target
        slider.action = #selector(ActionTarget.invoke(_:))
        actionTargets.append(target)
        container.addArrangedSubview(slider)
        container.addArrangedSubview(valueLabel)
        return container
    }

    private func makeColorWell(key: String, value: String) -> NSView {
        let well = NSColorWell()
        well.color = color(from: value)
        well.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let target = ActionTarget { [weak self, weak well] _ in
            guard let color = well?.color.usingColorSpace(.deviceRGB) else { return }
            let value = String(
                format: "%.4f %.4f %.4f",
                color.redComponent,
                color.greenComponent,
                color.blueComponent
            )
            self?.onChange(key, .string(value))
        }
        well.target = target
        well.action = #selector(ActionTarget.invoke(_:))
        actionTargets.append(target)
        return well
    }

    private func makePopup(key: String, values: [String: JSONValue]) -> NSView {
        let popup = NSPopUpButton()
        let options = values["options"]?.arrayValue ?? []
        let optionValues: [JSONValue] = options.compactMap { option in
            let object = option.objectValue ?? [:]
            let label = object["label"]?.stringValue
                ?? object["text"]?.stringValue
                ?? object["value"]?.stringValue
                ?? "Option"
            popup.addItem(withTitle: label.hasPrefix("ui_") ? label.dropFirst(3).description : label)
            return object["value"] ?? .string(label)
        }

        let current = values["value"] ?? .null
        if let index = optionValues.firstIndex(of: current) {
            popup.selectItem(at: index)
        }
        let target = ActionTarget { [weak self, weak popup] _ in
            guard let popup, optionValues.indices.contains(popup.indexOfSelectedItem) else { return }
            self?.onChange(key, optionValues[popup.indexOfSelectedItem])
        }
        popup.target = target
        popup.action = #selector(ActionTarget.invoke(_:))
        actionTargets.append(target)
        popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        return popup
    }

    private func makeTextField(key: String, value: String) -> NSView {
        let field = NSTextField(string: value)
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        let target = ActionTarget { [weak self, weak field] _ in
            self?.onChange(key, .string(field?.stringValue ?? ""))
        }
        field.target = target
        field.action = #selector(ActionTarget.invoke(_:))
        actionTargets.append(target)
        let token = NotificationCenter.default.addObserver(
            forName: NSControl.textDidEndEditingNotification,
            object: field,
            queue: .main
        ) { [weak self, weak field] _ in
            self?.onChange(key, .string(field?.stringValue ?? ""))
        }
        notificationTokens.append(token)
        return field
    }

    private func makePathPicker(
        key: String,
        value: String,
        directories: Bool
    ) -> NSView {
        let container = NSStackView()
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = 8

        let valueLabel = NSTextField(labelWithString: value.isEmpty ? "None" : value)
        valueLabel.lineBreakMode = .byTruncatingMiddle
        valueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true

        let button = NSButton(title: "Choose...", target: nil, action: nil)
        button.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Choose")
        button.imagePosition = .imageLeading
        let target = ActionTarget { [weak self, weak valueLabel] _ in
            let panel = NSOpenPanel()
            panel.canChooseDirectories = directories
            panel.canChooseFiles = !directories
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            valueLabel?.stringValue = url.path
            self?.onChange(key, .string(url.path))
        }
        button.target = target
        button.action = #selector(ActionTarget.invoke(_:))
        actionTargets.append(target)

        container.addArrangedSubview(valueLabel)
        container.addArrangedSubview(button)
        return container
    }

    private func color(from wallpaperValue: String) -> NSColor {
        let components = wallpaperValue
            .split(separator: " ")
            .compactMap { Double($0) }
        guard components.count >= 3 else { return .white }
        return NSColor(
            calibratedRed: components[0],
            green: components[1],
            blue: components[2],
            alpha: 1
        )
    }

    private func formattedNumber(_ value: Double) -> String {
        abs(value.rounded() - value) < 0.0001
            ? String(Int(value.rounded()))
            : String(format: "%.2f", value)
    }
}
