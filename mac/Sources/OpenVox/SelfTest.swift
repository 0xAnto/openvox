import AppKit
import CoreGraphics
import Foundation

/// Pure-logic self-check: no UI, no permissions, no sidecar process. Exits
/// 0 and prints "ok" when every assertion passes. `precondition` (not
/// `assert`) is used throughout so the checks still run under
/// `swift build -c release`, where `assert` is compiled out.
func runSelfTest() {
    testSuffixDiff()
    testNDJSON()
    testChunker()
    testPartialTyper()
    testShortcutChord()
    testMultiTapShortcut()
    testHotkeyEdgeDecision()
    testIndicatorModel()
    testHistoryPrune()
    testDictationStats()
    testAppearance()
    print("ok")
}

private func testHistoryPrune() {
    let now = Date()
    func entry(_ label: String, daysAgo: Double) -> DictationEntry {
        // Keep every fixture > 2 h away from a boundary so a DST shift
        // inside the window (calendar days, not 86 400 s) can't flip it.
        DictationEntry(date: now.addingTimeInterval(-daysAgo * 86_400), text: label)
    }
    let entries = [
        entry("now", daysAgo: 0),
        entry("6.9d", daysAgo: 6.9),
        entry("7.1d", daysAgo: 7.1),
        entry("29.9d", daysAgo: 29.9),
        entry("31d", daysAgo: 31),
    ]
    precondition(DictationHistory.prune(entries, retention: .forever, now: now) == entries, "all time keeps everything")
    precondition(DictationHistory.prune(entries, retention: .days30, now: now).map(\.text) == ["now", "6.9d", "7.1d", "29.9d"])
    precondition(DictationHistory.prune(entries, retention: .days7, now: now).map(\.text) == ["now", "6.9d"])
    precondition(DictationHistory.prune([], retention: .days7, now: now).isEmpty)
    precondition(HistoryRetention(rawValue: "days30") == .days30, "persisted raw value must round-trip")

    let searchable = [
        DictationEntry(date: now, text: "Fix HotkeyMonitor timing"),
        DictationEntry(date: now, text: "Review sidecar logs"),
    ]
    precondition(DictationHistory.matching(searchable, query: "hotkey").map(\.text) == ["Fix HotkeyMonitor timing"])
    precondition(DictationHistory.matching(searchable, query: "  LOGS ").map(\.text) == ["Review sidecar logs"])
    precondition(DictationHistory.matching(searchable, query: "   ") == searchable)
}

