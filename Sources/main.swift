import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

let guardVersion = "1.3.0"
let chatGPTBundleID = "com.openai.codex"
let supportedOwners = ["ChatGPT": chatGPTBundleID, "Microsoft Teams": "com.microsoft.teams2"]
let commitKeycodes: Set<Int64> = [41, 39, 44, 43, 47]

struct Candidate: Equatable {
    let id: CGWindowID
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let ownerBundleID: String

    init(id: CGWindowID, x: Double, y: Double, width: Double, height: Double,
         ownerBundleID: String = chatGPTBundleID) {
        self.id = id; self.x = x; self.y = y
        self.width = width; self.height = height; self.ownerBundleID = ownerBundleID
    }
}

// Explicit Apple namespaces: no third-party or non-Chinese input methods.
let supportedInputMethods = [
    "com.apple.inputmethod.TCIM": "TCIM_Extension",
    "com.apple.inputmethod.TYIM": "TYIM_Extension",
    "com.apple.inputmethod.SCIM": "SCIM_Extension",
]

func inputMethodProcess(_ sourceID: String) -> String? {
    supportedInputMethods.first { sourceID == $0.key || sourceID.hasPrefix($0.key + ".") }?.value
}

func isSupportedIME(_ sourceID: String) -> Bool { inputMethodProcess(sourceID) != nil }

// Window metadata does not identify the originating IME. Never choose between
// multiple running engines based on the current source: the bar may be older.
func restartTarget(sourceID: String, running: Set<String>) -> String? {
    let supported = running.intersection(supportedInputMethods.values)
    guard supported.count == 1, let sole = supported.first else { return nil }
    if let active = inputMethodProcess(sourceID) {
        return active == sole ? sole : nil
    }
    guard sourceID.hasPrefix("com.apple.keylayout.") else { return nil }
    return sole
}

struct Observation {
    let candidates: [Candidate]
    let sourceID: String
    let ownerIsFrontmost: Bool
    var ids: Set<CGWindowID> { Set(candidates.map(\.id)) }
    var supportedIME: Bool { isSupportedIME(sourceID) }
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
    private var leftIME: Departure?
    private var lastClear: TimeInterval?

    init(now: TimeInterval) { startedAt = now }

    mutating func keyDown(now: TimeInterval, punctuation: Bool,
                          sourceID: String, ownerIsFrontmost: Bool) {
        // A later key may start a new composition in the same native window.
        pending = nil
        guard punctuation, ownerIsFrontmost, isSupportedIME(sourceID),
              let previous = lastObservation, previous.ownerIsFrontmost,
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
            if !current.ownerIsFrontmost || current.sourceID != armed.sourceID {
                pending = nil
            } else if now >= armed.deadline {
                pending = nil
                if !ids.isDisjoint(with: armed.ids) { reason = "punctuation" }
            }
        }

        // Keep the departure timer across polls; only retain the original windows.
        if current.supportedIME || current.sourceID.isEmpty || ids.isEmpty {
            leftIME = nil
        } else {
            if previous?.supportedIME == true {
                let original = ids.intersection(previous?.ids ?? [])
                leftIME = original.isEmpty ? nil : Departure(ids: original, since: now)
            }
            if var departure = leftIME {
                departure.ids.formIntersection(ids)
                leftIME = departure.ids.isEmpty ? nil : departure
                if !departure.ids.isEmpty, now - departure.since >= 0.4 {
                    reason = reason ?? "left-ime"
                }
            }
        }

        if current.ownerIsFrontmost || ids.isEmpty {
            away = nil
        } else {
            if var departure = away {
                departure.ids.formIntersection(ids)
                away = departure.ids.isEmpty ? Departure(ids: ids, since: now) : departure
            } else {
                away = Departure(ids: ids, since: now)
            }
            if let away, now - away.since >= 0.6 { reason = reason ?? "left-owner" }
        }

        if ids.count >= 2 { reason = reason ?? "multiple" }

        if !startupHandled, now - startedAt >= 1.5 {
            startupHandled = true
            // A single active candidate at startup can be legitimate.
            if !ids.isEmpty, !current.sourceID.isEmpty,
               !current.ownerIsFrontmost || !current.supportedIME {
                reason = reason ?? "startup"
            }
        }

        // Window age or unchanged coordinates alone never prove a stale composition.
        guard !current.sourceID.isEmpty, let reason else { return nil }
        if let lastClear, now - lastClear < 2 { return nil }
        lastClear = now
        pending = nil
        away = nil
        leftIME = nil
        return reason
    }
}

