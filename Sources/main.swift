import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

let guardVersion = "1.1.1"
let chatGPTBundleID = "com.openai.codex"
let commitKeycodes: Set<Int64> = [41, 39, 44, 43, 47]

struct Candidate: Equatable {
    let id: CGWindowID
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

func isTYIM(_ sourceID: String) -> Bool {
    sourceID == "com.apple.inputmethod.TYIM"
        || sourceID.hasPrefix("com.apple.inputmethod.TYIM.")
}

struct Observation {
    let candidates: [Candidate]
    let sourceID: String
    let chatGPTIsFrontmost: Bool
    var ids: Set<CGWindowID> { Set(candidates.map(\.id)) }
    var tyim: Bool { isTYIM(sourceID) }
}

/// Pure policy: tests exercise timers and keyboard context without restarting an IME.
struct RecoveryPolicy {
    private struct Pending {
        let ids: Set<CGWindowID>
        let sourceID: String
        let deadline: TimeInterval
    }
    private struct Departure {
        var ids: Set<CGWindowID>
        let since: TimeInterval
    }
    private let startedAt: TimeInterval
    private var startupHandled = false
    private var lastObservation: Observation?
    private var observedAt: TimeInterval?
    private var pending: Pending?
    private var away: Departure?
    private var leftTYIM: Departure?
    private var lastClear: TimeInterval?

    init(now: TimeInterval) { startedAt = now }

    mutating func keyDown(now: TimeInterval, punctuation: Bool,
                          sourceID: String, chatGPTIsFrontmost: Bool) {
        // A later key may start a new composition in the same native window.
        pending = nil
        guard punctuation, chatGPTIsFrontmost, isTYIM(sourceID),
              let previous = lastObservation, previous.chatGPTIsFrontmost,
              previous.sourceID == sourceID, !previous.ids.isEmpty,
              let observedAt, now >= observedAt, now - observedAt <= 0.5 else { return }
        pending = Pending(ids: previous.ids, sourceID: sourceID, deadline: now + 0.2)
    }

    mutating func observe(_ current: Observation, now: TimeInterval) -> String? {
        let previous = lastObservation
        defer { lastObservation = current; observedAt = now }
        let ids = current.ids
        var reason: String?

        if let armed = pending {
            if !current.chatGPTIsFrontmost || current.sourceID != armed.sourceID {
                pending = nil
            } else if now >= armed.deadline {
                pending = nil
                if !ids.isDisjoint(with: armed.ids) { reason = "punctuation" }
            }
        }

        // Keep the departure timer across polls; only retain the original windows.
        if current.tyim || current.sourceID.isEmpty || ids.isEmpty {
            leftTYIM = nil
        } else {
            if previous?.tyim == true {
                let original = ids.intersection(previous?.ids ?? [])
                leftTYIM = original.isEmpty ? nil : Departure(ids: original, since: now)
            }
            if var departure = leftTYIM {
                departure.ids.formIntersection(ids)
                leftTYIM = departure.ids.isEmpty ? nil : departure
                if !departure.ids.isEmpty, now - departure.since >= 0.4 {
                    reason = reason ?? "left-tyim"
                }
            }
        }

        if current.chatGPTIsFrontmost || ids.isEmpty {
            away = nil
        } else {
            if var departure = away {
                departure.ids.formIntersection(ids)
                away = departure.ids.isEmpty ? Departure(ids: ids, since: now) : departure
            } else {
                away = Departure(ids: ids, since: now)
            }
            if let away, now - away.since >= 0.6 { reason = reason ?? "left-chatgpt" }
        }

        if ids.count >= 2 { reason = reason ?? "multiple" }

        if !startupHandled, now - startedAt >= 1.5 {
            startupHandled = true
            // A single active candidate at startup can be legitimate.
            if !ids.isEmpty, !current.sourceID.isEmpty,
               !current.chatGPTIsFrontmost || !current.tyim {
                reason = reason ?? "startup"
            }
        }

        // Window age or unchanged coordinates alone never prove a stale composition.
        guard !current.sourceID.isEmpty, let reason else { return nil }
        if let lastClear, now - lastClear < 2 { return nil }
        lastClear = now
        pending = nil
        away = nil
        leftTYIM = nil
        return reason
    }
}

func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }

func candidates() -> [Candidate] {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                            kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.compactMap { window in
        guard window[kCGWindowOwnerName as String] as? String == "ChatGPT",
              Int(number(window[kCGWindowLayer as String])) == 20,
              (window[kCGWindowName as String] as? String ?? "").isEmpty,
              let bounds = window[kCGWindowBounds as String] as? [String: Any] else { return nil }
        let width = number(bounds["Width"]), height = number(bounds["Height"])
        guard (20...40).contains(height), (80...900).contains(width) else { return nil }
        let id = CGWindowID(number(window[kCGWindowNumber as String]))
        guard id != 0 else { return nil }
        return Candidate(id: id, x: number(bounds["X"]), y: number(bounds["Y"]),
                         width: width, height: height)
    }
}

