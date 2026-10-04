import Foundation

/// One model × reasoning-effort total captured alongside the official Codex
/// weekly percentage. These totals come from local rollout token_count events.
struct QuotaEfficiencyVariantTotal: Codable, Equatable {
    let id: String
    let model: String
    let effort: String
    let usage: PricedTokenUsage
}

struct QuotaEfficiencyCheckpoint: Codable, Equatable {
    let capturedAt: Date
    let weeklyUsedPercent: Double
    let weeklyResetsAt: Date
    /// All detailed Codex usage in the same rolling local history, including
    /// models with no reasoning_effort field (for example auxiliary/review
    /// traffic). This is the denominator used by the dominance guard.
    let allUsage: PricedTokenUsage
    let variants: [QuotaEfficiencyVariantTotal]
}

struct QuotaEfficiencyVariantSummary: Identifiable, Equatable {
    let id: String
    let model: String
    let effort: String
    let sampleCount: Int
    let measuredQuotaPercent: Double
    let measuredUsage: PricedTokenUsage
    let projectedWeeklyTokens: Double
    let dominantShareAverage: Double
    let latestSampleAt: Date

    var tokensPerQuotaPercent: Double {
        guard measuredQuotaPercent > 0 else { return 0 }
        return Double(measuredUsage.tokens.visibleTotalTokens) / measuredQuotaPercent
    }

    var cacheHitPercent: Double? {
        let input = measuredUsage.tokens.inputTokens
        guard input > 0 else { return nil }
        return Double(measuredUsage.tokens.billableCachedInputTokens) / Double(input) * 100
    }

    var outputSharePercent: Double? {
        let total = measuredUsage.tokens.visibleTotalTokens
        guard total > 0 else { return nil }
        return Double(max(measuredUsage.tokens.outputTokens, 0)) / Double(total) * 100
    }

    var confidence: QuotaEfficiencyConfidence {
        if sampleCount >= 3, measuredQuotaPercent >= 15, dominantShareAverage >= 0.97 {
            return .high
        }
        if sampleCount >= 2, measuredQuotaPercent >= 7, dominantShareAverage >= 0.93 {
            return .medium
        }
        return .early
    }
}

enum QuotaEfficiencyConfidence: String, Equatable {
    case early
    case medium
    case high
}

private struct QuotaEfficiencyObservation {
    let variant: QuotaEfficiencyVariantTotal
    let quotaDeltaPercent: Double
    let usageDelta: PricedTokenUsage
    let dominantShare: Double
    let capturedAt: Date
}

private struct QuotaEfficiencyDiskState: Codable {
    let version: Int
    var checkpoints: [QuotaEfficiencyCheckpoint]
}

/// Persists sparse checkpoints only when the official 7-day percentage moves.
///
/// The resulting efficiency estimate is intentionally conservative: a quota
/// interval is attributed to a reasoning variant only when that variant owns at
/// least 90% of all measured reasoning-variant token growth in the interval.
/// Mixed-model / mixed-effort periods are retained as checkpoints but excluded
/// from the efficiency estimate rather than being guessed.
final class QuotaEfficiencyHistoryStore {
    static let shared = QuotaEfficiencyHistoryStore()

    private let fileManager = FileManager.default
    private let stateVersion = 1
    private let maximumCheckpoints = 512
    private let minimumQuotaStep = 0.5
    private let minimumVariantTokens: Int64 = 500_000
    private let minimumDominantShare = 0.90
    private let resetTolerance: TimeInterval = 15 * 60

    private init() {}

