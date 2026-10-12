import AppKit
import ApplicationServices
import Foundation

let bundleID = "com.agraabhi.oshodiscourses.translation-local"
let arguments = Array(CommandLine.arguments.dropFirst())
enum ControlError: Error { case permission, ambiguousApp, ambiguousElement(Int), disabled, unsupportedAction, failed(AXError) }

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

do {
    guard AXIsProcessTrusted() else { throw ControlError.permission }
    let applications = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleID }
    guard applications.count == 1, let application = applications.first else { throw ControlError.ambiguousApp }
    let root = AXUIElementCreateApplication(application.processIdentifier)
    var seen: [CFHashCode: [AXUIElement]] = [:]
    var seenCount = 0
    var elements: [(AXUIElement, [String: String])] = []
    func visit(_ element: AXUIElement, depth: Int) {
        let hash = CFHash(element)
        guard depth < 35, seenCount < 5_000,
              !(seen[hash] ?? []).contains(where: { CFEqual($0, element) }) else { return }
        seen[hash, default: []].append(element)
        seenCount += 1
        let role = attribute(element, kAXRoleAttribute) as? String
        guard role != "AXMenuBar", role != "AXApplication" else { return }
        var item: [String: String] = [:]
        for (key, name) in [("role", kAXRoleAttribute), ("title", kAXTitleAttribute),
                            ("description", kAXDescriptionAttribute), ("id", kAXIdentifierAttribute),
                            ("value", kAXValueAttribute)] {
            if let text = attribute(element, name) as? String { item[key] = text }
        }
        elements.append((element, item))
        if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
            for child in children { visit(child, depth: depth + 1) }
        }
    }
    for window in attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
        visit(window, depth: 0)
    }
    for child in attribute(root, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if attribute(child, kAXRoleAttribute) as? String != "AXMenuBar" { visit(child, depth: 0) }
    }
    if ["press", "show-menu"].contains(arguments.first ?? ""), arguments.count == 2 {
        let query = arguments[1]
        let actionable: Set<String> = ["AXButton", "AXPopUpButton", "AXMenuItem", "AXRadioButton", "AXCheckBox"]
        let matches = elements.filter { _, item in
            actionable.contains(item["role"] ?? "")
                && (item["id"] == query || item["title"] == query || item["description"] == query)
        }
        guard matches.count == 1, let match = matches.first else { throw ControlError.ambiguousElement(matches.count) }
        if let enabled = attribute(match.0, kAXEnabledAttribute) as? Bool, !enabled { throw ControlError.disabled }
        var actions: CFArray?
        let action = arguments[0] == "show-menu" ? "AXShowMenu" : kAXPressAction
        guard AXUIElementCopyActionNames(match.0, &actions) == .success,
              (actions as? [String] ?? []).contains(action) else { throw ControlError.unsupportedAction }
        let result = AXUIElementPerformAction(match.0, action as CFString)
        guard result == .success else { throw ControlError.failed(result) }
        print("Pressed \(query) in \(bundleID), PID \(application.processIdentifier)")
    } else {
        let data = try JSONSerialization.data(withJSONObject: elements.map(\.1), options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
} catch {
    fputs("Native test control refused: \(error)\n", stderr)
    exit(1)
}