func currentInputSourceID() -> String {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
    return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
}

func frontmostIsChatGPT() -> Bool {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier == chatGPTBundleID
}

func log(_ message: String) {
    let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/tyim-ch-guard.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if FileManager.default.fileExists(atPath: url.path),
       let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
    } else {
        try? data.write(to: url)
    }
}

@discardableResult
func clearCandidates(reason: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    process.arguments = ["-TERM", "TYIM_Extension"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        log("clear-attempt reason=\(reason) status=\(process.terminationStatus)")
        return process.terminationStatus == 0
    } catch {
        log("clear failed \(error.localizedDescription)")
        return false
    }
}

func printStatus() {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                            kCGNullWindowID) as? [[String: Any]] ?? []
    let trusted = AXIsProcessTrusted()
    let status: [String: Any] = [
        "version": guardVersion,
        "accessibility_granted": trusted,
        "punctuation_permission": trusted ? "granted" : "needs_accessibility",
        "input_source": currentInputSourceID(),
        "chatgpt_frontmost": frontmostIsChatGPT(),
        "matching_candidate_count": candidates().count,
        "window_list_available": !windows.isEmpty,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]),
       let text = String(data: data, encoding: .utf8) { print(text) }
}

final class Guard {
    static let shared = Guard()
    private var policy = RecoveryPolicy(now: ProcessInfo.processInfo.systemUptime)
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var prompted = false
    private var retryTapAfter: TimeInterval = 0
    private var lastState = ""
    private var lastStateLoggedAt: TimeInterval = 0

    func run() {
        log("start version=\(guardVersion) pid=\(ProcessInfo.processInfo.processIdentifier)")
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.run()
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        ensureTap(now: now)
        let observation = Observation(candidates: candidates(), sourceID: currentInputSourceID(),
                                      chatGPTIsFrontmost: frontmostIsChatGPT())
        let listening = tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
        let state = "candidates=\(observation.candidates.count) frontmostChatGPT=\(observation.chatGPTIsFrontmost) tyim=\(observation.tyim) sourceKnown=\(!observation.sourceID.isEmpty) punctuationListener=\(listening)"
        if state != lastState || now - lastStateLoggedAt >= 60 {
            log("state \(state)")
            lastState = state
            lastStateLoggedAt = now
        }
        if let reason = policy.observe(observation, now: now) { clearCandidates(reason: reason) }
    }

    private func keyDown(_ event: CGEvent) {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let shortcut = !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
        policy.keyDown(now: ProcessInfo.processInfo.systemUptime,
                       punctuation: !shortcut && commitKeycodes.contains(code),
                       sourceID: currentInputSourceID(), chatGPTIsFrontmost: frontmostIsChatGPT())
    }

    private func ensureTap(now: TimeInterval) {
        let trusted = AXIsProcessTrusted()
        if let tap {
            if trusted, !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
                log("event tap re-enabled")
            }
            return
        }
        if !trusted {
            if !prompted {
                prompted = true
                let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
                log("accessibility not granted; punctuation recovery inactive")
            }
            return
        }
        guard now >= retryTapAfter else { return }
        retryTapAfter = now + 5
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                if type == .keyDown { Guard.shared.keyDown(event) }
                // Disabled taps are re-enabled by the next timer tick.
                return Unmanaged.passUnretained(event)
            }, userInfo: nil
        ) else { log("event tap create failed; retry in 5s"); return }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0) else {
            CFMachPortInvalidate(created)
            log("event tap run-loop source failed")
            return
        }
        tap = created
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        log("event tap listening")
    }
}

#if !GUARD_TESTS
if CommandLine.arguments.contains("--version") {
    print("tyim-ch-guard \(guardVersion)")
} else if CommandLine.arguments.contains("--status") {
    printStatus()
} else if CommandLine.arguments.contains("--once") {
    let found = candidates()
    log("once count=\(found.count)")
    if found.isEmpty {
        print("No matching candidate windows found. Use --status to inspect permissions and visibility.")
    } else if clearCandidates(reason: "once") {
        print("Requested TYIM_Extension restart for \(found.count) matching window(s).")
    } else {
        fputs("TYIM restart failed. Check the guard log.\n", stderr)
        exit(1)
    }
} else {
    Guard.shared.run()
}
#endif
