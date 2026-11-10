import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

/// Clears stale ChatGPT-owned Traditional Chinese IME candidate bars.
/// Computer History can leave a 397x28, layer-20, untitled window behind.
/// Sending TERM to TYIM_Extension is the known way to drop those windows.
let chatGPTBundleID = "com.openai.codex"
let logURL = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Logs/tyim-ch-guard.log")

// ANSI keycodes that commit a Sucheng/Cangjie candidate and should dismiss it.
let commitKeycodes: Set<Int64> = [
    41, // ;
    39, // '
    44, // /
    43, // ,
    47, // .
]

func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: logURL)
        }
    }
}

struct Candidate: Equatable {
    let id: CGWindowID
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var boundsKey: String {
        "\(Int(x)):\(Int(y)):\(Int(width)):\(Int(height))"
    }
}

func number(_ value: Any?) -> Double {
    if let number = value as? NSNumber { return number.doubleValue }
    return 0
}

func candidates() -> [Candidate] {
    let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    var found: [Candidate] = []
    for window in raw {
        let owner = window[kCGWindowOwnerName as String] as? String ?? ""
        guard owner == "ChatGPT" else { continue }
        guard Int(number(window[kCGWindowLayer as String])) == 20 else { continue }
        let name = window[kCGWindowName as String] as? String ?? ""
        guard name.isEmpty else { continue }
        guard let bounds = window[kCGWindowBounds as String] as? [String: Any] else { continue }
        let width = number(bounds["Width"])
        let height = number(bounds["Height"])
        guard height >= 20, height <= 40, width >= 80, width <= 900 else { continue }
        let id = CGWindowID(number(window[kCGWindowNumber as String]))
        guard id != 0 else { continue }
        found.append(Candidate(
            id: id,
            x: number(bounds["X"]),
            y: number(bounds["Y"]),
            width: width,
            height: height
        ))
    }
    return found
}

func currentInputSourceID() -> String {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return "" }
    guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
    return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
}

func isTYIM(_ sourceID: String) -> Bool {
    sourceID.contains("com.apple.inputmethod.TYIM")
}

func frontmostIsChatGPT() -> Bool {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier == chatGPTBundleID
}

func clearCandidates(reason: String) {
    let running = Process()
    running.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    running.arguments = ["-TERM", "TYIM_Extension"]
    running.standardOutput = FileHandle.nullDevice
    running.standardError = FileHandle.nullDevice
    do {
        try running.run()
        running.waitUntilExit()
        log("cleared reason=\(reason) status=\(running.terminationStatus)")
    } catch {
        log("clear failed \(error.localizedDescription)")
    }
}

final class Guard {
    var tap: CFMachPort?
    var pendingPunctuation = false
    var armedIDs: Set<CGWindowID> = []
    var armDeadline: TimeInterval = 0
    var lastClear: TimeInterval = 0
    var startedAt = Date().timeIntervalSinceReferenceDate
    var startupCleared = false
    var awaySince: TimeInterval?
    var leftTYIMSince: TimeInterval?
    var wasTYIM = false
    var stillSince: [CGWindowID: (key: String, since: TimeInterval)] = [:]
    var prompted = false

    func run() {
        log("start pid=\(ProcessInfo.processInfo.processIdentifier)")
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.run()
    }

    func tick() {
        let now = Date().timeIntervalSinceReferenceDate
        ensureTap()
        if pendingPunctuation {
            pendingPunctuation = false
            let current = candidates()
            if !current.isEmpty {
                armedIDs = Set(current.map(\.id))
                armDeadline = now + 0.2
            }
        }

        let current = candidates()
        let sourceID = currentInputSourceID()
        let tyim = isTYIM(sourceID)

        if !armedIDs.isEmpty, now >= armDeadline {
            let stuck = current.contains { armedIDs.contains($0.id) }
            armedIDs.removeAll()
            if stuck { clear(reason: "punctuation", now: now) }
        }

        if current.count >= 2 {
            clear(reason: "multiple", now: now)
        }

        if !frontmostIsChatGPT(), !current.isEmpty {
            if awaySince == nil { awaySince = now }
            if let awaySince, now - awaySince > 0.6 {
                clear(reason: "left-chatgpt", now: now)
            }
        } else {
            awaySince = nil
        }

        if wasTYIM, !tyim, !current.isEmpty {
            if leftTYIMSince == nil { leftTYIMSince = now }
            if let leftTYIMSince, now - leftTYIMSince > 0.4 {
                clear(reason: "left-tyim", now: now)
            }
        } else {
            leftTYIMSince = nil
        }
        wasTYIM = tyim

        var nextStill: [CGWindowID: (key: String, since: TimeInterval)] = [:]
        for candidate in current {
            if let previous = stillSince[candidate.id], previous.key == candidate.boundsKey {
                nextStill[candidate.id] = previous
                if now - previous.since > 20 {
                    clear(reason: "still-20s", now: now)
                }
            } else {
                nextStill[candidate.id] = (candidate.boundsKey, now)
            }
        }
        stillSince = nextStill

        if !startupCleared, now - startedAt > 1.5, !current.isEmpty {
            startupCleared = true
            clear(reason: "startup", now: now)
        } else if now - startedAt > 1.5 {
            startupCleared = true
        }
    }

    func clear(reason: String, now: TimeInterval) {
        guard now - lastClear > 2 else { return }
        lastClear = now
        armedIDs.removeAll()
        clearCandidates(reason: reason)
    }

    func ensureTap() {
        guard tap == nil else { return }
        let trusted = AXIsProcessTrusted()
        if !trusted, !prompted {
            prompted = true
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [key: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            log("accessibility not granted; punctuation clear waits for permission")
            return
        }
        guard trusted else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    return Unmanaged.passUnretained(event)
                }
                let code = event.getIntegerValueField(.keyboardEventKeycode)
                if commitKeycodes.contains(code) {
                    Guard.shared.pendingPunctuation = true
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else {
            log("event tap create failed")
            return
        }
        tap = created
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        log("event tap listening")
    }

    static let shared = Guard()
}

if CommandLine.arguments.contains("--once") {
    let found = candidates()
    log("once count=\(found.count)")
    if !found.isEmpty {
        clearCandidates(reason: "once")
    }
    exit(0)
}

Guard.shared.run()