    func record(runtime: RuntimeUsageSnapshot, at date: Date) -> [QuotaEfficiencyVariantSummary] {
        guard runtime.scope == .codex,
              runtime.status == .available,
              runtime.snapshot.quotaReadSucceeded,
              let weekly = runtime.snapshot.sevenDayQuota,
              let reset = weekly.resetsAt,
              let trend = runtime.snapshot.local?.usageTrend,
              trend.sourceQuality == .detailed,
              let modelTrends = trend.modelTrends
        else {
            return loadSummaries()
        }

        let variants = variantTotals(from: modelTrends)
        guard !variants.isEmpty else { return loadSummaries() }

        let allUsage = trend.dayBuckets.reduce(into: PricedTokenUsage.zero) { result, bucket in
            result.add(
                tokens: bucket.usage.tokens,
                costUSD: bucket.usage.estimatedCostUSD,
                usesReferencePricing: bucket.usage.usesReferencePricing
            )
        }
        let checkpoint = QuotaEfficiencyCheckpoint(
            capturedAt: date,
            weeklyUsedPercent: max(0, min(100, weekly.usedPercent)),
            weeklyResetsAt: reset,
            allUsage: allUsage,
            variants: variants
        )

        var state = loadState()
        if let last = state.checkpoints.last {
            let sameCycle = abs(last.weeklyResetsAt.timeIntervalSince(checkpoint.weeklyResetsAt)) <= resetTolerance
            let quotaStep = checkpoint.weeklyUsedPercent - last.weeklyUsedPercent

            if sameCycle, quotaStep >= 0, quotaStep < minimumQuotaStep {
                // Keep the earlier token baseline until the provider percentage
                // advances. This avoids turning rounded 7-day percentages into
                // many tiny, noisy pseudo-samples.
                return summaries(from: state.checkpoints)
            }

            if !sameCycle || quotaStep < -minimumQuotaStep {
                // A new reset window starts a new baseline. No cross-window
                // observation is ever created.
                state.checkpoints.append(checkpoint)
            } else if quotaStep >= minimumQuotaStep {
                state.checkpoints.append(checkpoint)
            } else {
                return summaries(from: state.checkpoints)
            }
        } else {
            state.checkpoints.append(checkpoint)
        }

        if state.checkpoints.count > maximumCheckpoints {
            state.checkpoints.removeFirst(state.checkpoints.count - maximumCheckpoints)
        }
        saveState(state)
        return summaries(from: state.checkpoints)
    }

    func loadSummaries() -> [QuotaEfficiencyVariantSummary] {
        summaries(from: loadState().checkpoints)
    }

    private func variantTotals(from trends: [ModelUsageTrend]) -> [QuotaEfficiencyVariantTotal] {
        trends.compactMap { trend in
            guard let parsed = ModelVariantUsageSummaryBuilder.parseVariantID(trend.id) else {
                return nil
            }
            var usage = PricedTokenUsage.zero
            for bucket in trend.dayBuckets {
                usage.add(
                    tokens: bucket.usage.tokens,
                    costUSD: bucket.usage.estimatedCostUSD,
                    usesReferencePricing: bucket.usage.usesReferencePricing
                )
            }
            guard usage.tokens.visibleTotalTokens > 0 else { return nil }
            return QuotaEfficiencyVariantTotal(
                id: trend.id,
                model: parsed.model,
                effort: parsed.effort,
                usage: usage
            )
        }
        .sorted { $0.id < $1.id }
    }

