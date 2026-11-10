// Appended to main.swift with GUARD_TESTS: no native observer or kill command runs.
let tyimSource = "com.apple.inputmethod.TYIM.Sucheng"
let abcSource = "com.apple.keylayout.ABC"
var passed = 0
func expect(_ value: @autoclosure () -> Bool, _ name: String) {
    guard value() else { print("FAIL: \(name)"); exit(1) }
    passed += 1
    print("PASS: \(name)")
}
func observation(_ ids: [UInt32] = [7], source: String = tyimSource,
                 frontmost: Bool = true) -> Observation {
    Observation(candidates: ids.map { Candidate(id: $0, x: 100, y: 100, width: 397, height: 28) },
                sourceID: source, ownerIsFrontmost: frontmost)
}

do {
    var p = RecoveryPolicy(now: 0)
    _ = p.observe(observation(), now: 100)
    expect(p.observe(observation(source: abcSource), now: 100.2) == nil, "leaving TYIM starts a grace period")
    expect(p.observe(observation(source: abcSource), now: 100.4) == nil, "departure survives the next poll")
    expect(p.observe(observation(source: abcSource), now: 100.81) == "left-tyim", "original timer bug: persistent panel clears after leaving TYIM")
}
do {
    var p = RecoveryPolicy(now: 0)
    _ = p.observe(observation(), now: 1)
    _ = p.observe(observation(source: abcSource), now: 1.2)
    expect(p.observe(observation(), now: 1.4) == nil, "returning to TYIM cancels departure")
    expect(p.observe(observation(), now: 2) == nil, "canceled departure never fires later")
}
do {
    var p = RecoveryPolicy(now: 0)
    for t in [0.0, 1.6, 20.1, 21, 60, 3600] {
        expect(p.observe(observation(), now: t) == nil, "normal stationary composition survives at \(t)s")
    }
}
do {
    var p = RecoveryPolicy(now: 0)
    _ = p.observe(observation(), now: 0)
    p.keyDown(now: 0.1, punctuation: true, sourceID: tyimSource, ownerIsFrontmost: true)
    expect(p.observe(observation(), now: 0.29) == nil, "punctuation respects grace time")
    expect(p.observe(observation(), now: 0.31) == "punctuation", "punctuation clears the original lingering window")
}
do {
    var p = RecoveryPolicy(now: 0)
    _ = p.observe(observation(), now: 0)
    p.keyDown(now: 0.1, punctuation: true, sourceID: tyimSource, ownerIsFrontmost: true)
    expect(p.observe(observation([8]), now: 0.4) == nil, "a new candidate window is not the stale punctuation window")
}
do {
    var p = RecoveryPolicy(now: 0)
    _ = p.observe(observation(), now: 0)
    p.keyDown(now: 0.1, punctuation: true, sourceID: tyimSource, ownerIsFrontmost: true)
    p.keyDown(now: 0.2, punctuation: false, sourceID: tyimSource, ownerIsFrontmost: true)
    expect(p.observe(observation(), now: 0.4) == nil, "new typing cancels punctuation cleanup even if the native window ID is reused")
}
do {
    var p = RecoveryPolicy(now: 0)
    _ = p.observe(observation(), now: 0)
    p.keyDown(now: 0.1, punctuation: true, sourceID: tyimSource, ownerIsFrontmost: false)
    expect(p.observe(observation(), now: 0.4) == nil, "punctuation in another app never arms cleanup")
    p.keyDown(now: 0.45, punctuation: true, sourceID: abcSource, ownerIsFrontmost: true)
    expect(p.observe(observation(), now: 0.8) == nil, "punctuation in another input source never arms cleanup")
}
do {
    var p = RecoveryPolicy(now: 0)
    _ = p.observe(observation(), now: 0)
    p.keyDown(now: 0.1, punctuation: true, sourceID: tyimSource, ownerIsFrontmost: true)
    expect(p.observe(observation(frontmost: false), now: 0.4) == nil, "focus change cancels pending punctuation")
    expect(p.observe(observation(frontmost: false), now: 1.01) == "left-owner", "leaving ChatGPT still clears an old window after its grace time")
}
do {
    var p = RecoveryPolicy(now: 0)
    expect(p.observe(observation([7, 8]), now: 1) == "multiple", "multiple stale candidates are cleared")
    expect(p.observe(observation([7, 8]), now: 1.2) == nil, "cooldown prevents repeated restarts")
    expect(p.observe(observation([7, 8]), now: 3.1) == "multiple", "cleanup resumes after cooldown")
}
do {
    var p = RecoveryPolicy(now: 0)
    _ = p.observe(observation(), now: 0)
    _ = p.observe(observation(source: abcSource), now: 0.2)
    expect(p.observe(observation([8], source: abcSource), now: 0.8) == nil, "departure does not transfer to an unrelated new window")
}
do {
    var p = RecoveryPolicy(now: 0)
    expect(p.observe(observation(source: abcSource), now: 1.6) == "startup", "startup may clear an inactive old TYIM window")
    var q = RecoveryPolicy(now: 0)
    expect(q.observe(observation(source: ""), now: 1.6) == nil, "unknown input source never authorizes a reset")
}
expect(!isTYIM("com.apple.inputmethod.TYIM-Fake"), "input-source matching requires the exact TYIM namespace")
let teamsOwner = "com.microsoft.teams2"
func candidateWindow(_ id: Int, width: Double = 397, owner: String = "Microsoft Teams",
                     layer: Int = 20, title: String = "") -> [String: Any] {
    [kCGWindowOwnerName as String: owner, kCGWindowLayer as String: layer,
     kCGWindowName as String: title, kCGWindowNumber as String: id,
     kCGWindowBounds as String: ["X": 100.0, "Y": 100.0, "Width": width, "Height": 28.0]]
}
let teamsWindows = [397.0, 397, 397, 52, 397, 397].enumerated().map {
    candidateWindow($0.offset + 100, width: $0.element)
}
let teamsCandidates = teamsWindows.compactMap(candidate)
expect(teamsCandidates.count == 6, "user regression: all six Teams windows are recognized")
expect(teamsCandidates.contains { $0.width == 52 }, "52-point candidate pill is included")
expect(teamsCandidates.allSatisfy { $0.ownerBundleID == teamsOwner }, "Teams candidates retain their owner context")
expect(candidate(from: candidateWindow(1, owner: "Control Center", layer: 25)) == nil, "Control Center windows remain excluded")
expect(candidate(from: candidateWindow(1, width: 28, owner: "Window Server", layer: 2147483630)) == nil, "Window Server overlays remain excluded")
expect(candidate(from: candidateWindow(1, layer: 0)) == nil, "normal Teams main windows remain excluded")
expect(candidate(from: candidateWindow(1, title: "Meeting")) == nil, "titled Teams windows remain excluded")
expect(candidate(from: candidateWindow(1, width: 39)) == nil, "unobserved very narrow geometry remains excluded")
expect(candidate(from: candidateWindow(1, owner: "ChatGPT")) != nil, "ChatGPT remains supported")

