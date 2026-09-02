# Home and History redesign (Option A) — implementation plan

Spec: the approved HTML mockup at `.superpowers/mockups/home-history.html` (Option A, "Overview").
Ship as v1.0.2 via a PR to `main`.

## Global constraints

- Build and test from `mac/`: `swift build && .build/debug/OpenVox --selftest`. Both must pass before every commit.
- Target macOS 14, Swift 5 language mode, SwiftPM only (no Xcode project). No new dependencies. Apple system frameworks (SwiftUI, Charts, AppKit) are allowed.
- Follow existing visual style: cards use `RoundedRectangle(cornerRadius: 14, style: .continuous)`, `.background` fill, stroke `Color.primary.opacity(0.08)`. Accent is `Color.accentColor` (the root view applies `.tint`). Support light and dark mode with adaptive system colors only.
- Comments and commit messages: active voice, present tense, short sentences. No marketing words. Never mention "Apple style".
- Mark deliberate simplifications with a `// ponytail:` comment naming the ceiling and the upgrade path.
- No trend deltas ("vs last week"). No keyboard shortcuts beyond what SwiftUI gives for free.
- Word count = `text.split(whereSeparator: \.isWhitespace).count`. Typing pace for "time saved" = 40 words per minute.
- Duration display: rows use `Duration.seconds(x).formatted(.time(pattern: .minuteSecond))` ("0:09"). Tiles use `Duration.seconds(x).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))` ("41 min, 8 sec").

### Task 1: Record duration and mode, add pure stats, split HistoryView into its own file

Files: `mac/Sources/OpenVox/DictationHistory.swift`, `mac/Sources/OpenVox/AppState.swift`, `mac/Sources/OpenVox/AppDelegate.swift`, new `mac/Sources/OpenVox/DictationStats.swift`, new `mac/Sources/OpenVox/HistoryView.swift`, `mac/Sources/OpenVox/SelfTest.swift`.

1. `DictationEntry` gains two optional fields with defaults so old JSON and existing call sites keep working:
   ```swift
   var duration: TimeInterval? = nil   // seconds from shortcut press to release; nil for entries recorded before v1.0.2
   var mode: String? = nil             // AppState.Mode.rawValue ("fast" | "streaming")
   ```
2. `AppState`:
   - `func recordDictation(_ text: String, duration: TimeInterval?)` appends `DictationEntry(date: Date(), text: text, duration: duration, mode: mode.rawValue)` then prunes.
   - `func deleteDictation(_ id: DictationEntry.ID)` removes the entry and saves.
3. `AppDelegate`: add `private var dictationStartedAt: Date?` and `private var pendingDuration: TimeInterval?`.
   - Set `dictationStartedAt = Date()` right where `isDictating = true` is set in the start path (the line before `isToggleActive = false` / `partialTyper.reset()`).
   - In `finishDictation()`, right after `isDictating = false`, set `pendingDuration = dictationStartedAt.map { Date().timeIntervalSince($0) }` and `dictationStartedAt = nil`.
   - In `handleFinal`, call `appState.recordDictation(text, duration: pendingDuration)` and set `pendingDuration = nil` (in both the empty and non-empty branches, so a stale value never leaks into the next dictation).
   - In `cancelDictation()` (fast-mode branch) and `abortDictation()`, clear both fields.
4. New `DictationStats.swift`:
   ```swift
   enum StatsPeriod: String, CaseIterable, Identifiable {
       case today, week, allTime
       var id: String { rawValue }
       var label: String { switch self { case .today: "Today"; case .week: "This Week"; case .allTime: "All Time" } }
   }

   struct StatsSummary: Equatable {
       var dictations = 0
       var words = 0
       /// Sum of recorded durations. Entries without a duration add nothing here.
       var spokenSeconds: TimeInterval = 0
       /// Words with a recorded duration, at 40 wpm typing, minus spokenSeconds. Never negative.
       var savedSeconds: TimeInterval = 0
   }

   enum DictationStats {
       static let typingWordsPerMinute = 40.0
       static func wordCount(_ text: String) -> Int
       /// today: from startOfDay(now). week: from startOfDay(now - 6 days), so 7 calendar days including today. allTime: everything.
       static func entries(_ entries: [DictationEntry], in period: StatsPeriod, now: Date = Date(), calendar: Calendar = .current) -> [DictationEntry]
       static func summary(_ entries: [DictationEntry]) -> StatsSummary
       /// One bucket per calendar day, oldest first, last bucket is today's day. Days with no entries have 0 words.
       static func wordsPerDay(_ entries: [DictationEntry], days: Int = 7, now: Date = Date(), calendar: Calendar = .current) -> [DayWords]
       /// Words per minute, rounded. nil when seconds < 1.
       static func pace(words: Int, seconds: TimeInterval) -> Int?
   }

   struct DayWords: Identifiable, Equatable {
       var day: Date
       var words: Int
       var id: Date { day }
   }
   ```
   - `savedSeconds` only counts words from entries that have a duration. Add a `// ponytail:` comment: entries without a duration are excluded from spoken and saved time; add an estimate at ~150 wpm if legacy histories matter.
