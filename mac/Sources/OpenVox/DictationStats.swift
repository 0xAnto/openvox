import Foundation

/// The window the Home page reports on.
enum StatsPeriod: String, CaseIterable, Identifiable {
    case today, week, allTime

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: "Today"
        case .week: "This Week"
        case .allTime: "All Time"
        }
    }
}

/// What one period adds up to.
struct StatsSummary: Equatable {
    var dictations = 0
    var words = 0
    /// Sum of every recorded duration, long sessions included. The Time spoken
    /// tile reports real time, so it must not drop anything.
    var spokenSeconds: TimeInterval = 0
    /// Typing time saved against 40 wpm, clamped per entry. Never negative.
    var savedSeconds: TimeInterval = 0
    /// Words of the entries that set the pace: a duration exists and it is at
    /// most `DictationStats.pacedDurationLimit`.
    var timedWords = 0
    /// Seconds of those same entries.
    var timedSeconds: TimeInterval = 0
}

/// One calendar day of the activity chart.
struct DayWords: Identifiable, Equatable {
    var day: Date
    var words: Int

    var id: Date { day }
}

/// Pure history arithmetic. Every function takes the clock and the calendar,
/// so --selftest can pin a day boundary without touching either.
enum DictationStats {
    static let typingWordsPerMinute = 40.0

    /// A recording longer than this is an idle session, not speech. It still
    /// counts as spoken time, but it never sets the pace or the time saved.
    static let pacedDurationLimit: TimeInterval = 600

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// today: from startOfDay(now). week: from startOfDay(now - 6 days), so
    /// 7 calendar days including today. allTime: everything.
    static func entries(_ entries: [DictationEntry], in period: StatsPeriod, now: Date = Date(), calendar: Calendar = .current) -> [DictationEntry] {
        let start: Date?
        switch period {
        case .today: start = calendar.startOfDay(for: now)
        case .week: start = calendar.date(byAdding: .day, value: -6, to: now).map(calendar.startOfDay(for:))
        case .allTime: start = nil
        }
        guard let start else { return entries }
        return entries.filter { $0.date >= start }
    }

    static func summary(_ entries: [DictationEntry]) -> StatsSummary {
        var summary = StatsSummary()

        for entry in entries {
            let words = wordCount(entry.text)
            summary.dictations += 1
            summary.words += words
            // ponytail: an entry without a duration adds nothing to spoken
            // or saved time. Estimate its duration at ~150 wpm if legacy
            // histories matter.
            guard let duration = entry.duration else { continue }
            summary.spokenSeconds += duration
            guard duration <= pacedDurationLimit else { continue }
            summary.timedWords += words
            summary.timedSeconds += duration
            // Clamp each entry on its own. One long idle recording then costs
            // its own saving only, instead of zeroing the whole tile.
            summary.savedSeconds += max(0, Double(words) / typingWordsPerMinute * 60 - duration)
        }

        return summary
    }

    /// One bucket per calendar day, oldest first, last bucket is today's day.
    /// Days with no entries have 0 words.
    static func wordsPerDay(_ entries: [DictationEntry], days: Int = 7, now: Date = Date(), calendar: Calendar = .current) -> [DayWords] {
        let today = calendar.startOfDay(for: now)
        var words: [Date: Int] = [:]
        for entry in entries {
            words[calendar.startOfDay(for: entry.date), default: 0] += wordCount(entry.text)
        }
        return (0..<max(0, days)).reversed().compactMap { daysBack in
            guard let day = calendar.date(byAdding: .day, value: -daysBack, to: today) else { return nil }
            // Normalize again. A zone that changes its offset at midnight has
            // days whose 00:00 never happens, so date(byAdding:) keeps the
            // wall clock of `today` and misses every entry key.
            let start = calendar.startOfDay(for: day)
            return DayWords(day: start, words: words[start] ?? 0)
        }
    }

    /// Words per minute, rounded. Nil when seconds < 1.
    static func pace(words: Int, seconds: TimeInterval) -> Int? {
        guard seconds >= 1 else { return nil }
        return Int((Double(words) / seconds * 60).rounded())
    }
}