private func testDictationStats() {
    // A fixed clock keeps every day boundary stable, whatever day the
    // check runs on. Noon keeps the fixtures clear of a DST shift.
    let calendar = Calendar.current
    let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 12))!
    func entry(_ text: String, secondsAgo: TimeInterval, duration: TimeInterval? = nil) -> DictationEntry {
        DictationEntry(date: now.addingTimeInterval(-secondsAgo), text: text, duration: duration)
    }

    precondition(DictationStats.wordCount("  hello   world\n") == 2, "any whitespace run separates two words")
    precondition(DictationStats.wordCount("") == 0)

    let spread = [
        entry("one hour ago", secondsAgo: 3600),
        entry("two days ago", secondsAgo: 86_400 * 2),
        entry("six days ago", secondsAgo: 86_400 * 6),
        entry("eight days ago", secondsAgo: 86_400 * 8),
    ]
    precondition(DictationStats.entries(spread, in: .today, now: now).map(\.text) == ["one hour ago"])
    precondition(DictationStats.entries(spread, in: .week, now: now).map(\.text) == ["one hour ago", "two days ago", "six days ago"], "the week runs from the start of the day six days back")
    precondition(DictationStats.entries(spread, in: .allTime, now: now) == spread)

    let summary = DictationStats.summary([
        entry("one two three four five six seven eight", secondsAgo: 0, duration: 6),
        entry("nine ten", secondsAgo: 0),
    ])
    precondition(summary.dictations == 2)
    precondition(summary.words == 10, "words count whether or not the entry has a duration")
    precondition(summary.spokenSeconds == 6, "an entry without a duration adds no spoken time")
    precondition(summary.savedSeconds == 6, "eight timed words take 12 s to type at 40 wpm, minus 6 s spoken")
    precondition(DictationStats.summary([]) == StatsSummary())
    precondition(DictationStats.summary([entry("word", secondsAgo: 0, duration: 60)]).savedSeconds == 0, "saved time never goes negative")

    let days = DictationStats.wordsPerDay(spread + [entry("ten days ago", secondsAgo: 86_400 * 10)], days: 7, now: now)
    precondition(days.count == 7)
    precondition(days.last?.day == calendar.startOfDay(for: now), "the last bucket is today")
    precondition(days.map(\.day) == days.map(\.day).sorted(), "buckets run oldest first")
    precondition(days.map(\.words) == [3, 0, 0, 0, 3, 0, 3], "days without entries hold 0 words, and the 8- and 10-day-old entries fall outside the window")

    precondition(DictationStats.pace(words: 140, seconds: 60) == 140)
    precondition(DictationStats.pace(words: 5, seconds: 0.5) == nil, "a sub-second duration gives no meaningful pace")

    // History written before v1.0.2 has neither field.
    let legacy = #"{"id":"1B4E28BA-2FA1-11D2-883F-0016D3CCA427","date":0,"text":"legacy"}"#
    let decoded = try! JSONDecoder().decode(DictationEntry.self, from: Data(legacy.utf8))
    precondition(decoded.text == "legacy" && decoded.duration == nil && decoded.mode == nil)

    let recorded = DictationEntry(date: now, text: "hi", duration: 2, mode: AppState.Mode.fast.rawValue)
    precondition(try! JSONDecoder().decode(DictationEntry.self, from: JSONEncoder().encode(recorded)) == recorded, "duration and mode survive a save and load")
}

private func testSuffixDiff() {
    precondition(TextInserter.suffixToType(typed: "", full: "hello") == "hello")
    precondition(TextInserter.suffixToType(typed: "hel", full: "hello") == "lo")
    precondition(TextInserter.suffixToType(typed: "hello", full: "hello") == "")
    precondition(TextInserter.suffixToType(typed: "hello", full: "hel") == nil, "full shorter than typed is not a valid prefix extension")
    precondition(TextInserter.suffixToType(typed: "cat", full: "dog") == nil, "mismatch: typed is not a prefix of full")
    precondition(TextInserter.suffixToType(typed: "café", full: "café au lait") == " au lait", "multi-byte UTF-16 prefix must still diff correctly")
    precondition(TextInserter.suffixToType(typed: "hello world", full: "hello") == nil, "full growing shorter is a mismatch, not a valid partial")
}