    private func summaries(from checkpoints: [QuotaEfficiencyCheckpoint]) -> [QuotaEfficiencyVariantSummary] {
        guard checkpoints.count >= 2 else { return [] }

        var observations: [QuotaEfficiencyObservation] = []
        for index in 1..<checkpoints.count {
            if let observation = makeObservation(
                previous: checkpoints[index - 1],
                current: checkpoints[index]
            ) {
                observations.append(observation)
            }
        }

        struct Accumulator {
            var variant: QuotaEfficiencyVariantTotal
            var sampleCount = 0
            var quota = 0.0
            var usage = PricedTokenUsage.zero
            var dominantShareTotal = 0.0
            var latestSampleAt: Date?
        }

        var grouped: [String: Accumulator] = [:]
        for observation in observations {
            var accumulator = grouped[observation.variant.id]
                ?? Accumulator(variant: observation.variant)
            accumulator.sampleCount += 1
            accumulator.quota += observation.quotaDeltaPercent
            accumulator.usage.add(
                tokens: observation.usageDelta.tokens,
                costUSD: observation.usageDelta.estimatedCostUSD,
                usesReferencePricing: observation.usageDelta.usesReferencePricing
            )
            accumulator.dominantShareTotal += observation.dominantShare
            accumulator.latestSampleAt = max(
                accumulator.latestSampleAt ?? observation.capturedAt,
                observation.capturedAt
            )
            grouped[observation.variant.id] = accumulator
        }

        return grouped.values.compactMap { value in
            guard value.quota > 0,
                  value.usage.tokens.visibleTotalTokens > 0,
                  let latestSampleAt = value.latestSampleAt
            else { return nil }
            let projected = Double(value.usage.tokens.visibleTotalTokens) / value.quota * 100
            return QuotaEfficiencyVariantSummary(
                id: value.variant.id,
                model: value.variant.model,
                effort: value.variant.effort,
                sampleCount: value.sampleCount,
                measuredQuotaPercent: value.quota,
                measuredUsage: value.usage,
                projectedWeeklyTokens: projected,
                dominantShareAverage: value.sampleCount > 0
                    ? value.dominantShareTotal / Double(value.sampleCount)
                    : 0,
                latestSampleAt: latestSampleAt
            )
        }
        .sorted {
            if $0.model != $1.model { return $0.model < $1.model }
            return effortRank($0.effort) > effortRank($1.effort)
        }
    }

    private func makeObservation(
        previous: QuotaEfficiencyCheckpoint,
        current: QuotaEfficiencyCheckpoint
    ) -> QuotaEfficiencyObservation? {
        guard abs(previous.weeklyResetsAt.timeIntervalSince(current.weeklyResetsAt)) <= resetTolerance else {
            return nil
        }
        let quotaDelta = current.weeklyUsedPercent - previous.weeklyUsedPercent
        guard quotaDelta >= minimumQuotaStep else { return nil }

        let previousByID = Dictionary(uniqueKeysWithValues: previous.variants.map { ($0.id, $0) })
        var deltas: [(variant: QuotaEfficiencyVariantTotal, usage: PricedTokenUsage)] = []

        for currentVariant in current.variants {
            let oldUsage = previousByID[currentVariant.id]?.usage ?? .zero
            let tokenDelta = currentVariant.usage.tokens.delta(from: oldUsage.tokens)

            // A rolling-history boundary can make an old bucket leave the local
            // trend. Do not turn that into a negative usage interval.
            guard tokenDelta.inputTokens >= 0,
                  tokenDelta.cachedInputTokens >= 0,
                  tokenDelta.cacheWriteInputTokens >= 0,
                  tokenDelta.outputTokens >= 0,
                  tokenDelta.totalTokens >= 0
            else {
                return nil
            }

            let visible = tokenDelta.visibleTotalTokens
            guard visible > 0 else { continue }

            deltas.append((
                variant: currentVariant,
                usage: PricedTokenUsage(
                    tokens: tokenDelta,
                    estimatedCostUSD: max(
                        0,
                        currentVariant.usage.estimatedCostUSD - oldUsage.estimatedCostUSD
                    ),
                    usesReferencePricing: currentVariant.usage.usesReferencePricing
                        || oldUsage.usesReferencePricing
                )
            ))
        }

        let allTokenDelta = current.allUsage.tokens.delta(from: previous.allUsage.tokens)
        guard allTokenDelta.inputTokens >= 0,
              allTokenDelta.cachedInputTokens >= 0,
              allTokenDelta.cacheWriteInputTokens >= 0,
              allTokenDelta.outputTokens >= 0,
              allTokenDelta.totalTokens >= 0
        else {
            return nil
        }
        let totalTokens = allTokenDelta.visibleTotalTokens
        guard totalTokens > 0,
              let dominant = deltas.max(by: {
                  $0.usage.tokens.visibleTotalTokens < $1.usage.tokens.visibleTotalTokens
              })
        else {
            return nil
        }

        let dominantTokens = dominant.usage.tokens.visibleTotalTokens
        // A variant cannot grow by more than all detailed usage combined.
        // Reject inconsistent rolling-history or reclassification deltas.
        guard dominantTokens <= totalTokens else { return nil }
        let dominantShare = Double(dominantTokens) / Double(totalTokens)
        guard dominantTokens >= minimumVariantTokens,
              dominantShare >= minimumDominantShare
        else {
            // Mixed intervals are deliberately not apportioned across variants.
            return nil
        }

        return QuotaEfficiencyObservation(
            variant: dominant.variant,
            quotaDeltaPercent: quotaDelta,
            usageDelta: dominant.usage,
            dominantShare: dominantShare,
            capturedAt: current.capturedAt
        )
    }

