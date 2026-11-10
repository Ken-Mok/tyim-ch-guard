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
check(narrow["matches_current_guard"] as? Bool == false, "a narrow pill is reported even though the guard excludes it")
check((narrow["excluded_because"] as? [String])?.contains("width outside 80...900") == true, "narrow-window exclusion is explained")
let other = explainWindow(fixture(width: 397, owner: "OtherInputAgent", title: "PRIVATE CANDIDATE TEXT"))!
check(other["owner"] as? String == "OtherInputAgent", "a different owner remains visible to diagnostics")
let encoded = String(decoding: try JSONSerialization.data(withJSONObject: other), as: UTF8.self)
check(!encoded.contains("PRIVATE CANDIDATE TEXT"), "candidate or window title text is not emitted")
let ordinary = explainWindow(fixture(width: 397))!
check(ordinary["matches_current_guard"] as? Bool == true, "original candidate geometry is recognized")
let empty = diagnosticReport(windows: [], source: "", log: "", inputSource: "unknown")
check(empty["window_list_available"] as? Bool == false, "an unavailable window list is not reported as proof of no stuck bars")
check(sourceVersion("let guardVersion = \"1.1.0\"") == "1.1.0", "installed source version is labeled and parsed")
print("7 read-only diagnostic checks passed.")