private func testNDJSON() {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    func roundtrip(_ msg: SidecarOpMessage) -> SidecarOpMessage {
        let data = try! encoder.encode(msg)
        return try! decoder.decode(SidecarOpMessage.self, from: data)
    }
    func roundtripEvent(_ msg: SidecarEventMessage) -> SidecarEventMessage {
        let data = try! encoder.encode(msg)
        return try! decoder.decode(SidecarEventMessage.self, from: data)
    }

    let load = SidecarOpMessage.load(engine: "moonshine")
    precondition(roundtrip(load) == load)
    let loadRaw = String(data: try! encoder.encode(load), encoding: .utf8)!
    precondition(loadRaw.contains(#""op":"load""#) && loadRaw.contains(#""engine":"moonshine""#) && !loadRaw.contains("pcm"))

    let transcribe = SidecarOpMessage.transcribe(pcm: "AAAA")
    precondition(roundtrip(transcribe) == transcribe)

    let stream = SidecarOpMessage.stream(pcm: "AAAA")
    precondition(roundtrip(stream) == stream)

    precondition(roundtrip(.finalize) == .finalize)
    precondition(roundtrip(.ping) == .ping)

    let progress = SidecarEventMessage(ev: "progress", stage: "download", pct: 42, engine: nil, text: nil, message: nil, code: nil)
    precondition(roundtripEvent(progress) == progress)

    let ready = SidecarEventMessage(ev: "ready", stage: nil, pct: nil, engine: "nemotron", text: nil, message: nil, code: nil)
    precondition(roundtripEvent(ready) == ready)

    let partial = SidecarEventMessage(ev: "partial", stage: nil, pct: nil, engine: nil, text: "hello wor", message: nil, code: nil)
    precondition(roundtripEvent(partial) == partial)

    let final = SidecarEventMessage(ev: "final", stage: nil, pct: nil, engine: nil, text: "hello world", message: nil, code: nil)
    precondition(roundtripEvent(final) == final)

    let plainError = SidecarEventMessage(ev: "error", stage: nil, pct: nil, engine: nil, text: nil, message: "boom", code: nil)
    precondition(roundtripEvent(plainError) == plainError)

    let missingDeps = SidecarEventMessage(ev: "error", stage: nil, pct: nil, engine: nil, text: nil, message: nil, code: "missing-streaming-deps")
    precondition(roundtripEvent(missingDeps) == missingDeps)
    let missingDepsRaw = String(data: try! encoder.encode(missingDeps), encoding: .utf8)!
    precondition(missingDepsRaw.contains(#""code":"missing-streaming-deps""#))

    let pong = SidecarEventMessage(ev: "pong", stage: nil, pct: nil, engine: nil, text: nil, message: nil, code: nil)
    precondition(roundtripEvent(pong) == pong)
}

private func testPartialTyper() {
    // An injected sink makes the exact suffixes observable without
    // touching the real pasteboard.
    var inserted = ""
    let typer = PartialTyper { inserted += $0 }
    typer.partial("hello")
    typer.partial("hello world")
    typer.final("hello world and more")
    precondition(inserted == "hello world and more", "streaming must insert only each newly recognized suffix")
    typer.partial("fresh") // final() reset the typer: a new utterance starts from scratch
    precondition(inserted == "hello world and morefresh")
}

private func testShortcutChord() {
    let rightCommand: CGKeyCode = 54
    let rightOption: CGKeyCode = 61
    let chord = HotkeyShortcut([rightCommand, rightOption])

    precondition(!HotkeyMonitor.chordIsPressed(chord, pressedCodes: []))
    precondition(!HotkeyMonitor.chordIsPressed(chord, pressedCodes: [rightCommand]))
    precondition(!HotkeyMonitor.chordIsPressed(chord, pressedCodes: [rightOption]))
    precondition(HotkeyMonitor.chordIsPressed(chord, pressedCodes: [rightCommand, rightOption]))
    precondition(HotkeyMonitor.chordIsPressed(chord, pressedCodes: [55, rightCommand, rightOption]), "unrelated held keys must not prevent the shortcut")
    precondition(KeyLabel.name(for: chord) == "Right Command + Right Option")

    let single = HotkeyShortcut(keyCode: rightOption)
    precondition(HotkeyMonitor.chordIsPressed(single, pressedCodes: [rightOption]), "existing single-key shortcuts must keep working")

    // Modifier down/up is read from the event's device-specific flag bit,
    // never toggled: a Right Option release (bit clear) must read as up
    // even when the tracker never saw the press.
    let rightOptionDown = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
    let leftOptionDown = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20)
    precondition(HotkeyMonitor.modifierIsDown(code: rightOption, flags: rightOptionDown))
    precondition(!HotkeyMonitor.modifierIsDown(code: rightOption, flags: leftOptionDown), "the shared Option flag must not count as Right Option")
    precondition(!HotkeyMonitor.modifierIsDown(code: rightOption, flags: []))
}

private func testHotkeyEdgeDecision() {
    let threshold: TimeInterval = 0.35

    // Press: not already dictating -> start.
    precondition(HotkeyEdge.decide(.press, isDictating: false, isToggleActive: false, heldFor: 0, synthesized: false, holdThreshold: threshold) == .start)
    // Press while a toggle-active utterance is running -> finish (stop it), regardless of anything else.
    precondition(HotkeyEdge.decide(.press, isDictating: true, isToggleActive: true, heldFor: 0, synthesized: false, holdThreshold: threshold) == .finish)
    // Press while already mid-hold (e.g. a stray repeat) -> ignore, don't restart.
    precondition(HotkeyEdge.decide(.press, isDictating: true, isToggleActive: false, heldFor: 0, synthesized: false, holdThreshold: threshold) == .ignore)

    // Release: quick genuine tap (< threshold) -> enter toggle mode, stay dictating.
    precondition(HotkeyEdge.decide(.release, isDictating: true, isToggleActive: false, heldFor: 0.1, synthesized: false, holdThreshold: threshold) == .enterToggle)
    // Release: long genuine hold (>= threshold) -> finish (hold-to-talk).
    precondition(HotkeyEdge.decide(.release, isDictating: true, isToggleActive: false, heldFor: 0.5, synthesized: false, holdThreshold: threshold) == .finish)
    // Release: exactly at the threshold counts as a hold, not a tap.
    precondition(HotkeyEdge.decide(.release, isDictating: true, isToggleActive: false, heldFor: threshold, synthesized: false, holdThreshold: threshold) == .finish)
    // Release while not dictating (e.g. the toggle-stop's own matching release) -> ignore.
    precondition(HotkeyEdge.decide(.release, isDictating: false, isToggleActive: false, heldFor: 0.1, synthesized: false, holdThreshold: threshold) == .ignore)
    // Release while toggle-active (already handled at press-time) -> ignore.
    precondition(HotkeyEdge.decide(.release, isDictating: true, isToggleActive: true, heldFor: 0.1, synthesized: false, holdThreshold: threshold) == .ignore)

    // The bug 1 regression case: a SYNTHESIZED release (manufactured after
    // a tap-disabled recovery) that lands well under the hold threshold
    // must still finish, never enter toggle mode -- a broken hold-to-talk
    // used to treat this exactly like a genuine quick tap and get stuck
    // toggling forever.
    precondition(HotkeyEdge.decide(.release, isDictating: true, isToggleActive: false, heldFor: 0.01, synthesized: true, holdThreshold: threshold) == .finish, "a synthesized release must always finish, never enter toggle mode")
    // Even a "long" synthesized duration finishes the same way (the
    // duration is meaningless for a synthesized release; synthesized
    // always wins).
    precondition(HotkeyEdge.decide(.release, isDictating: true, isToggleActive: false, heldFor: 5, synthesized: true, holdThreshold: threshold) == .finish)
}

private func testChunker() {
    // 160 ms @ 16 kHz mono.
    precondition(Int(16000.0 * 0.160) == 2560)
    precondition(AudioCapture.chunkSize == 2560)
    // 150 ms @ 16 kHz mono: the offline accidental-tap guard (item 3).
    precondition(Int(16000.0 * 0.150) == 2400)
    precondition(AudioCapture.minSamplesToTranscribe == 2400)

    // Mirrors AudioCapture's accumulate-then-slice logic in streaming mode.
    var pending: [Float] = []
    var chunksEmitted = 0
    func feed(_ n: Int) {
        pending.append(contentsOf: [Float](repeating: 0, count: n))
        while pending.count >= AudioCapture.chunkSize {
            pending.removeFirst(AudioCapture.chunkSize)
            chunksEmitted += 1
        }
    }
    feed(1000)
    feed(2000) // total 3000 -> 1 chunk, 440 left
    precondition(chunksEmitted == 1 && pending.count == 440)
    feed(2200) // total 2640 -> 1 more chunk, 80 left
    precondition(chunksEmitted == 2 && pending.count == 80)
    feed(0)
    precondition(chunksEmitted == 2, "feeding zero samples must not spuriously emit a chunk")
}

private func testIndicatorModel() {
    let m = IndicatorModel()
    m.push(0.05) // typical speech RMS lands mid-scale
    precondition(abs(m.smooth - 0.1) < 0.001, "rms is scaled by 6 and averaged over the last three samples")
    m.push(5) // absurdly loud
    precondition(m.smooth <= 1, "level is clamped to 1")
    precondition(m.bump > 0.5, "a sudden loud sample is a transient")
    m.phase = .listening
    let t0 = Date()
    m.step(now: t0)
    m.step(now: t0.addingTimeInterval(1.0 / 60.0))
    precondition(m.a1 > 0.3 && m.a2 > 0.1, "a loud transient drives both the fundamental and the overtone")
    precondition(m.ph1 > 0 && m.ph2 > m.ph1, "the overtone oscillates faster than the fundamental")
    for _ in 0..<40 { m.push(0) }
    precondition(m.smooth == 0 && m.bump < 0.01, "level and bump decay back to rest in silence")
    m.phase = .hidden
    for i in 0..<120 { m.step(now: t0.addingTimeInterval(Double(i) / 60.0)) }
    precondition(m.a1 < 0.02 && m.a2 < 0.02, "the string rings down when no longer driven")
    m.reset()
    precondition(m.smooth == 0 && m.bump == 0 && m.a1 == 0 && m.a2 == 0)
}

/// Synthetic CGEvent for the hotkey tap, so the multi-tap state machine
/// runs the real `handle` path without a live event tap. `at` is seconds;
/// CGEvent timestamps are nanoseconds since boot.
private func modifierEvent(_ code: CGKeyCode, down: Bool, at seconds: Double) -> CGEvent {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
    event.type = .flagsChanged
    event.flags = down ? CGEventFlags(rawValue: HotkeyMonitor.modifierFlagBits[code]! | CGEventFlags.maskControl.rawValue) : []
    event.timestamp = CGEventTimestamp(seconds * 1_000_000_000)
    return event
}

private func keyEvent(_ code: CGKeyCode, down: Bool, at seconds: Double) -> CGEvent {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
    event.timestamp = CGEventTimestamp(seconds * 1_000_000_000)
    return event
}

private func testMultiTapShortcut() {
    let control: CGKeyCode = 59
    let keyC: CGKeyCode = 8

    // Single-tap shortcuts keep the existing behaviour: the first press activates.
    let single = HotkeyMonitor(shortcut: HotkeyShortcut([control]), cancelKeyCode: 53)
    _ = single.handle(type: .flagsChanged, event: modifierEvent(control, down: true, at: 0))
    precondition(single.isShortcutActive, "a single-tap shortcut activates on its first press")
    _ = single.handle(type: .flagsChanged, event: modifierEvent(control, down: false, at: 0.5))
    precondition(!single.isShortcutActive)

    let double = HotkeyMonitor(shortcut: HotkeyShortcut([control], tapCount: 2), cancelKeyCode: 53)
    // First tap only arms; the second press inside the window activates.
    _ = double.handle(type: .flagsChanged, event: modifierEvent(control, down: true, at: 1.0))
    precondition(!double.isShortcutActive, "the first tap of a double-tap shortcut must not activate")
    _ = double.handle(type: .flagsChanged, event: modifierEvent(control, down: false, at: 1.08))
    _ = double.handle(type: .flagsChanged, event: modifierEvent(control, down: true, at: 1.3))
    precondition(double.isShortcutActive, "the second press within the tap window activates")
    _ = double.handle(type: .flagsChanged, event: modifierEvent(control, down: false, at: 2.0))
    precondition(!double.isShortcutActive, "release after activation deactivates")

    // A second press after the window is a new first tap, not the second.
    _ = double.handle(type: .flagsChanged, event: modifierEvent(control, down: true, at: 3.0))
    _ = double.handle(type: .flagsChanged, event: modifierEvent(control, down: false, at: 3.1))
    _ = double.handle(type: .flagsChanged, event: modifierEvent(control, down: true, at: 3.1 + HotkeyMonitor.tapWindow + 0.05))
    precondition(!double.isShortcutActive, "a press after the tap window must not count as the second tap")
    _ = double.handle(type: .flagsChanged, event: modifierEvent(control, down: false, at: 4.0))

    // Any other key inside a tap breaks the sequence: Ctrl+C then Ctrl is
    // not a double tap of Control.
    _ = double.handle(type: .flagsChanged, event: modifierEvent(control, down: true, at: 5.0))
    _ = double.handle(type: .keyDown, event: keyEvent(keyC, down: true, at: 5.05))
    _ = double.handle(type: .keyUp, event: keyEvent(keyC, down: false, at: 5.1))
    _ = double.handle(type: .flagsChanged, event: modifierEvent(control, down: false, at: 5.15))
    _ = double.handle(type: .flagsChanged, event: modifierEvent(control, down: true, at: 5.3))
    precondition(!double.isShortcutActive, "a tap that carried another key must not count")
    _ = double.handle(type: .flagsChanged, event: modifierEvent(control, down: false, at: 5.4))

    // Any other key between taps breaks the sequence too.
    _ = double.handle(type: .flagsChanged, event: modifierEvent(control, down: true, at: 6.0))
    _ = double.handle(type: .flagsChanged, event: modifierEvent(control, down: false, at: 6.1))
    _ = double.handle(type: .keyDown, event: keyEvent(keyC, down: true, at: 6.15))
    _ = double.handle(type: .keyUp, event: keyEvent(keyC, down: false, at: 6.2))
    _ = double.handle(type: .flagsChanged, event: modifierEvent(control, down: true, at: 6.3))
    precondition(!double.isShortcutActive, "a key pressed between the taps must break the sequence")

    // Triple tap: two clean taps arm, the third press activates.
    let triple = HotkeyMonitor(shortcut: HotkeyShortcut([control], tapCount: 3), cancelKeyCode: 53)
    _ = triple.handle(type: .flagsChanged, event: modifierEvent(control, down: true, at: 0))
    _ = triple.handle(type: .flagsChanged, event: modifierEvent(control, down: false, at: 0.05))
    _ = triple.handle(type: .flagsChanged, event: modifierEvent(control, down: true, at: 0.2))
    precondition(!triple.isShortcutActive, "the second press of a triple-tap shortcut must not activate")
    _ = triple.handle(type: .flagsChanged, event: modifierEvent(control, down: false, at: 0.25))
    _ = triple.handle(type: .flagsChanged, event: modifierEvent(control, down: true, at: 0.4))
    precondition(triple.isShortcutActive, "the third press activates a triple-tap shortcut")

    precondition(KeyLabel.name(for: HotkeyShortcut([control], tapCount: 2)) == "Double-tap Control")
    precondition(KeyLabel.name(for: HotkeyShortcut([control], tapCount: 3)) == "Triple-tap Control")
    precondition(KeyLabel.name(for: HotkeyShortcut([control])) == "Control", "single-tap labels stay unchanged")
}

/// The appearance setting maps to the AppKit appearance the app applies.
/// The test never touches `NSApp`: `--selftest` runs without an app object.
private func testAppearance() {
    precondition(AppState.Appearance(rawValue: "dark")?.nsAppearance?.name == .darkAqua, "persisted raw value must round-trip")
    precondition(AppState.Appearance.light.nsAppearance?.name == .aqua, "Light forces the aqua appearance")
    precondition(AppState.Appearance.system.nsAppearance == nil, "System follows the macOS setting")
}