struct RecoveryAction {
    let ownerBundleID: String
    let reason: String
    let windowIDs: Set<CGWindowID>
}

enum Verification: Equatable {
    case unavailable
    case remaining(Int)
    case removed
}

func verify(_ action: RecoveryAction, against scan: CandidateScan) -> Verification {
    guard scan.available else { return .unavailable }
    let remaining = action.windowIDs.intersection(scan.candidates.map(\.id)).count
    return remaining == 0 ? .removed : .remaining(remaining)
}

/// Separate each owner's context and share one restart cooldown across clients.
struct RecoveryCoordinator {
    private var policies: [String: RecoveryPolicy]
    private var lastActionAt: TimeInterval?
    private var deferredUntil: [String: TimeInterval] = [:]

    init(now: TimeInterval) {
        policies = Dictionary(uniqueKeysWithValues: supportedOwners.values.map { ($0, RecoveryPolicy(now: now)) })
    }

    mutating func keyDown(now: TimeInterval, punctuation: Bool, sourceID: String, frontmost: String?) {
        for owner in policies.keys.sorted() {
            policies[owner]?.keyDown(now: now, punctuation: punctuation, sourceID: sourceID,
                                     ownerIsFrontmost: frontmost == owner)
        }
    }

    mutating func observe(_ candidates: [Candidate], sourceID: String,
                          frontmost: String?, now: TimeInterval) -> RecoveryAction? {
        let groups = Dictionary(grouping: candidates, by: \.ownerBundleID)
        var chosen: RecoveryAction?
        for owner in policies.keys.sorted() {
            let current = groups[owner] ?? []
            let snapshot = Observation(candidates: current, sourceID: sourceID, ownerIsFrontmost: frontmost == owner)
            let reason = policies[owner]?.observe(snapshot, now: now)
            guard chosen == nil, let reason, now >= (deferredUntil[owner] ?? 0),
                  lastActionAt.map({ now - $0 >= 2 }) ?? true else { continue }
            chosen = RecoveryAction(ownerBundleID: owner, reason: reason, windowIDs: Set(current.map(\.id)))
        }
        if chosen != nil { lastActionAt = now }
        return chosen
    }

    mutating func verified(_ action: RecoveryAction, outcome: Verification, now: TimeInterval) {
        if outcome == .removed { deferredUntil[action.ownerBundleID] = nil }
        else { deferredUntil[action.ownerBundleID] = now + 15 }
    }
}

func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }

func candidate(from window: [String: Any]) -> Candidate? {
    guard let ownerName = window[kCGWindowOwnerName as String] as? String,
          let ownerID = supportedOwners[ownerName],
          Int(number(window[kCGWindowLayer as String])) == 20,
          (window[kCGWindowName as String] as? String ?? "").isEmpty,
          let bounds = window[kCGWindowBounds as String] as? [String: Any] else { return nil }
    let width = number(bounds["Width"]), height = number(bounds["Height"])
    guard (20...40).contains(height), (40...900).contains(width) else { return nil }
    let id = CGWindowID(number(window[kCGWindowNumber as String]))
    guard id != 0 else { return nil }
    return Candidate(id: id, x: number(bounds["X"]), y: number(bounds["Y"]),
                     width: width, height: height, ownerBundleID: ownerID)
}

struct CandidateScan {
    let available: Bool
    let candidates: [Candidate]
}

func scanCandidates() -> CandidateScan {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                            kCGNullWindowID) as? [[String: Any]] ?? []
    return CandidateScan(available: !windows.isEmpty, candidates: windows.compactMap(candidate))
}

func candidates() -> [Candidate] { scanCandidates().candidates }

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

func commandStatus(_ executable: String, _ arguments: [String]) -> Int32? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    } catch {
        log("command failed executable=\(executable) error=\(error.localizedDescription)")
        return nil
    }
}

func runningInputMethodProcesses() -> Set<String> {
    Set(supportedInputMethods.values.filter {
        commandStatus("/usr/bin/pgrep", ["-u", String(getuid()), "-x", $0]) == 0
    })
}

