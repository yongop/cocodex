import Foundation

extension LimitUsageHistory {
    /// Resolve overlapping coverage before integration. Raw observations take precedence over
    /// old 15-minute summaries; overlapping legacy summaries use the best observed coverage.
    /// The sweep is O(n log n), with only the overlapping devices in the active set.
    func mergedBins(_ intervals: [DateInterval], minutes: Int, archives: [LimitUsageDay]) -> [Bin] {
        struct Segment {
            let start: Date
            let end: Date
            let rate: Double
            let coverage: Double
            let raw: Bool
        }
        struct Edge {
            let date: Date
            let index: Int
            let begins: Bool
        }
        guard let first = intervals.first, let last = intervals.last else { return [] }
        var segments: [Segment] = []
        for day in archives where day.end > first.start && day.start < last.end {
            guard let window = day.windows.first(where: { $0.minutes == minutes }) else { continue }
            for index in window.used.indices where window.observed[index] > 0 {
                let start = day.start.addingTimeInterval(Double(index) * 900)
                let end = min(day.end, start.addingTimeInterval(900))
                let duration = end.timeIntervalSince(start)
                guard duration > 0, end > first.start, start < last.end else { continue }
                segments.append(Segment(start: start, end: end, rate: window.used[index] / duration,
                                        coverage: min(1, window.observed[index] / duration), raw: false))
            }
        }
        let archiveCount = segments.count
        for (before, after) in zip(observations, observations.dropFirst()) {
            let duration = after.date.timeIntervalSince(before.date)
            guard duration > 0, duration <= Self.maximumGap, after.date > first.start, before.date < last.end,
                  let a = before.windows.first(where: { $0.minutes == minutes }),
                  let b = after.windows.first(where: { $0.minutes == minutes }),
                  a.reset == b.reset, after.date < a.reset, a.remaining >= b.remaining else { continue }
            segments.append(Segment(start: before.date, end: after.date,
                                    rate: (a.remaining - b.remaining) / duration, coverage: 1, raw: true))
        }
        // A legacy bucket contains a total, not a measured uniform rate. If raw data
        // refines only part of it, put the remaining total in the uncovered portion.
        // Simply clipping a uniform archive rate would lose usage near midnight.
        let raw = Array(segments.dropFirst(archiveCount))
        for index in 0..<archiveCount {
            let segment = segments[index]
            var lower = 0, upper = raw.count
            while lower < upper {
                let mid = (lower + upper) / 2
                if raw[mid].end <= segment.start { lower = mid + 1 } else { upper = mid }
            }
            var covered = 0.0, used = 0.0
            var cursor = lower
            while cursor < raw.count && raw[cursor].start < segment.end {
                let overlap = max(0, min(segment.end, raw[cursor].end)
                    .timeIntervalSince(max(segment.start, raw[cursor].start)))
                covered += overlap
                used += overlap * raw[cursor].rate
                cursor += 1
            }
            let duration = segment.end.timeIntervalSince(segment.start)
            let remaining = duration - covered
            if covered > 0 && remaining > 0 {
                segments[index] = Segment(start: segment.start, end: segment.end,
                    rate: max(0, segment.rate * duration - used) / remaining,
                    coverage: min(1, max(0, segment.coverage * duration - covered) / remaining), raw: false)
            }
        }
        let edges = segments.enumerated().flatMap { index, segment in
            [Edge(date: segment.start, index: index, begins: true),
             Edge(date: segment.end, index: index, begins: false)]
        }.sorted { $0.date < $1.date }
        var result = intervals.map { Bin(start: $0.start, end: $0.end) }
        var active = Set<Int>()
        var cursor = 0
        var destination = 0
        while cursor < edges.count {
            let start = edges[cursor].date
            while cursor < edges.count, edges[cursor].date == start {
                let edge = edges[cursor]
                if edge.begins { active.insert(edge.index) } else { active.remove(edge.index) }
                cursor += 1
            }
            guard cursor < edges.count else { break }
            let end = edges[cursor].date
            guard let winner = active.max(by: { a, b in
                let lhs = segments[a], rhs = segments[b]
                if lhs.raw != rhs.raw { return !lhs.raw }
                if lhs.coverage != rhs.coverage { return lhs.coverage < rhs.coverage }
                if lhs.rate != rhs.rate { return lhs.rate < rhs.rate }
                return a < b
            }) else { continue }
            let segment = segments[winner]
            while destination < result.count && result[destination].end <= start { destination += 1 }
            var index = destination
            while index < result.count && result[index].start < end {
                let overlap = min(end, result[index].end).timeIntervalSince(max(start, result[index].start))
                if overlap > 0 {
                    result[index].usedPercent = (result[index].usedPercent ?? 0) + segment.rate * overlap
                    result[index].observedSeconds += segment.coverage * overlap
                }
                index += 1
            }
        }
        return result
    }
}