    private func loadState() -> QuotaEfficiencyDiskState {
        let url = stateURL()
        guard let data = try? Data(contentsOf: url),
              data.count <= 4 * 1_024 * 1_024,
              let state = try? JSONDecoder().decode(QuotaEfficiencyDiskState.self, from: data),
              state.version == stateVersion
        else {
            return QuotaEfficiencyDiskState(version: stateVersion, checkpoints: [])
        }
        return state
    }

    private func saveState(_ state: QuotaEfficiencyDiskState) {
        let url = stateURL()
        let directory = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            // Efficiency history is optional analytics. A write failure must
            // never affect quota/token display or the main refresh path.
        }
    }

    private func stateURL() -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent(CodexUOwnedPaths.directoryName, isDirectory: true)
            .appendingPathComponent("quota-efficiency-v1.json")
    }

    private func effortRank(_ effort: String) -> Int {
        switch effort.lowercased() {
        case "max": return 5
        case "xhigh": return 4
        case "high": return 3
        case "medium": return 2
        case "low": return 1
        default: return 0
        }
    }

    static func selfTest() -> Bool {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        func usage(total: Int64, input: Int64, cached: Int64, output: Int64) -> PricedTokenUsage {
            PricedTokenUsage(
                tokens: TokenBreakdown(
                    inputTokens: input,
                    cachedInputTokens: cached,
                    outputTokens: output,
                    reasoningOutputTokens: 0,
                    totalTokens: total
                ),
                estimatedCostUSD: Double(total) / 1_000_000 * 0.25
            )
        }

        let reset = Date(timeIntervalSince1970: 2_000_000_000)
        let high0 = QuotaEfficiencyVariantTotal(
            id: "gpt-6-sol::effort=high",
            model: "gpt-6-sol",
            effort: "high",
            usage: usage(total: 10_000_000, input: 9_900_000, cached: 9_700_000, output: 100_000)
        )
        let high1 = QuotaEfficiencyVariantTotal(
            id: high0.id,
            model: high0.model,
            effort: high0.effort,
            usage: usage(total: 35_000_000, input: 34_750_000, cached: 34_000_000, output: 250_000)
        )
        let max0 = QuotaEfficiencyVariantTotal(
            id: "gpt-6-sol::effort=max",
            model: "gpt-6-sol",
            effort: "max",
            usage: usage(total: 5_000_000, input: 4_950_000, cached: 4_850_000, output: 50_000)
        )
        let max1 = QuotaEfficiencyVariantTotal(
            id: max0.id,
            model: max0.model,
            effort: max0.effort,
            usage: usage(total: 5_500_000, input: 5_445_000, cached: 5_335_000, output: 55_000)
        )

        let first = QuotaEfficiencyCheckpoint(
            capturedAt: reset.addingTimeInterval(-3600),
            weeklyUsedPercent: 20,
            weeklyResetsAt: reset,
            allUsage: usage(total: 15_000_000, input: 14_850_000, cached: 14_550_000, output: 150_000),
            variants: [high0, max0]
        )
        let second = QuotaEfficiencyCheckpoint(
            capturedAt: reset.addingTimeInterval(-1800),
            weeklyUsedPercent: 30,
            weeklyResetsAt: reset,
            allUsage: usage(total: 40_500_000, input: 40_195_000, cached: 39_335_000, output: 305_000),
            variants: [high1, max1]
        )

        let store = QuotaEfficiencyHistoryStore()
        let observation = store.makeObservation(previous: first, current: second)
        expect(observation?.variant.effort == "high",
               "a dominant High interval should be attributed to High")
        expect(abs((observation?.quotaDeltaPercent ?? 0) - 10) < 0.000_001,
               "weekly quota delta should be measured from official percentages")
        expect(observation?.usageDelta.tokens.visibleTotalTokens == 25_000_000,
               "variant token delta should use local cumulative rollout totals")

        let mixed = QuotaEfficiencyCheckpoint(
            capturedAt: reset.addingTimeInterval(-900),
            weeklyUsedPercent: 40,
            weeklyResetsAt: reset,
            allUsage: usage(total: 61_000_000, input: 60_490_000, cached: 59_200_000, output: 510_000),
            variants: [
                QuotaEfficiencyVariantTotal(
                    id: high0.id,
                    model: high0.model,
                    effort: high0.effort,
                    usage: usage(total: 45_000_000, input: 44_650_000, cached: 43_700_000, output: 350_000)
                ),
                QuotaEfficiencyVariantTotal(
                    id: max0.id,
                    model: max0.model,
                    effort: max0.effort,
                    usage: usage(total: 15_500_000, input: 15_345_000, cached: 15_000_000, output: 155_000)
                )
            ]
        )
        expect(store.makeObservation(previous: second, current: mixed) == nil,
               "mixed High/Max intervals should not be guessed or apportioned")

        let auxiliaryMixed = QuotaEfficiencyCheckpoint(
            capturedAt: reset.addingTimeInterval(-600),
            weeklyUsedPercent: 35,
            weeklyResetsAt: reset,
            allUsage: usage(total: 55_500_000, input: 55_095_000, cached: 53_900_000, output: 405_000),
            variants: [
                QuotaEfficiencyVariantTotal(
                    id: high0.id,
                    model: high0.model,
                    effort: high0.effort,
                    usage: usage(total: 45_000_000, input: 44_650_000, cached: 43_700_000, output: 350_000)
                ),
                max1
            ]
        )
        expect(store.makeObservation(previous: second, current: auxiliaryMixed) == nil,
               "non-effort traffic must count in the dominance denominator")

        let reclassifiedBaseline = QuotaEfficiencyCheckpoint(
            capturedAt: reset.addingTimeInterval(-3600),
            weeklyUsedPercent: 20,
            weeklyResetsAt: reset,
            allUsage: usage(total: 20_000_000, input: 19_800_000, cached: 19_400_000, output: 200_000),
            variants: [high0, max0]
        )
        let reclassifiedCurrent = QuotaEfficiencyCheckpoint(
            capturedAt: reset.addingTimeInterval(-1800),
            weeklyUsedPercent: 30,
            weeklyResetsAt: reset,
            allUsage: usage(total: 21_000_000, input: 20_790_000, cached: 20_370_000, output: 210_000),
            variants: [
                QuotaEfficiencyVariantTotal(
                    id: high0.id,
                    model: high0.model,
                    effort: high0.effort,
                    usage: usage(total: 12_000_000, input: 11_880_000, cached: 11_640_000, output: 120_000)
                ),
                max0
            ]
        )
        expect(store.makeObservation(previous: reclassifiedBaseline, current: reclassifiedCurrent) == nil,
               "variant growth larger than all-usage growth must not become a greater-than-100% dominance sample")

        let summaries = store.summaries(from: [first, second])
        expect(summaries.count == 1 && summaries[0].effort == "high",
               "clean interval should produce one High efficiency summary")
        expect(abs(summaries[0].projectedWeeklyTokens - 250_000_000) < 1,
               "25M tokens over 10% quota should project to 250M/week")
        expect(summaries[0].latestSampleAt == second.capturedAt,
               "summary should expose the capture time of its latest valid interval")
        expect(store.summaries(from: [first, second, mixed]).first?.latestSampleAt == second.capturedAt,
               "a later rejected interval must not change the latest valid sample time")

        if failures.isEmpty {
            print("quota efficiency self-test passed")
            return true
        }
        failures.forEach { print("quota efficiency self-test failed: \($0)") }
        return false
    }
}