@discardableResult
func clearCandidates(reason: String) -> Bool {
    let sourceID = currentInputSourceID()
    let running = runningInputMethodProcesses()
    guard let target = restartTarget(sourceID: sourceID, running: running) else {
        log("clear-skipped reason=\(reason) source=\(sourceID) running=\(running.sorted().joined(separator: ",")) no-unambiguous-target")
        return false
    }
    let status = commandStatus("/usr/bin/killall", ["-u", NSUserName(), "-TERM", target])
    log("clear-attempt reason=\(reason) target=\(target) status=\(status.map(String.init) ?? "unavailable")")
    return status == 0
}

func printStatus() {
    let scan = scanCandidates()
    let trusted = AXIsProcessTrusted()
    let grouped = Dictionary(grouping: scan.candidates, by: \.ownerBundleID).mapValues(\.count)
    let status: [String: Any] = [
        "version": guardVersion,
        "accessibility_granted": trusted,
        "punctuation_permission": trusted ? "granted" : "needs_accessibility",
        "input_source": currentInputSourceID(),
        "chatgpt_frontmost": frontmostIsChatGPT(),
        "matching_candidate_count": scan.candidates.count,
        "matching_candidates_by_owner": grouped,
        "supported_owners": supportedOwners,
        "supported_input_methods": supportedInputMethods,
        "active_input_method_process": inputMethodProcess(currentInputSourceID()) ?? "none",
        "window_list_available": scan.available,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]),
       let text = String(data: data, encoding: .utf8) { print(text) }
}

final class Guard {
    static let shared = Guard()
    private var coordinator = RecoveryCoordinator(now: ProcessInfo.processInfo.systemUptime)
    private var pendingVerification: (action: RecoveryAction, after: TimeInterval)?
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
        let scan = scanCandidates()
        let sourceID = currentInputSourceID()
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let pending = pendingVerification, now >= pending.after {
            let outcome = verify(pending.action, against: scan)
            log("verification owner=\(pending.action.ownerBundleID) result=\(outcome)")
            coordinator.verified(pending.action, outcome: outcome, now: now)
            pendingVerification = nil
        }
        let listening = tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
        let groups = Dictionary(grouping: scan.candidates, by: \.ownerBundleID).mapValues(\.count)
        let ownerSummary = groups.keys.sorted().map { "\($0):\(groups[$0] ?? 0)" }.joined(separator: ",")
        let state = "candidates=\(scan.candidates.count) owners=\(ownerSummary) windowListAvailable=\(scan.available) supportedIME=\(isSupportedIME(sourceID)) sourceKnown=\(!sourceID.isEmpty) punctuationListener=\(listening)"
        if state != lastState || now - lastStateLoggedAt >= 60 {
            log("state \(state)")
            lastState = state
            lastStateLoggedAt = now
        }
        if let action = coordinator.observe(scan.candidates, sourceID: sourceID, frontmost: frontmost, now: now) {
            if clearCandidates(reason: "\(action.ownerBundleID):\(action.reason)") {
                pendingVerification = (action, now + 0.8)
            } else {
                coordinator.verified(action, outcome: .remaining(action.windowIDs.count), now: now)
            }
        }
    }

    private func keyDown(_ event: CGEvent) {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let shortcut = !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
        coordinator.keyDown(now: ProcessInfo.processInfo.systemUptime,
                       punctuation: !shortcut && commitKeycodes.contains(code),
                       sourceID: currentInputSourceID(), frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
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
    let scan = scanCandidates()
    guard scan.available else {
        fputs("Cannot enumerate on-screen windows; no cleanup attempted.\n", stderr)
        exit(3)
    }
    let found = scan.candidates
    log("once count=\(found.count)")
    if found.isEmpty {
        print("No matching candidate windows found. Use --status to inspect permissions and visibility.")
    } else if clearCandidates(reason: "once") {
        Thread.sleep(forTimeInterval: 0.8)
        let action = RecoveryAction(ownerBundleID: "manual", reason: "once", windowIDs: Set(found.map(\.id)))
        switch verify(action, against: scanCandidates()) {
        case .removed:
            print("Verified that \(found.count) original matching window(s) disappeared.")
        case .remaining(let count):
            fputs("Input-method restart succeeded, but \(count) original matching window(s) remain.\n", stderr)
            exit(2)
        case .unavailable:
            fputs("Input-method restart sent; window enumeration is unavailable, so cleanup is unverified.\n", stderr)
            exit(3)
        }
    } else {
        fputs("Input-method restart failed. Check the guard log.\n", stderr)
        exit(1)
    }
} else {
    Guard.shared.run()
}
#endif
