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
                sourceID: source, chatGPTIsFrontmost: frontmost)
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
    p.keyDown(now: 0.1, punctuation: true, sourceID: tyimSource, chatGPTIsFrontmost: true)
    expect(p.observe(observation(), now: 0.29) == nil, "punctuation respects grace time")
    expect(p.observe(observation(), now: 0.31) == "punctuation", "punctuation clears the original lingering window")
}
do {
    var p = RecoveryPolicy(now: 0)
    _ = p.observe(observation(), now: 0)
    p.keyDown(now: 0.1, punctuation: true, sourceID: tyimSource, chatGPTIsFrontmost: true)
    expect(p.observe(observation([8]), now: 0.4) == nil, "a new candidate window is not the stale punctuation window")
}
do {
    var p = RecoveryPolicy(now: 0)
    _ = p.observe(observation(), now: 0)
    p.keyDown(now: 0.1, punctuation: true, sourceID: tyimSource, chatGPTIsFrontmost: true)
    p.keyDown(now: 0.2, punctuation: false, sourceID: tyimSource, chatGPTIsFrontmost: true)
    expect(p.observe(observation(), now: 0.4) == nil, "new typing cancels punctuation cleanup even if the native window ID is reused")
}
do {
    var p = RecoveryPolicy(now: 0)
    _ = p.observe(observation(), now: 0)
    p.keyDown(now: 0.1, punctuation: true, sourceID: tyimSource, chatGPTIsFrontmost: false)
    expect(p.observe(observation(), now: 0.4) == nil, "punctuation in another app never arms cleanup")
    p.keyDown(now: 0.45, punctuation: true, sourceID: abcSource, chatGPTIsFrontmost: true)
    expect(p.observe(observation(), now: 0.8) == nil, "punctuation in another input source never arms cleanup")
}
do {
    var p = RecoveryPolicy(now: 0)
    _ = p.observe(observation(), now: 0)
    p.keyDown(now: 0.1, punctuation: true, sourceID: tyimSource, chatGPTIsFrontmost: true)
    expect(p.observe(observation(frontmost: false), now: 0.4) == nil, "focus change cancels pending punctuation")
    expect(p.observe(observation(frontmost: false), now: 1.01) == "left-chatgpt", "leaving ChatGPT still clears an old window after its grace time")
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
print("\(passed) regression checks passed; no live IME was restarted.")
