import Foundation

/// Pure-logic self-check: no UI, no permissions, no sidecar process. Exits
/// 0 and prints "ok" when every assertion passes. `precondition` (not
/// `assert`) is used throughout so the checks still run under
/// `swift build -c release`, where `assert` is compiled out.
func runSelfTest() {
    testSuffixDiff()
    testNDJSON()
    testChunker()
    testSurrogateChunking()
    testFocusTargetRoles()
    testPartialTyperCancel()
    testHotkeyEdgeDecision()
    print("ok")
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

private func testSurrogateChunking() {
    // "🎉" (U+1F389) is a UTF-16 surrogate pair. Put it exactly on the
    // default 20-unit chunk boundary: 19 plain units, then the pair.
    let emoji = "🎉"
    precondition(Array(emoji.utf16).count == 2, "emoji fixture must be a surrogate pair")
    let text = String(repeating: "a", count: 19) + emoji + "b"

    let chunked = TextInserter.chunks(for: text)
    precondition(chunked.count >= 2, "text longer than 20 units must split")
    precondition(chunked[0].count == 19, "boundary must back off before a lone high surrogate")
    let secondChunk = String(utf16CodeUnits: chunked[1], count: chunked[1].count)
    precondition(secondChunk.hasPrefix(emoji), "the surrogate pair must stay together in the next chunk")

    // Rejoining every chunk must reproduce the exact original text.
    let rejoined = chunked.flatMap { $0 }
    precondition(String(utf16CodeUnits: rejoined, count: rejoined.count) == text)

    // A chunk boundary that doesn't touch a surrogate pair is unaffected.
    let plain = String(repeating: "b", count: 45)
    let plainChunks = TextInserter.chunks(for: plain)
    precondition(plainChunks.map(\.count) == [20, 20, 5])
}

private func testFocusTargetRoles() {
    // Native AppKit-style roles: a target regardless of the other signals.
    precondition(FocusTarget.isTextTarget(role: "AXTextField", hasSelectedTextRange: false, valueIsSettable: false))
    precondition(FocusTarget.isTextTarget(role: "AXTextArea", hasSelectedTextRange: false, valueIsSettable: false))
    precondition(FocusTarget.isTextTarget(role: "AXSearchField", hasSelectedTextRange: false, valueIsSettable: false))
    precondition(FocusTarget.isTextTarget(role: "AXComboBox", hasSelectedTextRange: false, valueIsSettable: false))

    // Browser/Electron web content: role is often generic or absent, but
    // kAXSelectedTextRangeAttribute or a settable value is the reliable
    // signal that it's editable -- this is the bug 2 fix (the old
    // allow-list treated all of these as "no target").
    precondition(FocusTarget.isTextTarget(role: "AXWebArea", hasSelectedTextRange: true, valueIsSettable: false), "a selected-text-range on an unrecognized web role must still be a target")
    precondition(FocusTarget.isTextTarget(role: "AXGroup", hasSelectedTextRange: false, valueIsSettable: true), "a settable value on an unrecognized role must still be a target")
    precondition(FocusTarget.isTextTarget(role: nil, hasSelectedTextRange: true, valueIsSettable: false), "a missing role must not suppress a strong positive signal")

    // Ambiguous: unknown/missing role, no positive signal either -- treat
    // as a target (type unless CONFIDENT there's nothing to type into).
    precondition(FocusTarget.isTextTarget(role: "AXWebArea", hasSelectedTextRange: false, valueIsSettable: false), "an unrecognized web role with no negative signal must default to typing")
    precondition(FocusTarget.isTextTarget(role: nil, hasSelectedTextRange: false, valueIsSettable: false), "a totally unknown/failed role query must default to typing")

    // Confident non-text controls: no target, even though this is the
    // "ambiguous" fallback case for anything else.
    precondition(!FocusTarget.isTextTarget(role: "AXButton", hasSelectedTextRange: false, valueIsSettable: false))
    precondition(!FocusTarget.isTextTarget(role: "AXStaticText", hasSelectedTextRange: false, valueIsSettable: false))
    // A positive signal always outranks a negative role (shouldn't happen
    // in practice, but the strong signal must win if it ever does).
    precondition(FocusTarget.isTextTarget(role: "AXButton", hasSelectedTextRange: true, valueIsSettable: false))
}

private func testPartialTyperCancel() {
    // Regression smoke test for a bug caught during design: cancelling
    // used to reset state outright, so the orphaned `final` that still
    // arrives afterwards (streaming sends finalize to reset the sidecar's
    // stream state even on cancel) would see typed == "" and retype the
    // entire transcript. cancel() must instead make partial()/final()
    // no-ops without touching `typed`. Exercises the real call sequence
    // (posts harmless CGEvents, same as any --selftest run without
    // Accessibility trust) -- the check is that this never traps.
    let typer = PartialTyper()
    typer.partial("hello")
    typer.cancel()
    typer.partial("hello world") // must be a no-op post-cancel
    typer.final("hello world and more") // must be a no-op post-cancel (but still resets)
    typer.reset()
    typer.partial("fresh utterance") // must behave normally again after reset
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