do {
    var c = RecoveryCoordinator(now: 0)
    let action = c.observe(teamsCandidates, sourceID: abcSource, frontmost: "com.apple.Terminal", now: 0)
    expect(action?.ownerBundleID == teamsOwner && action?.reason == "multiple", "multiple Teams bars trigger cleanup without a punctuation listener")
    expect(action?.windowIDs.count == 6, "verification tracks all six original windows")
}
do {
    var c = RecoveryCoordinator(now: 0)
    let single = [teamsCandidates[0]]
    expect(c.observe(single, sourceID: tyimSource, frontmost: teamsOwner, now: 0) == nil, "single active Teams candidate is protected")
    expect(c.observe(single, sourceID: tyimSource, frontmost: teamsOwner, now: 1.6) == nil, "startup protects active Teams composition")
    expect(c.observe(single, sourceID: tyimSource, frontmost: teamsOwner, now: 60) == nil, "normal Teams composition has no stationary timeout")
    _ = c.observe(single, sourceID: tyimSource, frontmost: chatGPTBundleID, now: 60.2)
    expect(c.observe(single, sourceID: tyimSource, frontmost: chatGPTBundleID, now: 60.9)?.reason == "left-owner", "leaving Teams uses the owning app's grace timer")
}
do {
    var c = RecoveryCoordinator(now: 0)
    let chat = Candidate(id: 200, x: 0, y: 0, width: 397, height: 28)
    expect(c.observe([chat, teamsCandidates[0]], sourceID: tyimSource, frontmost: chatGPTBundleID, now: 0) == nil,
           "one bar per owner is not counted as multiple bars for one app")
}
do {
    var c = RecoveryCoordinator(now: 0)
    let single = [teamsCandidates[0]]
    _ = c.observe(single, sourceID: tyimSource, frontmost: teamsOwner, now: 0)
    c.keyDown(now: 0.1, punctuation: true, sourceID: tyimSource, frontmost: teamsOwner)
    expect(c.observe(single, sourceID: tyimSource, frontmost: teamsOwner, now: 0.31)?.reason == "punctuation", "Teams punctuation is scoped to Teams context")
}
do {
    var c = RecoveryCoordinator(now: 0)
    let chat = [Candidate(id: 200, x: 0, y: 0, width: 397, height: 28),
                Candidate(id: 201, x: 0, y: 0, width: 397, height: 28)]
    let all = chat + teamsCandidates
    let first = c.observe(all, sourceID: abcSource, frontmost: nil, now: 0)!
    expect(c.observe(all, sourceID: abcSource, frontmost: nil, now: 0.2) == nil, "restart cooldown is global across owners")
    c.verified(first, outcome: .remaining(6), now: 0.8)
    let next = c.observe(all, sourceID: abcSource, frontmost: nil, now: 2.2)
    expect(next?.ownerBundleID == chatGPTBundleID, "failed Teams cleanup backs off while other owners can recover")
}
do {
    let action = RecoveryAction(ownerBundleID: teamsOwner, reason: "multiple", windowIDs: Set(teamsCandidates.map(\.id)))
    expect(verify(action, against: CandidateScan(available: true, candidates: teamsCandidates)) == .remaining(6), "successful TERM alone does not report old bars removed")
    expect(verify(action, against: CandidateScan(available: true, candidates: [])) == .removed, "verification confirms original IDs disappeared")
    expect(verify(action, against: CandidateScan(available: false, candidates: [])) == .unavailable, "unavailable enumeration never counts as successful cleanup")
}
print("\(passed) regression checks passed; no live IME was restarted.")
