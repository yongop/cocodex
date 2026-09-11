import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) throws {
    if try condition() == false { throw CheckFailure(description: "\(file):\(line): expectation failed") }
}

func expectThrows<E: Error & Equatable>(_ expected: E, body: () throws -> Void) throws {
    do { try body() }
    catch let error as E {
        try expect(error == expected)
        return
    }
    catch { throw CheckFailure(description: "Expected \(expected), received \(error)") }
    throw CheckFailure(description: "Expected \(expected), but no error was thrown")
}

@main
struct Checks {
    static func main() async {
        do { try await run() }
        catch { print("FAIL: \(error)"); exit(1) }
    }

    static func run() async throws {
        let models = UsageModelsTests()
        let rpc = RPCSessionTests()
        let periods = PeriodAndCreditTests()
        let local = LocalTokenTests()
        let limits = LimitUsageHistoryTests()
        let daily = DailyHistoryTests()
        let checks: [(String, () throws -> Void)] = [
            ("daily rollup preserves midnight, zero, missing coverage and codec", daily.midnightZeroMissingResetAndCodec),
            ("daily rollup DST, time-zone changes and retention", daily.dstTimeZoneAndRetention),
            ("daily rollup matches both windows across resets and gaps", daily.mixedWindowsMatchOriginalQueries),
            ("idle compaction preserves coverage and gaps", limits.idleCompactionPreservesCoverageAndGaps),
            ("linear aggregation matches reference", limits.linearAggregationMatchesReference),
            ("limit baseline, zero and window isolation", limits.baselineZeroAndWindowIsolation),
            ("limit interpolation across midnight", limits.interpolationAcrossMidnight),
            ("limit resets, gaps and invalid observations", limits.resetsGapsAndInvalidObservations),
            ("limit multiple periods, persistence and retention", limits.multiplePeriodsPersistenceAndRetention),
            ("limit daylight saving hours", limits.daylightSavingHours),
            ("cumulative local tokens and repeats", local.cumulativeAndRepeatedEvents),
            ("local day boundary and inherited tokens", local.dayBoundaryAndForkBaseline),
            ("today comparison and stale estimate", local.comparisonAndStaleDay),
            ("daily credit blocks", periods.dailyCreditBlocks),
            ("time ring bounds", periods.remainingTimeRing),
            ("two past periods and persistence", periods.historyKeepsTwoPastPeriods),
            ("early reset and absent history", periods.earlyResetAndMissingHistory),
            ("three-week calendar and DST", periods.calendarCrossesMonthAndDST),
            ("partial calendar days", periods.partialDayAndEndBoundary),
            ("authoritative credit count", periods.creditCountIsNotDetailCount),
            ("credit expiry and progress", periods.creditExpirySortingAndProgress),
            ("modern buckets", models.modernBucketsTakePriority),
            ("unrelated model isolation", models.unrelatedBucketDoesNotBecomeCodex),
            ("legacy and reversed windows", models.legacyAndReversedWindows),
            ("unknown quota", models.unknownQuotaRemainsUnknown),
            ("percentage bounds", {
                for (used, expected) in [(-15.0, 100.0), (150.0, 0.0), (100.0, 0.0), (0.0, 100.0)] {
                    try models.percentIsClamped(used: used, expected: expected)
                }
            }),
            ("expired reset", models.resetUsesSecondsAndDoesNotInventFreshQuota),
            ("window labels", models.shortWindowIsNotMislabeledAsWeekly),
            ("missing day versus zero", models.missingTokenDayDiffersFromZero),
            ("null token summary", models.nullTokenSummaryAndFormatting),
            ("executable override", models.invalidExecutableOverrideIsAnError),
            ("partial frames and notifications", rpc.fragmentedResponseAndNotification),
            ("sanitized errors", rpc.serverErrorIsSanitized),
            ("timeout", rpc.unresponsiveProcessTimesOut),
            ("unexpected EOF", rpc.unexpectedEOFIsHandled),
            ("handshake and read-only requests", rpc.initializationAndReadOnlyRejection),
        ]
        for (name, run) in checks {
            try run()
            print("PASS \(name)")
        }
        try await local.fileScanningAndCache()
        print("PASS local file scanning, deduplication and cache")
        try await local.incrementalAppendRewriteAndBoundedTail()
        print("PASS incremental append, rewrite, truncation, bounded tail and cancellation")
        try await UsageHistoryPersistenceTests().accountsRestorationAndExpiry()
        print("PASS persistence, account isolation, restoration and expiry")
        try await daily.migrationAndImmutableArchives()
        print("PASS migration and immutable day files")
        try await daily.interruptedCommitRecoveryAndCorruption()
        print("PASS interrupted commit recovery and archive corruption")
        try await daily.failedRolloverRetriesWithoutLosingRawData()
        print("PASS rollover retry preserves raw data and prunes expired accounts")
        print("\(checks.count + 6) checks passed.")
    }
}
