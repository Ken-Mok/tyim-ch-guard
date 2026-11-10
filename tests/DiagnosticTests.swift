func check(_ ok: @autoclosure () -> Bool, _ message: String) {
    guard ok() else { print("FAIL: \(message)"); exit(1) }
    print("PASS: \(message)")
}
func fixture(width: Double, owner: String = "ChatGPT", title: String = "") -> [String: Any] {
    [kCGWindowBounds as String: ["Width": width, "Height": 28.0, "X": 10.0, "Y": 10.0],
     kCGWindowLayer as String: 20, kCGWindowOwnerName as String: owner,
     kCGWindowOwnerPID as String: 0, kCGWindowNumber as String: 123,
     kCGWindowName as String: title]
}
let narrow = explainWindow(fixture(width: 52))!
check(narrow["matches_guard_1_1"] as? Bool == false, "legacy narrow-window exclusion is preserved in the report")
check(narrow["matches_guard_1_2"] as? Bool == true, "new matcher includes a 52-point candidate pill")
let other = explainWindow(fixture(width: 397, owner: "OtherInputAgent", title: "PRIVATE CANDIDATE TEXT"))!
check(other["owner"] as? String == "OtherInputAgent", "a different owner remains visible to diagnostics")
let encoded = String(decoding: try JSONSerialization.data(withJSONObject: other), as: UTF8.self)
check(!encoded.contains("PRIVATE CANDIDATE TEXT"), "candidate or window title text is not emitted")
let ordinary = explainWindow(fixture(width: 397))!
check(ordinary["matches_guard_1_2"] as? Bool == true, "original candidate geometry is recognized")
let empty = diagnosticReport(windows: [], source: "", log: "", inputSource: "unknown")
check(empty["window_list_available"] as? Bool == false, "an unavailable window list is not reported as proof of no stuck bars")
check(sourceVersion("let guardVersion = \"1.1.0\"") == "1.1.0", "installed source version is labeled and parsed")
let teams = explainWindow(fixture(width: 52, owner: "Microsoft Teams"))!
check(teams["matches_guard_1_1"] as? Bool == false, "legacy Teams exclusion is reported")
check(teams["matches_guard_1_2"] as? Bool == true, "Teams narrow pill is included by the new matcher")
print("9 read-only diagnostic checks passed.")