5. Move `HistoryView` and `HistoryDay` verbatim from `DictationHistory.swift` into new `HistoryView.swift`. Update the `recordDictation` call, nothing else in the view changes in this task.
6. Self-tests in `SelfTest.swift`: add `testDictationStats()` to `runSelfTest()` using `precondition`. Use a fixed `now` built with `Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 12))!` so day boundaries are stable. Cover:
   - `wordCount("  hello   world\n") == 2`, `wordCount("") == 0`.
   - `entries(in: .today)` keeps an entry at `now - 3600` and drops one at `now - 86_400 * 2`. `.week` keeps `now - 86_400 * 6` and drops `now - 86_400 * 8`. `.allTime` keeps all.
   - `summary` of `[("one two three four five six seven eight", duration: 6), ("nine ten", duration: nil)]`: `dictations == 2`, `words == 10`, `spokenSeconds == 6`, `savedSeconds == 6` (8 words at 40 wpm = 12 s, minus 6 s).
   - `wordsPerDay(days: 7)` returns 7 buckets, last bucket `== calendar.startOfDay(for: now)`, buckets sum equals the words of entries within the window, and an entry 10 days old is excluded.
   - `pace(words: 140, seconds: 60) == 140`, `pace(words: 5, seconds: 0.5) == nil`.
   - A `DictationEntry` decoded from `{"id":"<uuid>","date":0,"text":"legacy"}` has `duration == nil` and `mode == nil`.

Commit: `Record dictation duration and add stats helpers`.

### Task 2: Rebuild the Home page (Option A)

File: `mac/Sources/OpenVox/ProductWindow.swift` only (`ProductHomeView`, `MetricCard`, `RecentEntryRow`, `EmptyRecentCard`). Do not touch other files.

Layout, top to bottom, inside the existing `ScrollView` with `.padding(32)` and `.frame(maxWidth: 980, alignment: .leading)`:

1. **Toolbar**: `.toolbar { ToolbarItem(placement: .primaryAction) { Picker("Period", selection: $period) { ForEach(StatsPeriod.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented) } }`. `period` is `@AppStorage("homeStatsPeriod") private var periodRaw = StatsPeriod.week.rawValue` with a computed `period` binding. Default is This Week.
2. **Title**: `Text("Home").font(.largeTitle.bold())` and a subtitle with today's date: `Date().formatted(.dateTime.weekday(.wide).month(.wide).day())` in `.secondary`.
3. **Status card**: keep the existing `Status` enum and all its title/detail/symbol/tint logic. Layout: 46 pt circle with symbol on the left, title `.headline` and detail `.subheadline` `.secondary` in the middle. On the right, an `HStack(spacing: 8)`: when ready, an 8 pt green circle with a soft `Color.green.opacity(0.18)` 3 pt halo; then `Text("Shortcut")` caption secondary; then the key name in a chip: `.font(.system(.callout, design: .rounded, weight: .semibold))`, padding 3/8, `.background(.background, in: RoundedRectangle(cornerRadius: 6))`, stroke `Color.primary.opacity(0.12)`. When ready, the detail reads `"Hold your shortcut and speak in any app. \(appState.mode.label), on-device."`.
4. **Stats row**: `HStack(spacing: 14)` of three `MetricCard`s, values from `DictationStats.summary(DictationStats.entries(appState.history, in: period))`:
   - "Words dictated": value `summary.words.formatted()`, footnote `"\(summary.dictations) dictation(s)"` (singular/plural).
   - "Time spoken": value = tile duration format of `spokenSeconds` (show `"0 sec"` when zero). Footnote: `"\(pace) words per minute"` when `DictationStats.pace(words:seconds:)` is non-nil for entries with durations, else `"No timed dictations yet"`.
   - "Time saved": value = tile duration format of `savedSeconds`. Footnote `"vs typing at 40 wpm"`.
   `MetricCard` signature becomes `MetricCard(label:systemImage:value:footnote:)`. Label row on top: 13 pt semibold secondary text with a 13 pt accent symbol. Value `.system(size: 34, weight: .semibold, design: .rounded)` with `.monospacedDigit()`. Footnote `.caption` secondary. Padding 18/20, minHeight 118.
