#!/usr/bin/env swift
//
// Dumps the accessibility tree of a running app's windows as JSON, so layout and
// state can be checked without screenshots: every element's role, title, value,
// enabled state and frame (in screen points), nested as the system exposes it.
//
// Usage:
//   swift scripts/ui-dump.swift <pid> [--depth N] [--window N]
//   swift scripts/ui-dump.swift --bundle studio.anguria.obolo
//
// Requires Accessibility permission for the terminal (System Settings > Privacy &
// Security > Accessibility). Read-only: it never clicks, types or focuses anything.
//
// Typical checks:
//   - clipping: an element frame that extends past its window frame
//   - disabled/enabled controls, toggle values, picker selections
//   - truncation: a static text whose value is longer than its frame can show
//   - diffing two dumps before and after a change

import AppKit
import ApplicationServices
import Foundation

struct Options {
    var pid: pid_t?
    var bundleID: String?
    var maxDepth = 12
    var windowIndex: Int?
}

func parse() -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--bundle": options.bundleID = args.isEmpty ? nil : args.removeFirst()
        case "--depth": options.maxDepth = Int(args.isEmpty ? "" : args.removeFirst()) ?? 12
        case "--window": options.windowIndex = Int(args.isEmpty ? "" : args.removeFirst())
        default: options.pid = pid_t(arg)
        }
    }
    return options
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

let options = parse()

guard AXIsProcessTrusted() else {
    fail("Accessibility permission is missing. Allow your terminal in System Settings > Privacy & Security > Accessibility.")
}

var pid: pid_t
if let explicit = options.pid {
    pid = explicit
} else if let bundleID = options.bundleID {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    guard let app = apps.first else { fail("No running app with bundle id \(bundleID).") }
    if apps.count > 1 {
        FileHandle.standardError.write("warning: \(apps.count) processes match; using pid \(app.processIdentifier)\n".data(using: .utf8)!)
    }
    pid = app.processIdentifier
} else {
    fail("Pass a pid or --bundle <id>.")
}

// MARK: - Attribute helpers

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return result == .success ? value : nil
}

func string(_ element: AXUIElement, _ name: String) -> String? {
    guard let value = attribute(element, name) else { return nil }
    if let text = value as? String { return text }
    if let number = value as? NSNumber { return number.stringValue }
    if let url = value as? URL { return url.absoluteString }
    if let attributed = value as? NSAttributedString { return attributed.string }
    return nil
}

func bool(_ element: AXUIElement, _ name: String) -> Bool? {
    (attribute(element, name) as? NSNumber)?.boolValue
}

func frame(_ element: AXUIElement) -> [String: Double]? {
    guard let positionValue = attribute(element, kAXPositionAttribute),
          let sizeValue = attribute(element, kAXSizeAttribute) else { return nil }
    var position = CGPoint.zero
    var size = CGSize.zero
    // swiftlint:disable force_cast
    guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
          AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
    // swiftlint:enable force_cast
    return ["x": position.x, "y": position.y, "w": size.width, "h": size.height]
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

// MARK: - Tree

func describe(_ element: AXUIElement, depth: Int) -> [String: Any] {
    var node: [String: Any] = [:]
    node["role"] = string(element, kAXRoleAttribute) ?? "?"
    if let subrole = string(element, kAXSubroleAttribute) { node["subrole"] = subrole }
    if let title = string(element, kAXTitleAttribute), !title.isEmpty { node["title"] = title }
    if let value = string(element, kAXValueAttribute), !value.isEmpty { node["value"] = value }
    if let description = string(element, kAXDescriptionAttribute), !description.isEmpty { node["description"] = description }
    if let help = string(element, kAXHelpAttribute), !help.isEmpty { node["help"] = help }
    if let identifier = string(element, kAXIdentifierAttribute), !identifier.isEmpty { node["id"] = identifier }
    if let enabled = bool(element, kAXEnabledAttribute) { node["enabled"] = enabled }
    if let focused = bool(element, kAXFocusedAttribute), focused { node["focused"] = true }
    if let selected = bool(element, kAXSelectedAttribute), selected { node["selected"] = true }
    if let frame = frame(element) { node["frame"] = frame }

    if depth < options.maxDepth {
        let kids = children(element).map { describe($0, depth: depth + 1) }
        if !kids.isEmpty { node["children"] = kids }
    } else if !children(element).isEmpty {
        node["children"] = "…"
    }
    return node
}

let app = AXUIElementCreateApplication(pid)
var windows = (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
if let index = options.windowIndex {
    guard windows.indices.contains(index) else { fail("No window at index \(index); \(windows.count) window(s).") }
    windows = [windows[index]]
}

let output: [String: Any] = [
    "pid": Int(pid),
    "app": string(app, kAXTitleAttribute) ?? "",
    "windows": windows.map { describe($0, depth: 0) },
]

let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write("\n".data(using: .utf8)!)
