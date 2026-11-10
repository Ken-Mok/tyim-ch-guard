import AppKit
import Carbon
import CoreGraphics
import Foundation

// Read-only: no keyboard monitoring, permission requests, signals, or app control.
func numeric(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }

func explainWindow(_ window: [String: Any]) -> [String: Any]? {
    guard let bounds = window[kCGWindowBounds as String] as? [String: Any] else { return nil }
    let width = numeric(bounds["Width"]), height = numeric(bounds["Height"])
    let layer = Int(numeric(window[kCGWindowLayer as String]))
    // Include narrow pills and non-ChatGPT owners so we can diagnose exclusions.
    guard (10...80).contains(height), (10...1400).contains(width), layer > 0 else { return nil }
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    let hasTitle = !(window[kCGWindowName as String] as? String ?? "").isEmpty
    let pid = pid_t(numeric(window[kCGWindowOwnerPID as String]))
    var exclusions: [String] = []
    if owner != "ChatGPT" { exclusions.append("owner is not ChatGPT") }
    if layer != 20 { exclusions.append("layer is not 20") }
    if hasTitle { exclusions.append("window has a title") }
    if !(20...40).contains(height) { exclusions.append("height outside 20...40") }
    if !(80...900).contains(width) { exclusions.append("width outside 80...900") }
    return [
        "window_id": Int(numeric(window[kCGWindowNumber as String])),
        "owner": owner,
        "owner_pid": Int(pid),
        "owner_bundle_id": NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown",
        "layer": layer,
        "width": width,
        "height": height,
        "x": numeric(bounds["X"]),
        "y": numeric(bounds["Y"]),
        "has_title": hasTitle,
        "matches_current_guard": exclusions.isEmpty,
        "excluded_because": exclusions,
    ]
}

func inputSourceID() -> String {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "unknown" }
    return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
}

func sourceVersion(_ source: String) -> String {
    guard let expression = try? NSRegularExpression(pattern: #"let guardVersion = "([^"]+)""#),
          let match = expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
          let range = Range(match.range(at: 1), in: source) else { return "legacy or unavailable" }
    return String(source[range])
}

func diagnosticReport(windows: [[String: Any]], source: String, log: String,
                      inputSource: String) -> [String: Any] {
    [
        "diagnostic_version": "1",
        "read_only": true,
        "window_list_available": !windows.isEmpty,
        "on_screen_window_count": windows.count,
        "terminal_input_source": inputSource,
        "installed_source_version": sourceVersion(source),
        "small_floating_windows": windows.compactMap(explainWindow),
        "recent_guard_log": Array(log.split(separator: "\n").suffix(15)).map(String.init),
        "note": "No titles, candidate text, keystrokes, or screenshots are collected. Source/version and logs do not independently prove which executable is running.",
    ]
}

#if !DIAGNOSTIC_TESTS
let userDirectory = FileManager.default.homeDirectoryForCurrentUser
let sourceURL = userDirectory.appendingPathComponent("Library/Application Support/tyim-ch-guard/main.swift")
let logURL = userDirectory.appendingPathComponent("Library/Logs/tyim-ch-guard.log")
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                       kCGNullWindowID) as? [[String: Any]] ?? []
let report = diagnosticReport(windows: windows,
                              source: (try? String(contentsOf: sourceURL, encoding: .utf8)) ?? "",
                              log: (try? String(contentsOf: logURL, encoding: .utf8)) ?? "",
                              inputSource: inputSourceID())
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
#endif