5. **Chart card**: `import Charts`. Card with header row: `Text("Words per day").font(.subheadline.weight(.semibold))` and the date range `"\(first.day.formatted(.dateTime.month(.abbreviated).day())) – \(last.day.formatted(.dateTime.month(.abbreviated).day()))"` in `.caption` secondary. Below, `Chart(DictationStats.wordsPerDay(appState.history)) { item in BarMark(x: .value("Day", item.day, unit: .day), y: .value("Words", item.words)).foregroundStyle(isToday ? Color.accentColor : Color.accentColor.opacity(0.28)).cornerRadius(5) }` with `.chartXAxis { AxisMarks(values: .stride(by: .day)) { AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }`, `.chartYAxis(.hidden)`, `.frame(height: 96)`. The chart card is always shown, even with no data. Padding 16/20.
6. **Recent**: header `HStack` with `Text("Recent").font(.title3.bold())` and a plain "See All" button (calls `openHistory`) when history is non-empty. Then a card containing up to 5 newest entries, each `RecentEntryRow`: text `.body` `lineLimit(1)` truncating; then `Spacer`; then meta `"\(words) words · \(clock)"` in `.caption` `.tertiary` (omit the `· clock` part when duration is nil); then time `entry.date.formatted(date: .omitted, time: .shortened)` in `.caption` `.secondary` `frame(width: 64, alignment: .trailing)`. Rows have `padding(.vertical, 12)`, dividers between rows (no leading inset). Drop the waveform icon. Keep `EmptyRecentCard` when history is empty.

Run `swift build && .build/debug/OpenVox --selftest` from `mac/`. Commit: `Rebuild Home with period stats and activity chart`.

### Task 3: Rebuild the History page as a split view (Option A)

File: `mac/Sources/OpenVox/HistoryView.swift` only (created by Task 1). Do not touch other files. Reuse `DictationStats.wordCount`, `appState.deleteDictation`, and the existing `dayLabel(for:)` helper.

1. **Frame**: `.navigationTitle("History")` and `.navigationSubtitle("\(count) dictation(s)")` (subtitle omitted when empty). Keep `.searchable(text: $searchText, prompt: "Search dictations")`. Keep the existing confirmation dialog for Clear History.
2. **Empty states**: history empty → the existing `ContentUnavailableView("No Dictations Yet", …)` fills the whole page. Search with no results → existing "No Results" view fills the list column while the detail column shows the placeholder from step 5.
3. **Split**: `HSplitView` with the list column `.frame(minWidth: 300, idealWidth: 360, maxWidth: 440)` and the detail column `.frame(minWidth: 380, maxWidth: .infinity)`.
4. **List column**: `List(selection: $selectedID)` where `@State private var selectedID: DictationEntry.ID?`. `.listStyle(.plain)`. Sections per day (reuse `groupedEntries`). Section header: day label `.caption.weight(.semibold)` secondary, then `"\(entries.count) · \(words) words"` in `.caption2` tertiary, `.textCase(nil)`. Row (`.tag(entry.id)`): `VStack(alignment: .leading, spacing: 4)` with an `HStack(alignment: .top)` of the text (`.body`, `lineLimit(2)`) and the time (`.caption` secondary, `layoutPriority(1)`), then a meta line `"\(words) words · \(clock)"` in `.caption2` tertiary (omit `· clock` when duration is nil). Row padding vertical 6. Selection colors come from the system; do not set custom row backgrounds.
   Auto-select: on appear and whenever `visibleEntries` changes, if `selectedID` is nil or not in `visibleEntries`, set it to the first visible entry's id (newest).
5. **Detail column**: when the selected entry exists:
   - Header `HStack(alignment: .top)`: left `VStack` with `dayLabel(for: entry.date)` in `.subheadline` secondary and the time `.title2.bold()`; right `HStack(spacing: 8)` with a Copy button (bordered, shows "Copied" with a checkmark for 1.5 s, reuse the existing pasteboard code) and a Delete button (bordered, calls `appState.deleteDictation(entry.id)`).
   - Body: `ScrollView` with `Text(entry.text).font(.system(size: 16)).lineSpacing(4).textSelection(.enabled).frame(maxWidth: 560, alignment: .leading)`.
   - Facts row `HStack(spacing: 28)` of `Fact(key:value:)`: "Words" → count; "Duration" → `Duration.seconds(d).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))` or "—"; "Pace" → `"\(wpm) wpm"` via `DictationStats.pace` or "—"; "Mode" → "Fast" / "Streaming" from `entry.mode` ("fast" → Fast, "streaming" → Streaming) or "—". Key: `.caption2.weight(.semibold)` tertiary uppercase; value `.callout.weight(.medium)`.
   - Padding 30 horizontal, 26 top.
   When nothing is selected: `ContentUnavailableView("Select a Dictation", systemImage: "text.alignleft", description: Text("Pick an entry to read or copy it."))`.
6. **Footer** under the whole split, full width, with a top `Divider`: `Text("Keeping dictations for \(retentionPhrase)")` where days7 → "7 days", days30 → "30 days", forever → "all time"; `Spacer`; the existing destructive "Clear History…" button. `.font(.caption)` secondary, padding 18/10.
7. Remove the old header block (the icon, "History" title, subtitle, and count capsule) and the old footer; the navigation title and new footer replace them.

Run `swift build && .build/debug/OpenVox --selftest` from `mac/`. Commit: `Rebuild History as a split view with details`.
