import AppKit
import Darwin
import Foundation
import SwiftUI
import TokenBarCore

// Logic checks for the pure TokenBarCore ports, run via `TokenBar --selftest`.
// Plain assertions instead of swift-testing/XCTest because the dev machine has
// Command Line Tools only (no testing modules); CI runs this the same way.

private final class AsyncResultBox<Value: Sendable>: @unchecked Sendable {
    var result: Result<Value, Error>?
}

private actor ThrottleCallCounter {
    private(set) var count = 0
    func bump() { count += 1 }
    func reset() { count = 0 }
}

/// A settable clock, so the test can move time across a fetch rather than
/// sleep. The throttle reads it on the main actor and inside its own actor, and
/// the fetch closures that advance it do so before returning, so there is no
/// concurrent access to protect against — hence the plain class.
private final class ThrottleClock: @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
}

/// Holds a fetch open so concurrent arrivals overlap deterministically.
private actor ThrottleGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor ControlledTurnUsageDataSource: UsageDataSource {
    private struct PendingHourly {
        let clients: [String]?
        let continuation: CheckedContinuation<HourlyReport, Never>
    }

    nonisolated let allowsQuotaCachePersistence = false

    private let hourlyResponses: [Set<String>: HourlyReport]
    private var blockedGraphYears: Set<String> = []
    private var blockedHourlyYears: Set<String> = []
    /// Model-report call log. LP2B's claim is about *when* the model is
    /// requested relative to the graph, so the count alone is not enough —
    /// `modelCallsWhileGraphPending` records requests that arrived while a
    /// graph was still blocked, which is exactly the contention being removed.
    private var modelCalls = 0
    private var modelCallsWhileGraphPending = 0
    private var modelPriorities: [TaskPriority] = []
    private var hourlyCalls = 0
    private var blockedModel = false
    /// Fail the next model request once, then behave normally — the shape of a
    /// transient FFI error, which is the case that must self-heal.
    private var failModelOnce = false
    /// Same shape for the graph: a transient failure leaves whatever payload
    /// was already restored on screen, which is the state a model request must
    /// not mistake for a committed one.
    private var failGraphOnce = false
    private var pendingModel: [CheckedContinuation<ModelReport, Never>] = []
    private var pendingModelYears: [String?] = []
    /// When set, each graph response advances the fixture's "today" so
    /// `meta.generatedAt` actually moves between loads. Without this the demo
    /// payload is byte-identical across a refresh, the model identity gate
    /// always matches, and any test about per-generation refetching would pass
    /// no matter what the production code does.
    private var advancingGraphDays: Int?
    /// Freezes the advance without disabling it: `graph()` keeps replaying the
    /// CURRENT fixture day instead of moving to the next one. Needed so a
    /// LP3 restore-gate fixture can call `load()` (a real fetch, satisfying
    /// the gate) without that fetch itself moving the generation the test is
    /// trying to hold fixed — see `lagRestored` below.
    private var advancePaused = false
    private var pendingGraphs: [String: [CheckedContinuation<UsagePayload, Error>]] = [:]
    private var pendingHourly: [String: [PendingHourly]] = [:]
    private var blockedTrace = false
    private var forcedTraceOnce: [TraceBucket]?
    private var pendingTrace: [CheckedContinuation<[TraceBucket], Never>] = []

    init(hourlyResponses: [Set<String>: HourlyReport] = [:]) {
        self.hourlyResponses = hourlyResponses
    }

    private static func key(_ year: String?) -> String { year ?? "" }

    func blockGraph(year: String?) { blockedGraphYears.insert(Self.key(year)) }
    func blockHourly(year: String?) { blockedHourlyYears.insert(Self.key(year)) }
    func blockTrace() { blockedTrace = true }
    func forceNextTrace(_ trace: [TraceBucket]) { forcedTraceOnce = trace }

    func hasPendingGraph(year: String?) -> Bool {
        !(pendingGraphs[Self.key(year)] ?? []).isEmpty
    }

    func hasPendingHourly(year: String?) -> Bool {
        !(pendingHourly[Self.key(year)] ?? []).isEmpty
    }

    func hasPendingTrace() -> Bool { !pendingTrace.isEmpty }

    func releaseGraph(year: String?) {
        let key = Self.key(year)
        blockedGraphYears.remove(key)
        let continuations = pendingGraphs.removeValue(forKey: key) ?? []
        let payload = DemoData.payload(for: year)
        continuations.forEach { $0.resume(returning: payload) }
    }

    func pendingGraphCount(year: String?) -> Int {
        (pendingGraphs[Self.key(year)] ?? []).count
    }

    /// Release exactly ONE parked graph fetch, chosen by park order, with a
    /// fixture day that makes its payload distinguishable. `releaseGraph`
    /// resumes every parked fetch with the same payload, so it cannot express
    /// "the later fetch commits first and the earlier one lands after".
    func releaseGraph(year: String?, index: Int, day: Int) {
        let key = Self.key(year)
        guard var parked = pendingGraphs[key], parked.indices.contains(index) else { return }
        let continuation = parked.remove(at: index)
        pendingGraphs[key] = parked
        if parked.isEmpty { blockedGraphYears.remove(key) }
        continuation.resume(returning: DemoData.payload(for: year, today: Self.fixtureDay(day)))
    }

    /// Fail exactly ONE parked graph fetch, chosen by park order, leaving the
    /// rest parked — the failure analog of `releaseGraph(year:index:day:)`,
    /// needed to fail specifically the OLDER of two overlapping fetches while
    /// a newer one stays in flight.
    func failGraph(year: String?, index: Int) {
        let key = Self.key(year)
        guard var parked = pendingGraphs[key], parked.indices.contains(index) else { return }
        let continuation = parked.remove(at: index)
        pendingGraphs[key] = parked
        if parked.isEmpty { blockedGraphYears.remove(key) }
        continuation.resume(throwing: CancellationError())
    }

    /// Release a parked graph fetch as a FAILURE. Needed to land a stale
    /// fetch's error after a newer one has already committed, which no
    /// one-shot `failNextGraph` can order.
    func failPendingGraph(year: String?) {
        let key = Self.key(year)
        blockedGraphYears.remove(key)
        let continuations = pendingGraphs.removeValue(forKey: key) ?? []
        continuations.forEach { $0.resume(throwing: CancellationError()) }
    }

    func releaseHourly(year: String?) {
        let key = Self.key(year)
        blockedHourlyYears.remove(key)
        let pending = pendingHourly.removeValue(forKey: key) ?? []
        pending.forEach {
            let report = hourlyResponses[Set($0.clients ?? [])]
                ?? DemoData.hourlyReport(for: year, clients: $0.clients)
            $0.continuation.resume(returning: report)
        }
    }

    func releaseTrace(_ trace: [TraceBucket]) {
        blockedTrace = false
        let waiting = pendingTrace
        pendingTrace = []
        waiting.forEach { $0.resume(returning: trace) }
    }

    /// Returned verbatim for the NEXT `graph()` call regardless of the year
    /// requested — simulates the real scenario `apply()`'s empty-year branch
    /// exists for (the selected year's logs were deleted/moved mid-session),
    /// which `DemoData.payload(for:)` cannot reproduce on its own since it
    /// always manufactures data for whatever year it is asked for.
    private var forcedPayloadOnce: UsagePayload?
    func forceNextGraphPayload(_ payload: UsagePayload) { forcedPayloadOnce = payload }

    func graph(year: String?, priority: TaskPriority) async throws -> UsagePayload {
        _ = priority
        if failGraphOnce {
            failGraphOnce = false
            throw CancellationError()
        }
        if let forced = forcedPayloadOnce {
            forcedPayloadOnce = nil
            return forced
        }
        let key = Self.key(year)
        if blockedGraphYears.contains(key) {
            return try await withCheckedThrowingContinuation {
                pendingGraphs[key, default: []].append($0)
            }
        }
        if let day = advancingGraphDays {
            if !advancePaused { advancingGraphDays = day + 1 }
            return DemoData.payload(for: year, today: Self.fixtureDay(day))
        }
        return DemoData.payload(for: year)
    }

    /// Freezes the advance AND rewinds it one step, so the next `graph()`
    /// call (and every one after it, while paused) replays the exact fixture
    /// day the MOST RECENT call already returned, rather than the day that
    /// call's own advance had already moved on to.
    func pauseGraphAdvance() {
        advancePaused = true
        if let day = advancingGraphDays, day > 0 { advancingGraphDays = day - 1 }
    }
    func resumeGraphAdvance() { advancePaused = false }

    /// Deterministic fixture dates far from any real "today" so the advancing
    /// sequence cannot collide with the default fixture.
    private static func fixtureDay(_ offset: Int) -> String {
        String(format: "2037-06-%02d", 10 + offset)
    }

    func advanceGraphGenerationPerCall() { advancingGraphDays = 0 }

    func refreshGraph(year: String?, priority: TaskPriority) async throws -> UsagePayload {
        try await graph(year: year, priority: priority)
    }

    func modelReport(year: String?, priority: TaskPriority) async throws -> ModelReport {
        modelCalls += 1
        modelPriorities.append(priority)
        if !pendingGraphs.values.allSatisfy(\.isEmpty) || !blockedGraphYears.isEmpty {
            modelCallsWhileGraphPending += 1
        }
        if failModelOnce {
            failModelOnce = false
            throw CancellationError()
        }
        if blockedModel {
            pendingModelYears.append(year)
            return await withCheckedContinuation { pendingModel.append($0) }
        }
        return DemoData.modelReport(for: year)
    }

    func modelCallCount() -> Int { modelCalls }
    func modelCallsRacingGraph() -> Int { modelCallsWhileGraphPending }
    func modelCallPriorities() -> [TaskPriority] { modelPriorities }
    func hourlyCallCount() -> Int { hourlyCalls }
    func blockModel() { blockedModel = true }
    func failNextModel() { failModelOnce = true }
    func failNextGraph() { failGraphOnce = true }
    func pendingModelCount() -> Int { pendingModel.count }

    /// Retire the oldest parked model request while leaving the rest parked —
    /// needed to reproduce a stale scan completing underneath a live one.
    func releaseOneModel() {
        guard !pendingModel.isEmpty else { return }
        let continuation = pendingModel.removeFirst()
        let year = pendingModelYears.removeFirst()
        continuation.resume(returning: DemoData.modelReport(for: year))
    }

    func releaseModel() {
        blockedModel = false
        let waiting = pendingModel
        let years = pendingModelYears
        pendingModel = []
        pendingModelYears = []
        for (index, continuation) in waiting.enumerated() {
            continuation.resume(returning: DemoData.modelReport(for: years[index]))
        }
    }

    func hourlyReport(
        year: String?, clients: [String]?, priority: TaskPriority
    ) async throws -> HourlyReport {
        _ = priority
        hourlyCalls += 1
        let key = Self.key(year)
        if blockedHourlyYears.contains(key) {
            return await withCheckedContinuation {
                pendingHourly[key, default: []].append(
                    PendingHourly(clients: clients, continuation: $0))
            }
        }
        return hourlyResponses[Set(clients ?? [])]
            ?? DemoData.hourlyReport(for: year, clients: clients)
    }

    func agentsReport(
        year: String?, clients: [String]?, priority: TaskPriority
    ) async throws -> AgentsReport {
        _ = priority
        return DemoData.agentsReport(for: year, clients: clients)
    }

    func agentUsage() async throws -> AgentUsagePayload { DemoData.agentUsage }

    func usageTrace(windowSecs: Int64) async throws -> [TraceBucket] {
        if let forcedTraceOnce {
            self.forcedTraceOnce = nil
            return forcedTraceOnce
        }
        if blockedTrace {
            return await withCheckedContinuation { pendingTrace.append($0) }
        }
        return DemoData.trace(windowSecs: windowSecs)
    }

    func tokensPerMin() async throws -> Double { DemoData.tokensPerMin }
}

/// Wait for a condition another task has to establish.
///
/// Bounded by a deadline rather than by an iteration count. A fixed number of
/// yields measures scheduler turns, not elapsed time, so how long it actually
/// waits depends on how much other work shares the cooperative pool — which
/// made the tests that use it fail intermittently as unrelated cases were added
/// ahead of them. The failure was always a false negative: the condition would
/// have held, the wait just gave up first.
///
/// The deadline is generous because the cost of raising it is only paid when a
/// test is genuinely about to fail, while the cost of setting it too low is a
/// flake that looks like a product defect.
private func waitUntil(
    timeout: Duration = .seconds(5),
    _ predicate: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await predicate() { return true }
        await Task.yield()
    }
    return await predicate()
}

/// Proves every re-entry task has started on the MainActor before a fixture
/// observes the state those tasks should have reached. Resuming the waiter does
/// not preempt the current actor job, so the last entrant continues until its
/// next suspension before the waiter can inspect the shared model request.
@MainActor
private final class MainActorArrivalGate {
    private let target: Int
    private var arrivals = 0
    private var waiter: CheckedContinuation<Void, Never>?

    init(target: Int) {
        precondition(target > 0)
        self.target = target
    }

    func arrive() {
        precondition(arrivals < target, "arrival gate received too many entrants")
        arrivals += 1
        guard arrivals == target, let waiter else { return }
        self.waiter = nil
        waiter.resume()
    }

    func waitForTarget() async {
        if arrivals == target { return }
        precondition(waiter == nil, "arrival gate supports one waiter")
        await withCheckedContinuation { waiter = $0 }
    }
}

private enum DashboardModelTestError: Error {
    case graphUnavailable
}

private struct DashboardModelTestSource: UsageDataSource {
    let failingGraphYear: String
    let allowsQuotaCachePersistence = false

    func graph(year: String?, priority: TaskPriority) async throws -> UsagePayload {
        _ = priority
        if year == failingGraphYear { throw DashboardModelTestError.graphUnavailable }
        return DemoData.payload(for: year)
    }

    func refreshGraph(year: String?, priority: TaskPriority) async throws -> UsagePayload {
        try await graph(year: year, priority: priority)
    }

    func modelReport(year: String?, priority: TaskPriority) async throws -> ModelReport {
        _ = priority
        let marker = year ?? "all"
        let tokens = year == "2024" ? 24 : year == "2023" ? 23 : 1
        let json = """
        {"entries":[{"client":"claude","model":"loaded-MARKER","provider":"test",
         "input":TOKENS,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0,
         "total":TOKENS,"messageCount":1,"cost":1.0,"msPer1kTokens":null}],
         "totalInput":TOKENS,"totalOutput":0,"totalCacheRead":0,"totalCacheWrite":0,
         "totalMessages":1,"totalCost":1.0}
        """
        .replacingOccurrences(of: "MARKER", with: marker)
        .replacingOccurrences(of: "TOKENS", with: String(tokens))
        return try JSONDecoder().decode(ModelReport.self, from: Data(json.utf8))
    }

    func hourlyReport(
        year: String?, clients: [String]?, priority: TaskPriority
    ) async throws -> HourlyReport {
        _ = priority
        return DemoData.hourlyReport(for: year, clients: clients)
    }

    func agentsReport(
        year: String?, clients: [String]?, priority: TaskPriority
    ) async throws -> AgentsReport {
        _ = priority
        return DemoData.agentsReport(for: year, clients: clients)
    }

    func agentUsage() async throws -> AgentUsagePayload { DemoData.agentUsage }

    func usageTrace(windowSecs: Int64) async throws -> [TraceBucket] {
        DemoData.trace(windowSecs: windowSecs)
    }

    func tokensPerMin() async throws -> Double { DemoData.tokensPerMin }
}

/// Counts message scans so the "no open agent tab, no scan" bound is assertable
/// rather than asserted in a comment. Everything else forwards to the ordinary
/// double; only `windowUsage` is instrumented.
private final class WindowScanCountingSource: UsageDataSource, @unchecked Sendable {
    private let inner = DashboardModelTestSource(failingGraphYear: "")
    private let payload: AgentUsagePayload
    var scans = 0
    /// Which account each scan asked for, in order. `SC1` only needs the count;
    /// the per-account cases need to see that the right accounts were asked.
    var scannedAccounts: [String?] = []
    /// Rows served per account, keyed the way the model keys its scans (the
    /// empty string is the primary). Empty means "no messages", which is the
    /// pre-existing behaviour every other case relies on.
    var messagesByAccount: [String: [WindowMessage]] = [:]
    /// Served for every window, so a case about the strip summaries has
    /// something to summarise. Nil keeps the pre-existing behaviour.
    var curve: QuotaCurve?
    /// Makes the quota fetch fail, so a case can drive the poll's failure path
    /// rather than reason about it.
    var failAgentUsage = false
    /// Makes the curve read THROW, which is not the same as returning nil: nil
    /// is "no history", a throw is "could not be read". Conflating them is the
    /// defect the case using this drives.
    var failCurveRead = false
    struct QuotaUnavailable: Error {}

    init(payload: AgentUsagePayload) { self.payload = payload }

    /// Per-account override, checked before the shared `curve` fallback: lets
    /// a case give a second Claude account its own distinct curve so a test
    /// can prove the two are not conflated.
    var curveByAccount: [String?: QuotaCurve] = [:]

    func quotaCurveSync(
        clientId: String, accountKey: String?, windowKey: String, generation: UInt64
    ) throws -> QuotaCurve? {
        if failCurveRead { throw QuotaUnavailable() }
        if let byAccount = curveByAccount[accountKey] { return byAccount }
        return curve
    }

    var allowsQuotaCachePersistence: Bool { false }
    func graph(year: String?, priority: TaskPriority) async throws -> UsagePayload {
        try await inner.graph(year: year, priority: priority)
    }
    func refreshGraph(year: String?, priority: TaskPriority) async throws -> UsagePayload {
        try await inner.refreshGraph(year: year, priority: priority)
    }
    func modelReport(year: String?, priority: TaskPriority) async throws -> ModelReport {
        try await inner.modelReport(year: year, priority: priority)
    }
    func hourlyReport(
        year: String?, clients: [String]?, priority: TaskPriority
    ) async throws -> HourlyReport {
        try await inner.hourlyReport(year: year, clients: clients, priority: priority)
    }
    func agentsReport(
        year: String?, clients: [String]?, priority: TaskPriority
    ) async throws -> AgentsReport {
        try await inner.agentsReport(year: year, clients: clients, priority: priority)
    }
    func agentUsage() async throws -> AgentUsagePayload {
        if failAgentUsage { throw QuotaUnavailable() }
        return payload
    }
    func usageTrace(windowSecs: Int64) async throws -> [TraceBucket] {
        try await inner.usageTrace(windowSecs: windowSecs)
    }
    func tokensPerMin() async throws -> Double { try await inner.tokensPerMin() }
    /// Counts a scan per ACCOUNT, because the shipping code now issues one
    /// call per account rather than one call for all of them.
    ///
    /// The signature has to track the protocol's exactly. An outdated one still
    /// compiles — the conformance falls through to the extension's default,
    /// which returns empty and counts nothing — and the counter then reads zero
    /// for a model that scanned. That is how this double stopped observing
    /// anything while `SC1` still ran.
    func windowUsage(
        accountKey: String?, from: Int64, until: Int64
    ) async throws -> WindowUsage {
        scans += 1
        scannedAccounts.append(accountKey)
        return WindowUsage(
            messages: messagesByAccount[accountKey ?? ""] ?? [],
            undatedCount: 0, processingTimeMs: 0)
    }
}

/// Moves the account registry WHILE the quota fetch is in flight, which is the
/// only moment the guard `M3-p` covers can be observed: the payload is already
/// being built when the registry changes, so it answers the previous one.
///
/// The first fetch signals and returns the stale payload; every fetch after it
/// returns the fresh one. A poll that applies the first has published the
/// previous account set.
private final class RegistryRaceSource: UsageDataSource, @unchecked Sendable {
    private let inner = DashboardModelTestSource(failingGraphYear: "")
    private let stale: AgentUsagePayload
    private let fresh: AgentUsagePayload
    private var pending: CheckedContinuation<Void, Never>?
    var fetches = 0

    init(stale: AgentUsagePayload, fresh: AgentUsagePayload) {
        self.stale = stale
        self.fresh = fresh
    }

    func quotaCurveSync(
        clientId: String, accountKey: String?, windowKey: String, generation: UInt64
    ) throws -> QuotaCurve? { nil }

    var allowsQuotaCachePersistence: Bool { false }
    func graph(year: String?, priority: TaskPriority) async throws -> UsagePayload {
        try await inner.graph(year: year, priority: priority)
    }
    func refreshGraph(year: String?, priority: TaskPriority) async throws -> UsagePayload {
        try await inner.refreshGraph(year: year, priority: priority)
    }
    func modelReport(year: String?, priority: TaskPriority) async throws -> ModelReport {
        try await inner.modelReport(year: year, priority: priority)
    }
    func hourlyReport(
        year: String?, clients: [String]?, priority: TaskPriority
    ) async throws -> HourlyReport {
        try await inner.hourlyReport(year: year, clients: clients, priority: priority)
    }
    func agentsReport(
        year: String?, clients: [String]?, priority: TaskPriority
    ) async throws -> AgentsReport {
        try await inner.agentsReport(year: year, clients: clients, priority: priority)
    }
    /// Every fetch after the first SUSPENDS until `release()` — that pause is
    /// what makes the property observable. Left running, the loop applies the
    /// fresh payload a few milliseconds later and the final value is the same
    /// whether or not the stale one was published on the way; the first version
    /// of this source did that and its gate could not fail.
    func agentUsage() async throws -> AgentUsagePayload {
        fetches += 1
        if fetches == 1 {
            await MainActor.run { ClaudeExtraRoots.RegistryChange.signal() }
            return stale
        }
        await withCheckedContinuation { pending = $0 }
        return fresh
    }

    /// Lets the held fetch finish. A continuation rather than a semaphore: the
    /// poll runs on the main actor, and blocking it would stop the very test
    /// that is about to release this.
    func release() {
        pending?.resume()
        pending = nil
    }
    func usageTrace(windowSecs: Int64) async throws -> [TraceBucket] {
        try await inner.usageTrace(windowSecs: windowSecs)
    }
    func tokensPerMin() async throws -> Double { try await inner.tokensPerMin() }
    func windowUsage(
        accountKey: String?, from: Int64, until: Int64
    ) async throws -> WindowUsage {
        WindowUsage(messages: [], undatedCount: 0, processingTimeMs: 0)
    }
}

private final class AttributedSeriesTestSource: UsageDataSource, @unchecked Sendable {
    let graphPayload: UsagePayload
    let refreshPayload: UsagePayload
    let allowsQuotaCachePersistence = false
    var graphYears: [String?] = []
    var refreshYears: [String?] = []

    init(graphPayload: UsagePayload, refreshPayload: UsagePayload) {
        self.graphPayload = graphPayload
        self.refreshPayload = refreshPayload
    }

    /// Lets a case stand in for a reopened popover whose acquisition has not
    /// come back yet (or fails): the model must still have something to draw.
    var failGraph = false
    var failRefresh = false
    struct GraphUnavailable: Error {}

    /// Holds `graph` open so a case can read what the model published BEFORE
    /// the acquisition returned. That frame is not an implementation detail:
    /// it is what the user looks at for the seconds a scan takes, and the only
    /// place a stale attribution split is visible.
    var graphGate: ThrottleGate?
    var graphEntries: ThrottleCallCounter?
    /// Runs INSIDE the fetch, so a case can move process state while the
    /// request is outstanding — the position a value read after the fetch
    /// would see and a value read before it would not.
    var onGraph: (@Sendable () -> Void)?

    func graph(year: String?, priority: TaskPriority) async throws -> UsagePayload {
        _ = priority
        graphYears.append(year)
        onGraph?()
        await graphEntries?.bump()
        await graphGate?.wait()
        if failGraph { throw GraphUnavailable() }
        return graphPayload
    }

    func refreshGraph(year: String?, priority: TaskPriority) async throws -> UsagePayload {
        _ = priority
        refreshYears.append(year)
        if failRefresh { throw GraphUnavailable() }
        return refreshPayload
    }

    func modelReport(year: String?, priority: TaskPriority) async throws -> ModelReport {
        _ = priority
        return DemoData.modelReport(for: year)
    }

    func hourlyReport(
        year: String?, clients: [String]?, priority: TaskPriority
    ) async throws -> HourlyReport {
        _ = priority
        return DemoData.hourlyReport(for: year, clients: clients)
    }

    func agentsReport(
        year: String?, clients: [String]?, priority: TaskPriority
    ) async throws -> AgentsReport {
        _ = priority
        return DemoData.agentsReport(for: year, clients: clients)
    }

    func agentUsage() async throws -> AgentUsagePayload { DemoData.agentUsage }

    func usageTrace(windowSecs: Int64) async throws -> [TraceBucket] {
        DemoData.trace(windowSecs: windowSecs)
    }

    func tokensPerMin() async throws -> Double { DemoData.tokensPerMin }
}

/// Runs a hook while an acquisition is suspended, so a self-test can make the
/// world change underneath an in-flight load.
private final class AttributedSeriesHookSource: UsageDataSource, @unchecked Sendable {
    let payload: UsagePayload
    let allowsQuotaCachePersistence = false
    var onAcquire: (@MainActor @Sendable () -> Void)?
    var graphCalls = 0
    var refreshCalls = 0

    init(payload: UsagePayload) { self.payload = payload }

    private func serve() async -> UsagePayload {
        if let onAcquire { await MainActor.run { onAcquire() } }
        return payload
    }

    func graph(year: String?, priority: TaskPriority) async throws -> UsagePayload {
        _ = (year, priority)
        graphCalls += 1
        return await serve()
    }

    func refreshGraph(year: String?, priority: TaskPriority) async throws -> UsagePayload {
        _ = (year, priority)
        refreshCalls += 1
        return await serve()
    }

    func modelReport(year: String?, priority: TaskPriority) async throws -> ModelReport {
        _ = priority
        return DemoData.modelReport(for: year)
    }

    func hourlyReport(
        year: String?, clients: [String]?, priority: TaskPriority
    ) async throws -> HourlyReport {
        _ = priority
        return DemoData.hourlyReport(for: year, clients: clients)
    }

    func agentsReport(
        year: String?, clients: [String]?, priority: TaskPriority
    ) async throws -> AgentsReport {
        _ = priority
        return DemoData.agentsReport(for: year, clients: clients)
    }

    func agentUsage() async throws -> AgentUsagePayload { DemoData.agentUsage }

    func usageTrace(windowSecs: Int64) async throws -> [TraceBucket] {
        DemoData.trace(windowSecs: windowSecs)
    }

    func tokensPerMin() async throws -> Double { DemoData.tokensPerMin }
}

/// Runs a complete nested load while an outer acquisition is suspended, which
/// is the actor-reentrancy shape made deterministic: the inner load publishes
/// first and the outer one then resumes holding an older payload.
private final class AttributedSeriesReentrantSource: UsageDataSource, @unchecked Sendable {
    struct Failure: Error {}

    let outerPayload: UsagePayload
    let innerPayload: UsagePayload
    let allowsQuotaCachePersistence = false
    /// Runs only while the first acquisition is suspended.
    var onFirstAcquire: (@MainActor @Sendable () async -> Void)?
    var failOuter = false
    var calls = 0

    init(outerPayload: UsagePayload, innerPayload: UsagePayload) {
        self.outerPayload = outerPayload
        self.innerPayload = innerPayload
    }

    private func serve() async throws -> UsagePayload {
        calls += 1
        guard calls == 1 else { return innerPayload }
        if let onFirstAcquire { await onFirstAcquire() }
        if failOuter { throw Failure() }
        return outerPayload
    }

    func graph(year: String?, priority: TaskPriority) async throws -> UsagePayload {
        _ = (year, priority)
        return try await serve()
    }

    func refreshGraph(year: String?, priority: TaskPriority) async throws -> UsagePayload {
        _ = (year, priority)
        return try await serve()
    }

    func modelReport(year: String?, priority: TaskPriority) async throws -> ModelReport {
        _ = priority
        return DemoData.modelReport(for: year)
    }

    func hourlyReport(
        year: String?, clients: [String]?, priority: TaskPriority
    ) async throws -> HourlyReport {
        _ = priority
        return DemoData.hourlyReport(for: year, clients: clients)
    }

    func agentsReport(
        year: String?, clients: [String]?, priority: TaskPriority
    ) async throws -> AgentsReport {
        _ = priority
        return DemoData.agentsReport(for: year, clients: clients)
    }

    func agentUsage() async throws -> AgentUsagePayload { DemoData.agentUsage }

    func usageTrace(windowSecs: Int64) async throws -> [TraceBucket] {
        DemoData.trace(windowSecs: windowSecs)
    }

    func tokensPerMin() async throws -> Double { DemoData.tokensPerMin }
}

/// Serves one payload until `failing` is set, then throws from both acquisition
/// paths — the transient-dependency-failure case. `onAcquire` runs while the
/// acquisition is suspended, so a test can make the world change under a load
/// that is about to fail.
private final class AttributedSeriesFailingSource: UsageDataSource, @unchecked Sendable {
    struct Failure: Error {}

    let graphPayload: UsagePayload
    let allowsQuotaCachePersistence = false
    var failing = false
    var onAcquire: (@MainActor @Sendable () -> Void)?

    init(graphPayload: UsagePayload) { self.graphPayload = graphPayload }

    private func serve() async throws -> UsagePayload {
        if let onAcquire { await MainActor.run { onAcquire() } }
        if failing { throw Failure() }
        return graphPayload
    }

    func graph(year: String?, priority: TaskPriority) async throws -> UsagePayload {
        _ = (year, priority)
        return try await serve()
    }

    func refreshGraph(year: String?, priority: TaskPriority) async throws -> UsagePayload {
        _ = (year, priority)
        return try await serve()
    }

    func modelReport(year: String?, priority: TaskPriority) async throws -> ModelReport {
        _ = priority
        return DemoData.modelReport(for: year)
    }

    func hourlyReport(
        year: String?, clients: [String]?, priority: TaskPriority
    ) async throws -> HourlyReport {
        _ = priority
        return DemoData.hourlyReport(for: year, clients: clients)
    }

    func agentsReport(
        year: String?, clients: [String]?, priority: TaskPriority
    ) async throws -> AgentsReport {
        _ = priority
        return DemoData.agentsReport(for: year, clients: clients)
    }

    func agentUsage() async throws -> AgentUsagePayload { DemoData.agentUsage }

    func usageTrace(windowSecs: Int64) async throws -> [TraceBucket] {
        DemoData.trace(windowSecs: windowSecs)
    }

    func tokensPerMin() async throws -> Double { DemoData.tokensPerMin }
}

private struct DashboardModelTestObservation: Sendable {
    let selectedYear: String?
    let loadedYear: String?
    let loadedModel: String?
    let loadedTokens: Int64?
    let cardRangeLabel: String
}

enum SelfTest {
    static func run() -> Never {
        var failures = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            if condition() {
                print("ok   \(label)")
            } else {
                failures += 1
                print("FAIL \(label)")
            }
        }

        func awaitValue<Value: Sendable>(
            _ operation: @escaping @Sendable () async throws -> Value
        ) -> Value? {
            let semaphore = DispatchSemaphore(value: 0)
            let box = AsyncResultBox<Value>()
            Task.detached(priority: .userInitiated) {
                defer { semaphore.signal() }
                do {
                    box.result = .success(try await operation())
                } catch {
                    box.result = .failure(error)
                }
            }
            semaphore.wait()
            return try? box.result?.get()
        }

        func awaitMainActorValue<Value: Sendable>(
            _ operation: @escaping @MainActor @Sendable () async throws -> Value
        ) -> Value? {
            let box = AsyncResultBox<Value>()
            Task { @MainActor in
                do {
                    box.result = .success(try await operation())
                } catch {
                    box.result = .failure(error)
                }
            }
            while box.result == nil {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
            }
            return try? box.result?.get()
        }

        // Per-level overrides survive reopening; Automatic restores the
        // original quota/native policy without discarding any saved colors.
        let textColorSuite = "com.tokenbar.selftest.menu-bar-text-color"
        if let defaults = UserDefaults(suiteName: textColorSuite) {
            defaults.removePersistentDomain(forName: textColorSuite)
            defer { defaults.removePersistentDomain(forName: textColorSuite) }
            let automatic = TrayIcons.gaugeColor(remaining: 8)
            expect(MenuBarTextColor.resolve(automatic: automatic, quotaRemaining: 8, defaults: defaults) == automatic,
                "menu bar font defaults preserve quota warning colors")
            expect(MenuBarTextColor.resolve(automatic: nil, defaults: defaults) == nil,
                "menu bar font defaults preserve native text")
            defaults.set("custom", forKey: MenuBarTextColor.storageKey)
            defaults.set("#B35CFF", forKey: MenuBarTextColor.customColorKey)
            let reopened = UserDefaults(suiteName: textColorSuite)!
            let custom = MenuBarTextColor.resolve(automatic: nil, quotaRemaining: 80, defaults: reopened)
            expect(custom.flatMap { MenuBarTextColor.hex(color: $0) } == "#B35CFF",
                "the existing custom font color persists as the normal color")
            expect(MenuBarTextColor.resolve(automatic: nil, defaults: reopened) == custom,
                "non-quota and unavailable text use the normal custom color")
            expect(MenuBarTextColor.resolve(automatic: automatic, quotaRemaining: 20, defaults: reopened)
                    .flatMap { MenuBarTextColor.hex(color: $0) } == "#F59E0B"
                && MenuBarTextColor.resolve(automatic: automatic, quotaRemaining: 8, defaults: reopened)
                    .flatMap { MenuBarTextColor.hex(color: $0) } == "#EF4444",
                "new warning and critical preferences have separate defaults")
            defaults.set("#123456", forKey: MenuBarTextColor.warningColorKey)
            defaults.set("#FF0066", forKey: MenuBarTextColor.criticalColorKey)
            for (remaining, expectedHex) in [
                (100.0, "#B35CFF"), (25.01, "#B35CFF"),
                (25.0, "#123456"), (10.01, "#123456"),
                (10.0, "#FF0066"), (0.0, "#FF0066"),
            ] {
                let resolved = MenuBarTextColor.resolve(
                    automatic: nil, quotaRemaining: remaining, defaults: reopened)
                expect(resolved.flatMap { MenuBarTextColor.hex(color: $0) } == expectedHex,
                    "custom quota text selects the saved level at \(remaining)%")
            }
            expect(TrayIcons.gaugeColor(remaining: 25.01)
                    == NSColor(srgbRed: 0.13, green: 0.77, blue: 0.37, alpha: 1)
                && TrayIcons.gaugeColor(remaining: 25)
                    == NSColor(srgbRed: 0.96, green: 0.62, blue: 0.04, alpha: 1)
                && TrayIcons.gaugeColor(remaining: 10)
                    == NSColor(srgbRed: 0.94, green: 0.27, blue: 0.27, alpha: 1),
                "shared quota levels preserve the automatic palette and thresholds")
            defaults.set("invalid", forKey: MenuBarTextColor.warningColorKey)
            expect(MenuBarTextColor.resolve(automatic: automatic, quotaRemaining: 20, defaults: defaults) == automatic
                && MenuBarTextColor.resolve(automatic: nil, quotaRemaining: 8, defaults: defaults)
                    .flatMap { MenuBarTextColor.hex(color: $0) } == "#FF0066",
                "an invalid saved level falls back without affecting other levels")
            defaults.set("automatic", forKey: MenuBarTextColor.storageKey)
            expect(MenuBarTextColor.resolve(automatic: automatic, quotaRemaining: 8, defaults: defaults) == automatic
                && MenuBarTextColor.resolve(automatic: nil, defaults: defaults) == nil
                && defaults.string(forKey: MenuBarTextColor.customColorKey) == "#B35CFF"
                && defaults.string(forKey: MenuBarTextColor.criticalColorKey) == "#FF0066",
                "automatic restores quota and native colors while retaining the custom palette")
            defaults.set("custom", forKey: MenuBarTextColor.storageKey)
            defaults.set("#notRGB", forKey: MenuBarTextColor.customColorKey)
            expect(MenuBarTextColor.resolve(automatic: automatic, defaults: defaults) == automatic,
                "malformed saved font colors fall back to automatic")
        } else {
            expect(false, "menu bar text-color defaults suite")
        }

        // THROTTLE. Three independent callers fetch the OAuth quota payload
        // fetch-first, and the popover's loop is remounted by a `.task` on every
        // reopen — so opening and closing ten times issued ten requests, which
        // is enough to reach Anthropic's rate limit. The engine's gate handles
        // the aftermath of a 429; nothing bounded the attempts that cause one.
        let throttleResult = awaitMainActorValue { () async throws -> [Int] in
            let throttle = AgentUsageThrottle()
            let base = Date(timeIntervalSince1970: 1_000_000)
            let counter = ThrottleCallCounter()
            let empty = try JSONDecoder().decode(
                AgentUsagePayload.self,
                from: Data(#"{"generatedAt":"2026-08-22T00:00:00Z","agents":[]}"#.utf8))
            let fetch: @Sendable () async throws -> AgentUsagePayload = {
                await counter.bump()
                return empty
            }
            // Three callers arriving TOGETHER, before any of them has a result
            // to cache. This is the case the actor alone does not cover: it is
            // reentrant across `await`, so while the first is suspended in the
            // fetch the others walk past the empty cache and open their own.
            let gate = ThrottleGate()
            let blocking: @Sendable () async throws -> AgentUsagePayload = {
                await counter.bump()
                await gate.wait()
                return empty
            }
            let clock = ThrottleClock(base)
            let concurrent = (0..<3).map { _ in
                Task { try await throttle.payload(now: { clock.value }, fetch: blocking) }
            }
            while await counter.count < 1 { await Task.yield() }
            await gate.open()
            for task in concurrent { _ = try await task.value }
            let concurrentCalls = await counter.count
            await throttle.reset()
            await counter.reset()

            clock.value = base
            _ = try await throttle.payload(now: { clock.value }, fetch: fetch)
            // Nine reopens inside the floor.
            for i in 1...9 {
                clock.value = base.addingTimeInterval(Double(i))
                _ = try await throttle.payload(now: { clock.value }, fetch: fetch)
            }
            let insideFloor = await counter.count
            // The 60s poll tick is outside it and must still go through.
            clock.value = base.addingTimeInterval(60)
            _ = try await throttle.payload(now: { clock.value }, fetch: fetch)
            let afterTick = await counter.count

            // A request that itself takes longer than the floor. Stamping the
            // ASK time made its payload land already expired, so the next
            // reopen fetched again — the floor dissolving exactly while the
            // endpoint was slow, which is when it was doing the work.
            await throttle.reset()
            await counter.reset()
            clock.value = base
            let slow: @Sendable () async throws -> AgentUsagePayload = {
                await counter.bump()
                clock.value = base.addingTimeInterval(60)
                return empty
            }
            _ = try await throttle.payload(now: { clock.value }, fetch: slow)
            // One second after that request returned — deep inside the floor
            // measured from completion, well outside it measured from the ask.
            clock.value = base.addingTimeInterval(61)
            _ = try await throttle.payload(now: { clock.value }, fetch: fetch)
            let afterSlow = await counter.count
            return [insideFloor, afterTick, concurrentCalls, afterSlow]
        }
        expect(throttleResult?.first == 1,
               "THROTTLE ten opens within the floor issue ONE request, not ten")
        expect(throttleResult?.count == 4 && throttleResult?[1] == 2,
               "THROTTLE and the 60s poll tick still goes through, so the floor "
                   + "collapses reopens without slowing the cadence it protects")
        expect(throttleResult?.count == 4 && throttleResult?[3] == 1,
               "THROTTLE a request slower than the floor is stamped when it "
                   + "returned, not when it was asked, so it does not land "
                   + "already expired")
        // QT-FLOOR. A provider correction can make the recent samples fall
        // steeply enough that the projection goes below zero — "-190% used",
        // and a drop larger than the amount that exists. The mirror of the
        // overshoot `runsOutEarly` names, with no state to name it.
        let qtFall = QuotaTrendFold.trend(
            usedPercent: 10, windowStartMs: 0, windowEndMs: 100_000, nowMs: 20_000,
            samples: [QuotaSample(atMs: 10_000, usedPercent: 90),
                      QuotaSample(atMs: 20_000, usedPercent: 10)])
        expect(
            (qtFall?.projectedUsedPercent ?? -1) >= 0,
            "QT-FLOOR a steep fall cannot project below an empty meter")
        expect(
            qtFall.map { abs(($0.projectedUsedPercent - 10) - $0.projectedDeltaPercent) < 1e-9 }
                == true,
            "QT-FLOOR and the delta is derived from the clamped projection, so adding "
                + "it to the current reading lands on the projection beside it")

        // Indexed, not `.last`: appending a case to the returned array silently
        // repointed this at a different measurement, and it kept passing only
        // because both values happened to be 1.
        expect(throttleResult?.count == 4 && throttleResult?[2] == 1,
               "THROTTLE three callers arriving before any result exists share ONE "
                   + "request — the actor is reentrant across await, so the cache "
                   + "check alone does not coalesce them")

        expect(
            !AppLanguage.requiresRelaunch(from: "en", to: "en"),
            "language reselect does not prompt for relaunch")
        expect(
            AppLanguage.requiresRelaunch(from: "en", to: "zh-Hant"),
            "language change prompts for relaunch")
        expect(
            AppLanguage.requiresRelaunch(from: "en", to: "zh-Hans"),
            "Simplified Chinese language change prompts for relaunch")
        expect(
            !AppLanguage.requiresRelaunch(from: "en", to: "unsupported"),
            "invalid language does not prompt for relaunch")

        let localizationBundles = [
            (name: "main bundle", bundle: Bundle.main),
            (name: "SwiftPM resource bundle", bundle: Bundle.tokenBarResources),
        ]
        for (bundleName, bundle) in localizationBundles {
            let zhHansWindow = AppLanguage.localizedString(
                "Session", locale: "zh-Hans", bundle: bundle)
            let zhHansWindowFormat = AppLanguage.localizedString(
                "%@ window", locale: "zh-Hans", bundle: bundle)
            expect(
                zhHansWindow == "会话"
                    && zhHansWindowFormat.map { String(format: $0, zhHansWindow ?? "") }
                        == "会话窗口",
                "Simplified Chinese window labels resolve from the \(bundleName)")

            let zhHansMore = AppLanguage.localizedString(
                "Show %lld more · %lld of %lld", locale: "zh-Hans", bundle: bundle)
            expect(
                zhHansMore.map { String(format: $0, Int64(7), Int64(20), Int64(27)) }
                    == "再显示 7 项 · 已显示 20／共 27 项",
                "Simplified Chinese pagination resolves from the \(bundleName)")
            let zhHansError = AppLanguage.localizedString(
                "Failed to load usage: %@", locale: "zh-Hans", bundle: bundle)
            expect(
                AppLanguage.localizedString(
                    "OAuth quota", locale: "zh-Hans", bundle: bundle) == "OAuth 额度"
                    && zhHansError.map { String(format: $0, "offline") }
                        == "加载用量失败：offline",
                "Simplified Chinese dynamic usage copy resolves from the \(bundleName)")
            let zhHansDays = AppLanguage.localizedString(
                "%lldd", locale: "zh-Hans", bundle: bundle)
            let zhHansTokens = AppLanguage.localizedString(
                "%@ tokens", locale: "zh-Hans", bundle: bundle)
            expect(
                zhHansDays.map { String(format: $0, Int64(3)) } == "3天"
                    && zhHansTokens.map { String(format: $0, "5.2K") } == "5.2K token",
                "Simplified Chinese streak and token formats resolve from the \(bundleName)")
            expect(
                AppLanguage.localizedString(
                    "Not a subscription", locale: "zh-Hans", bundle: bundle)
                    == "不计入订阅"
                    && AppLanguage.localizedString(
                        "Suggested: not a subscription", locale: "zh-Hans", bundle: bundle)
                        == "建议：不计入订阅",
                "Simplified Chinese attribution terms resolve from the \(bundleName)")

            // The three keys zh-Hans introduced. A missing entry renders as
            // English rather than breaking, so nothing else in this suite can
            // notice one catalog carrying a key the other does not.
            let zhHantMore = AppLanguage.localizedString(
                "Show %lld more · %lld of %lld", locale: "zh-Hant", bundle: bundle)
            let zhHantError = AppLanguage.localizedString(
                "Failed to load usage: %@", locale: "zh-Hant", bundle: bundle)
            expect(
                zhHantMore.map { String(format: $0, Int64(7), Int64(20), Int64(27)) }
                    == "再顯示 7 筆 · 已顯示 20／共 27 筆"
                    && zhHantError.map { String(format: $0, "offline") }
                        == "載入用量失敗：offline"
                    && AppLanguage.localizedString(
                        "OAuth quota", locale: "zh-Hant", bundle: bundle) == "OAuth 額度",
                "Traditional Chinese carries the keys zh-Hans added, from the \(bundleName)")
        }

        let popoverResizeResult = MainActor.assumeIsolated { () -> (Bool, Bool) in
            let defaults = UserDefaults.standard
            let savedHeight = defaults.object(forKey: PopoverChrome.heightKey)
            defer {
                if let savedHeight {
                    defaults.set(savedHeight, forKey: PopoverChrome.heightKey)
                } else {
                    defaults.removeObject(forKey: PopoverChrome.heightKey)
                }
            }
            defaults.set(620.0, forKey: PopoverChrome.heightKey)
            let chrome = PopoverChrome()
            chrome.resolve(visibleHeight: 1_000)
            var liveResize: (CGFloat, Bool)?
            chrome.onResize = { liveResize = ($0, $1) }
            chrome.setHeight(700, persist: false, live: true)
            let liveBypassedPublication =
                chrome.rawHeight == 620 && liveResize?.0 == 700 && liveResize?.1 == true
            chrome.setHeight(700, persist: false, live: false)
            return (liveBypassedPublication, chrome.rawHeight == 700)
        }
        expect(
            popoverResizeResult.0,
            "live popover resize bypasses environment publication")
        expect(
            popoverResizeResult.1,
            "final popover resize commits published height")

        // Tray animation timing: preserve the shipping integer-millisecond
        // cadence while mapping the runner rate from 2 to 40 fps.
        let idleLoad = TrayAnimator.animationLoad(tokensPerMinute: 0)
        let thresholdLoad = TrayAnimator.animationLoad(tokensPerMinute: 50_000)
        let mediumLoad = TrayAnimator.animationLoad(tokensPerMinute: 100_000)
        let quantizedLoad = TrayAnimator.animationLoad(tokensPerMinute: 333_000)
        let fullLoad = TrayAnimator.animationLoad(tokensPerMinute: 1_000_000)
        let clampedLoad = TrayAnimator.animationLoad(tokensPerMinute: 2_000_000)
        expect(TrayAnimator.effectiveAnimationFPS(load: idleLoad) == 2, "tray idle is 2 fps")
        expect(TrayAnimator.effectiveAnimationFPS(load: thresholdLoad) == 2, "tray 50K threshold is 2 fps")
        expect(TrayAnimator.effectiveAnimationFPS(load: mediumLoad) == 4, "tray 100K is 4 fps")
        expect(
            TrayAnimator.animationIntervalMilliseconds(load: quantizedLoad) == 75,
            "tray cadence preserves integer-ms quantization")
        expect(TrayAnimator.effectiveAnimationFPS(load: fullLoad) == 40, "tray 1M is 40 fps")
        expect(TrayAnimator.effectiveAnimationFPS(load: clampedLoad) == 40, "tray speed clamps at 40 fps")
        expect(TrayAnimator.baseAnimationDuration(frameCount: 5) == 2.5, "tray five-frame base duration")
        expect(TrayAnimator.baseAnimationDuration(frameCount: 10) == 5, "tray ten-frame base duration")

#if DEBUG
        let trayFrameURL = Bundle.tokenBarResources.url(
            forResource: "frame-00",
            withExtension: "png",
            subdirectory: "anim-cat2"
        )
        let trayFrame = trayFrameURL.flatMap(NSImage.init(contentsOf:))
        trayFrame?.size = NSSize(width: 18, height: 18)
        let oneX = trayFrame.flatMap {
            StatusItemAnimationSurface.rasterizedFrameMetricsForTesting(
                $0,
                scale: 1
            )
        }
        let twoX = trayFrame.flatMap {
            StatusItemAnimationSurface.rasterizedFrameMetricsForTesting(
                $0,
                scale: 2
            )
        }
        expect(
            oneX?.pixelSize == CGSize(width: 18, height: 18),
            "tray 1x raster is 18 pixels"
        )
        expect(
            twoX?.pixelSize == CGSize(width: 36, height: 36),
            "tray 2x raster is 36 pixels"
        )
        expect(
            twoX.map { $0.alphaBounds.width } ?? 0
                >= (oneX.map { $0.alphaBounds.width } ?? .infinity) * 1.8
                && (twoX.map { $0.alphaBounds.height } ?? 0)
                    >= (oneX.map { $0.alphaBounds.height } ?? .infinity) * 1.8,
            "tray 2x raster preserves logical alpha coverage"
        )
#endif

        // ModelColors: provider inference + shade math.
        expect(ModelColors.providerFromModel("claude-sonnet-4-6") == "anthropic", "provider claude")
        expect(ModelColors.providerFromModel("gpt-5.5") == "openai", "provider gpt")
        expect(ModelColors.providerFromModel("o3-mini") == "openai", "provider o3")
        expect(ModelColors.providerFromModel("gemini-3-pro") == "google", "provider gemini")
        expect(ModelColors.providerFromModel("auto") == "cursor", "provider cursor auto")
        expect(ModelColors.providerFromModel("mystery") == "unknown", "provider unknown")
        expect(ModelColors.providerColorKey("litellm, openai", "gpt-5.5") == "openai", "merged provider id")
        expect(ModelColors.providerColorKey("Anthropic", "whatever") == "anthropic", "provider id alias")
        expect(ModelColors.shadeFromBase("#da7756", rank: 0) == "#da7756", "shade rank 0 is base")
        // rank 1 factor 0.11: 59→81 (0x51), 130→144 (0x90), 246→247 (0xf7)
        expect(ModelColors.shadeFromBase("#3b82f6", rank: 1) == "#5190f7", "shade rank 1 lerp")

        let providerSplitReportJSON = """
        {"entries":[
          {"client":"claude","model":"shared-model","provider":"openai",
           "input":100,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0,
           "total":100,"messageCount":1,"cost":6.0,"msPer1kTokens":2.0},
          {"client":"claude","model":"shared-model","provider":"nvidia",
           "input":200,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0,
           "total":200,"messageCount":1,"cost":5.0,"msPer1kTokens":3.0},
          {"client":"claude","model":"runner-up","provider":"openai",
           "input":150,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0,
           "total":150,"messageCount":1,"cost":9.0,"msPer1kTokens":1.0}
        ],"totalInput":450,"totalOutput":0,"totalCacheRead":0,"totalCacheWrite":0,
        "totalMessages":3,"totalCost":20.0}
        """
        let providerSplitReport = try! JSONDecoder().decode(
            ModelReport.self, from: Data(providerSplitReportJSON.utf8))
        let modelLevelEntries = providerSplitReport.modelLevelEntries
        let favoriteModel = modelLevelEntries.max { $0.cost < $1.cost }
        expect(
            favoriteModel?.model == "shared-model" && favoriteModel?.cost == 11.0,
            "provider-split favorite uses combined model cost")
        let modelCardRows = modelLevelEntries.filter { $0.client == "claude" }
        expect(
            modelCardRows.count == 2 && modelCardRows.filter { $0.model == "shared-model" }.count == 1,
            "provider-split model count treats one model as one row")
        expect(
            modelLevelEntries.first { $0.model == "shared-model" }?.provider == "nvidia, openai",
            "provider-split model fold preserves merged providers")
        expect(
            modelLevelEntries.first { $0.model == "shared-model" }?.msPer1kTokens == nil,
            "provider-split model fold omits unrecomputable throughput")

        // Implausible self-reported cost. A client that records its own cost
        // (OpenCode, MiMo Code) has it taken verbatim by tokscale-core and
        // never priced, so this comparison against the local estimate is the
        // only thing between a unit error upstream and the number on screen.
        func costEntry(_ cost: Double, _ estimate: Double?, provider: String = "p") -> String {
            """
            {"client":"c","model":"m","provider":"\(provider)",
             "input":1,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0,
             "total":1,"messageCount":1,"cost":\(cost),"msPer1kTokens":null,
             "costEstimate":\(estimate.map { "\($0)" } ?? "null")}
            """
        }
        func costReport(_ entries: [String]) -> ModelReport {
            let json = """
            {"entries":[\(entries.joined(separator: ","))],
             "totalInput":1,"totalOutput":0,"totalCacheRead":0,"totalCacheWrite":0,
             "totalMessages":\(entries.count),"totalCost":0.0}
            """
            return try! JSONDecoder().decode(ModelReport.self, from: Data(json.utf8))
        }
        func onlyRow(_ entries: [String]) -> ModelReportEntry {
            costReport(entries).modelLevelEntries[0]
        }

        expect(
            onlyRow([costEntry(1000, 1)]).implausibleCostRatio == 1000,
            "a cost 1000x the local estimate is flagged, with that multiple — the shape of "
                + "the user report where a per-1K rate was billed per-token")
        expect(
            onlyRow([costEntry(CostPlausibility.threshold, 1)]).implausibleCostRatio == nil
                && onlyRow([costEntry(CostPlausibility.threshold + 0.5, 1)])
                    .implausibleCostRatio != nil,
            "the threshold is pinned from both sides, so a comparison flipped to >= or < "
                + "cannot pass this pair")
        expect(
            onlyRow([costEntry(0.3, 1)]).implausibleCostRatio == nil,
            "a row costing LESS than the estimate is never flagged — every healthy row "
                + "measured on real data sits at 0.1-0.3x, so a two-sided check would flag "
                + "all of them forever")
        expect(
            onlyRow([costEntry(0, 1)]).implausibleCostRatio == nil,
            "a genuinely free model reports 0.0 against a positive estimate and must stay quiet")
        expect(
            onlyRow([costEntry(99_999, nil)]).implausibleCostRatio == nil,
            "no estimate means the table cannot price these tokens at all, which is not "
                + "evidence about the reported cost — and must not divide by nil")
        expect(
            onlyRow([costEntry(99_999, 0)]).implausibleCostRatio == nil,
            "a zero estimate is not a usable denominator")

        // The fold is where a pre-fold ratio would go wrong (PR #264 review):
        // one broken component merged with a larger healthy row is NOT the
        // component's multiple. 100/1 + 1000/1000 = 1100/1001 = 1.1x.
        let mergedMostlyHealthy = onlyRow([
            costEntry(100, 1, provider: "a"), costEntry(1000, 1000, provider: "b"),
        ])
        expect(
            mergedMostlyHealthy.cost == 1100 && mergedMostlyHealthy.costEstimate == 1001,
            "the fold sums cost and estimate together, so the ratio describes the merged row")
        expect(
            mergedMostlyHealthy.implausibleCostRatio == nil,
            "a merged row at 1.1x is not flagged, even though one component alone was 100x — "
                + "carrying the component's ratio onto the aggregate would be materially false")
        expect(
            onlyRow([costEntry(100_000, 1, provider: "a"), costEntry(1000, 1000, provider: "b")])
                .implausibleCostRatio != nil,
            "a component broken badly enough to distort the merged total still flags after "
                + "the fold — the warning is not lost by summing")
        expect(
            onlyRow([costEntry(100_000, nil, provider: "a"), costEntry(1, 1, provider: "b")])
                .costEstimate == nil,
            "one unpriceable component makes the merged estimate a partial denominator, "
                + "which would overstate the ratio — the merged row reports no estimate instead")
        expect(
            CostPlausibility.warningText(308.4).contains("308")
                && !CostPlausibility.warningText(308.4).contains("308.4"),
            "the warning names the multiple as a whole number — one wording shared by the "
                + "tooltip line and the icon's accessibility label, which is the only channel "
                + "a VoiceOver user has because the tooltip is pointer-only")

        // Usage attribution: declarations are explicit, provider-level by
        // default, and model overrides are more specific. Suggestions never
        // participate in effective-state resolution.
        func attributionEntry(
            client: String, provider: String, model: String,
            total: Int64 = 1, cost: Double = 0.0
        ) -> ModelReportEntry {
            let json = """
            {"client":"\(client)","model":"\(model)","provider":"\(provider)",
             "input":1,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0,
             "total":\(total),"messageCount":1,"cost":\(cost),"msPer1kTokens":null}
            """
            return try! JSONDecoder().decode(
                ModelReportEntry.self, from: Data(json.utf8))
        }

        func contributionJSON(
            date: String,
            clients: [(String, String, String, Int64, Double)],
            totalsTokens: Int64,
            totalsCost: Double
        ) -> String {
            let clientJSON = clients.map { client in
                """
                {"client":"\(client.0)","modelId":"\(client.1)","providerId":"\(client.2)","tokens":{"input":\(client.3),"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0},"cost":\(client.4),"messages":1}
                """
            }.joined(separator: ",")
            return """
            {"date":"\(date)","totals":{"tokens":\(totalsTokens),"cost":\(totalsCost),"messages":\(clients.count)},"intensity":0,"tokenBreakdown":{"input":\(totalsTokens),"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0},"clients":[\(clientJSON)]}
            """
        }

        func contributionFixture(_ json: String) -> Contribution {
            try! JSONDecoder().decode(Contribution.self, from: Data(json.utf8))
        }

        func payloadFixture(_ contributionJSON: [String]) -> UsagePayload {
            let json = """
            {"meta":{"generatedAt":"now","version":"selftest","dateRange":{"start":"2023-12-31","end":"2024-12-31"}},"summary":{"totalTokens":0,"totalCost":0.0,"totalDays":0,"activeDays":0,"averagePerDay":0.0,"maxCostInSingleDay":0.0,"clients":[],"models":[]},"years":[],"contributions":[\(contributionJSON.joined(separator: ","))]}
            """
            return try! JSONDecoder().decode(UsagePayload.self, from: Data(json.utf8))
        }

        let claudeOpenAIEntry = attributionEntry(
            client: "claude", provider: "openai", model: "gpt-5.6-sol")
        expect(
            UsageAttribution.resolve(
                client: "claude", provider: "openai", model: "gpt-5.6-sol", records: [])
                == .unassigned,
            "empty attribution table resolves unassigned")

        let providerDeclaration = UsageAttribution.Record(
            client: "claude", provider: "openai", state: .excluded)
        let modelDeclaration = UsageAttribution.Record(
            client: "claude", provider: "openai", model: "gpt-5.6-sol",
            state: .assigned("codex"))
        expect(
            UsageAttribution.resolve(claudeOpenAIEntry, records: [providerDeclaration, modelDeclaration])
                == .assigned("codex"),
            "model attribution override wins over provider declaration")

        let crossAssignment = UsageAttribution.Record(
            client: "claude", provider: "openai", state: .assigned("codex"))
        let crossAssignmentRaw = UsageAttribution.confirmedRaw(
            updating: nil, record: crossAssignment)
        expect(
            crossAssignmentRaw
                == "[{\"client\":\"claude\",\"model\":null,\"provider\":\"openai\",\"state\":\"assigned\",\"target\":\"codex\"}]"
                && UsageAttribution.parseRaw(crossAssignmentRaw).records.first?.state
                    == .assigned("codex"),
            "cross-client attribution round-trips its target")

        let emptyProviderDeclaration = UsageAttribution.Record(
            client: "opencode", provider: "", state: .assigned("codex"))
        let namedProviderDeclaration = UsageAttribution.Record(
            client: "opencode", provider: "nvidia", state: .excluded)
        let emptyProviderEntry = attributionEntry(
            client: "opencode", provider: "", model: "deepseek-v4-pro")
        let namedProviderEntry = attributionEntry(
            client: "opencode", provider: "nvidia", model: "deepseek-v4-pro")
        func applyConfirmed(_ records: [UsageAttribution.Record]) -> String? {
            records.reduce(String?.none) { raw, record in
                UsageAttribution.confirmedRaw(updating: raw, record: record)
            }
        }
        let emptyProviderRaw = applyConfirmed([namedProviderDeclaration, emptyProviderDeclaration])
        expect(
            UsageAttribution.resolve(emptyProviderEntry, records: [namedProviderDeclaration, emptyProviderDeclaration])
                == .assigned("codex")
                && UsageAttribution.resolve(namedProviderEntry, records: [namedProviderDeclaration, emptyProviderDeclaration])
                    == .excluded
                && emptyProviderRaw
                    == "[{\"client\":\"opencode\",\"model\":null,\"provider\":\"\",\"state\":\"assigned\",\"target\":\"codex\"},{\"client\":\"opencode\",\"model\":null,\"provider\":\"nvidia\",\"state\":\"excluded\"}]",
            "empty provider is a distinct usable source key")

        let providerRows = UsageAttributionSettings.rows(
            entries: [
                attributionEntry(
                    client: "claude", provider: "openai", model: "shared-model",
                    total: 100, cost: 6.0),
                attributionEntry(
                    client: "claude", provider: "nvidia", model: "shared-model",
                    total: 200, cost: 5.0),
                attributionEntry(
                    client: "claude", provider: "openai", model: "other-model",
                    total: 50, cost: 1.0),
            ],
            confirmed: [],
            suggestions: [])
        expect(
                providerRows.count == 2
                && providerRows.map(\.provider) == ["openai", "nvidia"]
                && providerRows.map(\.tokens) == [150, 200]
                && providerRows.map(\.cost) == [7.0, 5.0],
            "attribution rows retain two providers for one model")

        // Stats attribution consumes raw provider rows. Keep bucket totals
        // lossless so a mixed model cannot hide a source classification.
        let breakdownEntries = [
            attributionEntry(
                client: "claude", provider: "anthropic", model: "claude-model",
                total: 100, cost: 1.0),
            attributionEntry(
                client: "claude", provider: "openai", model: "gpt-model",
                total: 200, cost: 2.0),
            attributionEntry(
                client: "claude", provider: "nvidia", model: "deepseek-model",
                total: 300, cost: 3.0),
        ]
        let breakdownRecords = [
            UsageAttribution.Record(
                client: "claude", provider: "anthropic", state: .assigned("claude")),
            UsageAttribution.Record(
                client: "claude", provider: "openai", state: .excluded),
        ]
        let oneEachBreakdown = UsageAttributionBreakdown.rows(
            entries: breakdownEntries, clientIds: ["claude"], confirmed: breakdownRecords)
        expect(
            oneEachBreakdown.map(\.state) == [
                UsageAttribution.State.assigned("claude"), .excluded, .unassigned,
            ]
                && oneEachBreakdown.map(\.tokens) == [100, 200, 300]
                && oneEachBreakdown.map(\.cost) == [1.0, 2.0, 3.0],
            "attribution breakdown reports assigned, excluded, and unassigned buckets")

        // Unpriced/local usage still carries tokens. Keep every bucket's
        // non-zero guard load-bearing so zero-cost rows cannot vanish.
        let zeroCostBreakdown = UsageAttributionBreakdown.rows(
            entries: [
                attributionEntry(
                    client: "claude", provider: "anthropic", model: "zero-assigned",
                    total: 11, cost: 0.0),
                attributionEntry(
                    client: "claude", provider: "openai", model: "zero-excluded",
                    total: 22, cost: 0.0),
                attributionEntry(
                    client: "claude", provider: "local", model: "zero-unassigned",
                    total: 33, cost: 0.0),
            ],
            clientIds: ["claude"],
            confirmed: [
                UsageAttribution.Record(
                    client: "claude", provider: "anthropic", state: .assigned("claude")),
                UsageAttribution.Record(
                    client: "claude", provider: "openai", state: .excluded),
            ])
        expect(
            zeroCostBreakdown.map(\.state) == [
                UsageAttribution.State.assigned("claude"), .excluded, .unassigned,
            ]
                && zeroCostBreakdown.map(\.tokens) == [11, 22, 33]
                && zeroCostBreakdown.map(\.cost) == [0.0, 0.0, 0.0],
            "zero-cost tokens remain visible in every attribution bucket")

        let mergedBreakdown = UsageAttributionBreakdown.rows(
            entries: [
                attributionEntry(
                    client: "claude", provider: "openai", model: "one",
                    total: 10, cost: 1.0),
                attributionEntry(
                    client: "claude", provider: "anthropic", model: "two",
                    total: 20, cost: 2.0),
                attributionEntry(
                    client: "claude", provider: "nvidia", model: "three",
                    total: 30, cost: 3.0),
            ],
            clientIds: ["claude"],
            confirmed: [
                UsageAttribution.Record(
                    client: "claude", provider: "openai", state: .assigned("codex")),
                UsageAttribution.Record(
                    client: "claude", provider: "anthropic", state: .assigned("codex")),
                UsageAttribution.Record(
                    client: "claude", provider: "nvidia", state: .assigned("claude")),
            ])
        expect(
            mergedBreakdown.map(\.state) == [
                UsageAttribution.State.assigned("claude"), .assigned("codex"),
            ]
                && mergedBreakdown.map(\.tokens) == [30, 30]
                && mergedBreakdown.map(\.cost) == [3.0, 3.0],
            "attribution breakdown merges same targets and keeps targets separate")

        expect(
            oneEachBreakdown.reduce(Int64.zero) { $0 + $1.tokens } == 600
                && oneEachBreakdown.reduce(0.0) { $0 + $1.cost } == 6.0,
            "attribution breakdown preserves pinned unfiltered totals")

        let overrideBreakdown = UsageAttributionBreakdown.rows(
            entries: [claudeOpenAIEntry],
            clientIds: ["claude"],
            confirmed: [providerDeclaration, modelDeclaration])
        expect(
            overrideBreakdown.count == 1
                && overrideBreakdown[0].state == .assigned("codex")
                && overrideBreakdown[0].tokens == 1
                && overrideBreakdown[0].cost == 0.0,
            "attribution breakdown delegates model override resolution")

        let suggestionOnlyRecords = UsageAttributionSettings.suggestionRecords(
            entries: [
                attributionEntry(
                    client: "claude", provider: "anthropic", model: "claude-model",
                    total: 40, cost: 4.0),
            ],
            confirmed: [],
            subscriptionClients: ["claude"])
        let suggestionOnlyBreakdown = UsageAttributionBreakdown.rows(
            entries: [
                attributionEntry(
                    client: "claude", provider: "anthropic", model: "claude-model",
                    total: 40, cost: 4.0),
            ],
            clientIds: ["claude"],
            confirmed: [])
        expect(
            suggestionOnlyRecords.count == 1
                && suggestionOnlyBreakdown.count == 1
                && suggestionOnlyBreakdown[0].state == .unassigned
                && suggestionOnlyBreakdown[0].tokens == 40
                && suggestionOnlyBreakdown[0].cost == 4.0,
            "suggestion-only attribution remains unassigned")

        let emptyBreakdown = UsageAttributionBreakdown.rows(
            entries: [
                attributionEntry(
                    client: "claude", provider: "openai", model: "one",
                    total: 10, cost: 1.0),
                attributionEntry(
                    client: "claude", provider: "nvidia", model: "two",
                    total: 20, cost: 2.0),
            ],
            clientIds: ["claude"],
            confirmed: [])
        expect(
            emptyBreakdown.count == 1
                && emptyBreakdown[0].state == .unassigned
                && emptyBreakdown[0].tokens == 30
                && emptyBreakdown[0].cost == 3.0,
            "empty attribution table puts all usage in unassigned")

        let selectedOnlyBreakdown = UsageAttributionBreakdown.rows(
            entries: [
                attributionEntry(
                    client: "claude", provider: "openai", model: "selected-assigned",
                    total: 10, cost: 1.0),
                attributionEntry(
                    client: "claude", provider: "anthropic", model: "selected-excluded",
                    total: 20, cost: 2.0),
                attributionEntry(
                    client: "claude", provider: "nvidia", model: "selected-unassigned",
                    total: 30, cost: 3.0),
                attributionEntry(
                    client: "codex", provider: "openai", model: "hidden-assigned",
                    total: 100, cost: 10.0),
                attributionEntry(
                    client: "codex", provider: "anthropic", model: "hidden-excluded",
                    total: 200, cost: 20.0),
                attributionEntry(
                    client: "codex", provider: "nvidia", model: "hidden-unassigned",
                    total: 300, cost: 30.0),
            ],
            clientIds: ["claude"],
            confirmed: [
                UsageAttribution.Record(
                    client: "claude", provider: "openai", state: .assigned("codex")),
                UsageAttribution.Record(
                    client: "claude", provider: "anthropic", state: .excluded),
                UsageAttribution.Record(
                    client: "codex", provider: "openai", state: .assigned("codex")),
                UsageAttribution.Record(
                    client: "codex", provider: "anthropic", state: .excluded),
            ])
        expect(
            selectedOnlyBreakdown.map(\.state) == [
                UsageAttribution.State.assigned("codex"), .excluded, .unassigned,
            ]
                && selectedOnlyBreakdown.map(\.tokens) == [10, 20, 30]
                && selectedOnlyBreakdown.map(\.cost) == [1.0, 2.0, 3.0],
            "attribution breakdown filters every bucket by selected clients")

        let emptyProviderRow = UsageAttributionSettings.rows(
            entries: [attributionEntry(
                client: "opencode", provider: "", model: "shared-model", total: 7, cost: 1.5)],
            confirmed: [],
            suggestions: []).first
        expect(
            emptyProviderRow?.provider.isEmpty == true
                && emptyProviderRow?.providerLabel == "Unspecified provider",
            "empty provider row has a readable label")

        let attributionTargets = UsageAttributionSettings.subscriptionClients(
            from: DemoData.agentUsage)
        let claudeProviderRow = providerRows.first { $0.client == "claude" }
        expect(
            claudeProviderRow?.client == "claude" && attributionTargets.contains("codex"),
            "claude source rows can target a different subscription client")

        expect(
            UsageAttributionSettings.suggestionTarget(
                sourceClient: "copilot", provider: "openai",
                subscriptionClients: attributionTargets) == .assigned("copilot"),
            "copilot openai usage suggests copilot")
        expect(
            UsageAttributionSettings.suggestionTarget(
                sourceClient: "copilot", provider: "anthropic",
                subscriptionClients: attributionTargets) == .assigned("copilot"),
            "copilot anthropic usage suggests copilot")
        expect(
            UsageAttributionSettings.suggestionTarget(
                sourceClient: "claude", provider: "anthropic",
                subscriptionClients: attributionTargets) == .assigned("claude"),
            "claude anthropic usage suggests claude")
        // The case the whole feature exists for: a gateway routes Claude Code to
        // an OpenAI model, so the row says claude/openai while the subscription
        // consumed is Codex. Asking source-first would leave exactly these rows
        // unsuggested, which is most of the usage on a gateway user's machine.
        expect(
            UsageAttributionSettings.suggestionTarget(
                sourceClient: "claude", provider: "openai",
                subscriptionClients: ["claude", "codex"]) == .assigned("codex"),
            "gateway-routed openai usage suggests the codex subscription")
        // opencode is a router with no plan of its own, so with nothing declared
        // about what it is signed into, nothing can be said. This used to answer
        // `.excluded` — an assertion that the tokens were bought — which the
        // 2026-08 survey showed there was never evidence for.
        expect(
            UsageAttributionSettings.suggestionTarget(
                sourceClient: "opencode", provider: "anthropic",
                subscriptionClients: ["claude", "codex"]) == nil,
            "an undeclared router produces no suggestion")
        // Declare what it is signed into and the answer follows from that, not
        // from any policy about who may reach anthropic from where: the user
        // authed to Copilot here deliberately.
        expect(
            UsageAttributionSettings.suggestionTarget(
                sourceClient: "opencode", provider: "anthropic",
                subscriptionClients: ["claude", "copilot"],
                routedSubscriptions: ["opencode": ["copilot"]]) == .assigned("copilot"),
            "a declared router spends the subscription it is signed into")
        // Two of its subscriptions cover the provider, so which one paid is not
        // decidable from here.
        expect(
            UsageAttributionSettings.suggestionTarget(
                sourceClient: "opencode", provider: "anthropic",
                subscriptionClients: ["claude", "copilot"],
                routedSubscriptions: ["opencode": ["claude", "copilot"]]) == nil,
            "a router signed into two covering subscriptions produces no suggestion")
        // copilot accepts openai too, so with both subscribed nothing here can
        // tell which one paid. Suggesting either would be a coin flip presented
        // as an inference.
        // claude does not sell an openai plan, so this falls to the cross-agent
        // path where codex and copilot both cover it — undecidable from here.
        expect(
            UsageAttributionSettings.suggestionTarget(
                sourceClient: "claude", provider: "openai",
                subscriptionClients: ["claude", "codex", "copilot"]) == nil,
            "two subscriptions covering one provider produce no suggestion")
        expect(
            UsageAttributionSettings.suggestionTarget(
                sourceClient: "claude", provider: "openai",
                subscriptionClients: ["claude"]) == nil,
            "no subscription covering the provider produces no suggestion")
        expect(
            UsageAttributionSettings.suggestionTarget(
                sourceClient: "copilot", provider: "openai",
                subscriptionClients: ["codex", "copilot"]) == .assigned("copilot"),
            "an owning source client wins over another subscription that also covers it")
        // xAI signs third-party agents in with the subscription itself, and
        // that usage draws on the same weekly pool, so it really is the
        // subscription being spent.
        expect(
            UsageAttributionSettings.suggestionTarget(
                sourceClient: "claude", provider: "xai",
                subscriptionClients: ["claude", "grok"]) == .assigned("grok"),
            "xai reached from another client is spending the grok subscription")
        // Cursor bundles a jointly-trained Grok, so an xai row it logged is its
        // own plan — the survey's clearest example of a reseller relationship
        // that the old provider-keyed model could not express.
        expect(
            UsageAttributionSettings.suggestionTarget(
                sourceClient: "cursor", provider: "xai",
                subscriptionClients: ["grok"]) == .assigned("cursor"),
            "cursor's bundled grok is cursor's own spend")
        // The two policies contradict each other, so no provider may appear in
        // both — otherwise which one wins depends on the order of the branches.
        expect(
            UsageAttributionSettings.crossAgentSubscriptionProviders
                .isDisjoint(with: UsageAttributionSettings.subscriptionBoundProviders),
            "a provider cannot be both safe and unsafe to assign across agents")
        // Every provider a subscription can serve needs a decided policy. This
        // is what stops a new entry in the map from silently inheriting the
        // permissive branch: adding one without choosing a side fails here.
        let policedProviders = UsageAttributionSettings.crossAgentSubscriptionProviders
            .union(UsageAttributionSettings.subscriptionBoundProviders)
        let servedProviders = Set(
            UsageAttributionSettings.subscriptionProviderMap.values.flatMap { $0 })
        expect(
            servedProviders.isSubset(of: policedProviders),
            "every provider a subscription serves has a checked cross-agent policy")

        let codexOnlyPayload = try! JSONDecoder().decode(
            AgentUsagePayload.self,
            from: Data(#"{"generatedAt":"now","agents":[{"clientId":"codex","source":"fixture","updatedAt":"now","identity":{"plan":"Plus"},"windows":[]}]}"#.utf8))
        let codexOnlySubscriptions = UsageAttributionSettings.subscriptionClients(
            from: codexOnlyPayload)
        let terminalAndLastGoodPayload = try! JSONDecoder().decode(
            AgentUsagePayload.self,
            from: Data(#"{"generatedAt":"now","agents":[{"clientId":"codex","source":"fixture","updatedAt":"now","windows":[],"error":"not configured"},{"clientId":"claude","source":"fixture","updatedAt":"now","windows":[],"error":"not configured"},{"clientId":"copilot","source":"fixture","updatedAt":"now","identity":{"plan":"Pro"},"windows":[],"error":"temporarily unavailable"}]}"#.utf8))
        expect(
            UsageAttributionSettings.subscriptionClients(from: terminalAndLastGoodPayload)
                == ["copilot"],
            "terminal empty provider cards are not subscription candidates, but last-good cards remain")

        // A subscription reached only through opencode has no snapshot of its
        // own — just the empty placeholder the filter above removes — so without
        // folding the labels back in, exactly the rows that consume it cannot
        // name it. This is the case the placeholder filter regressed.
        let opencodeOnlyPayload = try! JSONDecoder().decode(
            AgentUsagePayload.self,
            from: Data(#"{"generatedAt":"now","agents":[{"clientId":"codex","source":"fixture","updatedAt":"now","windows":[],"error":"not configured"}],"opencodeSubscriptions":["Codex","Gemini"]}"#.utf8))
        expect(
            UsageAttributionSettings.subscriptionClients(from: opencodeOnlyPayload)
                == ["codex", "antigravity"],
            "an opencode-only subscription is still an assignment target")
        // Both statements naming the same client must not produce it twice.
        let opencodeDuplicatePayload = try! JSONDecoder().decode(
            AgentUsagePayload.self,
            from: Data(#"{"generatedAt":"now","agents":[{"clientId":"codex","source":"fixture","updatedAt":"now","identity":{"plan":"Plus"},"windows":[]}],"opencodeSubscriptions":["Codex"]}"#.utf8))
        expect(
            UsageAttributionSettings.subscriptionClients(from: opencodeDuplicatePayload) == ["codex"],
            "a subscription reported by both sources appears once")

        // Kiro is a real multi-vendor subscription (architecture.md attribution
        // table), not a router: its own quota snapshot makes it an assignment
        // target, exactly like Copilot and unlike opencode, which is excluded.
        // The Kiro provider now publishes such a snapshot, so this guards that
        // it is admitted here rather than filtered out.
        let kiroPayload = try! JSONDecoder().decode(
            AgentUsagePayload.self,
            from: Data(#"{"generatedAt":"now","agents":[{"clientId":"kiro","source":"oauth","updatedAt":"now","identity":{"plan":"Kiro Pro"},"windows":[{"cardId":"usage.v1","label":"Monthly","usedPercent":41,"remainingPercent":59,"paceStatus":{"state":"learningDuration","windowKey":"usage.v1","completeCycles":0}}]}]}"#.utf8))
        expect(
            UsageAttributionSettings.subscriptionClients(from: kiroPayload) == ["kiro"],
            "a kiro quota snapshot makes kiro an assignment target")
        // Kiro sells a deepseek plan, so a kiro row logged against deepseek is
        // its own spend — the owning-source rule resolves it to kiro.
        expect(
            UsageAttributionSettings.suggestionTarget(
                sourceClient: "kiro", provider: "deepseek",
                subscriptionClients: ["kiro"]) == .assigned("kiro"),
            "kiro's own deepseek usage suggests the kiro subscription")

        // The structural guard, not another hand-kept row. Rust's
        // `subscription_label` renames four providers and capitalizes the rest,
        // so every provider a subscription serves must be reachable from its
        // capitalized label. `xai` was not — a Grok subscription reached only
        // through opencode could not be named — and only a check derived from
        // the map itself fails when the next provider is added.
        // opencode emits a label only for a vendor the user actually authed to,
        // so the set it can produce is the vendors that sell first-party access
        // — not every vendor some subscription carries. `microsoft`, `amazon`,
        // `open-weights` and `own` are sold only inside someone else's bundle
        // and can never appear as an oauth entry. The assertion is therefore
        // that every first-party vendor resolves, and that resolution names
        // that vendor's own client rather than a reseller that also carries it.
        let firstPartyVendors = UsageAttributionSettings.providerOwnClient
        let unresolvableVendors = firstPartyVendors.filter { vendor, expected in
            let label = vendor.prefix(1).uppercased() + vendor.dropFirst()
            return UsageAttributionSettings.subscriptionClient(forLabel: label) != expected
        }
        expect(
            unresolvableVendors.isEmpty,
            "every first-party vendor resolves from its opencode label to its own client (broken: \(unresolvableVendors.keys.sorted()))")
        // The four the producer renames rather than capitalizes.
        expect(
            ClientRegistry.subscriptionLabelAliases.allSatisfy { label, id in
                UsageAttributionSettings.subscriptionClient(forLabel: label) == id
                    && ClientRegistry.allIds.contains(id)
            },
            "every renamed opencode label resolves to a registered client")
        expect(
            UsageAttributionSettings.subscriptionClient(forLabel: "Xai") == "grok",
            "an opencode xai subscription names the grok client")
        // opencode's provider keys carry the plan: `minimax-coding-plan` becomes
        // the label `Minimax-coding-plan`, which no vendor lookup matches. These
        // vendors sell per-plan keys, so the qualifier is trimmed rather than
        // each plan enumerated.
        expect(
            UsageAttributionSettings.subscriptionClient(forLabel: "Minimax-coding-plan") == "micode"
                && UsageAttributionSettings.subscriptionClient(forLabel: "Kimi-for-coding") == "kimi",
            "a plan-qualified opencode label resolves to its vendor's client")
        // Trimming must not turn an unknown vendor into a known one.
        expect(
            UsageAttributionSettings.subscriptionClient(forLabel: "Crush-plan") == nil,
            "trimming a qualifier does not invent a subscription")

        // Routing is a second input to every suggestion, and it can change while
        // the resolved target list does not: a Codex snapshot contributes
        // `codex` whether or not opencode also holds an OpenAI oauth entry.
        let routingEntries = [attributionEntry(
            client: "opencode", provider: "openai", model: "gpt-5.6-sol", total: 1, cost: 0.1)]
        expect(
            UsageAttributionSettings.signature(
                entries: routingEntries, subscriptionClients: ["codex"],
                routedSubscriptions: [:])
                != UsageAttributionSettings.signature(
                    entries: routingEntries, subscriptionClients: ["codex"],
                    routedSubscriptions: ["opencode": ["codex"]]),
            "routing state changes the refresh signature even when targets do not")
        // A label that lowercases to a registered client which sells no plan
        // must still name nothing — returning it would put an unresolvable
        // target in the picker. `Kiro` no longer serves as the example: the
        // corrected table says Kiro does sell one, so the case moved to a client
        // that genuinely does not.
        expect(
            UsageAttributionSettings.subscriptionClient(forLabel: "Crush") == nil
                && ClientRegistry.allIds.contains("crush")
                && UsageAttributionSettings.subscriptionProviderMap["crush"] == nil,
            "an opencode label naming no subscription is not a target")

        // These three previously encoded the reseller rule as a property of the
        // *provider*: anthropic reached from anywhere else was assigned to
        // whichever non-Claude subscription covered it. The survey showed the
        // premise is wrong — an opencode row is paid by whatever opencode is
        // signed into, and that is declared, not inferred from who else carries
        // anthropic. Undeclared, the honest answer is nothing.
        expect(
            UsageAttributionSettings.suggestionTarget(
                sourceClient: "opencode", provider: "anthropic",
                subscriptionClients: ["copilot"]) == nil,
            "an undeclared router is not assigned to whoever happens to cover the provider")
        expect(
            UsageAttributionSettings.suggestionTarget(
                sourceClient: "opencode", provider: "anthropic",
                subscriptionClients: ["copilot"],
                routedSubscriptions: ["opencode": ["copilot"]]) == .assigned("copilot"),
            "the same row is assigned once the routing is declared")
        // Anthropic's own subscription is still never a cross-agent target: a
        // client that sells no anthropic plan and routes nowhere gets excluded.
        expect(
            UsageAttributionSettings.suggestionTarget(
                sourceClient: "zed", provider: "xai",
                subscriptionClients: ["grok"]) == .assigned("grok"),
            "a surveyed client that does not sell the provider still uses the cross-agent path")
        // Every provider a subscription serves must name the client whose own
        // subscription it is, or the eligibility filter above silently keeps a
        // bound owner assignable.
        // Only a bound provider needs an own client — that entry names who the
        // restriction protects. Requiring one for permitted providers would be
        // inventing a fact; requiring one for bound providers is what stops the
        // eligibility filter from silently leaving a bound owner assignable.
        let unownedBound = UsageAttributionSettings.subscriptionBoundProviders
            .filter { UsageAttributionSettings.providerOwnClient[$0] == nil }
        expect(
            unownedBound.isEmpty,
            "every bound provider names the client it protects (missing: \(unownedBound.sorted()))")
        let ownClientsAreRegistered = UsageAttributionSettings.providerOwnClient.values
            .allSatisfy { ClientRegistry.allIds.contains($0) }
        expect(ownClientsAreRegistered, "every protected client is registered")

        // The table is hand-maintained product knowledge, so every client in it
        // must be a client this app knows — a typo would otherwise sit there
        // covering nothing.
        let unknownSubscriptionClients = UsageAttributionSettings.subscriptionProviderMap.keys
            .filter { !ClientRegistry.allIds.contains($0) }
        expect(
            unknownSubscriptionClients.isEmpty,
            "every subscription client is registered (unknown: \(unknownSubscriptionClients.sorted()))")

        // The case the whole survey was run for. Cursor sells its own plan
        // covering Anthropic models, and TokenBar has no Cursor quota gauge — so
        // a rule that asks `subscriptionClients` cannot see it, and the row gets
        // proposed against whatever else happens to cover anthropic.
        expect(
            UsageAttributionSettings.suggestionTarget(
                sourceClient: "cursor", provider: "anthropic",
                subscriptionClients: ["claude", "copilot"]) == .assigned("cursor"),
            "a client's own subscription wins even without a quota snapshot")
        // And the same row must not be offered to a subscription that merely
        // also covers anthropic.
        expect(
            UsageAttributionSettings.suggestionTarget(
                sourceClient: "cursor", provider: "anthropic",
                subscriptionClients: ["copilot"]) != .assigned("copilot"),
            "a foreign subscription is never proposed for a client that has its own")
        // A source the table says nothing about yields nothing. `crush` is
        // registered but no plan has been established for it, and that is not
        // the same claim as "its plan does not cover anthropic".
        expect(
            UsageAttributionSettings.subscriptionProviderMap["crush"] == nil
                && UsageAttributionSettings.suggestionTarget(
                    sourceClient: "crush", provider: "anthropic",
                    subscriptionClients: ["claude", "copilot"]) == nil,
            "an unsurveyed source produces no suggestion rather than a guess")

        // "No subscriptions" and "not asked yet" both render an empty target
        // list, so without the lifecycle token the signature is unchanged when a
        // payload arrives carrying zero candidates — the refresh never reruns
        // and stale proposals stop being suppressed without being reconciled.
        let signatureEntries = [attributionEntry(
            client: "claude", provider: "openai", model: "gpt-5.6-sol", total: 1, cost: 0.1)]
        expect(
            UsageAttributionSettings.signature(
                entries: signatureEntries, subscriptionClients: [], targetsKnown: false)
                != UsageAttributionSettings.signature(
                    entries: signatureEntries, subscriptionClients: [], targetsKnown: true),
            "an empty target list is distinguishable from an unknown one")

        // A stored proposal names a target, and until the quota payload says
        // which subscriptions exist there is nothing to check it against.
        let staleSuggestionRows = UsageAttributionSettings.rows(
            entries: [attributionEntry(
                client: "claude", provider: "openai", model: "gpt-5.6-sol", total: 5, cost: 0.5)],
            confirmed: [],
            suggestions: [])
        expect(
            staleSuggestionRows.count == 1 && staleSuggestionRows[0].suggestedState == nil
                && UsageAttributionSettings.acceptanceRecords(rows: staleSuggestionRows).isEmpty,
            "suppressed suggestions offer nothing to accept")

        expect(
            [
                UsageAttributionSettings.pageState(hasReport: false, rowCount: 0, isLoading: true),
                UsageAttributionSettings.pageState(hasReport: false, rowCount: 0, isLoading: false),
                UsageAttributionSettings.pageState(hasReport: true, rowCount: 0, isLoading: false),
                UsageAttributionSettings.pageState(hasReport: true, rowCount: 2, isLoading: false),
            ] == [.loading, .unavailable, .empty, .rows],
            "the attribution page separates a failed report from one with no rows")
        expect(
            UsageAttributionSettings.Copy.all.contains(UsageAttributionSettings.Copy.unavailable)
                && UsageAttributionSettings.Copy.unavailable
                    != UsageAttributionSettings.Copy.noRows,
            "the attribution page has distinct copy for an unavailable report")

        // `antigravity-cli` is its own client but spends the `antigravity`
        // subscription, exactly as the quota views already fold it. Comparing
        // the raw id finds no owner and falls through to the subscription-bound
        // branch, which would call the CLI's own subscription usage API spend.
        expect(
            UsageAttributionSettings.suggestionTarget(
                sourceClient: "antigravity-cli", provider: "google",
                subscriptionClients: ["antigravity"]) == .assigned("antigravity"),
            "antigravity-cli usage suggests the antigravity subscription it spends")
        // The fold decides ownership only. A router with nothing declared says
        // nothing, and a surveyed client that genuinely sells no google plan
        // still gets the bound-provider answer.
        expect(
            UsageAttributionSettings.suggestionTarget(
                sourceClient: "opencode", provider: "google",
                subscriptionClients: ["antigravity"]) == nil,
            "an undeclared router reaching google produces no suggestion")
        expect(
            UsageAttributionSettings.suggestionTarget(
                sourceClient: "kimi", provider: "google",
                subscriptionClients: ["antigravity"]) == .excluded,
            "a surveyed client that sells no google plan is API spend")
        let missingSourceSuggestions = UsageAttributionSettings.suggestionRecords(
            entries: [
                attributionEntry(client: "copilot", provider: "openai", model: "gpt-5.6-sol"),
                attributionEntry(client: "copilot", provider: "anthropic", model: "claude-sonnet-4-6"),
            ],
            confirmed: [],
            subscriptionClients: codexOnlySubscriptions)
        // Copilot sells both, so both rows are its own spend regardless of what
        // the quota payload lists. Before the survey this table claimed Copilot
        // covered only openai and anthropic, and the anthropic row came back as
        // API spend — the same shape of error as the Cursor row that started
        // this: a subscription the user holds, unrecognised.
        expect(
            missingSourceSuggestions.map(\.state)
                == [UsageAttribution.State.assigned("copilot"), .assigned("copilot")]
                && missingSourceSuggestions.map(\.provider) == ["openai", "anthropic"],
            "a client that sells both providers keeps both rows as its own spend")

        let suggestionRows = UsageAttributionSettings.rows(
            entries: [
                attributionEntry(
                    client: "copilot", provider: "openai", model: "gpt-5.6-sol",
                    total: 10, cost: 1.0),
                attributionEntry(
                    client: "claude", provider: "openai", model: "gpt-5.6-sol",
                    total: 20, cost: 2.0),
            ],
            confirmed: [],
            suggestions: UsageAttributionSettings.suggestionRecords(
                entries: [
                    attributionEntry(client: "copilot", provider: "openai", model: "gpt-5.6-sol"),
                    attributionEntry(client: "claude", provider: "openai", model: "gpt-5.6-sol"),
                ],
                confirmed: [],
                subscriptionClients: attributionTargets))
        let acceptedAttributionRecords = UsageAttributionSettings.acceptanceRecords(
            rows: suggestionRows)
        let acceptedAttributionRaw = UsageAttribution.confirmedRaw(
            updating: nil, records: acceptedAttributionRecords)
        let acceptedAttributionTable = UsageAttribution.parseRaw(acceptedAttributionRaw)
        expect(
            acceptedAttributionRecords.count == 1
                && UsageAttribution.resolve(
                    client: "copilot", provider: "openai", model: nil,
                    records: acceptedAttributionTable.records) == .assigned("copilot")
                && UsageAttribution.resolve(
                    client: "claude", provider: "openai", model: nil,
                    records: acceptedAttributionTable.records) == .unassigned,
            "accept all assigns only suggested rows")

        let staleSuggestion = UsageAttribution.Record(
            client: "claude", provider: "stale-provider", state: .excluded)
        let currentSuggestion = UsageAttribution.Record(
            client: "claude", provider: "openai", state: .assigned("codex"))
        let staleSuggestionRaw = UsageAttribution.suggestionsRaw(
            updating: nil, records: [staleSuggestion, currentSuggestion])
        let reconciledSuggestionRaw = UsageAttribution.suggestionsRaw(
            replacing: staleSuggestionRaw, with: [currentSuggestion])
        expect(
            UsageAttribution.parseRaw(reconciledSuggestionRaw).records == [currentSuggestion],
            "suggestion reconciliation drops sources absent from the current report")

        let nearLimitRecords = (0..<(UsageAttribution.maxEntries - 1)).map {
            UsageAttribution.Record(
                client: "opencode", provider: "provider-\($0)", state: .excluded)
        }
        let nearLimitRaw = UsageAttribution.confirmedRaw(
            updating: nil, records: nearLimitRecords)
        let overflowingBatch = [
            UsageAttribution.Record(client: "claude", provider: "new-a", state: .excluded),
            UsageAttribution.Record(client: "claude", provider: "new-b", state: .excluded),
        ]
        let rejectedBatchRaw = UsageAttribution.confirmedRaw(
            updating: nearLimitRaw, records: overflowingBatch)
        expect(
            UsageAttribution.parseRaw(nearLimitRaw).records.count
                == UsageAttribution.maxEntries - 1
                && rejectedBatchRaw == nil
                && UsageAttributionSettings.writeFailure(
                    table: UsageAttribution.parseRaw(nearLimitRaw),
                    records: overflowingBatch,
                    result: rejectedBatchRaw) == .entryLimit,
            "accept-all batch validates the complete result before any write")

        let refusedAttributionWrite = UsageAttributionSettings.writeFailure(
            table: UsageAttribution.parseRaw("not-json"),
            record: crossAssignment,
            result: nil)
        expect(
            refusedAttributionWrite != nil
                && refusedAttributionWrite?.message.contains("Could not save") == true,
            "refused attribution writes are reported as failures")
        expect(
            (UsageAttributionSettings.Copy.all + UsageAttributionBreakdown.Copy.all).allSatisfy {
                let copy = $0.lowercased()
                return !copy.contains("consumed") && !copy.contains("deducted")
            },
            "attribution screen copy does not claim consumption or deduction")

        let savedCardRaw = UserDefaults.standard.object(forKey: UsageAttribution.confirmedKey)
        let cardRaw = UsageAttribution.confirmedRaw(updating: nil, record: crossAssignment)
        UserDefaults.standard.set(cardRaw, forKey: UsageAttribution.confirmedKey)
        let cardState = awaitMainActorValue { () -> UsageAttribution.State? in
            let card = UsageAttributionBreakdownCard(
                report: nil, clientIds: [], singleClient: nil)
            return UsageAttribution.resolve(
                client: "claude", provider: "openai", model: nil, records: card.confirmed)
        }
        // Reading the right value is not the defect. A computed read of
        // UserDefaults returns the same records; what it does not create is a
        // dependency SwiftUI can invalidate on, so a mounted card kept showing
        // the previous split after Settings wrote. Only a stored @AppStorage
        // creates it, so assert the storage itself is present.
        let cardObservesStore = awaitMainActorValue { () -> Bool in
            let card = UsageAttributionBreakdownCard(
                report: nil, clientIds: [], singleClient: nil)
            return Mirror(reflecting: card).children.contains {
                String(describing: type(of: $0.value)).hasPrefix("AppStorage<")
            }
        }
        if let savedCardRaw {
            UserDefaults.standard.set(savedCardRaw, forKey: UsageAttribution.confirmedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: UsageAttribution.confirmedKey)
        }
        expect(
            cardState == .some(.assigned("codex")) && cardObservesStore == true,
            "attribution card derives confirmed records from an observed stored value")

        // A nil report is two different states. `load()` fetches the report with
        // `try?` and still reaches `.ready` on the graph alone, so treating nil
        // as in-flight leaves the card spinning forever once the report keeps
        // failing. The flag is what separates them, and the copy differs from
        // `noUsage`, which is an answer about a report that did arrive.
        expect(
            UsageAttributionBreakdown.Copy.all.contains(
                UsageAttributionBreakdown.Copy.unavailable)
                && UsageAttributionBreakdown.Copy.unavailable
                    != UsageAttributionBreakdown.Copy.noUsage,
            "the breakdown card has distinct copy for an unavailable report")
        // Assert the branch the body actually takes, not just that the flag can
        // be set — a card that stored the flag and ignored it would satisfy the
        // weaker check while still spinning forever.
        let cardStates = awaitMainActorValue { () -> [UsageAttributionBreakdownCard.ContentState] in
            [
                UsageAttributionBreakdownCard.contentState(
                    rowCount: nil, reportLoading: true),
                UsageAttributionBreakdownCard.contentState(
                    rowCount: nil, reportLoading: false),
                UsageAttributionBreakdownCard.contentState(
                    rowCount: 0, reportLoading: false),
                UsageAttributionBreakdownCard.contentState(
                    rowCount: 3, reportLoading: false),
            ]
        }
        expect(
            cardStates ?? [] == [.loading, .unavailable, .empty, .rows],
            "the breakdown card separates an in-flight report from a finished one with none")

        let canonicalRecords = [
            UsageAttribution.Record(
                client: "opencode", provider: "nvidia", model: "deepseek-v4-pro",
                state: .assigned("codex")),
            UsageAttribution.Record(
                client: "claude", provider: "openai", state: .assigned("codex")),
            UsageAttribution.Record(
                client: "opencode", provider: "nvidia", state: .excluded),
        ]
        let canonicalExpected = "[{\"client\":\"claude\",\"model\":null,\"provider\":\"openai\",\"state\":\"assigned\",\"target\":\"codex\"},{\"client\":\"opencode\",\"model\":null,\"provider\":\"nvidia\",\"state\":\"excluded\"},{\"client\":\"opencode\",\"model\":\"deepseek-v4-pro\",\"provider\":\"nvidia\",\"state\":\"assigned\",\"target\":\"codex\"}]"
        let canonicalForward = applyConfirmed(canonicalRecords)
        let canonicalReverse = applyConfirmed(Array(canonicalRecords.reversed()))
        let excludedEntry = attributionEntry(
            client: "opencode", provider: "nvidia", model: "other-model")
        let unassignedEntry = attributionEntry(
            client: "gemini", provider: "openai", model: "other-model")
        let canonicalTable = UsageAttribution.parseRaw(canonicalForward)
        expect(
            canonicalForward == canonicalExpected && canonicalReverse == canonicalExpected
                && UsageAttribution.resolve(claudeOpenAIEntry, records: canonicalTable.records)
                    == .assigned("codex")
                && UsageAttribution.resolve(excludedEntry, records: canonicalTable.records)
                    == .excluded
                && UsageAttribution.resolve(unassignedEntry, records: canonicalTable.records)
                    == .unassigned,
            "attribution serialization is canonical and preserves all states")
        expect(
            UsageAttribution.confirmedRaw(
                updating: nil,
                record: UsageAttribution.Record(
                    client: "claude", provider: "openai", state: .unassigned)
            ) == "[]",
            "unassigned attribution update removes its declaration")

        let attributionDefaultsName = "TokenBar.SelfTest.UsageAttribution.\(UUID().uuidString)"
        if let attributionDefaults = UserDefaults(suiteName: attributionDefaultsName) {
            defer { attributionDefaults.removePersistentDomain(forName: attributionDefaultsName) }
            let suggestion = UsageAttribution.Record(
                client: "claude", provider: "openai", state: .assigned("codex"))
            let suggestionRaw = UsageAttribution.suggestionsRaw(updating: nil, record: suggestion)
            attributionDefaults.set(suggestionRaw, forKey: UsageAttribution.suggestionsKey)
            expect(
                UsageAttribution.suggestions(defaults: attributionDefaults).records.count == 1
                    && UsageAttribution.effectiveState(
                        for: claudeOpenAIEntry, defaults: attributionDefaults) == .unassigned,
                "suggestion alone does not affect effective attribution")
        } else {
            expect(false, "isolated attribution defaults suite is available")
        }

        let malformedAttributionRaw = "not-json"
        // An unregistered *target* is what cannot be persisted: it names a quota
        // bucket the app cannot render. The source is whatever the report
        // observed, and the report emits ids outside the registry
        // (`cc-mirror/*`), so constraining it would render those rows and then
        // refuse every classification made on them.
        let invalidAttributionRecordRaw = "[{\"client\":\"claude\",\"model\":null,\"provider\":\"openai\",\"state\":\"assigned\",\"target\":\"not-registered\"}]"
        let dynamicSourceRecord = UsageAttribution.Record(
            client: "cc-mirror/sonnet", provider: "anthropic", state: .excluded)
        let dynamicSourceRaw = UsageAttribution.confirmedRaw(
            updating: nil, record: dynamicSourceRecord)
        expect(
            UsageAttribution.parseRaw(dynamicSourceRaw).records == [dynamicSourceRecord]
                && !ClientRegistry.allIds.contains("cc-mirror/sonnet"),
            "a dynamic report client can carry a declaration")
        expect(
            UsageAttribution.parseRaw(malformedAttributionRaw).records.isEmpty
                && !UsageAttribution.parseRaw(malformedAttributionRaw).isWritable
                && UsageAttribution.confirmedRaw(
                    updating: malformedAttributionRaw, record: crossAssignment) == nil
                && UsageAttribution.suggestionsRaw(
                    replacing: malformedAttributionRaw, with: [crossAssignment]) == nil,
            "malformed attribution raw fails closed and refuses writes")
        expect(
            UsageAttribution.parseRaw(invalidAttributionRecordRaw).records.isEmpty
                && !UsageAttribution.parseRaw(invalidAttributionRecordRaw).isWritable
                && UsageAttribution.confirmedRaw(
                    updating: invalidAttributionRecordRaw, record: crossAssignment) == nil,
            "invalid attribution records are rejected at parse time")

        let malformedDefaultsName = "TokenBar.SelfTest.UsageAttribution.Malformed.\(UUID().uuidString)"
        if let malformedDefaults = UserDefaults(suiteName: malformedDefaultsName) {
            defer { malformedDefaults.removePersistentDomain(forName: malformedDefaultsName) }
            malformedDefaults.set("not-json", forKey: UsageAttribution.confirmedKey)
            let read = UsageAttribution.confirmed(defaults: malformedDefaults)
            var records = read.records
            records.append(crossAssignment)
            let attemptedRaw = UsageAttribution.confirmedRaw(
                updating: malformedDefaults.object(forKey: UsageAttribution.confirmedKey),
                record: records.last!)
            if let attemptedRaw {
                malformedDefaults.set(attemptedRaw, forKey: UsageAttribution.confirmedKey)
            }
            expect(
                records.count == 1 && !read.isWritable && attemptedRaw == nil
                    && (malformedDefaults.object(forKey: UsageAttribution.confirmedKey) as? String)
                        == "not-json",
                "public attribution read-modify-write preserves rejected raw bytes")
        } else {
            expect(false, "isolated malformed attribution defaults suite is available")
        }

        let wrongTypeDefaultsName = "TokenBar.SelfTest.UsageAttribution.WrongType.\(UUID().uuidString)"
        if let wrongTypeDefaults = UserDefaults(suiteName: wrongTypeDefaultsName) {
            defer { wrongTypeDefaults.removePersistentDomain(forName: wrongTypeDefaultsName) }
            wrongTypeDefaults.set(["foreign"], forKey: UsageAttribution.confirmedKey)
            let read = UsageAttribution.confirmed(defaults: wrongTypeDefaults)
            var records = read.records
            records.append(crossAssignment)
            let attemptedRaw = UsageAttribution.confirmedRaw(
                updating: wrongTypeDefaults.object(forKey: UsageAttribution.confirmedKey),
                record: records.last!)
            if let attemptedRaw {
                wrongTypeDefaults.set(attemptedRaw, forKey: UsageAttribution.confirmedKey)
            }
            expect(
                records.count == 1 && !read.isWritable && attemptedRaw == nil
                    && (wrongTypeDefaults.object(forKey: UsageAttribution.confirmedKey)
                        as? [String]) == ["foreign"],
                "wrong-typed attribution defaults value is non-writable")
        } else {
            expect(false, "isolated wrong-type attribution defaults suite is available")
        }

        let absentDefaultsName = "TokenBar.SelfTest.UsageAttribution.Absent.\(UUID().uuidString)"
        if let absentDefaults = UserDefaults(suiteName: absentDefaultsName) {
            defer { absentDefaults.removePersistentDomain(forName: absentDefaultsName) }
            let read = UsageAttribution.confirmed(defaults: absentDefaults)
            let firstWriteRaw = UsageAttribution.confirmedRaw(
                updating: absentDefaults.object(forKey: UsageAttribution.confirmedKey),
                record: crossAssignment)
            if let firstWriteRaw {
                absentDefaults.set(firstWriteRaw, forKey: UsageAttribution.confirmedKey)
            }
            expect(
                read.records.isEmpty && read.isWritable
                    && firstWriteRaw
                        == "[{\"client\":\"claude\",\"model\":null,\"provider\":\"openai\",\"state\":\"assigned\",\"target\":\"codex\"}]"
                    && absentDefaults.string(forKey: UsageAttribution.confirmedKey)
                        == firstWriteRaw,
                "absent attribution defaults value remains writable")
        } else {
            expect(false, "fresh attribution defaults suite is available")
        }

        // QD-1: retain date, attribution bucket, and canonical model while
        // resolving each raw contribution-client row.
        let oneDayContributions = [contributionFixture(contributionJSON(
            date: "2024-01-01",
            clients: [
                ("opencode", "excluded-model", "nvidia", 10, 1.0),
                ("claude", "cross-model", "openai", 20, 2.0),
                ("claude", "merged-model", "anthropic, github_copilot", 30, 3.0),
                ("claude", "zero-model", "openai", 0, 0.0),
            ],
            totalsTokens: 999,
            totalsCost: 999.0))]
        let oneDayConfirmed = [
            UsageAttribution.Record(
                client: "opencode", provider: "nvidia", state: .excluded),
            UsageAttribution.Record(
                client: "claude", provider: "openai", state: .assigned("codex")),
        ]
        let oneDaySuggestions = [
            UsageAttribution.Record(
                client: "claude", provider: "openai", state: .excluded),
        ]
        let oneDayPoints = AttributedDailySeries.points(
            contributions: oneDayContributions, confirmed: oneDayConfirmed)
        let expectedOneDayPoints = [
            AttributedDailySeries.Point(
                date: "2024-01-01", state: .assigned("codex"), model: "cross-model",
                tokens: 20, cost: 2.0),
            AttributedDailySeries.Point(
                date: "2024-01-01", state: .excluded, model: "excluded-model",
                tokens: 10, cost: 1.0),
            AttributedDailySeries.Point(
                date: "2024-01-01", state: .unassigned, model: "merged-model",
                tokens: 30, cost: 3.0),
        ]
        let suggestionRaw = oneDaySuggestions.reduce(String?.none) {
            UsageAttribution.suggestionsRaw(updating: $0, record: $1)
        }
        let suggestionTable = UsageAttribution.parseRaw(suggestionRaw)
        let oneDayDefaultsName = "TokenBar.SelfTest.AttributedSeries.\(UUID().uuidString)"
        if let oneDayDefaults = UserDefaults(suiteName: oneDayDefaultsName) {
            defer { oneDayDefaults.removePersistentDomain(forName: oneDayDefaultsName) }
            let confirmedRaw = oneDayConfirmed.reduce(String?.none) {
                UsageAttribution.confirmedRaw(updating: $0, record: $1)
            }
            oneDayDefaults.set(confirmedRaw, forKey: UsageAttribution.confirmedKey)
            oneDayDefaults.set(suggestionRaw, forKey: UsageAttribution.suggestionsKey)
            let storedConfirmed = UsageAttribution.confirmed(defaults: oneDayDefaults).records
            let storedSuggestions = UsageAttribution.suggestions(defaults: oneDayDefaults).records
            let oneDayFromStore = AttributedDailySeries.points(
                contributions: oneDayContributions, confirmed: storedConfirmed)
            expect(
                oneDayPoints == expectedOneDayPoints
                    && suggestionTable.records == oneDaySuggestions
                    && storedSuggestions == oneDaySuggestions
                    && oneDayFromStore == expectedOneDayPoints,
                "attributed daily series keeps buckets and ignores stored suggestions")
        } else {
            expect(false, "attributed series defaults suite is available")
        }

        let fullKeyContributions = [
            contributionFixture(contributionJSON(
                date: "2024-01-02",
                clients: [
                    ("claude", "shared-model", "openai", 30, 3.0),
                    ("opencode", "shared-model", "nvidia", 40, 4.0),
                ],
                totalsTokens: 70,
                totalsCost: 7.0)),
            contributionFixture(contributionJSON(
                date: "2024-01-01",
                clients: [
                    ("claude", "shared-model", "openai", 10, 1.0),
                    ("opencode", "shared-model", "nvidia", 20, 2.0),
                ],
                totalsTokens: 30,
                totalsCost: 3.0)),
        ]
        let fullKeyPoints = AttributedDailySeries.points(
            contributions: fullKeyContributions,
            confirmed: [
                UsageAttribution.Record(
                    client: "claude", provider: "openai", state: .assigned("codex")),
                UsageAttribution.Record(
                    client: "opencode", provider: "nvidia", state: .assigned("claude")),
            ])
        let expectedFullKeyPoints = [
            AttributedDailySeries.Point(
                date: "2024-01-01", state: .assigned("claude"), model: "shared-model",
                tokens: 20, cost: 2.0),
            AttributedDailySeries.Point(
                date: "2024-01-01", state: .assigned("codex"), model: "shared-model",
                tokens: 10, cost: 1.0),
            AttributedDailySeries.Point(
                date: "2024-01-02", state: .assigned("claude"), model: "shared-model",
                tokens: 40, cost: 4.0),
            AttributedDailySeries.Point(
                date: "2024-01-02", state: .assigned("codex"), model: "shared-model",
                tokens: 30, cost: 3.0),
        ]
        expect(
            fullKeyPoints == expectedFullKeyPoints,
            "attributed daily series sorts and retains the full date-state-model key")

        let maxContribution = contributionFixture(contributionJSON(
            date: "2024-01-03",
            clients: [
                ("claude", "max-model", "openai", Int64.max, 1.0),
                ("claude", "max-model", "openai", 7, 2.0),
            ],
            totalsTokens: 0,
            totalsCost: 0.0))
        let maxPoints = AttributedDailySeries.points(
            contributions: [maxContribution],
            confirmed: [
                UsageAttribution.Record(
                    client: "claude", provider: "openai", state: .assigned("codex")),
            ])
        expect(
            maxPoints.count == 1 && maxPoints[0].tokens == Int64.max
                && maxPoints[0].cost == 3.0,
            "attributed daily series saturates Int64.max token folds")

        let droppedPointContribution = contributionFixture(contributionJSON(
            date: "2024-01-03",
            clients: [
                ("claude", "cancels-model", "openai", 1, 0.0),
                ("claude", "cancels-model", "openai", -1, 0.0),
            ],
            totalsTokens: 0,
            totalsCost: 0.0))
        let droppedPoints = AttributedDailySeries.points(
            contributions: [droppedPointContribution],
            confirmed: [
                UsageAttribution.Record(
                    client: "claude", provider: "openai", state: .assigned("codex")),
            ])
        expect(
            droppedPoints.isEmpty,
            "attributed daily series drops a point that aggregates to zero")

        let mergedBypassContribution = contributionFixture(contributionJSON(
            date: "2024-01-04",
            clients: [
                ("opencode", "merged-model", "nvidia, openai", 9, 0.9),
            ],
            totalsTokens: 9,
            totalsCost: 0.9))
        let mergedBypassPoints = AttributedDailySeries.points(
            contributions: [mergedBypassContribution],
            confirmed: [
                UsageAttribution.Record(
                    client: "opencode", provider: "nvidia", state: .excluded),
                UsageAttribution.Record(
                    client: "opencode", provider: "nvidia, openai", state: .assigned("codex")),
            ])
        expect(
            mergedBypassPoints.count == 1 && mergedBypassPoints[0].state == .unassigned,
            "merged providers remain unassigned despite a literal joined declaration")

        let conservationContributions = [
            contributionFixture(contributionJSON(
                date: "2024-02-01",
                clients: [("claude", "conservation-model", "anthropic", 7, 0.1)],
                totalsTokens: 999,
                totalsCost: 999.0)),
            contributionFixture(contributionJSON(
                date: "2024-02-01",
                clients: [("claude", "conservation-model", "anthropic", 5, 0.2)],
                totalsTokens: 999,
                totalsCost: 999.0)),
            contributionFixture(contributionJSON(
                date: "2024-02-01",
                clients: [("claude", "conservation-model", "openai", 11, 4.75)],
                totalsTokens: 999,
                totalsCost: 999.0)),
            contributionFixture(contributionJSON(
                date: "2024-02-01",
                clients: [("claude", "conservation-model", "nvidia", 13, 0.125)],
                totalsTokens: 999,
                totalsCost: 999.0)),
        ]
        let conservationRecords = [
            UsageAttribution.Record(
                client: "claude", provider: "anthropic", state: .assigned("claude")),
            UsageAttribution.Record(
                client: "claude", provider: "openai", state: .excluded),
        ]
        let conservationPoints = AttributedDailySeries.points(
            contributions: conservationContributions, confirmed: conservationRecords)
        let permutedConservationPoints = AttributedDailySeries.points(
            contributions: Array(conservationContributions.reversed()), confirmed: conservationRecords)
        let conservationTokens = conservationPoints.reduce(Int64.zero) {
            $0.saturatingAdding($1.tokens)
        }
        let conservationCost = conservationPoints.reduce(0.0) { $0 + $1.cost }
        let conservationBucketsCorrect = conservationPoints.count == 3
            && conservationPoints[0].state == .assigned("claude")
            && conservationPoints[0].tokens == 12
            && abs(conservationPoints[0].cost - 0.3) < 1e-9
            && conservationPoints[1].state == .excluded
            && conservationPoints[1].tokens == 11
            && abs(conservationPoints[1].cost - 4.75) < 1e-9
            && conservationPoints[2].state == .unassigned
            && conservationPoints[2].tokens == 13
            && abs(conservationPoints[2].cost - 0.125) < 1e-9
        let conservationOrderIndependent = conservationPoints.count == permutedConservationPoints.count
            && zip(conservationPoints, permutedConservationPoints).allSatisfy { left, right in
                left.date == right.date && left.state == right.state && left.model == right.model
                    && left.tokens == right.tokens && abs(left.cost - right.cost) < 1e-9
            }
        expect(
            conservationBucketsCorrect && conservationTokens == 36
                && abs(conservationCost - 5.175) < 1e-9
                && conservationOrderIndependent,
            "attributed daily series conserves row-derived tokens and costs")

        let literalProviderContributions = [contributionFixture(contributionJSON(
            date: "2024-02-02",
            clients: [
                ("claude", "codex-model", "openai-codex", 8, 0.8),
                ("claude", "openai-model", "openai", 9, 0.9),
            ],
            totalsTokens: 17,
            totalsCost: 1.7))]
        let literalProviderPoints = AttributedDailySeries.points(
            contributions: literalProviderContributions,
            confirmed: [
                UsageAttribution.Record(
                    client: "claude", provider: "openai-codex", state: .assigned("codex")),
                UsageAttribution.Record(
                    client: "claude", provider: "openai", state: .excluded),
            ])
        expect(
            literalProviderPoints.map(\.state) == [.assigned("codex"), .excluded],
            "attributed daily series compares provider IDs literally")

        let exactResolverRecords = [
            UsageAttribution.Record(
                client: "claude", provider: "openai", model: "exact-model",
                state: .assigned("codex")),
        ]
        let nonMatchingResolverRecords = [
            UsageAttribution.Record(
                client: "claude", provider: "openai", state: .excluded),
            UsageAttribution.Record(
                client: "claude", provider: "openai", model: "other-model",
                state: .assigned("codex")),
        ]
        let coexistingResolverRecords = [
            UsageAttribution.Record(
                client: "claude", provider: "openai", state: .excluded),
            UsageAttribution.Record(
                client: "claude", provider: "openai", model: "exact-model",
                state: .assigned("codex")),
        ]
        // Drive the three model-record cases through the producer, not the
        // resolver: calling resolve directly would stay green even if the
        // producer stopped passing the row's model at all.
        func modelRecordState(
            model: String, records: [UsageAttribution.Record]
        ) -> UsageAttribution.State? {
            let points = AttributedDailySeries.points(
                contributions: [contributionFixture(contributionJSON(
                    date: "2024-04-01",
                    clients: [("claude", model, "openai", 5, 0.5)],
                    totalsTokens: 5,
                    totalsCost: 0.5))],
                confirmed: records)
            guard points.count == 1, points[0].model == model else { return nil }
            return points[0].state
        }
        expect(
            modelRecordState(model: "exact-model", records: exactResolverRecords)
                == .assigned("codex")
                // The row's model has no override of its own, so the only
                // override present must not apply and the provider-level
                // declaration stands.
                && modelRecordState(model: "unlisted-model", records: nonMatchingResolverRecords)
                    == .excluded
                && modelRecordState(model: "exact-model", records: coexistingResolverRecords)
                    == .assigned("codex"),
            "attributed daily series resolves exact, non-matching, and provider model records")

        expect(
            UsageAttributionSettings.Copy.all.contains(UsageAttributionSettings.Copy.canonicalizationHint)
                && UsageAttributionSettings.Copy.canonicalizationHint.contains(
                    "compared exactly as the source emitted")
                && !UsageAttributionSettings.Copy.canonicalizationHint.contains("canonicalized"),
            "attribution copy describes exact provider comparison")

        // Parsers that call `provider_identity::n` fold `vertex` into
        // `anthropic` and `openai_codex` into `openai` before the report is
        // built, so two billing relationships share one row no later stage can
        // split. Fourteen parsers never call it, so the same aliases stay
        // separable there. Both halves must be present and the claim must be
        // hedged: "nothing is merged" is false for Claude Code, "Codex is
        // reported as OpenAI" is false for OpenClaw.
        expect(
            UsageAttributionSettings.Copy.canonicalizationHint.contains(
                "Vertex AI arriving as Anthropic")
                && UsageAttributionSettings.Copy.canonicalizationHint.contains(
                    "Codex as OpenAI")
                && UsageAttributionSettings.Copy.canonicalizationHint.contains(
                    "Some clients merge them"),
            "attribution copy discloses merged routes as something only some clients do")

        let zeroSourceRows = UsageAttributionSettings.rows(
            entries: [
                attributionEntry(
                    client: "cursor", provider: "anthropic", model: "idle-model",
                    total: 0, cost: 0.0),
                attributionEntry(
                    client: "claude", provider: "anthropic", model: "used-model",
                    total: 41, cost: 0.5),
            ],
            confirmed: [],
            suggestions: [])
        expect(
            zeroSourceRows.map(\.client) == ["claude"]
                && UsageAttributionSettings.pageState(
                    hasReport: true,
                    rowCount: UsageAttributionSettings.rows(
                        entries: [attributionEntry(
                            client: "cursor", provider: "anthropic", model: "idle-model",
                            total: 0, cost: 0.0)],
                        confirmed: [], suggestions: []).count,
                    isLoading: false) == .empty,
            "a source observed at zero is not offered for classification")

        // The Stats breakdown keeps any entry with `total != 0 || cost != 0`.
        // Settings must not be stricter, or the card can report unassigned
        // usage the settings page offers no row to classify. A negative
        // aggregate is the case where a positive test and a nonzero test part.
        let negativeSourceEntries = [
            attributionEntry(
                client: "cursor", provider: "anthropic", model: "corrupt-model",
                total: -5, cost: 0.0),
        ]
        expect(
            UsageAttributionSettings.rows(
                entries: negativeSourceEntries, confirmed: [], suggestions: []
            ).map(\.tokens) == [-5]
                && UsageAttributionBreakdown.rows(
                    entries: negativeSourceEntries, clientIds: ["cursor"], confirmed: []
                ).contains { $0.tokens == -5 },
            "settings keeps every source the breakdown card still reports")

        // The same test has to run at the same stage as the card's, not merely
        // read the same. Two rows that cancel are individually nonzero, so the
        // card keeps both and — resolving each before folding — can place them
        // in different buckets and report them. A settings filter applied to
        // the sum would see one empty source and offer nothing to classify.
        let cancellingEntries = [
            attributionEntry(
                client: "cursor", provider: "anthropic", model: "credited-model",
                total: 5, cost: 0.0),
            attributionEntry(
                client: "cursor", provider: "anthropic", model: "reversed-model",
                total: -5, cost: 0.0),
        ]
        expect(
            UsageAttributionSettings.rows(
                entries: cancellingEntries, confirmed: [], suggestions: []
            ).map { ($0.provider, $0.tokens) }.map { "\($0.0)=\($0.1)" } == ["anthropic=0"]
                && UsageAttributionBreakdown.rows(
                    entries: cancellingEntries,
                    clientIds: ["cursor"],
                    confirmed: [UsageAttribution.Record(
                        client: "cursor", provider: "anthropic", model: "credited-model",
                        state: .assigned("claude"))]
                ).count == 2,
            "a source whose rows cancel is still offered for classification")

        let allTimeSource = AttributedSeriesTestSource(
            graphPayload: payloadFixture([
                contributionJSON(
                    date: "2023-12-31",
                    clients: [("claude", "year-model", "openai", 12, 1.2)],
                    totalsTokens: 12,
                    totalsCost: 1.2),
                contributionJSON(
                    date: "2024-01-01",
                    clients: [("claude", "year-model", "openai", 34, 3.4)],
                    totalsTokens: 34,
                    totalsCost: 3.4),
            ]),
            refreshPayload: payloadFixture([]))
        let allTimePoints = awaitMainActorValue { () -> [AttributedDailySeries.Point]? in
            AttributedSeriesModel.resetForTesting()
            AttributedSeriesModel.captureLaunchTimeZone("UTC")
            let model = AttributedSeriesModel()
            await model.load(source: allTimeSource, confirmed: [], timeZone: "UTC")
            return model.points
        }
        expect(
            allTimeSource.graphYears == [nil] && allTimeSource.refreshYears.isEmpty
                && allTimePoints??.map(\.date) == ["2023-12-31", "2024-01-01"],
            "attributed series acquisition always requests the all-time graph")

        let timezoneSource = AttributedSeriesTestSource(
            graphPayload: payloadFixture([
                contributionJSON(
                    date: "2024-03-01",
                    clients: [("claude", "timezone-model", "openai", 1, 0.1)],
                    totalsTokens: 1,
                    totalsCost: 0.1),
            ]),
            refreshPayload: payloadFixture([
                contributionJSON(
                    date: "2024-03-02",
                    clients: [("claude", "timezone-model", "openai", 2, 0.2)],
                    totalsTokens: 2,
                    totalsCost: 0.2),
            ]))
        let timezonePoints = awaitMainActorValue { () -> [AttributedDailySeries.Point]? in
            AttributedSeriesModel.resetForTesting()
            AttributedSeriesModel.captureLaunchTimeZone("Zone/A")
            let model = AttributedSeriesModel()
            await model.load(source: timezoneSource, confirmed: [], timeZone: "Zone/A")
            await model.load(source: timezoneSource, confirmed: [], timeZone: "Zone/B")
            return model.points
        }
        expect(
            timezoneSource.graphYears == [nil] && timezoneSource.refreshYears == [nil]
                && timezonePoints??.map(\.date) == ["2024-03-02"],
            "attributed series refreshes when the effective timezone changes")

        // The baseline has to outlive the model: PopoverView holds these as
        // @State and StatusItemController rebuilds it on every open, so a
        // per-instance baseline would be nil again by the time the user's new
        // timezone reaches a load and the stale cached day keys would be served.
        let remountSource = AttributedSeriesTestSource(
            graphPayload: payloadFixture([
                contributionJSON(
                    date: "2024-03-01",
                    clients: [("claude", "timezone-model", "openai", 1, 0.1)],
                    totalsTokens: 1,
                    totalsCost: 0.1),
            ]),
            refreshPayload: payloadFixture([
                contributionJSON(
                    date: "2024-03-02",
                    clients: [("claude", "timezone-model", "openai", 2, 0.2)],
                    totalsTokens: 2,
                    totalsCost: 0.2),
            ]))
        let remountPoints = awaitMainActorValue { () -> [AttributedDailySeries.Point]? in
            AttributedSeriesModel.resetForTesting()
            AttributedSeriesModel.captureLaunchTimeZone("Zone/A")
            await AttributedSeriesModel().load(
                source: remountSource, confirmed: [], timeZone: "Zone/A")
            // A brand-new model, exactly as a reopened popover would build it.
            let remounted = AttributedSeriesModel()
            await remounted.load(source: remountSource, confirmed: [], timeZone: "Zone/B")
            return remounted.points
        }
        expect(
            remountSource.refreshYears == [nil]
                && remountPoints??.map(\.date) == ["2024-03-02"],
            "attributed series still refreshes when a remounted model sees a new timezone")

        // The popover is torn down and rebuilt on every open, so a model that
        // keeps its rows only per-instance leaves the subscription card on its
        // spinner for a whole acquisition each time — which is what the user
        // saw. Rows survive the remount under unchanged provenance.
        let reopenSource = AttributedSeriesTestSource(
            graphPayload: payloadFixture([
                contributionJSON(
                    date: "2024-03-01",
                    clients: [("claude", "timezone-model", "openai", 1, 0.1)],
                    totalsTokens: 1,
                    totalsCost: 0.1),
            ]),
            refreshPayload: payloadFixture([]))
        let reopenPoints = awaitMainActorValue { () -> [AttributedDailySeries.Point]? in
            AttributedSeriesModel.resetForTesting()
            AttributedSeriesModel.captureLaunchTimeZone("Zone/A")
            await AttributedSeriesModel().load(
                source: reopenSource, confirmed: [], timeZone: "Zone/A")
            // Reopened, and this time nothing comes back at all.
            reopenSource.failGraph = true
            let reopened = AttributedSeriesModel()
            await reopened.load(source: reopenSource, confirmed: [], timeZone: "Zone/A")
            return reopened.points
        }
        expect(
            reopenPoints??.map(\.date) == ["2024-03-01"],
            "attributed series draws the previous open's rows instead of respinning")

        // AS-REFOLD. The other thing that restarts this load is a declaration
        // change — `PopoverView` keys its task on the attribution string — and
        // then the model already HAS points: the split the user just moved away
        // from. The pre-await publication used to be gated on `points == nil`,
        // so the case it most needed to serve was the one it skipped, and the
        // chart showed the old classification for the whole acquisition.
        //
        // Read mid-flight on purpose. Both the failure path and a remounted
        // model re-fold correctly, so a case that waits for the load to settle
        // passes either way and asserts nothing.
        let refoldSource = AttributedSeriesTestSource(
            graphPayload: payloadFixture([
                contributionJSON(
                    date: "2024-03-01",
                    clients: [("claude", "timezone-model", "openai", 1, 0.1)],
                    totalsTokens: 1,
                    totalsCost: 0.1),
            ]),
            refreshPayload: payloadFixture([]))
        let refoldStates = awaitMainActorValue { () -> [UsageAttribution.State]? in
            AttributedSeriesModel.resetForTesting()
            AttributedSeriesModel.captureLaunchTimeZone("Zone/A")
            let model = AttributedSeriesModel()
            await model.load(source: refoldSource, confirmed: [], timeZone: "Zone/A")
            let gate = ThrottleGate()
            let entries = ThrottleCallCounter()
            refoldSource.graphGate = gate
            refoldSource.graphEntries = entries
            // The user declares that provider/model as this subscription's, and
            // SwiftUI restarts the task on the SAME model instance.
            let declared = [UsageAttribution.Record(
                client: "claude", provider: "openai", model: "timezone-model",
                state: .assigned("claude"))]
            let second = Task {
                await model.load(
                    source: refoldSource, confirmed: declared, timeZone: "Zone/A")
            }
            while await entries.count < 1 { await Task.yield() }
            let midFlight = model.points?.map(\.state)
            await gate.open()
            await second.value
            return midFlight
        }
        expect(
            refoldStates??.allSatisfy { $0 == .assigned("claude") } == true
                && refoldStates??.isEmpty == false,
            "AS-REFOLD a declaration change re-folds the retained rows before "
                + "awaiting, so the chart is not left on the split the user "
                + "just changed away from")

        // But only under provenance it can vouch for: a transition since that
        // load means those day keys may be misdated, and nothing may be shown.
        let staleReopenPoints = awaitMainActorValue { () -> [AttributedDailySeries.Point]? in
            AttributedSeriesModel.resetForTesting()
            AttributedSeriesModel.captureLaunchTimeZone("Zone/A")
            let priming = AttributedSeriesTestSource(
                graphPayload: payloadFixture([
                    contributionJSON(
                        date: "2024-03-01",
                        clients: [("claude", "timezone-model", "openai", 1, 0.1)],
                        totalsTokens: 1,
                        totalsCost: 0.1),
                ]),
                refreshPayload: payloadFixture([]))
            await AttributedSeriesModel().load(
                source: priming, confirmed: [], timeZone: "Zone/A")
            AttributedSeriesModel.invalidateTimeZoneProvenance()
            priming.failGraph = true
            priming.failRefresh = true
            let reopened = AttributedSeriesModel()
            await reopened.load(source: priming, confirmed: [], timeZone: "Zone/A")
            return reopened.points
        }
        expect(
            staleReopenPoints ?? nil == nil,
            "attributed series does not reuse rows across a timezone transition")

        // AppDelegate's title-refresh loop warms the all-time graph cache from
        // launch, so the very first QD-1 load can be the first one to see a
        // changed timezone. Without the launch baseline it would accept those
        // cached pre-change day buckets and then stamp them as current.
        let firstLoadSource = AttributedSeriesTestSource(
            graphPayload: payloadFixture([
                contributionJSON(
                    date: "2024-03-01",
                    clients: [("claude", "timezone-model", "openai", 1, 0.1)],
                    totalsTokens: 1,
                    totalsCost: 0.1),
            ]),
            refreshPayload: payloadFixture([
                contributionJSON(
                    date: "2024-03-02",
                    clients: [("claude", "timezone-model", "openai", 2, 0.2)],
                    totalsTokens: 2,
                    totalsCost: 0.2),
            ]))
        let firstLoadPoints = awaitMainActorValue { () -> [AttributedDailySeries.Point]? in
            AttributedSeriesModel.resetForTesting()
            AttributedSeriesModel.captureLaunchTimeZone("Zone/A")
            let model = AttributedSeriesModel()
            await model.load(source: firstLoadSource, confirmed: [], timeZone: "Zone/B")
            return model.points
        }
        expect(
            firstLoadSource.graphYears.isEmpty && firstLoadSource.refreshYears == [nil]
                && firstLoadPoints??.map(\.date) == ["2024-03-02"],
            "attributed series recomputes on its first load when the timezone already changed")

        // A failed fetch must not go on publishing the classification the user
        // just changed away from: the rows are still held, so re-derive them.
        let failingSource = AttributedSeriesFailingSource(
            graphPayload: payloadFixture([
                contributionJSON(
                    date: "2024-05-01",
                    clients: [("claude", "stale-model", "openai", 4, 0.4)],
                    totalsTokens: 4,
                    totalsCost: 0.4),
            ]))
        let staleInputStates = awaitMainActorValue { () -> [UsageAttribution.State]? in
            AttributedSeriesModel.resetForTesting()
            AttributedSeriesModel.captureLaunchTimeZone("Zone/A")
            let model = AttributedSeriesModel()
            await model.load(
                source: failingSource, confirmed: [], timeZone: "Zone/A")
            let before = model.points?.map(\.state) ?? []
            failingSource.failing = true
            await model.load(
                source: failingSource,
                confirmed: [UsageAttribution.Record(
                    client: "claude", provider: "openai", state: .excluded)],
                timeZone: "Zone/A")
            return before + (model.points?.map(\.state) ?? [])
        }
        expect(
            staleInputStates ?? [] == [.unassigned, .excluded],
            "a failed reload re-derives held rows against the current declarations")

        // Day keys cannot be salvaged that way, so a recompute that fails after
        // a timezone change publishes nothing rather than known-misdated buckets.
        let failingTimezoneSource = AttributedSeriesFailingSource(
            graphPayload: payloadFixture([
                contributionJSON(
                    date: "2024-05-01",
                    clients: [("claude", "stale-model", "openai", 4, 0.4)],
                    totalsTokens: 4,
                    totalsCost: 0.4),
            ]))
        let droppedOnTimezoneFailure = awaitMainActorValue { () -> Bool in
            AttributedSeriesModel.resetForTesting()
            AttributedSeriesModel.captureLaunchTimeZone("Zone/A")
            let model = AttributedSeriesModel()
            await model.load(source: failingTimezoneSource, confirmed: [], timeZone: "Zone/A")
            guard model.points?.isEmpty == false else { return false }
            failingTimezoneSource.failing = true
            await model.load(source: failingTimezoneSource, confirmed: [], timeZone: "Zone/B")
            return model.points == nil
        }
        expect(
            droppedOnTimezoneFailure == true,
            "a failed recompute after a timezone change drops the series")

        // Travel A -> B -> A. Another consumer rewrites the shared cache under
        // B; by the time QD-1 first loads the zone reads A again, so comparing
        // identifiers would see a match and accept B's day buckets. Only having
        // dropped the marker on the transitions catches it.
        let roundTripSource = AttributedSeriesTestSource(
            graphPayload: payloadFixture([
                contributionJSON(
                    date: "2024-03-01",
                    clients: [("claude", "timezone-model", "openai", 1, 0.1)],
                    totalsTokens: 1,
                    totalsCost: 0.1),
            ]),
            refreshPayload: payloadFixture([
                contributionJSON(
                    date: "2024-03-02",
                    clients: [("claude", "timezone-model", "openai", 2, 0.2)],
                    totalsTokens: 2,
                    totalsCost: 0.2),
            ]))
        let roundTripPoints = awaitMainActorValue { () -> [AttributedDailySeries.Point]? in
            AttributedSeriesModel.resetForTesting()
            AttributedSeriesModel.captureLaunchTimeZone("Zone/A")
            // NotificationCenter delivers to the main queue on a later turn, so
            // wait for the observer to actually run rather than assuming one
            // yield is enough. Giving up here fails the assertion below; it can
            // never pass by luck.
            let before = AttributedSeriesModel.timeZoneGenerationForTesting
            NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
            NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
            for _ in 0..<1000
            where AttributedSeriesModel.timeZoneGenerationForTesting == before {
                await Task.yield()
            }
            let model = AttributedSeriesModel()
            await model.load(source: roundTripSource, confirmed: [], timeZone: "Zone/A")
            return model.points
        }
        expect(
            roundTripSource.graphYears.isEmpty && roundTripSource.refreshYears == [nil]
                && roundTripPoints??.map(\.date) == ["2024-03-02"],
            "a timezone round trip still recomputes rather than trusting the shared cache")

        // The same round trip, but landing while an acquisition is suspended.
        // Stamping unconditionally on resume would overwrite the invalidation
        // with a zone nobody verified this payload was built under — and unlike
        // a stale in-flight payload, no later load could correct that.
        let suspendedSource = AttributedSeriesHookSource(
            payload: payloadFixture([
                contributionJSON(
                    date: "2024-03-01",
                    clients: [("claude", "timezone-model", "openai", 1, 0.1)],
                    totalsTokens: 1,
                    totalsCost: 0.1),
            ]))
        let suspendedOutcome = awaitMainActorValue { () -> (Int, Bool) in
            AttributedSeriesModel.resetForTesting()
            AttributedSeriesModel.captureLaunchTimeZone("Zone/A")
            suspendedSource.onAcquire = {
                // A -> B -> A while the first acquisition is in flight.
                AttributedSeriesModel.invalidateTimeZoneProvenance()
                AttributedSeriesModel.invalidateTimeZoneProvenance()
            }
            let stranded = AttributedSeriesModel()
            await stranded.load(
                source: suspendedSource, confirmed: [], timeZone: "Zone/A")
            // Its payload was acquired under a zone nobody can vouch for, so it
            // must not reach the view either.
            let published = stranded.points == nil
            suspendedSource.onAcquire = nil
            await AttributedSeriesModel().load(
                source: suspendedSource, confirmed: [], timeZone: "Zone/A")
            return (suspendedSource.refreshCalls, published)
        }
        expect(
            suspendedSource.graphCalls == 1 && suspendedOutcome?.0 == 1
                && suspendedOutcome?.1 == true,
            "a transition during a suspended acquisition is neither published nor stamped")

        // Invalidation is process-wide but retained rows are per-instance. A
        // model that last succeeded before a transition must not re-derive its
        // old-zone rows on a later failure, even once another model has already
        // stamped the new zone and made the marker match again.
        let strandedRowsSource = AttributedSeriesFailingSource(
            graphPayload: payloadFixture([
                contributionJSON(
                    date: "2024-06-01",
                    clients: [("claude", "stranded-model", "openai", 3, 0.3)],
                    totalsTokens: 3,
                    totalsCost: 0.3),
            ]))
        let strandedRowsDropped = awaitMainActorValue { () -> Bool in
            AttributedSeriesModel.resetForTesting()
            AttributedSeriesModel.captureLaunchTimeZone("Zone/A")
            let stale = AttributedSeriesModel()
            await stale.load(source: strandedRowsSource, confirmed: [], timeZone: "Zone/A")
            guard stale.points?.isEmpty == false else { return false }
            AttributedSeriesModel.invalidateTimeZoneProvenance()
            // Another model brings the process up to date under the new zone.
            await AttributedSeriesModel().load(
                source: strandedRowsSource, confirmed: [], timeZone: "Zone/B")
            strandedRowsSource.failing = true
            await stale.load(source: strandedRowsSource, confirmed: [], timeZone: "Zone/B")
            return stale.points == nil
        }
        expect(
            strandedRowsDropped == true,
            "rows retained before a transition are never re-derived after it")

        // The same drop, but for a transition that lands *during* a failing
        // acquisition. `shouldRefresh` was decided before it and reads false, so
        // only comparing the generation catches this one; the captured flag would
        // happily re-derive day buckets already known to be misdated.
        let failDuringTransitionSource = AttributedSeriesFailingSource(
            graphPayload: payloadFixture([
                contributionJSON(
                    date: "2024-07-01",
                    clients: [("claude", "transition-model", "openai", 5, 0.5)],
                    totalsTokens: 5,
                    totalsCost: 0.5),
            ]))
        let failDuringTransitionDropped = awaitMainActorValue { () -> Bool in
            AttributedSeriesModel.resetForTesting()
            AttributedSeriesModel.captureLaunchTimeZone("Zone/A")
            let model = AttributedSeriesModel()
            await model.load(
                source: failDuringTransitionSource, confirmed: [], timeZone: "Zone/A")
            guard model.points?.isEmpty == false else { return false }
            // Same zone and no transition seen yet, so this load takes the cheap
            // cached path and captures `shouldRefresh == false`.
            failDuringTransitionSource.failing = true
            failDuringTransitionSource.onAcquire = {
                AttributedSeriesModel.invalidateTimeZoneProvenance()
            }
            await model.load(
                source: failDuringTransitionSource, confirmed: [], timeZone: "Zone/A")
            failDuringTransitionSource.onAcquire = nil
            return model.points == nil
        }
        expect(
            failDuringTransitionDropped == true,
            "a transition during a failing acquisition drops the retained rows")

        // Two loads overlap: the newer one publishes while the older is still
        // suspended. The older must not resume and overwrite it, neither with its
        // stale payload nor with the `confirmed` set it captured.
        let supersededSource = AttributedSeriesReentrantSource(
            outerPayload: payloadFixture([
                contributionJSON(
                    date: "2024-08-01",
                    clients: [("claude", "superseded-model", "openai", 1, 0.1)],
                    totalsTokens: 1,
                    totalsCost: 0.1),
            ]),
            innerPayload: payloadFixture([
                contributionJSON(
                    date: "2024-08-02",
                    clients: [("claude", "current-model", "openai", 2, 0.2)],
                    totalsTokens: 2,
                    totalsCost: 0.2),
            ]))
        let supersededDates = awaitMainActorValue { () -> [String]? in
            AttributedSeriesModel.resetForTesting()
            AttributedSeriesModel.captureLaunchTimeZone("Zone/A")
            let model = AttributedSeriesModel()
            supersededSource.onFirstAcquire = { @MainActor @Sendable in
                await model.load(
                    source: supersededSource, confirmed: [], timeZone: "Zone/A")
            }
            await model.load(source: supersededSource, confirmed: [], timeZone: "Zone/A")
            supersededSource.onFirstAcquire = nil
            return model.points?.map(\.date)
        }
        expect(
            supersededDates ?? [] == ["2024-08-02"],
            "a superseded attributed-series load does not overwrite the newer result")

        // The failure path publishes too, by re-deriving retained rows, so it
        // needs the same guard: a superseded load that then fails would republish
        // the declarations the user has already moved on from.
        let supersededFailureSource = AttributedSeriesReentrantSource(
            outerPayload: payloadFixture([]),
            innerPayload: payloadFixture([
                contributionJSON(
                    date: "2024-08-03",
                    clients: [("claude", "current-model", "openai", 3, 0.3)],
                    totalsTokens: 3,
                    totalsCost: 0.3),
            ]))
        supersededFailureSource.failOuter = true
        let supersededFailureStates = awaitMainActorValue { () -> [UsageAttribution.State]? in
            AttributedSeriesModel.resetForTesting()
            AttributedSeriesModel.captureLaunchTimeZone("Zone/A")
            let model = AttributedSeriesModel()
            supersededFailureSource.onFirstAcquire = { @MainActor @Sendable in
                // The newer load classifies this source as excluded.
                await model.load(
                    source: supersededFailureSource,
                    confirmed: [UsageAttribution.Record(
                        client: "claude", provider: "openai", state: .excluded)],
                    timeZone: "Zone/A")
            }
            // The older load carries no declarations and then fails.
            await model.load(source: supersededFailureSource, confirmed: [], timeZone: "Zone/A")
            supersededFailureSource.onFirstAcquire = nil
            return model.points?.map(\.state)
        }
        expect(
            supersededFailureStates ?? [] == [.excluded],
            "a superseded load that fails does not re-derive with its stale declarations")

        // One recompute cannot outrun the producer race: a computation begun
        // before the transition can still land in the shared entry afterwards.
        // So once a transition is seen, stop reading that entry for good.
        let bypassSource = AttributedSeriesHookSource(
            payload: payloadFixture([
                contributionJSON(
                    date: "2024-06-02",
                    clients: [("claude", "bypass-model", "openai", 6, 0.6)],
                    totalsTokens: 6,
                    totalsCost: 0.6),
            ]))
        let bypassCalls = awaitMainActorValue { () -> (Int, Int) in
            AttributedSeriesModel.resetForTesting()
            AttributedSeriesModel.captureLaunchTimeZone("Zone/A")
            let model = AttributedSeriesModel()
            await model.load(source: bypassSource, confirmed: [], timeZone: "Zone/A")
            AttributedSeriesModel.invalidateTimeZoneProvenance()
            await model.load(source: bypassSource, confirmed: [], timeZone: "Zone/B")
            // Third load, zone unchanged since the second and the marker now
            // matches — the cheap cached path must still not come back.
            await model.load(source: bypassSource, confirmed: [], timeZone: "Zone/B")
            return (bypassSource.graphCalls, bypassSource.refreshCalls)
        }
        expect(
            bypassCalls?.0 == 1 && bypassCalls?.1 == 2,
            "the shared cache is never read again after a transition")

        // Seeding is a launch-time statement about an empty cache. Repeating it
        // later would re-assert a provenance that has since been invalidated.
        let reseedSource = AttributedSeriesHookSource(
            payload: payloadFixture([
                contributionJSON(
                    date: "2024-03-01",
                    clients: [("claude", "timezone-model", "openai", 1, 0.1)],
                    totalsTokens: 1,
                    totalsCost: 0.1),
            ]))
        // Deliberately a re-capture under a DIFFERENT zone with no transition
        // observed. Pairing it with a transition instead would prove nothing:
        // the post-transition cache bypass would force a refresh on its own and
        // mask whether this guard exists at all.
        let reseedRefreshCalls = awaitMainActorValue { () -> Int in
            AttributedSeriesModel.resetForTesting()
            AttributedSeriesModel.captureLaunchTimeZone("Zone/A")
            AttributedSeriesModel.captureLaunchTimeZone("Zone/B")
            await AttributedSeriesModel().load(
                source: reseedSource, confirmed: [], timeZone: "Zone/B")
            return reseedSource.refreshCalls
        }
        expect(
            reseedRefreshCalls == 1 && reseedSource.graphCalls == 0,
            "a repeated launch capture cannot re-seed provenance to another zone")

        // Without the launch hook provenance simply starts unknown, so the first
        // load recomputes and installs the observer itself. That is what makes
        // deleting the hook a cost, not a correctness defect — assert it rather
        // than asserting it in prose.
        let unseededSource = AttributedSeriesHookSource(
            payload: payloadFixture([
                contributionJSON(
                    date: "2024-03-01",
                    clients: [("claude", "timezone-model", "openai", 1, 0.1)],
                    totalsTokens: 1,
                    totalsCost: 0.1),
            ]))
        let unseededRefreshCalls = awaitMainActorValue { () -> Int in
            AttributedSeriesModel.resetForTesting()
            let model = AttributedSeriesModel()
            await model.load(source: unseededSource, confirmed: [], timeZone: "Zone/A")
            let before = AttributedSeriesModel.timeZoneGenerationForTesting
            NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
            for _ in 0..<1000
            where AttributedSeriesModel.timeZoneGenerationForTesting == before {
                await Task.yield()
            }
            await model.load(source: unseededSource, confirmed: [], timeZone: "Zone/A")
            return unseededSource.refreshCalls
        }
        expect(
            unseededRefreshCalls == 2 && unseededSource.graphCalls == 0,
            "an unseeded process still observes transitions without the launch hook")

        // tb_quota_curve across the real seam: the ctb.h declaration, the built
        // symbol, and the envelope. A Rust-side unit test cannot see a header
        // that disagrees with the library. No binding exists in this process
        // (no agent-usage publication has run), so every selection must fail
        // closed — and the polarity matters as much as the message, since a
        // success envelope carrying an error string would read the same to a
        // substring check.
        func quotaCurveFailure(client: String, window: String, generation: UInt64) -> String? {
            do {
                _ = try TBCore.quotaCurve(
                    clientId: client, accountKey: nil, windowKey: window, generation: generation)
                return nil
            } catch let TBCoreError.bridge(message) {
                return message
            } catch {
                return "unexpected: \(error)"
            }
        }
        let unboundCurve = quotaCurveFailure(
            client: "codex", window: "main.session.v1", generation: 1)
        let emptyClientCurve = quotaCurveFailure(client: "", window: "weekly.v1", generation: 1)
        let emptyWindowCurve = quotaCurveFailure(client: "codex", window: "", generation: 1)
        expect(
            unboundCurve?.contains("binding") == true
                && emptyClientCurve?.contains("client_id") == true
                && emptyWindowCurve?.contains("window_key") == true,
            "tb_quota_curve fails closed through the built C ABI for unbound and invalid selections")

        // A bound series with no history answers {"ok":true,"data":null}. The
        // ordinary envelope path treats a missing payload on ok:true as a decode
        // failure, which is right everywhere else and wrong here — so the
        // optional path gets its own check, including that it still rejects a
        // failure envelope rather than swallowing it as "no history".
        func decodeOptionalCurve(_ json: String) -> Result<QuotaCurve?, any Error> {
            Result { try TBCore.decodeOptionalEnvelope(Data(json.utf8)) as QuotaCurve? }
        }
        func curveValue(_ result: Result<QuotaCurve?, any Error>) -> QuotaCurve?? {
            switch result {
            case let .success(value): return .some(value)
            case .failure: return nil
            }
        }
        let curvePointJSON = #"{"sampledAt":10,"usedPercent":4.5,"resetAt":106,"durationSeconds":96,"durationSource":"provider","origin":"liveV3","isActiveGroup":false}"#
        let curveCoverageJSON = #"{"oldestSampledAt":10,"newestSampledAt":10,"sampleCount":1}"#
        let curveDataJSON = #"{"points":["# + curvePointJSON + #"],"coverage":"# + curveCoverageJSON
            + #","activeResetAt":106,"generation":3}"#
        let nullCurve = curveValue(decodeOptionalCurve(#"{"ok":true,"data":null}"#))
        let realCurve = curveValue(decodeOptionalCurve(#"{"ok":true,"data":"# + curveDataJSON + "}"))
        let failedCurve = curveValue(decodeOptionalCurve(#"{"ok":false,"err":"nope"}"#))
        expect(
            nullCurve == .some(nil)
                && realCurve??.points.first?.sampledAt == 10
                && realCurve??.coverage.sampleCount == 1
                && realCurve??.generation == 3
                && failedCurve == nil,
            "an empty-history curve decodes as nil while a failure envelope still throws")

        // ModelColorMap: cost ranking drives shades; unseen models fall back.
        let map = ModelColorMap(entries: [
            ("anthropic", "claude-opus-4-8", 100.0),
            ("anthropic", "claude-haiku-4-5", 1.0),
        ])
        expect(map.color("anthropic", "claude-opus-4-8") == "#da7756", "priciest model gets base shade")
        expect(map.color("anthropic", "claude-haiku-4-5") != "#da7756", "cheaper model is tinted")
        expect(map.color(nil, "gemini-3-pro") == "#06b6d4", "unseen model falls back to provider base")

        // ISODay: civil-date round trip.
        expect(ISODay("1970-01-01")?.number == 0, "epoch day number")
        expect(ISODay("2026-06-10")?.iso == "2026-06-10", "iso round trip")
        expect(ISODay("garbage") == nil, "invalid iso rejected")

        // Streaks: longest run vs current run touching the range end.
        func perDay(_ dates: [String]) -> [String: PerDay] {
            Dictionary(uniqueKeysWithValues: dates.map {
                ($0, PerDay(date: $0, tokens: 10, cost: 1, intensity: 1))
            })
        }
        let s1 = Streaks.compute(
            perDayMap: perDay(["2026-06-01", "2026-06-02", "2026-06-03", "2026-06-05", "2026-06-06"]),
            rangeStart: "2026-06-01", rangeEnd: "2026-06-06")
        expect(s1.longest == 3 && s1.current == 2, "streaks longest 3 current 2")
        let s2 = Streaks.compute(
            perDayMap: perDay(["2026-06-01"]),
            rangeStart: "2026-06-01", rangeEnd: "2026-06-03")
        expect(s2.longest == 1 && s2.current == 0, "broken current streak is zero")
        let s3 = Streaks.compute(perDayMap: [:], rangeStart: "2026-06-10", rangeEnd: "2026-06-01")
        expect(s3.longest == 0 && s3.current == 0, "inverted range is empty")

        // UsagePace: explicit v3 state fixtures, exact duration timing, and
        // mode/basis policy. No pace assertion uses the legacy constructor.
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        func v3Window(
            used: Double,
            durationSeconds: Int64 = 3_600,
            untilReset: TimeInterval = 1_800,
            state: UsagePaceState = .learningHistory,
            historicalPace: HistoricalPace? = nil,
            windowMinutes: Int64? = nil
        ) -> UsageWindow {
            let duration: Int64? = state == .learningDuration || state == .unavailable
                ? nil : durationSeconds
            let durationSource: UsagePaceDurationSource? = duration == nil
                ? (state == .learningDuration ? .observed : nil) : .contract
            let status = PaceStatus(
                state: state, windowKey: "session.v3", durationSeconds: duration,
                durationSource: durationSource,
                completeCycles: state == .available ? 5 : 0,
                reason: state == .unavailable ? .nonRecurring : nil)
            return UsageWindow(
                label: "Session", usedPercent: used, remainingPercent: 100 - used,
                resetsAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(untilReset)),
                windowMinutes: windowMinutes ?? duration.map { $0 / 60 },
                historicalPace: historicalPace,
                cardId: "session.v3", durationSeconds: duration, paceStatus: status)
        }

        let onPace = UsagePace.compute(window: v3Window(used: 50), now: now)
        expect(onPace?.stage == .onTrack && onPace?.basis == .linear
            && onPace?.label == "On pace", "pace on track at 50%/50%")
        let ahead = UsagePace.compute(window: v3Window(used: 80), now: now)
        expect(ahead?.stage == .farAhead && ahead?.label == "30% in deficit"
            && ahead?.basis == .linear, "pace far ahead label")
        // 80% in 30min → 100% in 37.5min, before the 30min reset → ETA 7.5min.
        expect(ahead?.willLastToReset == false && abs((ahead?.etaSeconds ?? 0) - 450) < 1, "pace eta 450s")
        expect(ahead?.etaText == "Projected empty in 8m", "pace eta text")
        let reserve = UsagePace.compute(window: v3Window(used: 40), now: now)
        expect(reserve?.stage == .behind && reserve?.label == "10% in reserve", "pace reserve label")
        expect(reserve?.willLastToReset == true
                   && reserve?.etaText == "On average: lasts until reset",
               "slow burn lasts, and says on what basis — the recent-trend indicator "
                   + "beside it reads a different span and can disagree")
        let learningDurationWindow = v3Window(used: 50, state: .learningDuration)
        expect(UsagePace.compute(window: learningDurationWindow, now: now) == nil,
            "learning duration has no pace")
        expect(UsagePace.compute(
            window: learningDurationWindow, mode: .historical, now: now) == nil,
            "historical learningDuration has no pace")
        expect(UsagePace.compute(
            window: learningDurationWindow, mode: .linear, now: now) == nil,
            "linear learningDuration has no pace")
        expect(UsagePace.compute(window: v3Window(used: 50, untilReset: -10), now: now) == nil,
            "past reset, no pace")
        expect(UsagePace.compute(window: v3Window(used: 50, untilReset: 3_600), now: now) == nil,
            "elapsed-zero positive usage has no pace")

        // A non-minute duration proves timing uses exact v3 seconds rather than
        // the compatibility windowMinutes field.
        let exactDuration = UsagePace.compute(
            window: v3Window(used: 50, durationSeconds: 3_601, untilReset: 1_800), now: now)
        let exactExpected = (Double(3_601 - 1_800) / Double(3_601)) * 100
        expect(exactDuration?.expectedUsedPercent == exactExpected
            && exactDuration?.expectedUsedPercent != 50,
            "pace uses exact duration seconds")

        let historicalLasts = HistoricalPace(
            expectedUsedPercent: 80, etaSeconds: nil,
            willLastToReset: true, runOutProbability: nil)
        let availableWindow = v3Window(
            used: 50, state: .available, historicalPace: historicalLasts)
        let hist = UsagePace.compute(
            window: availableWindow, mode: .historical, now: now)
        expect(hist?.expectedUsedPercent == 80 && hist?.stage == .farBehind
            && hist?.basis == .historical, "historical available uses backend expected")
        expect(hist?.willLastToReset == true && hist?.etaSeconds == nil,
            "historical lasts result is trusted")
        expect(hist?.isHistoricalDeficit == false, "historical reserve is not a deficit")
        // PACE-BASIS. The lasts-until-reset phrasing names the span it read,
        // because the recent-trend indicator beside it can say the window runs
        // out — both true, and a self-contradiction when each is stated bare.
        // `.linear` reaches the same branch, so a label hardcoded to the
        // historical wording would be a false attribution on the other mode.
        expect(hist?.etaText == "Historically: lasts until reset",
               "PACE-BASIS a historical projection says it is historical")
        expect(
            reserve?.etaText != hist?.etaText
                && reserve?.willLastToReset == hist?.willLastToReset,
            "PACE-BASIS and the linear one says something different for the same "
                + "verdict, so the basis is read rather than assumed")

        let riskyWindow = v3Window(
            used: 90, state: .available,
            historicalPace: HistoricalPace(
                expectedUsedPercent: 50, etaSeconds: 120,
                willLastToReset: false, runOutProbability: 0.8))
        let risky = UsagePace.compute(window: riskyWindow, mode: .historical, now: now)
        expect(risky?.willLastToReset == false && risky?.etaSeconds == 120
            && risky?.basis == .historical && risky?.isHistoricalDeficit == true,
            "historical projected empty trusts backend eta and deficit gate")
        expect(risky?.etaText == "Projected empty in 2m", "historical projected empty text")

        let learningHistoryWindow = v3Window(used: 80, state: .learningHistory)
        let learningEstimate = UsagePace.compute(
            window: learningHistoryWindow, mode: .historical, now: now)
        expect(learningEstimate?.basis == .linear
            && learningEstimate?.stage.isDeficit == true
            && learningEstimate?.isHistoricalDeficit == false,
            "historical learningHistory is identifiable Linear estimate")
        expect(learningEstimate?.expectedUsedPercent == 50,
            "learningHistory historical mode uses Linear estimate")

        // Stage 5D UI presentation: typed state copy and mode gates are pure
        // helper behavior, so these contracts do not depend on SwiftUI layout.
        for mode in [PaceMode.historical, PaceMode.linear] {
            expect(
                AgentLimitsCard.PacePresentation.statusText(
                    state: .learningDuration, reason: nil, mode: mode)
                    == "Learning reset duration",
                "learningDuration copy in \(mode.rawValue) mode")
            expect(
                AgentLimitsCard.PacePresentation.statusText(
                    state: .legacyMissing, reason: nil, mode: mode)
                    == "Pace unavailable · legacy data",
                "legacy pace copy in \(mode.rawValue) mode")
        }
        expect(
            AgentLimitsCard.PacePresentation.statusText(
                state: .learningHistory, reason: nil, mode: .historical)
                == "Learning history · Linear estimate",
            "learningHistory uses exact Linear estimate copy")
        expect(
            AgentLimitsCard.PacePresentation.statusText(
                state: .learningHistory, reason: nil, mode: .linear) == "Linear"
                && AgentLimitsCard.PacePresentation.statusText(
                    state: .available, reason: nil, mode: .linear) == "Linear",
            "linear mode labels duration-ready cards")

        let unavailableCopies: [(UsagePaceUnavailableReason, String)] = [
            (.windowIdentity, "Pace unavailable · unknown quota window"),
            (.missingReset, "Pace unavailable · missing reset"),
            (.invalidEvidence, "Pace unavailable · invalid quota data"),
            (.accountScope, "Pace unavailable · account identity unavailable"),
            (.storeCapacity, "Pace unavailable · history storage full"),
            (.history, "Pace unavailable · history unavailable"),
            (.nonRecurring, "Pace unavailable · non-recurring quota"),
        ]
        for (reason, copy) in unavailableCopies {
            expect(
                AgentLimitsCard.PacePresentation.statusText(
                    state: .unavailable, reason: reason, mode: .historical) == copy,
                "typed unavailable \(reason.rawValue) copy")
        }
        expect(
            AgentLimitsCard.PacePresentation.statusText(
                state: .available, reason: nil, mode: .historical) == nil,
            "available has no learning status copy")
        expect(
            AgentLimitsCard.PacePresentation.statusText(
                state: .learningHistory, reason: nil, mode: .off) == nil
                    && AgentLimitsCard.PacePresentation.statusText(
                        state: .unavailable, reason: .history, mode: .off) == nil
                    && AgentLimitsCard.PacePresentation.statusText(
                        state: .legacyMissing, reason: nil, mode: .off) == nil,
            "off hides pace status")

        expect(UsagePace.compute(window: availableWindow, mode: .off, now: now) == nil,
            "pace mode off")
        let linear = UsagePace.compute(window: availableWindow, mode: .linear, now: now)
        expect(linear?.expectedUsedPercent == 50 && linear?.basis == .linear,
            "linear mode ignores available historical")
        expect(UsagePace.compute(window: availableWindow, now: now)?.basis == .linear,
            "direct pace compute stays linear")
        // The warning color is basis-independent: a Linear estimate in deficit
        // is colored exactly like a Historical one, so the marker cannot blink
        // out when the Historical fit stops re-qualifying. `linear` is the
        // 50%/50% available window — on track, so not colored — and `hist` is a
        // historical *reserve*, the negative control on the other side.
        let linearDeficit = UsagePace.compute(
            window: v3Window(used: 80, state: .available, historicalPace: historicalLasts),
            mode: .linear, now: now)
        expect(
            AgentLimitsCard.PacePresentation.isDeficit(risky)
                && AgentLimitsCard.PacePresentation.isDeficit(learningEstimate)
                && AgentLimitsCard.PacePresentation.isDeficit(linearDeficit)
                && linearDeficit?.basis == .linear
                && !AgentLimitsCard.PacePresentation.isDeficit(linear)
                && !AgentLimitsCard.PacePresentation.isDeficit(hist),
            "UI warning color follows the deficit stage, not the pace basis")
        let unavailableWindow = v3Window(used: 50, state: .unavailable)
        expect(UsagePace.compute(
            window: unavailableWindow, mode: .historical, now: now) == nil,
            "historical unavailable has no silent Linear fallback")
        expect(UsagePace.compute(
            window: unavailableWindow, mode: .linear, now: now) == nil,
            "linear unavailable has no pace")

        // Stage 0 old-fail/new-pass baseline: legacy windowMinutes cannot
        // restore pace when the typed paceStatus key is absent.
        let legacyWindow = try? JSONDecoder().decode(
            UsageWindow.self,
            from: Data(#"{"label":"Weekly","usedPercent":80,"remainingPercent":20,"windowMinutes":60}"#.utf8))
        expect(legacyWindow.flatMap {
            UsagePace.compute(window: $0, mode: .historical, now: now)
        } == nil, "stage0 legacy payload has no silent historical Linear fallback")
        expect(legacyWindow.flatMap {
            UsagePace.compute(window: $0, now: now)
        } == nil, "legacy windowMinutes cannot revive direct pace")

        let lastingRiskWindow = v3Window(
            used: 50, state: .available,
            historicalPace: HistoricalPace(
                expectedUsedPercent: 80, etaSeconds: nil,
                willLastToReset: true, runOutProbability: 0.2))
        let lastingRiskPace = UsagePace.compute(
            window: lastingRiskWindow, mode: .historical, now: now)!
        let lastingRiskPresentation = UsagePace.presentation(
            window: lastingRiskWindow, mode: .historical, pace: lastingRiskPace)
        expect(lastingRiskPresentation.etaText == nil
            && lastingRiskPresentation.riskText == "≈ 20% run-out risk",
            "historical available risk suppresses lasts text")
        expect(runOutRiskLabel(window: riskyWindow) == "≈ 80% run-out risk",
            "risk belongs to historical available")
        expect(runOutRiskLabel(window: riskyWindow, pace: linear) == nil,
            "Linear basis cannot display nested risk")
        expect(UsagePace.presentation(
            window: riskyWindow, mode: .linear, pace: linear!).riskText == nil,
            "linear presentation cannot display nested risk")
        expect(UsagePace.presentation(
            window: learningHistoryWindow, mode: .historical, pace: learningEstimate!).riskText == nil,
            "learningHistory Linear estimate cannot display nested risk")
        expect(runOutRiskLabel(window: v3Window(used: 50, state: .learningHistory)) == nil,
            "learningHistory has no historical risk")

        let exhaustedWindow = v3Window(
            used: 100, state: .available,
            historicalPace: HistoricalPace(
                expectedUsedPercent: 80, etaSeconds: 0,
                willLastToReset: false, runOutProbability: 1))
        let exhausted = UsagePace.compute(
            window: exhaustedWindow, mode: .historical, now: now)
        expect(exhausted?.etaSeconds == 0 && exhausted?.willLastToReset == false
            && exhausted?.etaText == "Projected empty now"
            && runOutRiskLabel(window: exhaustedWindow) == "≈ 100% run-out risk",
            "historical exhausted result is coherent")
        expect(UsagePace.durationText(130 * 60) == "2h 10m", "duration text h m")
        expect(UsagePace.durationText(26 * 3600) == "1d 2h", "duration text d h")
        let resetFormatter = ISO8601DateFormatter()
        let resetAt = resetFormatter.string(from: now.addingTimeInterval(1_801))
        expect(
            UsagePace.resetText(for: resetAt, now: now) == "Resets in 31m",
            "reset countdown uses structured timestamp and ceil-minute rounding")
        let resetNow = resetFormatter.string(from: now.addingTimeInterval(-1))
        expect(
            UsagePace.resetText(for: resetNow, now: now) == "Resets now",
            "expired reset countdown is localized")

        // Stage 5A production decoder: v3 pace states are typed and strict;
        // only an entirely missing paceStatus key takes the internal legacy path.
        func decodeWindow(_ json: String) -> UsageWindow? {
            try? JSONDecoder().decode(UsageWindow.self, from: Data(json.utf8))
        }
        let learningDurationJSON = """
        {"cardId":"session.v1","label":"Session","usedPercent":20,"remainingPercent":80,
         "resetsAt":"2026-07-17T05:00:00Z",
         "paceStatus":{"state":"learningDuration","windowKey":"session.v1",
         "durationSource":"observed","completeCycles":0}}
        """
        let learningHistoryJSON = """
        {"cardId":"weekly.v1","label":"Weekly","usedPercent":35,"remainingPercent":65,
         "resetsAt":"2026-07-24T00:00:00Z","windowMinutes":300,
         "paceStatus":{"state":"learningHistory","windowKey":"weekly.v1",
         "durationSeconds":18000,"durationSource":"contract","completeCycles":2}}
        """
        let availableJSON = """
        {"cardId":"daily.v1","label":"Daily","usedPercent":60,"remainingPercent":40,
         "resetsAt":"2026-07-24T00:00:00Z","windowMinutes":300,
         "paceStatus":{"state":"available","windowKey":"daily.v1",
         "durationSeconds":18000,"durationSource":"contract","completeCycles":4},
         "historicalPace":{"expectedUsedPercent":55,"etaSeconds":900,
         "willLastToReset":false,"runOutProbability":0.25}}
        """
        let currentFitReset = resetFormatter.string(from: now.addingTimeInterval(10_800))
        let currentFitJSON = """
        {"cardId":"current-fit.v1","label":"Current fit","usedPercent":36,"remainingPercent":64,
         "resetsAt":"\(currentFitReset)","windowMinutes":300,
         "paceStatus":{"state":"available","windowKey":"current-fit.v1",
         "durationSeconds":18000,"durationSource":"provider","completeCycles":0},
         "historicalPace":{"expectedUsedPercent":30,"etaSeconds":5400,
         "willLastToReset":false}}
        """
        let unavailableJSON = """
        {"cardId":"extra_usage.v1","label":"Extra usage","usedPercent":70,"remainingPercent":30,
         "paceStatus":{"state":"unavailable","windowKey":"extra_usage.v1",
         "completeCycles":0,"reason":"nonRecurring"}}
        """
        let learningDuration = decodeWindow(learningDurationJSON)
        let learningHistory = decodeWindow(learningHistoryJSON)
        let available = decodeWindow(availableJSON)
        let currentFit = decodeWindow(currentFitJSON)
        let unavailable = decodeWindow(unavailableJSON)
        expect(
            learningDuration?.paceStatus.state == UsagePaceState.learningDuration &&
                learningDuration?.durationSeconds == nil &&
                learningDuration?.paceStatus.durationSource == .observed,
            "v3 learningDuration decodes with observed source")
        expect(
            learningHistory?.paceStatus.state == UsagePaceState.learningHistory &&
                learningHistory?.durationSeconds == 18_000 &&
                learningHistory?.historicalPace == nil,
            "v3 learningHistory decodes with exact duration")
        expect(
            available?.paceStatus.state == UsagePaceState.available &&
                available?.durationSeconds == 18_000 &&
                available?.historicalPace?.expectedUsedPercent == 55,
            "v3 available decodes with historical result")
        expect(
            currentFit?.paceStatus.state == UsagePaceState.available &&
                currentFit?.paceStatus.completeCycles == 0 &&
                currentFit?.durationSeconds == 18_000 &&
                currentFit?.historicalPace?.expectedUsedPercent == 30 &&
                currentFit?.historicalPace?.runOutProbability == nil,
            "v3 current fit decodes zero-cycle historical result")
        let currentFitPace = currentFit.flatMap {
            UsagePace.compute(window: $0, mode: .historical, now: now)
        }
        expect(
            currentFitPace?.basis == .historical &&
                currentFitPace?.actualUsedPercent == 36 &&
                currentFitPace?.expectedUsedPercent == 30 &&
                currentFitPace?.etaSeconds == 5_400 &&
                currentFitPace?.willLastToReset == false,
            "zero-cycle current fit uses backend historical projection")
        let currentFitRisk = currentFit.flatMap {
            runOutRiskLabel(window: $0, pace: currentFitPace)
        }
        expect(currentFitRisk == nil, "zero-cycle current fit keeps partial risk absent")
        expect(
            currentFitPace?.expectedUsedPercent != 40,
            "zero-cycle current fit does not fall back to Linear")
        expect(
            unavailable?.paceStatus.state == UsagePaceState.unavailable &&
                unavailable?.paceStatus.reason == .nonRecurring &&
                unavailable?.durationSeconds == nil,
            "v3 unavailable decodes with typed reason")

        let legacyDecoded = decodeWindow(
            "{\"label\":\"Weekly\",\"usedPercent\":50,\"remainingPercent\":50,\"windowMinutes\":60}")
        expect(
            legacyDecoded?.paceStatus.state == UsagePaceState.legacyMissing &&
                legacyDecoded?.cardId == "legacy.missing.v1" &&
                legacyDecoded?.durationSeconds == nil && legacyDecoded?.windowMinutes == 60,
            "missing whole paceStatus uses fixed legacy identity without duration inference")

        let invalidFixtures: [(String, String)] = [
            ("present null paceStatus", """
             {"cardId":"weekly.v1","label":"Weekly","usedPercent":50,"remainingPercent":50,
              "paceStatus":null}
             """),
            ("unknown state", """
             {"cardId":"weekly.v1","label":"Weekly","usedPercent":50,"remainingPercent":50,
              "paceStatus":{"state":"futureState","windowKey":"weekly.v1","completeCycles":0}}
             """),
            ("unknown source", """
             {"cardId":"weekly.v1","label":"Weekly","usedPercent":50,"remainingPercent":50,
              "paceStatus":{"state":"learningHistory","windowKey":"weekly.v1",
              "durationSeconds":18000,"durationSource":"calendar","completeCycles":0}}
             """),
            ("unknown reason", """
             {"cardId":"extra_usage.v1","label":"Extra usage","usedPercent":50,"remainingPercent":50,
              "paceStatus":{"state":"unavailable","windowKey":"extra_usage.v1",
              "completeCycles":0,"reason":"unsupported"}}
             """),
            ("missing cardId", """
             {"label":"Weekly","usedPercent":50,"remainingPercent":50,
              "paceStatus":{"state":"learningDuration","windowKey":"weekly.v1","completeCycles":0}}
             """),
            ("contradictory percentages", """
             {"cardId":"weekly.v1","label":"Weekly","usedPercent":80,"remainingPercent":80,
              "paceStatus":{"state":"learningDuration","windowKey":"weekly.v1","completeCycles":0}}
             """),
            ("available without historicalPace", """
             {"cardId":"weekly.v1","label":"Weekly","usedPercent":50,"remainingPercent":50,
              "windowMinutes":300,"paceStatus":{"state":"available","windowKey":"weekly.v1",
              "durationSeconds":18000,"durationSource":"contract","completeCycles":0}}
             """),
            ("learningHistory with historicalPace", """
             {"cardId":"weekly.v1","label":"Weekly","usedPercent":50,"remainingPercent":50,
              "windowMinutes":300,"paceStatus":{"state":"learningHistory","windowKey":"weekly.v1",
              "durationSeconds":18000,"durationSource":"contract","completeCycles":0},
              "historicalPace":{"expectedUsedPercent":50,"willLastToReset":true}}
             """),
            ("windowKey and reason contradiction", """
             {"cardId":"unknown.v1","label":"Unknown","usedPercent":50,"remainingPercent":50,
              "paceStatus":{"state":"unavailable","windowKey":null,"completeCycles":0,
              "reason":"accountScope"}}
             """),
            ("duration and windowMinutes contradiction", """
             {"cardId":"weekly.v1","label":"Weekly","usedPercent":50,"remainingPercent":50,
              "windowMinutes":301,"paceStatus":{"state":"learningHistory","windowKey":"weekly.v1",
              "durationSeconds":18000,"durationSource":"contract","completeCycles":0}}
             """),
            ("duration without derived windowMinutes", """
             {"cardId":"weekly.v1","label":"Weekly","usedPercent":50,"remainingPercent":50,
              "paceStatus":{"state":"learningHistory","windowKey":"weekly.v1",
              "durationSeconds":18000,"durationSource":"contract","completeCycles":0}}
             """),
        ]
        for (label, json) in invalidFixtures {
            expect(decodeWindow(json) == nil, "v3 rejects \(label)")
        }

        let productionPayloadJSON = """
        {"generatedAt":"2026-07-17T00:00:00Z","agents":[
          {"clientId":"codex","source":"oauth","updatedAt":"2026-07-17T00:00:00Z",
           "identity":{"email":"fixture@example.invalid","plan":"plus"},
           "windows":[\(learningDurationJSON),\(learningHistoryJSON),\(availableJSON),\(currentFitJSON),\(unavailableJSON)],
           "credits":{"remaining":12.5,"unlimited":false},"error":null}
        ],"opencodeSubscriptions":["Codex"]}
        """
        let productionPayload = try? JSONDecoder().decode(
            AgentUsagePayload.self, from: Data(productionPayloadJSON.utf8))
        expect(
            productionPayload?.agents.count == 1 &&
                productionPayload?.agents.first?.windows.count == 5 &&
                productionPayload?.agents.first?.windows[2].paceStatus.state == .available &&
                productionPayload?.agents.first?.windows[3].paceStatus.state == .available &&
                productionPayload?.agents.first?.windows[3].paceStatus.completeCycles == 0 &&
                productionPayload?.agents.first?.windows[3].historicalPace?.expectedUsedPercent == 30,
            "complete AgentUsagePayload v3 shape decodes zero-cycle current fit")

        // Rust's publication gate orders generations, while the Swift state
        // guards apply order shared by popover and Settings models.
        let publicationAJSON = """
        {"generatedAt":"A","publicationGeneration":1,"agents":[
          {"clientId":"codex","source":"oauth","updatedAt":"A",
           "windows":[{"cardId":"session.v1","label":"Session","usedPercent":12,"remainingPercent":88}],
           "error":null}]}
        """
        let publicationBJSON = """
        {"generatedAt":"B","publicationGeneration":2,"agents":[
          {"clientId":"codex","source":"oauth","updatedAt":"B",
           "windows":[],"error":"terminal B"}]}
        """
        let legacyPublicationJSON = """
        {"generatedAt":"legacy","agents":[
          {"clientId":"codex","source":"oauth","updatedAt":"legacy",
           "windows":[],"error":"legacy payload"}]}
        """
        let publicationA = try! JSONDecoder().decode(
            AgentUsagePayload.self, from: Data(publicationAJSON.utf8))
        let publicationB = try! JSONDecoder().decode(
            AgentUsagePayload.self, from: Data(publicationBJSON.utf8))
        let legacyPublication = try! JSONDecoder().decode(
            AgentUsagePayload.self, from: Data(legacyPublicationJSON.utf8))

        var stalePublicationState = AgentUsagePublicationState()
        _ = stalePublicationState.resolve(publicationB)
        let staleResult = stalePublicationState.resolve(publicationA)
        expect(
            staleResult.publicationGeneration == 2 &&
                staleResult.agents.first?.error == "terminal B" &&
                staleResult.agents.first?.windows.isEmpty == true,
            "stale generation resolves to newer terminal payload content")

        var orderedPublicationState = AgentUsagePublicationState()
        let firstResult = orderedPublicationState.resolve(publicationA)
        let secondResult = orderedPublicationState.resolve(publicationB)
        expect(
            firstResult.publicationGeneration == 1 &&
                firstResult.agents.first?.windows.first?.usedPercent == 12,
            "generation 1 success applies its own payload")
        expect(
            secondResult.publicationGeneration == 2 &&
                secondResult.agents.first?.error == "terminal B",
            "generation 2 terminal replaces generation 1")

        let legacyResult = stalePublicationState.resolve(legacyPublication)
        expect(
            legacyResult.publicationGeneration == nil &&
                legacyResult.agents.first?.error == "legacy payload",
            "legacy payload passes through without touching generation state")
        let afterLegacy = stalePublicationState.resolve(publicationA)
        expect(
            afterLegacy.publicationGeneration == 2 &&
                afterLegacy.agents.first?.error == "terminal B",
            "legacy payload does not lower generated publication state")

        func settingsQuotaPayload(generation: UInt64?, remaining: Double) -> AgentUsagePayload {
            let generationField = generation.map { #","publicationGeneration":\#($0)"# } ?? ""
            let json = """
            {"generatedAt":"same"\(generationField),"agents":[
              {"clientId":"codex","source":"oauth","updatedAt":"same",
               "windows":[{"cardId":"session.v1","label":"Session","usedPercent":\(100 - remaining),"remainingPercent":\(remaining)}]}]}
            """
            return try! JSONDecoder().decode(AgentUsagePayload.self, from: Data(json.utf8))
        }
        let settingsGeneration41 = settingsQuotaPayload(generation: 41, remaining: 80)
        let settingsGeneration42 = settingsQuotaPayload(generation: 42, remaining: 80)
        let settingsGeneration41ID = SettingsWindowView.quotaReconciliationID(
            payload: settingsGeneration41,
            persistedSelection: "codex|session.v1",
            excluding: [],
            exclusionSignature: "")
        let settingsGeneration42ID = SettingsWindowView.quotaReconciliationID(
            payload: settingsGeneration42,
            persistedSelection: "codex|session.v1",
            excluding: [],
            exclusionSignature: "")
        expect(
            settingsGeneration41ID != settingsGeneration42ID,
            "Settings reconciliation identity tracks publication generation")

        let settingsLegacy80 = settingsQuotaPayload(generation: nil, remaining: 80)
        let settingsLegacy20 = settingsQuotaPayload(generation: nil, remaining: 20)
        let settingsLegacy80ID = SettingsWindowView.quotaReconciliationID(
            payload: settingsLegacy80,
            persistedSelection: "codex|session.v1",
            excluding: [],
            exclusionSignature: "")
        let settingsLegacy20ID = SettingsWindowView.quotaReconciliationID(
            payload: settingsLegacy20,
            persistedSelection: "codex|session.v1",
            excluding: [],
            exclusionSignature: "")
        expect(
            settingsLegacy80ID != settingsLegacy20ID,
            "Settings legacy reconciliation identity fingerprints resolved quota")
        expect(
            settingsGeneration41ID != SettingsWindowView.quotaReconciliationID(
                payload: settingsGeneration41,
                persistedSelection: "codex|weekly.v1",
                excluding: [],
                exclusionSignature: "") &&
                settingsGeneration41ID != SettingsWindowView.quotaReconciliationID(
                    payload: settingsGeneration41,
                    persistedSelection: "codex|session.v1",
                    excluding: ["codex"],
                    exclusionSignature: "codex"),
            "Settings reconciliation identity tracks selection and exclusions")

        // Contribution grid: GitHub layout, col 0 row 0 = Sunday on/before
        // Jan 1; out-of-year cells are never active; max tracks active only.
        expect(ISODay("1970-01-01")?.weekday == 4, "epoch day is Thursday")
        expect(ISODay("2026-06-07")?.weekday == 0, "2026-06-07 is Sunday")
        let grid = buildGrid(
            year: "2026",
            perDayMap: [
                "2026-01-01": PerDay(date: "2026-01-01", tokens: 500, cost: 1, intensity: 1),
                "2025-12-29": PerDay(date: "2025-12-29", tokens: 900, cost: 1, intensity: 1),
            ])
        expect(grid.rows == 7 && grid.cols >= 53 && grid.cells.count == grid.cols * 7, "grid shape")
        expect(grid.cells.first?.date == "2025-12-28" && grid.cells.first?.inYear == false, "grid starts on the prior Sunday")
        let jan1 = grid.cells.first { $0.date == "2026-01-01" }
        expect(jan1?.col == 0 && jan1?.row == 4 && jan1?.active == true, "jan 1 lands on Thursday row")
        expect(grid.maxTokens == 500, "out-of-year tokens don't drive max")
        expect(grid.cells.first { $0.date == "2025-12-29" }?.active == false, "out-of-year cell inactive")

        // Trace collapse: one row per client, agents/models joined sorted,
        // "unknown" dropped when named models exist, rows sorted by tokens.
        func bucket(_ client: String, _ agent: String, _ model: String, _ tokens: Int64) -> TraceBucket {
            TraceBucket(
                client: client, agent: agent, model: model, tokens: tokens,
                messages: 1, tokensPerMin: Double(tokens))
        }
        let collapsed = TraceBucket.collapseByClient([
            bucket("claude-code", "Main", "claude-opus-4-8", 100),
            bucket("claude-code", "Subagent", "unknown", 50),
            bucket("codex-cli", "Main", "gpt-5.5", 400),
        ])
        expect(collapsed.count == 2 && collapsed[0].client == "codex-cli", "collapse groups and sorts by tokens")
        expect(collapsed[1].tokens == 150 && collapsed[1].tokensPerMin == 150, "collapse sums tokens and rate")
        expect(collapsed[1].agent == "Main, Subagent", "collapse joins agents sorted")
        expect(collapsed[1].model == "claude-opus-4-8", "collapse drops unknown among named models")
        expect(
            TraceBucket.collapseByClient([bucket("amp", "Main", "unknown", 5)]).first?.model == "unknown",
            "collapse keeps a lone unknown model")

        // Live-rate total with hidden clients excluded (issue #35). Bucket
        // tokens_per_min == tokens here (see `bucket`), so sums are exact. The
        // rows carry RAW tail ids (claude-code/codex-cli); the hidden set holds
        // CANONICAL short ids (claude/codex) — totalRate normalizes each row
        // before the membership test, so hiding "claude" must drop claude-code.
        let rateRows = [
            bucket("claude-code", "Main", "claude-opus-4-8", 100),
            bucket("claude-code", "Subagent", "unknown", 50),
            bucket("codex-cli", "Main", "gpt-5.5", 400),
        ]
        expect(TraceBucket.totalRate(rateRows, hidden: []) == 550, "rate empty-hidden is the plain sum")
        expect(TraceBucket.totalRate(rateRows, hidden: ["codex"]) == 150, "rate hiding canonical codex drops codex-cli rows")
        expect(TraceBucket.totalRate(rateRows, hidden: ["claude"]) == 400, "rate hiding canonical claude drops claude-code rows")
        expect(TraceBucket.totalRate(rateRows, hidden: ["claude", "codex"]) == 0, "rate all-hidden is zero")

        // Trace id canonicalization (issue #36): raw tail ids fold to the
        // registry's short ids via EXPLICIT aliases only — a mixed set drops
        // only the hidden client, and already-canonical ids pass through. There
        // is deliberately NO generic "-cli" strip: `antigravity-cli` is a
        // registered client distinct from the `antigravity` IDE, so stripping
        // would conflate them.
        let mixedRows = [
            bucket("claude-code", "Main", "m", 100),
            bucket("codex-cli", "Main", "m", 50),
            bucket("cursor", "Main", "m", 30),
        ]
        expect(TraceBucket.totalRate(mixedRows, hidden: ["claude"]) == 80, "canonical hide drops only claude-code rows")
        expect(ClientRegistry.canonicalClient("gemini-cli") == "gemini", "canonical explicit gemini-cli")
        expect(ClientRegistry.canonicalClient("antigravity-cli") == "antigravity-cli", "canonical preserves registered antigravity-cli")
        expect(ClientRegistry.canonicalClient("droid-cli") == "droid-cli", "canonical does NOT strip a generic -cli")
        expect(ClientRegistry.canonicalClient("claude") == "claude", "canonical short id passes through")
        expect(ClientRegistry.style("kimi").displayName == "Kimi", "Kimi registry covers CLI and Code")
        expect(ClientRegistry.style("junie").displayName == "Junie", "Junie registry metadata")
        expect(ClientRegistry.style("opencodereview").displayName == "OpenCodeReview", "OpenCodeReview registry metadata")
        // Sources that are not surface-scoped carry no form-factor suffix:
        // ~/.codex/sessions is majority Codex Desktop, ~/.copilot merges CLI
        // OTel with the desktop app's data.db, and the cursor source is an
        // account-level billing export. Naming any of them "... CLI"/"... IDE"
        // claims a scope the data does not have.
        for (id, name) in [("codex", "Codex"), ("copilot", "Copilot"), ("cursor", "Cursor")] {
            expect(ClientRegistry.style(id).displayName == name,
                "\(id) carries no form-factor suffix — its source spans CLI, IDE and desktop")
            expect(ClientRegistry.shortName(id) == name,
                "\(id) legend label is unchanged by dropping the suffix")
        }
        // The " IDE" arm of shortName was dropped with "Cursor IDE"; it stays
        // dropped only while no registered name ends in it.
        expect(ClientRegistry.allIds.allSatisfy { !ClientRegistry.style($0).displayName.hasSuffix(" IDE") },
            "no registered display name ends in \" IDE\" (shortName no longer strips it)")
        // AgentLimitsCard keeps its own generic "-cli" fold for quota-card
        // attribution: explicit aliases via the registry, then a local strip so
        // antigravity-cli shares the antigravity quota snapshot — this fold must
        // NOT leak into the deny-filter canonicalizer above.
        expect(AgentLimitsCard.normalizeTraceClient("codex-cli") == "codex", "limits wrapper applies explicit alias")
        expect(AgentLimitsCard.normalizeTraceClient("antigravity-cli") == "antigravity", "limits wrapper folds generic -cli for quota attribution")

        // Quota resolver: card IDs are explicit and missing paceStatus remains
        // a valid legacy fixture. Selection tests intentionally read only
        // identity and percentage fields.
        let quotaJSON = """
        {"generatedAt":"now","agents":[
          {"clientId":"codex","source":"oauth","updatedAt":"now",
           "windows":[{"cardId":"session.v1","label":"Session","usedPercent":20,"remainingPercent":80},
                      {"cardId":"weekly.v1","label":"Weekly","usedPercent":65,"remainingPercent":35},
                      {"cardId":"model.gpt|preview.v1","label":"Delimiter","usedPercent":5,"remainingPercent":95}]},
          {"clientId":"claude","source":"oauth","updatedAt":"now",
           "windows":[{"cardId":"session.v1","label":"Session","usedPercent":88,"remainingPercent":12},
                      {"cardId":"weekly.v1","label":"Weekly","usedPercent":10,"remainingPercent":90}]},
          {"clientId":"antigravity","source":"oauth","updatedAt":"now","windows":[],
           "error":"Antigravity OAuth client was not found."},
          {"clientId":"grok","source":"oauth","updatedAt":"now",
           "windows":[{"cardId":"billing.weekly.v1","label":"Weekly","usedPercent":99,"remainingPercent":1}],
           "error":"Grok request timed out.",
           "transportDiagnostic":{"category":"timeout"}}
        ]}
        """
        let quotaPayload = try! JSONDecoder().decode(
            AgentUsagePayload.self, from: Data(quotaJSON.utf8))

        // Individual client trays: bounded persistence, client-local quota
        // resolution, eligibility, display privacy, and static icon rendering.
        let clientGraphJSON = """
        {"meta":{"generatedAt":"now","version":"1","dateRange":{"start":"2026-07-01","end":"2026-07-01"}},
         "summary":{"totalTokens":0,"totalCost":0,"totalDays":0,"activeDays":0,"averagePerDay":0,
                    "maxCostInSingleDay":0,"clients":["claude","codex","grok"],"models":[]},
         "years":[],"contributions":[]}
        """
        let clientGraph = try! JSONDecoder().decode(
            UsagePayload.self, from: Data(clientGraphJSON.utf8))
        let officialClientIDs = MainActor.assumeIsolated {
            AgentIconView.availableOfficialClientIDs()
        }
        let registeredOfficialClientIDs = MainActor.assumeIsolated {
            AgentIconView.officialClientIDs
        }
        expect(
            officialClientIDs == registeredOfficialClientIDs,
            "every official registry id has a loadable brand asset")
        expect(
            officialClientIDs.contains("antigravity-cli")
                && officialClientIDs.contains("kilo")
                && !officialClientIDs.contains("junie"),
            "icon aliases are official while fallback-only clients are not")
        let renderedBrandImage = MainActor.assumeIsolated {
            AgentIconView.statusItemImage(clientId: "claude")
        }
        let brandReps = renderedBrandImage?.representations.compactMap { $0 as? NSBitmapImageRep } ?? []
        expect(
            renderedBrandImage?.isTemplate == false && brandReps.count == 2
                && brandReps.map(\.pixelsWide) == [18, 36]
                && brandReps.map(\.pixelsHigh) == [18, 36],
            "official status icon has fixed 1x and 2x representations")
        expect(
            MainActor.assumeIsolated {
                AgentIconView.statusItemImage(clientId: "junie") == nil
                    && AgentIconView.statusItemImage(clientId: "unknown") == nil
            },
            "fallback-only and unknown clients cannot create status icons")

        let clientDefaultsName = "TokenBar.SelfTest.ClientTray.\(UUID().uuidString)"
        if let clientDefaults = UserDefaults(suiteName: clientDefaultsName) {
            defer { clientDefaults.removePersistentDomain(forName: clientDefaultsName) }

            func trayPaddedID(_ i: Int, _ n: Int) -> String {
                let p = "c\(i)_"
                return p + String(repeating: "a", count: n - p.utf8.count)
            }
            func trayEnabledIDs(_ count: Int, _ bytes: Int, stretchFirst: Int = 0) -> Set<String> {
                var ids = (0 ..< count).map { trayPaddedID($0, bytes) }
                if stretchFirst != 0 { ids[0] = trayPaddedID(0, bytes + stretchFirst) }
                return Set(ids)
            }
            func traySelectionMap(count: Int, valueBytes: Int, padExact: Bool) -> [String: String] {
                var map = Dictionary(uniqueKeysWithValues: (0 ..< count).map {
                    ("c\($0)", String(repeating: "x", count: valueBytes))
                })
                guard padExact else { return map }
                map["final"] = "x"
                let seed = try! JSONSerialization.data(withJSONObject: map, options: [.sortedKeys]).count
                map["final"] = String(repeating: "x", count: 1 + ClientTray.maxSelectionRawBytes - seed)
                return map
            }

            let enabledExact = ClientTray.canonicalEnabledRaw(
                trayEnabledIDs(64, 127, stretchFirst: 1))!
            let selMap = traySelectionMap(
                count: 15, valueBytes: ClientTray.maxCardIDBytes, padExact: true)
            let selExact = ClientTray.canonicalSelectionsRaw(selMap)!
            var selOver = selMap
            selOver["overflow"] = String(repeating: "x", count: ClientTray.maxCardIDBytes)
            let oversizedEnabled = String(repeating: "a,", count: ClientTray.maxEnabledRawBytes)
            let overEntrySel = String(data: try! JSONSerialization.data(
                withJSONObject: Dictionary(uniqueKeysWithValues: (0 ... ClientTray.maxEntries).map {
                    ("c\($0)", "card\($0)")
                }), options: [.sortedKeys]), encoding: .utf8)!
            let delim = "{\"claude\":\"model.gpt|preview.v1\",\"codex\":\"weekly.v1\"}"

            expect(ClientTray.enabled(defaults: clientDefaults).isEmpty, "enabled codec: defaults off")
            for (name, raw, want) in [
                ("deterministic sorted CSV", ClientTray.canonicalEnabledRaw(["codex", "claude"]), Optional("claude,codex")),
                ("refuses one-over exact-byte set", ClientTray.canonicalEnabledRaw(trayEnabledIDs(65, 128)), nil),
                ("refuses over-entry set", ClientTray.canonicalEnabledRaw(Set((0 ... ClientTray.maxEntries).map { "c\($0)" })), nil),
            ] as [(String, String?, String?)] {
                expect(raw == want, "enabled codec serialize: \(name)")
            }
            expect(
                enabledExact.utf8.count == ClientTray.maxEnabledRawBytes
                    && ClientTray.parseEnabledRaw(enabledExact).count == 64,
                "enabled codec parse: exact raw-byte boundary")
            expect(
                selExact.utf8.count == ClientTray.maxSelectionRawBytes
                    && ClientTray.parseSelectionsRaw(selExact).count == 16
                    && ClientTray.canonicalSelectionsRaw(selOver) == nil,
                "selection codec parse: exact raw-byte boundary; serialize refuses oversized valid map")
            expect(
                ClientTray.selectionsRaw(
                    updating: "{\"codex\":\"weekly.v1\"}", clientId: "claude",
                    selection: "model.gpt|preview.v1") == delim,
                "selection codec serialize: deterministic sorted JSON")
            clientDefaults.set(delim, forKey: ClientTray.selectionsKey)
            expect(
                ClientTray.selections(defaults: clientDefaults)["claude"] == "model.gpt|preview.v1",
                "selection codec parse: preserves card delimiters")
            for (name, stored, parsed, write, id, on) in [
                ("one extra byte fails closed", enabledExact + "a", Set<String>(), nil, "claude", true),
                ("oversized input fails closed", oversizedEnabled, [], nil, "claude", true),
                ("AppStorage enable", "claude", ["claude"], Optional("claude,codex"), "codex", true),
                ("AppStorage disable", "claude,codex", ["claude", "codex"], Optional("claude"), "codex", false),
            ] as [(String, String, Set<String>, String?, String, Bool)] {
                clientDefaults.set(stored, forKey: ClientTray.enabledKey)
                expect(ClientTray.enabled(defaults: clientDefaults) == parsed, "enabled codec parse: \(name)")
                expect(
                    ClientTray.enabledRaw(updating: stored, clientId: id, enabled: on) == write,
                    "enabled codec write-back: \(name)")
            }
            for (name, stored, parsed, write, id, sel) in [
                ("one extra byte fails closed", selExact + " ", [String: String](), nil, "claude", "auto"),
                ("AppStorage write-back", "{}", [:], Optional("{\"codex\":\"weekly.v1\"}"), "codex", "weekly.v1"),
                ("over-entry root fails closed", overEntrySel, [:], nil, "claude", "auto"),
            ] as [(String, String, [String: String], String?, String, String)] {
                clientDefaults.set(stored, forKey: ClientTray.selectionsKey)
                expect(
                    ClientTray.selections(defaults: clientDefaults) == parsed,
                    "selection codec parse: \(name)")
                expect(
                    ClientTray.selectionsRaw(updating: stored, clientId: id, selection: sel) == write,
                    "selection codec write-back: \(name)")
            }
            clientDefaults.set(
                "{\"claude\":\"auto\",\"Codex\":\"bad\",\"codex\":42,\"unknown\":\"bounded\"}",
                forKey: ClientTray.selectionsKey)
            expect(
                ClientTray.selections(defaults: clientDefaults) == ["claude": "auto", "unknown": "bounded"],
                "selection codec parse: drops invalid entries, keeps bounded unknown ids")
            clientDefaults.set(42, forKey: ClientTray.selectionsKey)
            expect(
                ClientTray.selections(defaults: clientDefaults).isEmpty,
                "selection codec parse: non-string defaults fail closed")
        } else {
            expect(false, "isolated individual-tray defaults suite is available")
        }

        for (name, id, sel, card, remaining) in [
            ("Auto picks this client's tightest healthy window", "claude", ClientTray.autoSelection, Optional("session.v1"), Optional<Double>.none),
            ("Auto rejects an unhealthy snapshot", "grok", ClientTray.autoSelection, nil, nil),
            ("explicit selection may use a same-client error snapshot", "grok", "billing.weekly.v1", Optional("billing.weekly.v1"), Optional(1.0)),
            ("missing explicit cards never fall back across cards or clients", "codex", "missing.v1", nil, nil),
        ] as [(String, String, String, String?, Double?)] {
            let window = ClientTray.resolveWindow(payload: quotaPayload, clientId: id, selection: sel)
            expect(
                window?.cardId == card && (remaining == nil || window?.remainingPercent == remaining),
                "quota selection: \(name)")
        }
        expect(
            ClientTray.resolveWindow(
                payload: quotaPayload, clientId: "claude", selection: "weekly.v1")?.cardId != "missing.v1",
            "quota selection: missing explicit cards never fall back across cards or clients")
        expect(
            ClientTray.percentText(-2) == "0%" && ClientTray.percentText(101) == "100%"
                && ClientTray.percentText(.nan) == "—%" && ClientTray.percentText(nil) == "—%",
            "percent presentation: clamps finite values and fails closed")
        expect(
            ClientTray.quotaClientID(for: "antigravity-cli") == "antigravity"
                && ClientTray.processIdentity(for: "antigravity")
                    != ClientTray.processIdentity(for: "antigravity-cli")
                && ClientTray.autosaveName(for: "kilo")
                    != ClientTray.autosaveName(for: "kilocode"),
            "identity: quota lookup aliases stay disjoint from process and placement")

        enum TrayRouteAction {
            case activateClient(String), activateMain, recordView(String), switchClient(String)
        }
        func playRoutes(
            _ title: String, start: StatusItemRouteMemory.Route,
            steps: [(String, TrayRouteAction, StatusItemRouteMemory.Route?)]
        ) {
            let memory = StatusItemRouteMemory(mainClient: start.clientId, mainView: start.view)
            var cur = start
            for step in steps {
                switch step.1 {
                case .activateClient(let id):
                    cur = memory.activateClient(id, currentClient: cur.clientId, currentView: cur.view)
                case .activateMain:
                    cur = memory.activateMain(currentClient: cur.clientId, currentView: cur.view)
                case .recordView(let view):
                    memory.record(clientId: cur.clientId, view: view)
                    cur = .init(clientId: cur.clientId, view: view)
                case .switchClient(let id):
                    cur = memory.switchClient(from: cur.clientId, currentView: cur.view, to: id)
                }
                if let want = step.2 {
                    expect(cur == want, "route memory \(title): \(step.0)")
                }
            }
        }
        expect(ClientTray.activeViewKey == "tokenbar.view", "route memory: main view preference key")
        playRoutes(
            "disjoint lenses",
            start: .init(clientId: ClientTray.overviewTab, view: AppView.monthly.rawValue),
            steps: [
                ("first Claude opens Overview", .activateClient("claude"), .init(clientId: "claude", view: AppView.overview.rawValue)),
                ("record Claude models", .recordView(AppView.models.rawValue), nil),
                ("first Codex opens Overview", .activateClient("codex"), .init(clientId: "codex", view: AppView.overview.rawValue)),
                ("record Codex hourly", .recordView(AppView.hourly.rawValue), nil),
                ("Claude individual lens restored", .activateClient("claude"), .init(clientId: "claude", view: AppView.models.rawValue)),
                ("main restores its own monthly route", .activateMain, .init(clientId: ClientTray.overviewTab, view: AppView.monthly.rawValue)),
                ("main Codex tab ignores individual hourly lens", .switchClient("codex"), .init(clientId: "codex", view: AppView.overview.rawValue)),
                ("revisit Claude individual", .activateClient("claude"), nil),
                ("returning to main keeps Codex Overview", .activateMain, .init(clientId: "codex", view: AppView.overview.rawValue)),
            ])
        playRoutes(
            "persisted main lens",
            start: .init(clientId: "claude", view: AppView.models.rawValue),
            steps: [
                ("unvisited individual ignores persisted main lens", .activateClient("claude"), .init(clientId: "claude", view: AppView.overview.rawValue)),
                ("individual visit cannot clobber persisted main lens", .activateMain, .init(clientId: "claude", view: AppView.models.rawValue)),
            ])

        let auto = ClientTray.autoSelection
        for (name, present, enabled, hidden, sel, payload, status, value, showRuntime) in [
            ("error-only stays configurable", ["antigravity-cli"], Set<String>(), Set<String>(), [String: String](), quotaPayload as AgentUsagePayload?, ClientTray.Status.errorAuto, "—%", false),
            ("missing explicit stays represented", ["codex"], Set(["codex"]), Set<String>(), ["codex": "missing.v1"], quotaPayload, .missingSelection, "—%", true),
            ("hidden is Settings-only suppressed", ["codex"], Set(["codex"]), Set(["codex"]), ["codex": "weekly.v1"], quotaPayload, .suppressed, "35%", false),
            ("Auto error snapshot", ["grok"], Set(["grok"]), Set<String>(), ["grok": auto], quotaPayload, .errorAuto, "—%", true),
            ("explicit last-good error", ["grok"], Set(["grok"]), Set<String>(), ["grok": "billing.weekly.v1"], quotaPayload, .errorExplicit, "1%", true),
            ("missing payload keeps enabled row", ["codex"], Set(["codex"]), Set<String>(), [String: String](), nil, .unavailable, "—%", true),
        ] as [(String, [String], Set<String>, Set<String>, [String: String], AgentUsagePayload?, ClientTray.Status, String, Bool)] {
            let row = ClientTray.settingsRows(
                presentClients: present, payload: payload, enabled: enabled, selections: sel,
                hidden: hidden, orderRaw: "", officialClients: officialClientIDs).first
            expect(row?.status == status && row?.valueText == value, "tray status: \(name)")
            let items = ClientTray.runtimePresentations(
                graph: clientGraph, payload: payload, enabled: enabled, selections: sel,
                hidden: hidden, officialClients: officialClientIDs)
            if showRuntime {
                expect(items.first?.status == status && items.first?.valueText == value, "tray runtime: \(name)")
            } else {
                expect(items.isEmpty || items.first?.clientId != present.first, "tray runtime omits Settings-only row: \(name)")
            }
        }

        // #286 reaches this picker too. A provider that repeats a WHITELISTED
        // label — two windows both called `Weekly` — comes out of the card view
        // as `Weekly · Session` and `Weekly · Weekly`, and the sanitiser used to
        // accept any whitelisted PREFIX, collapsing both rows back to `Weekly`.
        // An exact match keeps the bare word and sends a qualified one to the
        // indexed fallback, which is distinct per row.
        let repeatedSafeJSON = """
        {"generatedAt":"t","publicationGeneration":7,"agents":[
          {"clientId":"codex","source":"oauth","updatedAt":"t","windows":[
            {"cardId":"a.v1","label":"Weekly","usedPercent":10,"remainingPercent":90,
             "windowMinutes":300,
             "paceStatus":{"state":"learningHistory","windowKey":"a.v1",
             "durationSeconds":18000,"durationSource":"provider","completeCycles":1}},
            {"cardId":"b.v1","label":"Weekly","usedPercent":20,"remainingPercent":80,
             "windowMinutes":10080,
             "paceStatus":{"state":"learningHistory","windowKey":"b.v1",
             "durationSeconds":604800,"durationSource":"provider","completeCycles":1}}
          ]}
        ]}
        """
        let repeatedSafePayload = try! JSONDecoder().decode(
            AgentUsagePayload.self, from: Data(repeatedSafeJSON.utf8))
        let repeatedSafeLabels = ClientTray.settingsRows(
            presentClients: ["codex"], payload: repeatedSafePayload, enabled: Set(["codex"]),
            selections: ["codex": "a.v1"], hidden: Set<String>(), orderRaw: "",
            officialClients: officialClientIDs
        ).first?.options.dropFirst().map(\.label) ?? []
        expect(
            repeatedSafePayload.agents[0].uniqueCardWindows.map(\.label)
                == ["Weekly · Session", "Weekly · Weekly"],
            "a repeated whitelisted label is qualified in the card view, so the "
                + "picker below is asked the question this guards")
        expect(
            repeatedSafeLabels.count == 2 && Set(repeatedSafeLabels).count == 2,
            "and the per-client window picker keeps the two rows distinguishable")

        for (phase, attempted, spinning, name) in [
            (DashboardModel.Phase.loading, false, true, "loading unsettled"),
            (.loading, true, true, "loading after quota"),
            (.ready, false, true, "ready unsettled"),
            (.ready, true, false, "ready settled"),
            (.failed("boom"), false, true, "failed unsettled"),
            (.failed("boom"), true, false, "failed settled"),
        ] as [(DashboardModel.Phase, Bool, Bool, String)] {
            expect(
                SettingsWindowView.isInitialLoad(phase: phase, agentUsageAttempted: attempted) == spinning,
                "individual-items spinner: \(name)")
        }
        expect(
            MainActor.assumeIsolated { DashboardModel(initialYear: nil).year == nil },
            "Settings can pin its client universe to the all-time graph")

        // The invariant is that the card never labels rows with a range they do
        // not cover. `invalidateModel()` drops the report the moment the slice
        // changes — deliberately, so a late in-flight scan cannot publish the
        // previous year's models — so on a failed switch there are no rows left
        // to mislabel and the subtitle falls back to the unscoped form. The two
        // successful switches are where the pairing is actually exercised.
        let dashboardYearKey = "tokenbar.dashboard.year"
        let savedDashboardYear = UserDefaults.standard.object(forKey: dashboardYearKey)
        let reportRangeSequence: [DashboardModelTestObservation] = awaitMainActorValue {
            let source = DashboardModelTestSource(failingGraphYear: "2022")
            let model = DashboardModel(source: source, initialYear: "2024")
            await model.load()
            // PR #187 took the model report off the critical path: `load()`
            // fetches the graph alone and a model-dependent lens asks for the
            // report when it appears. The Stats lens is where this card lives,
            // so that is the call that has to drive this sequence now.
            await model.ensureModelData(for: .stats)
            let initial = DashboardModelTestObservation(
                selectedYear: model.year,
                loadedYear: model.modelYear,
                loadedModel: model.modelReport?.entries.first?.model,
                loadedTokens: model.modelReport?.entries.first?.total,
                cardRangeLabel: UsageAttributionBreakdownCard.rangeLabel(
                    reportYear: model.modelYear))
            await model.setYear("2023")
            await model.ensureModelData(for: .stats)
            let successfulSwitch = DashboardModelTestObservation(
                selectedYear: model.year,
                loadedYear: model.modelYear,
                loadedModel: model.modelReport?.entries.first?.model,
                loadedTokens: model.modelReport?.entries.first?.total,
                cardRangeLabel: UsageAttributionBreakdownCard.rangeLabel(
                    reportYear: model.modelYear))
            await model.setYear("2022")
            await model.ensureModelData(for: .stats)
            let failedSwitch = DashboardModelTestObservation(
                selectedYear: model.year,
                loadedYear: model.modelYear,
                loadedModel: model.modelReport?.entries.first?.model,
                loadedTokens: model.modelReport?.entries.first?.total,
                cardRangeLabel: UsageAttributionBreakdownCard.rangeLabel(
                    reportYear: model.modelYear))
            return [initial, successfulSwitch, failedSwitch]
        } ?? []
        if let savedDashboardYear {
            UserDefaults.standard.set(savedDashboardYear, forKey: dashboardYearKey)
        } else {
            UserDefaults.standard.removeObject(forKey: dashboardYearKey)
        }
        expect(
            reportRangeSequence.count == 3
                && reportRangeSequence.map(\.selectedYear) == ["2024", "2023", "2022"]
                && reportRangeSequence.map(\.loadedYear) == ["2024", "2023", nil]
                && reportRangeSequence.map(\.loadedModel)
                    == ["loaded-2024", "loaded-2023", nil]
                && reportRangeSequence.map(\.loadedTokens) == [24, 23, nil]
                // Never "2022": the label always states the range the rows come
                // from, and with no rows it states no range at all.
                && reportRangeSequence.map(\.cardRangeLabel)
                    == ["2024", "2023", "All years"],
            "attribution card labels rows only with the range they come from |"
                + " selected=\(reportRangeSequence.map(\.selectedYear))"
                + " loaded=\(reportRangeSequence.map(\.loadedYear))"
                + " model=\(reportRangeSequence.map(\.loadedModel))"
                + " label=\(reportRangeSequence.map(\.cardRangeLabel))")

        // The card's figures change with BOTH the year and the client tab, so
        // naming only the year let a client subtotal read as an account-wide
        // breakdown. Overview passes nil rather than relying on a one-element
        // clientIds, which Overview can legitimately produce.
        expect(
            UsageAttributionBreakdownCard.subtitle(
                reportYear: "2026", singleClient: nil) == "2026"
                && UsageAttributionBreakdownCard.subtitle(
                    reportYear: "2026", singleClient: "claude")
                    == "2026 · \(ClientRegistry.shortName("claude"))"
                && UsageAttributionBreakdownCard.subtitle(
                    reportYear: nil, singleClient: "claude")
                    == "All years · \(ClientRegistry.shortName("claude"))"
                // Empty is the identity form's all-time marker, so it must read
                // the same as never having been scoped.
                && UsageAttributionBreakdownCard.subtitle(
                    reportYear: "", singleClient: nil) == "All years",
            "attribution card subtitle names the client scope, not only the year")

        // Browsing a client inside the MAIN popover must not decide what that
        // client's own item opens on.
        let mainBrowsingMemory = StatusItemRouteMemory(
            mainClient: ClientTray.overviewTab, mainView: AppView.overview.rawValue)
        _ = mainBrowsingMemory.switchClient(
            from: ClientTray.overviewTab, currentView: AppView.overview.rawValue,
            to: "claude")
        mainBrowsingMemory.record(clientId: "claude", view: AppView.models.rawValue)
        expect(
            mainBrowsingMemory.activateClient(
                "claude", currentClient: "claude", currentView: AppView.models.rawValue
            ) == .init(clientId: "claude", view: AppView.overview.rawValue),
            "main-popover browsing never seeds an individual item's lens")

        let errorOnlyRows = ClientTray.settingsRows(
            presentClients: ["antigravity-cli"], payload: quotaPayload,
            enabled: [], selections: [:], hidden: [], orderRaw: "",
            officialClients: officialClientIDs)
        expect(
            errorOnlyRows.count == 1
                && errorOnlyRows[0].clientId == "antigravity-cli"
                && errorOnlyRows[0].status == .errorAuto
                && errorOnlyRows[0].valueText == "—%"
                && errorOnlyRows[0].options.map(\.tag) == [ClientTray.autoSelection],
            "error-only quota providers remain configurable while windows are unavailable")

        let normalRows = ClientTray.settingsRows(
            presentClients: ["codex", "claude"], payload: quotaPayload,
            enabled: ["codex"], selections: ["codex": "missing.v1"], hidden: [],
            orderRaw: "claude,codex", officialClients: officialClientIDs)
        expect(
            normalRows.map(\.clientId) == ["claude", "codex"],
            "Settings rows follow the existing client tab order")
        let missingRow = normalRows.first { $0.clientId == "codex" }
        expect(
            missingRow?.status == .missingSelection
                && missingRow?.options.last?.label == "Unavailable selection"
                && missingRow?.options.last?.tag == "missing.v1"
                && missingRow?.options.last?.isEnabled == false
                && missingRow?.valueText == "—%",
            "explicitly missing selection stays selected but unavailable")
        let hiddenRows = ClientTray.settingsRows(
            presentClients: ["codex"], payload: quotaPayload,
            enabled: ["codex"], selections: ["codex": "weekly.v1"], hidden: ["codex"],
            orderRaw: "", officialClients: officialClientIDs)
        expect(
            hiddenRows.first?.status == .suppressed && hiddenRows.first?.isEnabled == true,
            "hidden tabs preserve Settings enablement and selection")
        let errorAutoRow = ClientTray.settingsRows(
            presentClients: ["grok"], payload: quotaPayload,
            enabled: ["grok"], selections: ["grok": ClientTray.autoSelection], hidden: [],
            orderRaw: "", officialClients: officialClientIDs).first
        let errorExplicitRow = ClientTray.settingsRows(
            presentClients: ["grok"], payload: quotaPayload,
            enabled: ["grok"], selections: ["grok": "billing.weekly.v1"], hidden: [],
            orderRaw: "", officialClients: officialClientIDs).first
        expect(
            errorAutoRow?.status == .errorAuto && errorAutoRow?.valueText == "—%"
                && errorExplicitRow?.status == .errorExplicit
                && errorExplicitRow?.valueText == "1%",
            "error snapshots distinguish Auto from explicit fallback")
        expect(
            ClientTray.settingsRows(
                presentClients: ["codex"], payload: nil, enabled: ["codex"], selections: [:],
                hidden: [], orderRaw: "", officialClients: officialClientIDs).first?.status == .unavailable,
            "enabled rows survive a temporarily missing payload")
        let absentExplicitRow = ClientTray.settingsRows(
            presentClients: ["codex"], payload: nil, enabled: ["codex"],
            selections: ["codex": "missing.v1"], hidden: [], orderRaw: "",
            officialClients: officialClientIDs).first
        expect(
            absentExplicitRow?.status == .missingSelection
                && absentExplicitRow?.options.last?.label == "Unavailable selection"
                && absentExplicitRow?.options.last?.tag == "missing.v1",
            "missing payload keeps an explicit selection represented without exposing its id")
        expect(
            ClientTray.settingsRows(
                presentClients: ["claude"], payload: quotaPayload, enabled: ["codex"], selections: [:],
                hidden: [], orderRaw: "", officialClients: officialClientIDs).map(\.clientId) == ["claude"],
            "disabled clients disappear when no longer present while capable rows remain")
        expect(
            ClientTray.settingsRows(
                presentClients: [], payload: nil, enabled: [], selections: [:], hidden: [],
                orderRaw: "", officialClients: officialClientIDs).isEmpty,
            "Settings uses a fixed empty state when no rows are eligible")
        let runtimePresentations = ClientTray.runtimePresentations(
            graph: clientGraph, payload: quotaPayload, enabled: ["claude", "codex"],
            selections: ["codex": "weekly.v1"], hidden: ["claude"],
            officialClients: officialClientIDs)
        expect(
            runtimePresentations.map(\.clientId) == ["codex"]
                && runtimePresentations.first?.valueText == "35%",
            "runtime shells use graph presence, enabled state, official assets, and hidden tabs")
        let lastGoodRuntime = ClientTray.runtimePresentations(
            graph: clientGraph, payload: quotaPayload, enabled: ["grok"],
            selections: ["grok": "billing.weekly.v1"], hidden: [],
            officialClients: officialClientIDs).first
        expect(
            lastGoodRuntime?.status == .errorExplicit
                && lastGoodRuntime?.valueText == "1%"
                && lastGoodRuntime?.toolTip.contains("last known") == true
                && lastGoodRuntime?.accessibilityLabel.contains("last known") == true
                && lastGoodRuntime?.toolTip.contains("timed out") == false,
            "explicit error fallback is labeled as last-known quota, not current data")

        // Rows must not depend on Set iteration order. With no saved tab order
        // and no payload, every row comes from the preserved-enabled path, which
        // must follow the ordered `present` array.
        expect(
            ClientTray.settingsRows(
                presentClients: ["codex", "claude", "grok"], payload: nil,
                enabled: ["grok", "claude", "codex"], selections: [:], hidden: [],
                orderRaw: "", officialClients: officialClientIDs
            ).map(\.clientId) == ["codex", "claude", "grok"],
            "preserved enabled rows follow graph order, not enabled-set hash order")

        // A vanished explicit card is reported as a missing selection on the item
        // itself, not as a generic provider outage — the user has to change the
        // saved window, and waiting will not fix it. The raw card ID stays hidden.
        let missingRuntime = ClientTray.runtimePresentations(
            graph: clientGraph, payload: quotaPayload, enabled: ["codex"],
            selections: ["codex": "missing.v1"], hidden: [],
            officialClients: officialClientIDs).first
        expect(
            missingRuntime?.status == .missingSelection
                && missingRuntime?.valueText == "—%"
                && missingRuntime?.toolTip.contains("missing.v1") == false
                && missingRuntime?.accessibilityLabel.contains("missing.v1") == false
                && missingRuntime?.toolTip != ClientTray.runtimePresentations(
                    graph: clientGraph, payload: nil, enabled: ["codex"],
                    selections: [:], hidden: [],
                    officialClients: officialClientIDs).first?.toolTip,
            "a missing explicit card reads as an unavailable selection, not a provider outage")

        let sensitiveQuotaJSON = """
        {"generatedAt":"now","agents":[
          {"clientId":"codex","source":"SECRET_SOURCE","updatedAt":"now",
           "identity":{"email":"SECRET_IDENTITY","plan":"SECRET_PLAN"},
           "windows":[{"cardId":"SECRET_CARD","label":"SECRET_LABEL","usedPercent":1,"remainingPercent":99}],
           "error":"SECRET_ERROR"}
        ]}
        """
        let sensitiveQuota = try! JSONDecoder().decode(
            AgentUsagePayload.self, from: Data(sensitiveQuotaJSON.utf8))
        let sensitiveRow = ClientTray.settingsRows(
            presentClients: ["codex"], payload: sensitiveQuota, enabled: ["codex"],
            selections: ["codex": "SECRET_CARD"], hidden: [], orderRaw: "",
            officialClients: officialClientIDs).first!
        let sensitiveRuntime = ClientTray.runtimePresentations(
            graph: clientGraph, payload: sensitiveQuota, enabled: ["codex"],
            selections: ["codex": "SECRET_CARD"], hidden: [],
            officialClients: officialClientIDs).first!
        let sensitiveVisibleText = ([
            sensitiveRow.displayName,
            sensitiveRow.valueText,
            sensitiveRow.statusHint ?? "",
            sensitiveRow.accessibilityLabel,
        ] + sensitiveRow.options.filter(\.isEnabled).map(\.label)).joined(separator: "|")
        let sensitiveRuntimeText = [
            sensitiveRuntime.valueText,
            sensitiveRuntime.toolTip,
            sensitiveRuntime.accessibilityLabel,
        ].joined(separator: "|")
        expect(
            !sensitiveVisibleText.contains("SECRET_")
                && !sensitiveRuntimeText.contains("SECRET_"),
            "client Settings and status surfaces redact provider and card input")

        func transportPayload(_ body: String) -> AgentUsagePayload? {
            do {
                return try JSONDecoder().decode(
                    AgentUsagePayload.self,
                    from: Data("{\"generatedAt\":\"now\",\"agents\":[{\(body)}]}".utf8))
            } catch {
                return nil
            }
        }
        func transportEntries(_ body: String) -> [AgentUsageTransportLogEntry]? {
            transportPayload(body).map(agentUsageTransportLogEntries)
        }
        let transportBase = #""clientId":"codex","source":"fixture","updatedAt":"now","windows":[]"#
        expect(
            transportEntries(transportBase + #","error":"SECRET_ERROR""#)?.isEmpty == true,
            "transport diagnostics absent from sensitive error yields no candidates")
        let validTransport = transportEntries(
            transportBase + #","transportDiagnostic":{"category":"serverError","status":504,"osCode":-9806}"#)
        expect(
            validTransport?.count == 1 && validTransport?.first?.clientId == "codex"
                && validTransport?.first?.category == "serverError"
                && validTransport?.first?.status == 504 && validTransport?.first?.osCode == nil,
            "server-error diagnostic keeps status but drops osCode")
        let validRateLimited = transportEntries(
            transportBase + #","transportDiagnostic":{"category":"rateLimited","status":429,"osCode":-1}"#)
        expect(
            validRateLimited?.count == 1 && validRateLimited?.first?.status == 429
                && validRateLimited?.first?.osCode == nil,
            "rate-limit diagnostic accepts only status 429 without osCode")
        let contradictoryHTTP = transportEntries(
            transportBase + #","transportDiagnostic":{"category":"rateLimited","status":500,"osCode":-1}"#)
        let contradictoryServer = transportEntries(
            transportBase + #","transportDiagnostic":{"category":"serverError","status":429,"osCode":-1}"#)
        expect(
            contradictoryHTTP?.count == 1 && contradictoryHTTP?.first?.status == nil
                && contradictoryHTTP?.first?.osCode == nil
                && contradictoryServer?.count == 1 && contradictoryServer?.first?.status == nil
                && contradictoryServer?.first?.osCode == nil,
            "contradictory HTTP diagnostics keep category only")
        let crossFieldTransport = transportEntries(
            transportBase + #","transportDiagnostic":{"category":"timeout","status":504,"osCode":-9806}"#)
        expect(
            crossFieldTransport?.count == 1 && crossFieldTransport?.first?.status == nil
                && crossFieldTransport?.first?.osCode == -9806,
            "transport diagnostic rejects status on timeout but keeps osCode")
        let unknownTransport = transportEntries(
            transportBase.replacingOccurrences(of: "codex", with: "future-client") + #","transportDiagnostic":{"category":"futureCategory","status":200,"osCode":7}"#)
        expect(
            unknownTransport?.first?.clientId == "unknown"
                && unknownTransport?.first?.category == "unknown"
                && unknownTransport?.first?.status == nil
                && unknownTransport?.first?.osCode == nil,
            "unknown transport tuples drop associated numerics")
        let malformedTransportBodies = [
            transportBase + #","transportDiagnostic":"not-an-object""#,
            transportBase + #","transportDiagnostic":{"status":500}"#,
            transportBase + #","transportDiagnostic":{"category":42}"#,
        ]
        expect(
            malformedTransportBodies.allSatisfy { body in
                transportEntries(body)?.isEmpty == true
            },
            "malformed transport diagnostics decode with no candidates")
        let invalidNumeric = transportEntries(
            transportBase + #","transportDiagnostic":{"category":"dns","status":99,"osCode":2147483648}"#)
        expect(
            invalidNumeric?.count == 1 && invalidNumeric?.first?.status == nil
                && invalidNumeric?.first?.osCode == nil,
            "invalid transport numeric fields are retained as nil")
        let malformedOptionalInteger = transportEntries(
            transportBase + #","transportDiagnostic":{"category":"dns","status":"SECRET","osCode":7}"#)
        expect(
            malformedOptionalInteger?.count == 1
                && malformedOptionalInteger?.first?.category == "dns"
                && malformedOptionalInteger?.first?.status == nil
                && malformedOptionalInteger?.first?.osCode == 7,
            "malformed optional status drops only that field")
        let sensitiveTransport = transportEntries(
            #""clientId":"codex","source":"SECRET_SOURCE","updatedAt":"now","identity":{"email":"SECRET_IDENTITY","plan":"SECRET_PLAN"},"windows":[{"cardId":"SECRET_WINDOW","label":"SECRET_LABEL","usedPercent":1,"remainingPercent":99}],"error":"SECRET_ERROR","transportDiagnostic":{"category":"tls","status":502,"osCode":-1}"#)
        let sensitiveDescription = String(describing: sensitiveTransport ?? [])
        expect(
            !["SECRET_SOURCE", "SECRET_IDENTITY", "SECRET_PLAN", "SECRET_WINDOW",
              "SECRET_LABEL", "SECRET_ERROR"].contains { sensitiveDescription.contains($0) },
            "transport candidates exclude sensitive source identity window and error text")

        func failedBoundaryEvents(_ data: Data?) -> [AgentUsageBoundaryLogEvent]? {
            var events: [AgentUsageBoundaryLogEvent] = []
            do {
                _ = try TBCore.decodeAgentUsageBoundary(data) { events.append($0) }
                return nil
            } catch {
                return events
            }
        }
        let bridgeEvents = failedBoundaryEvents(Data(
            #"{"ok":false,"err":"SECRET_TOKEN https://example.invalid/?secret /private/credential"}"#.utf8))
        expect(
            bridgeEvents == [.bridgeFailed]
                && !String(describing: bridgeEvents).contains("SECRET_TOKEN"),
            "agent usage bridge failure logs only a fixed event")
        let decodeEvents = failedBoundaryEvents(Data(
            #"{"ok":true,"data":{"generatedAt":"SECRET_DECODE","agents":"not-an-array"}}"#.utf8))
        expect(
            decodeEvents == [.decodeFailed]
                && !String(describing: decodeEvents).contains("SECRET_DECODE"),
            "agent usage decode failure logs only a fixed event")
        expect(
            failedBoundaryEvents(Data(#"{"ok":true,"data":null}"#.utf8)) == [.decodeFailed],
            "agent usage successful envelope without data is a decode failure")
        expect(
            failedBoundaryEvents(Data(#"{not json"#.utf8)) == [.decodeFailed],
            "agent usage malformed envelope is a decode failure")
        expect(
            failedBoundaryEvents(nil) == [.returnedNull],
            "agent usage null pointer logs only a fixed event")

        var quotaApplyEvents: [String] = []
        MainActor.assumeIsolated {
            TrayAnimator.applyQuotaPayload(
                quotaPayload,
                store: { _ in quotaApplyEvents.append("store") },
                reconcile: { _ in quotaApplyEvents.append("reconcile") },
                persistSelection: { _ in quotaApplyEvents.append("persist") },
                render: { quotaApplyEvents.append("render") },
                notify: { quotaApplyEvents.append("notify") })
        }
        expect(
            quotaApplyEvents == ["store", "reconcile", "persist", "render", "notify"],
            "quota payload applies scalar state before render and notification")

        let suiteName = "TokenBar.SelfTest.PT0.\(UUID().uuidString)"
        if let defaults = UserDefaults(suiteName: suiteName) {
            let sentinelKey = "pt0.sentinel"
            defaults.set("keep", forKey: sentinelKey)
            let beforeFailure = defaults.persistentDomain(forName: suiteName)
            let failed = TrayAnimator.applyQuotaRemaining(
                payload: nil, persistedSelection: "codex|session.v1", excluding: [],
                cachedRemaining: 77, defaults: defaults)
            expect(
                failed == 77 && NSDictionary(dictionary: defaults.persistentDomain(forName: suiteName) ?? [:])
                    .isEqual(to: beforeFailure ?? [:]),
                "outer quota failure returns cached scalar without changing defaults")

            let fresh = TrayAnimator.applyQuotaRemaining(
                payload: quotaPayload, persistedSelection: "codex|session.v1", excluding: [],
                cachedRemaining: 77, defaults: defaults)
            expect(
                fresh == 80 && defaults.double(forKey: TrayAnimator.lastRemainingKey) == 80,
                "successful quota payload replaces cached scalar and defaults")

            let trayRaceRejected = MainActor.assumeIsolated { () -> Bool in
                let raceSuiteName = "TokenBar.SelfTest.PT0.Race.\(UUID().uuidString)"
                guard let raceDefaults = UserDefaults(suiteName: raceSuiteName) else { return false }
                defer { raceDefaults.removePersistentDomain(forName: raceSuiteName) }
                var remaining: Double? = fresh
                var generations: [UInt64?] = []
                for candidate in [publicationB, publicationA] {
                    TrayAnimator.applyQuotaPayload(
                        candidate,
                        store: { generations.append($0.publicationGeneration) },
                        reconcile: {
                            remaining = TrayAnimator.applyQuotaRemaining(
                                payload: $0,
                                persistedSelection: "codex|session.v1",
                                excluding: [],
                                cachedRemaining: remaining,
                                defaults: raceDefaults)
                        },
                        persistSelection: { _ in },
                        render: {},
                        notify: {})
                }
                return generations == [2, 2] && remaining == nil
                    && raceDefaults.object(forKey: TrayAnimator.lastRemainingKey) == nil
            }
            expect(
                trayRaceRejected,
                "late tray generation cannot revive a newer terminal scalar")

            let dashboardGeneration3 = settingsQuotaPayload(generation: 3, remaining: 80)
            let dashboardPublicationReachesTray = MainActor.assumeIsolated { () -> Bool in
                let dashboardSuiteName = "TokenBar.SelfTest.PT0.Dashboard.\(UUID().uuidString)"
                guard let dashboardDefaults = UserDefaults(suiteName: dashboardSuiteName) else {
                    return false
                }
                defer { dashboardDefaults.removePersistentDomain(forName: dashboardSuiteName) }
                let iconSignatureBefore = TrayAnimator.currentIconSignature(
                    defaults: dashboardDefaults)
                let resolved = AgentUsagePublicationCoordinator.resolve(dashboardGeneration3)
                let remaining = TrayAnimator.applyQuotaRemaining(
                    payload: resolved,
                    persistedSelection: "codex|session.v1",
                    excluding: [],
                    cachedRemaining: 20,
                    defaults: dashboardDefaults)
                let trayPayload = TrayAnimator.publishedQuota(publicationA)
                let iconSignatureAfter = TrayAnimator.currentIconSignature(
                    defaults: dashboardDefaults)
                return trayPayload?.publicationGeneration == 3
                    && trayPayload?.agents.first?.windows.first?.remainingPercent == 80
                    && remaining == 80
                    && dashboardDefaults.double(forKey: TrayAnimator.lastRemainingKey) == 80
                    && iconSignatureAfter != iconSignatureBefore
            }
            expect(
                dashboardPublicationReachesTray,
                "dashboard publication updates tray payload scalar and gauge invalidation")

            let unresolved = TrayAnimator.applyQuotaRemaining(
                payload: quotaPayload, persistedSelection: "missing|session.v1", excluding: [],
                cachedRemaining: fresh, defaults: defaults)
            let unresolvedRestarted = UserDefaults(suiteName: suiteName)
            let resumedAfterRestart = TrayAnimator.applyQuotaRemaining(
                payload: nil, persistedSelection: "missing|session.v1", excluding: [],
                cachedRemaining: unresolvedRestarted?.object(
                    forKey: TrayAnimator.lastRemainingKey) as? Double,
                defaults: unresolvedRestarted)
            expect(
                unresolved == nil && resumedAfterRestart == nil
                    && defaults.object(forKey: TrayAnimator.lastRemainingKey) == nil
                    && unresolvedRestarted?.object(forKey: TrayAnimator.lastRemainingKey) == nil,
                "same-generation unresolved selection clears scalar without restart revival")

            let replaced = TrayAnimator.applyQuotaRemaining(
                payload: quotaPayload, persistedSelection: "claude|session.v1", excluding: [],
                cachedRemaining: unresolved, defaults: defaults)
            expect(
                replaced == 12 && defaults.double(forKey: TrayAnimator.lastRemainingKey) == 12,
                "same-generation healthy selection replaces scalar")

            let hiddenAllAfterReplacement = TrayAnimator.applyQuotaRemaining(
                payload: quotaPayload, persistedSelection: QuotaResolver.auto,
                excluding: ["codex", "claude"], cachedRemaining: replaced, defaults: defaults)
            let hiddenAllRestarted = UserDefaults(suiteName: suiteName)
            expect(
                hiddenAllAfterReplacement == nil
                    && hiddenAllRestarted?.object(forKey: TrayAnimator.lastRemainingKey) == nil,
                "same-generation hidden-all clears replaced scalar across restart")

            let terminalPayload = try! JSONDecoder().decode(
                AgentUsagePayload.self,
                from: Data(#"{"generatedAt":"now","agents":[{"clientId":"codex","source":"oauth","updatedAt":"now","windows":[],"error":"Unauthorized"}]}"#.utf8))
            let terminalResult = TrayAnimator.applyQuotaRemaining(
                payload: terminalPayload, persistedSelection: QuotaResolver.auto, excluding: [],
                cachedRemaining: 80, defaults: defaults)
            let restarted = UserDefaults(suiteName: suiteName)
            expect(
                terminalResult == nil && defaults.object(forKey: TrayAnimator.lastRemainingKey) == nil
                    && restarted?.object(forKey: TrayAnimator.lastRemainingKey) == nil,
                "terminal empty provider payload clears scalar across restart")

            defaults.set(80, forKey: TrayAnimator.lastRemainingKey)
            let settingsTerminal = SettingsWindowView.applyQuotaRemaining(
                payload: terminalPayload,
                persistedSelection: QuotaResolver.auto,
                excluding: [],
                defaults: defaults)
            let settingsRestarted = UserDefaults(suiteName: suiteName)
            expect(
                settingsTerminal == nil
                    && defaults.object(forKey: TrayAnimator.lastRemainingKey) == nil
                    && settingsRestarted?.object(forKey: TrayAnimator.lastRemainingKey) == nil,
                "Settings terminal payload clears persisted scalar across restart")

            defaults.set(65, forKey: TrayAnimator.lastRemainingKey)
            let settingsBeforeFailure = defaults.persistentDomain(forName: suiteName)
            let settingsFailure = SettingsWindowView.applyQuotaRemaining(
                payload: nil,
                persistedSelection: QuotaResolver.auto,
                excluding: [],
                defaults: defaults)
            expect(
                settingsFailure == 65
                    && NSDictionary(dictionary: defaults.persistentDomain(forName: suiteName) ?? [:])
                        .isEqual(to: settingsBeforeFailure ?? [:]),
                "Settings outer quota failure preserves persisted scalar")

            let fallback = TrayAnimator.applyQuotaRemaining(
                payload: quotaPayload, persistedSelection: "grok|billing.weekly.v1", excluding: [],
                cachedRemaining: 80, defaults: defaults)
            expect(
                fallback == 1 && defaults.double(forKey: TrayAnimator.lastRemainingKey) == 1,
                "explicit selection keeps same-binding fallback window despite error")

            let errorOnlyPayload = try! JSONDecoder().decode(
                AgentUsagePayload.self,
                from: Data((#"{"generatedAt":"now","agents":[{"clientId":"grok","source":"oauth","updatedAt":"now","windows":[{"cardId":"billing.weekly.v1","label":"Weekly","usedPercent":99,"remainingPercent":1}],"error":"Grok request timed out.","transportDiagnostic":{"category":"timeout"}}]}"#).utf8))
            let autoError = TrayAnimator.applyQuotaRemaining(
                payload: errorOnlyPayload, persistedSelection: QuotaResolver.auto,
                excluding: [], cachedRemaining: 1, defaults: defaults)
            expect(
                autoError == nil && defaults.object(forKey: TrayAnimator.lastRemainingKey) == nil,
                "Auto excludes an error-only fallback payload and clears scalar")

            defaults.set(1, forKey: TrayAnimator.lastRemainingKey)
            let optionalAbsentPayload = try! JSONDecoder().decode(
                AgentUsagePayload.self,
                from: Data(#"{"generatedAt":"now","agents":[{"clientId":"codex","source":"oauth","updatedAt":"now","windows":[{"cardId":"session.v1","label":"Session","usedPercent":20,"remainingPercent":80}]}]}"#.utf8))
            let optionalAbsent = TrayAnimator.applyQuotaRemaining(
                payload: optionalAbsentPayload,
                persistedSelection: "grok|billing.weekly.v1",
                excluding: [], cachedRemaining: 1, defaults: defaults)
            expect(
                optionalAbsent == nil
                    && defaults.object(forKey: TrayAnimator.lastRemainingKey) == nil,
                "optional provider absence clears an explicit cached scalar")

            let standardBefore = UserDefaults.standard.persistentDomain(
                forName: Bundle.main.bundleIdentifier ?? "TokenBar")
            let demoFresh = TrayAnimator.applyQuotaRemaining(
                payload: quotaPayload, persistedSelection: "codex|session.v1", excluding: [],
                cachedRemaining: nil, defaults: nil)
            let standardAfter = UserDefaults.standard.persistentDomain(
                forName: Bundle.main.bundleIdentifier ?? "TokenBar")
            expect(
                demoFresh == 80 && NSDictionary(dictionary: standardBefore ?? [:])
                    .isEqual(to: standardAfter ?? [:]),
                "nil defaults returns fresh quota without touching live defaults")

            let hiddenAll = TrayAnimator.applyQuotaRemaining(
                payload: quotaPayload, persistedSelection: QuotaResolver.auto,
                excluding: ["codex", "claude"], cachedRemaining: 66, defaults: defaults)
            expect(
                hiddenAll == nil && defaults.object(forKey: TrayAnimator.lastRemainingKey) == nil,
                "all-hidden successful payload cannot fall back to cached scalar")
            defaults.removePersistentDomain(forName: suiteName)
        } else {
            expect(false, "isolated quota defaults suite is available")
        }

        let tightest = QuotaResolver.resolve(payload: quotaPayload, selection: "auto")
        expect(
            tightest?.clientId == "claude" && tightest?.window.cardId == "session.v1",
            "auto resolves the tightest healthy card")
        expect(
            QuotaResolver.selection(clientId: "codex", cardId: "weekly.v1") == "codex|weekly.v1",
            "canonical selection stores cardId")
        let delimiterSelection = QuotaResolver.selection(
            clientId: "codex", cardId: "model.gpt|preview.v1")
        expect(
            delimiterSelection == "codex|model.gpt|preview.v1"
                && QuotaResolver.canonicalSelection(
                    payload: quotaPayload, selection: delimiterSelection) == delimiterSelection
                && QuotaResolver.resolve(payload: quotaPayload, selection: delimiterSelection)?
                    .window.cardId == "model.gpt|preview.v1",
            "card selection preserves delimiters inside cardId")
        expect(
            QuotaResolver.canonicalSelection(payload: quotaPayload, selection: "codex|Weekly")
                == "codex|weekly.v1"
                && QuotaResolver.resolve(payload: quotaPayload, selection: "codex|Weekly")?
                    .window.cardId == "weekly.v1",
            "unique legacy label migrates to cardId")
        expect(
            QuotaSelectionPolicy.migrationToPersist(
                payload: quotaPayload, persistedSelection: "codex|Weekly") == "codex|weekly.v1"
                && QuotaSelectionPolicy.migrationToPersist(
                    payload: quotaPayload, persistedSelection: "codex|weekly.v1") == nil
                && QuotaSelectionPolicy.migrationToPersist(
                    payload: quotaPayload, persistedSelection: "codex|stale") == nil,
            "selection policy persists only a proven legacy migration")
        expect(
            QuotaResolver.canonicalSelection(payload: quotaPayload, selection: "codex|stale")
                == "codex|stale"
                && QuotaResolver.resolve(payload: quotaPayload, selection: "codex|stale") == nil,
            "temporarily absent explicit card stays selected instead of following Auto")
        expect(
            QuotaResolver.canonicalSelection(payload: quotaPayload, selection: "nope|Session")
                == "nope|Session"
                && QuotaResolver.resolve(payload: quotaPayload, selection: "nope|Session") == nil,
            "temporarily absent explicit client stays selected instead of following Auto")
        expect(
            QuotaResolver.canonicalSelection(payload: quotaPayload, selection: "codex|Weekly|extra")
                == "codex|Weekly|extra"
                && QuotaResolver.resolve(
                    payload: quotaPayload, selection: "codex|Weekly|extra") == nil,
            "unmatched explicit selection preserves delimiter characters")
        expect(
            QuotaResolver.canonicalSelection(payload: nil, selection: "future|legacy-card.v1")
                == "future|legacy-card.v1"
                && QuotaResolver.canonicalSelection(payload: nil, selection: "future|legacy|extra")
                    == "future|legacy|extra",
            "payload nil preserves explicit selection delimiters")
        expect(
            QuotaResolver.canonicalSelection(payload: quotaPayload, selection: "future")
                == QuotaResolver.auto
                && QuotaResolver.canonicalSelection(payload: quotaPayload, selection: "|card")
                    == QuotaResolver.auto
                && QuotaResolver.canonicalSelection(payload: quotaPayload, selection: "future|")
                    == QuotaResolver.auto,
            "structurally malformed selections normalize to Auto")
        expect(QuotaResolver.resolve(payload: nil, selection: "auto") == nil, "no payload, no quota")

        let duplicateJSON = """
        {"generatedAt":"now","agents":[
          {"clientId":"dupe","source":"fixture","updatedAt":"now",
           "windows":[
             {"cardId":"same.v1","label":"Ambiguous","usedPercent":20,"remainingPercent":80},
             {"cardId":"same.v1","label":"Ambiguous","usedPercent":99,"remainingPercent":1},
             {"cardId":"other.v1","label":"Ambiguous","usedPercent":70,"remainingPercent":30},
             {"cardId":"Session","label":"Other","usedPercent":90,"remainingPercent":10},
             {"cardId":"other-session.v1","label":"Session","usedPercent":75,"remainingPercent":25}
           ]}
        ]}
        """
        let duplicatePayload = try! JSONDecoder().decode(
            AgentUsagePayload.self, from: Data(duplicateJSON.utf8))
        let duplicateAgent = duplicatePayload.agents[0]
        expect(
            duplicateAgent.uniqueCardWindows.map(\.cardId)
                == ["same.v1", "other.v1", "Session", "other-session.v1"],
            "unique card view keeps first occurrence order")
        expect(
            duplicateAgent.uniqueCardWindows.allSatisfy { $0.cardId != "same.v1" || $0.remainingPercent == 80 }
                && duplicateAgent.uniqueCardWindows.count == 4,
            "duplicate card later occurrence fails closed")
        expect(
            QuotaResolver.canonicalSelection(payload: duplicatePayload, selection: "dupe|Ambiguous")
                == "dupe|Ambiguous",
            "ambiguous legacy label cannot be migrated")
        expect(
            QuotaResolver.resolve(payload: duplicatePayload, selection: "dupe|Ambiguous") == nil,
            "ambiguous legacy label stays explicit instead of following Auto")
        expect(
            QuotaResolver.resolve(payload: duplicatePayload, selection: "dupe|same.v1")?
                .window.remainingPercent == 80
                && QuotaResolver.resolve(payload: duplicatePayload, selection: "auto")?.window.cardId
                    == "Session",
            "duplicate card is not rendered or considered by Auto")
        expect(
            QuotaResolver.canonicalSelection(payload: duplicatePayload, selection: "dupe|Other")
                == "dupe|Session"
                && QuotaResolver.canonicalSelection(payload: duplicatePayload, selection: "dupe|Session")
                    == "dupe|Session",
            "exact cardId wins over same-named legacy label")

        // Issue #286: Codex names both windows of one additional limit after
        // the limit, so the 5-hour and the 7-day Spark allowance arrive with
        // the same label and different card IDs. The card view qualifies a
        // repeated label with the window's own duration; a label that appears
        // once, and the identities themselves, are untouched.
        let sparkJSON = """
        {"generatedAt":"now","agents":[
          {"clientId":"codex","source":"fixture","updatedAt":"now",
           "windows":[
             {"cardId":"additional.deadbeef.primary.v1","label":"Codex Spark",
              "usedPercent":0,"remainingPercent":100,"windowMinutes":300,
              "paceStatus":{"state":"learningHistory","windowKey":"additional.deadbeef.primary.v1",
              "durationSeconds":18000,"durationSource":"provider","completeCycles":3}},
             {"cardId":"additional.deadbeef.secondary.v1","label":"Codex Spark",
              "usedPercent":0,"remainingPercent":100,"windowMinutes":10080,
              "paceStatus":{"state":"learningHistory","windowKey":"additional.deadbeef.secondary.v1",
              "durationSeconds":604800,"durationSource":"provider","completeCycles":2}},
             {"cardId":"weekly.v1","label":"Weekly","usedPercent":40,"remainingPercent":60,
              "windowMinutes":10080,
              "paceStatus":{"state":"learningHistory","windowKey":"weekly.v1",
              "durationSeconds":604800,"durationSource":"contract","completeCycles":5}}
           ]}
        ]}
        """
        let sparkPayload = try! JSONDecoder().decode(
            AgentUsagePayload.self, from: Data(sparkJSON.utf8))
        let sparkWindows = sparkPayload.agents[0].uniqueCardWindows
        expect(
            sparkWindows.map(\.label) == ["Codex Spark · Session", "Codex Spark · Weekly", "Weekly"],
            "repeated window label is qualified by duration, a unique one is left alone")
        expect(
            sparkWindows.map(\.cardId) == [
                "additional.deadbeef.primary.v1", "additional.deadbeef.secondary.v1", "weekly.v1",
            ] && sparkWindows.compactMap(\.paceStatus.windowKey) == [
                "additional.deadbeef.primary.v1", "additional.deadbeef.secondary.v1", "weekly.v1",
            ] && sparkPayload.agents[0].windows.map(\.label)
                == ["Codex Spark", "Codex Spark", "Weekly"],
            "qualifying a label changes no identity and no wire value")
        expect(
            QuotaResolver.resolve(
                payload: sparkPayload,
                selection: "codex|additional.deadbeef.secondary.v1")?
                .window.durationSeconds == 604_800,
            "each qualified option still resolves to its own window")

        // Qualification must not break a tie the legacy-label migration exists
        // to refuse. Only one of these two same-labelled windows has duration
        // evidence — the sibling is still learning its own — so qualifying the
        // card view leaves exactly one window carrying the raw text, and a
        // persisted pre-v3 label that matched BOTH would migrate to whichever
        // window happened to lack a duration. Ambiguity is a fact about what
        // the provider sent, so the migration reads the raw labels.
        let mixedJSON = """
        {"generatedAt":"now","agents":[
          {"clientId":"codex","source":"fixture","updatedAt":"now",
           "windows":[
             {"cardId":"additional.deadbeef.primary.v1","label":"Codex Spark",
              "usedPercent":0,"remainingPercent":100,"windowMinutes":300,
              "paceStatus":{"state":"learningHistory","windowKey":"additional.deadbeef.primary.v1",
              "durationSeconds":18000,"durationSource":"provider","completeCycles":3}},
             {"cardId":"additional.deadbeef.secondary.v1","label":"Codex Spark",
              "usedPercent":0,"remainingPercent":100,
              "paceStatus":{"state":"learningDuration",
              "windowKey":"additional.deadbeef.secondary.v1",
              "durationSource":"observed","completeCycles":0}}
           ]}
        ]}
        """
        let mixedPayload = try! JSONDecoder().decode(
            AgentUsagePayload.self, from: Data(mixedJSON.utf8))
        expect(
            mixedPayload.agents[0].uniqueCardWindows.map(\.label)
                == ["Codex Spark · 1", "Codex Spark · 2"]
                && mixedPayload.agents[0].rawCardWindows.map(\.label)
                    == ["Codex Spark", "Codex Spark"],
            "a group with one length and one durationless sibling has no tier that "
                + "names both, so it falls to ordinals and the provider's own text "
                + "survives only in the raw view the migration reads")
        expect(
            QuotaResolver.canonicalSelection(
                payload: mixedPayload, selection: "codex|Codex Spark") == "codex|Codex Spark",
            "a persisted label that was ambiguous before qualification stays unmigrated")
        expect(
            QuotaResolver.resolve(payload: mixedPayload, selection: "codex|Codex Spark") == nil,
            "and it stays explicit rather than following Auto to one of the two")

        // The qualifier has to carry the remainder. Provider durations are not
        // whole hours by contract, and truncating to the largest unit rebuilds
        // the very ambiguity this change removes — one hour and ninety minutes
        // would both read `1h`. When two durations render the same anyway, the
        // pair is left as the provider labelled it rather than being given a
        // distinction the reader cannot act on.
        func sparkPair(_ first: Int64, _ second: Int64) -> [String] {
            let json = """
            {"generatedAt":"now","agents":[
              {"clientId":"codex","source":"fixture","updatedAt":"now",
               "windows":[
                 {"cardId":"a.v1","label":"Codex Spark","usedPercent":0,
                  "remainingPercent":100,"windowMinutes":\(first / 60),
                  "paceStatus":{"state":"learningHistory","windowKey":"a.v1",
                  "durationSeconds":\(first),"durationSource":"provider","completeCycles":1}},
                 {"cardId":"b.v1","label":"Codex Spark","usedPercent":0,
                  "remainingPercent":100,"windowMinutes":\(second / 60),
                  "paceStatus":{"state":"learningHistory","windowKey":"b.v1",
                  "durationSeconds":\(second),"durationSource":"provider","completeCycles":1}}
               ]}
            ]}
            """
            return try! JSONDecoder()
                .decode(AgentUsagePayload.self, from: Data(json.utf8))
                .agents[0].uniqueCardWindows.map(\.label)
        }
        expect(
            sparkPair(3_600, 5_400) == ["Codex Spark · 1h", "Codex Spark · 1h 30m"],
            "durations differing below the largest unit still produce different names")
        expect(
            sparkPair(18_000, 604_800) == ["Codex Spark · Session", "Codex Spark · Weekly"],
            "and the two lengths the engine already names take those same words")
        // Two windows of one period have no period to be told apart by, so the
        // length tier is refused and the reset tier is asked — these two carry
        // no reset either, so the ordinal is what remains. #286 requires a
        // unique name here, not the identical pair it was filed about.
        expect(
            sparkPair(90, 119) == ["Codex Spark · 1", "Codex Spark · 2"],
            "windows whose lengths render identically still get unique names")

        // A generated name must also avoid a label some OTHER window already
        // carries. Two durationless `Foo` windows beside one already called
        // `Foo · 1` used to produce `Foo · 1` twice: uniqueness inside the
        // repeated group says nothing about the rest of the card view.
        let collisionJSON = """
        {"generatedAt":"now","agents":[
          {"clientId":"codex","source":"fixture","updatedAt":"now",
           "windows":[
             {"cardId":"a.v1","label":"Foo","usedPercent":0,"remainingPercent":100},
             {"cardId":"b.v1","label":"Foo","usedPercent":0,"remainingPercent":100},
             {"cardId":"c.v1","label":"Foo · 1","usedPercent":0,"remainingPercent":100}
           ]}
        ]}
        """
        let collisionLabels = try! JSONDecoder()
            .decode(AgentUsagePayload.self, from: Data(collisionJSON.utf8))
            .agents[0].uniqueCardWindows.map(\.label)
        expect(
            Set(collisionLabels).count == 3 && collisionLabels.contains("Foo · 1"),
            "a generated name steps over a label another window already carries")

        // The state the issue was filed from, and the one this account is in:
        // Codex reports a window with no usage yet as
        // `unavailable(invalidEvidence)`, and `UsageWindow.unavailable` clears
        // the duration and `windowMinutes` with it, so BOTH rows arrive at
        // 100% remaining with no length at all. The reset each row already
        // displays is what separates them.
        let resetOnly: [String] = {
            let iso = ISO8601DateFormatter()
            let soon = iso.string(from: Date().addingTimeInterval(5 * 3_600))
            let later = iso.string(from: Date().addingTimeInterval(7 * 86_400))
            let json = """
            {"generatedAt":"now","agents":[
              {"clientId":"codex","source":"fixture","updatedAt":"now",
               "windows":[
                 {"cardId":"additional.deadbeef.primary.v1","label":"Codex Spark",
                  "usedPercent":0,"remainingPercent":100,"resetsAt":"\(soon)",
                  "paceStatus":{"state":"unavailable",
                  "windowKey":"additional.deadbeef.primary.v1",
                  "completeCycles":0,"reason":"invalidEvidence"}},
                 {"cardId":"additional.deadbeef.secondary.v1","label":"Codex Spark",
                  "usedPercent":0,"remainingPercent":100,"resetsAt":"\(later)",
                  "paceStatus":{"state":"unavailable",
                  "windowKey":"additional.deadbeef.secondary.v1",
                  "completeCycles":0,"reason":"invalidEvidence"}}
               ]}
            ]}
            """
            return try! JSONDecoder()
                .decode(AgentUsagePayload.self, from: Data(json.utf8))
                .agents[0].uniqueCardWindows.map(\.label)
        }()
        expect(
            resetOnly == ["Codex Spark · 5h", "Codex Spark · 7d"],
            "a pair the provider left without any duration is named by the resets "
                + "the rows already show")

        // And named under the countdown's rounding, not its own. The countdown
        // takes minutes UP while `durationText` alone rounds to the nearest, so
        // a reset one second inside five hours put `4h 59m` in the name beside
        // `Resets in 5h` in the same row, for the first half of every minute.
        let roundingIso = ISO8601DateFormatter()
        let nearlyFiveHours = Date().addingTimeInterval(5 * 3_600 - 1)
        let roundingJSON = """
        {"generatedAt":"now","agents":[
          {"clientId":"codex","source":"fixture","updatedAt":"now",
           "windows":[
             {"cardId":"a.v1","label":"Codex Spark","usedPercent":0,
              "remainingPercent":100,"resetsAt":"\(roundingIso.string(from: nearlyFiveHours))",
              "paceStatus":{"state":"unavailable","windowKey":"a.v1",
              "completeCycles":0,"reason":"invalidEvidence"}},
             {"cardId":"b.v1","label":"Codex Spark","usedPercent":0,
              "remainingPercent":100,
              "resetsAt":"\(roundingIso.string(from: Date().addingTimeInterval(7 * 86_400)))",
              "paceStatus":{"state":"unavailable","windowKey":"b.v1",
              "completeCycles":0,"reason":"invalidEvidence"}}
           ]}
        ]}
        """
        let roundingPayload = try! JSONDecoder().decode(
            AgentUsagePayload.self, from: Data(roundingJSON.utf8))
        let roundingWindow = roundingPayload.agents[0].uniqueCardWindows[0]
        expect(
            roundingWindow.label == "Codex Spark · 5h"
                && UsagePace.resetText(for: roundingWindow.resetsAt ?? "") == "Resets in 5h",
            "the qualifier and the countdown beside it round the same way")

        // Auto pick excludes hidden clients (issue #36): hiding the tightest
        // (claude|Session, 12%) makes auto fall to the next healthy card
        // (codex|Weekly, 35%); an EXPLICIT pick of a hidden client is honored;
        // empty exclusion is byte-identical to the default.
        let autoExClaude = QuotaResolver.resolve(
            payload: quotaPayload, selection: "auto", excluding: ["claude"])
        expect(autoExClaude?.clientId == "codex" && autoExClaude?.window.cardId == "weekly.v1",
            "auto skips a hidden tightest-window client")
        expect(
            QuotaResolver.resolve(
                payload: quotaPayload, selection: "claude|session.v1", excluding: ["claude"])?
                .window.remainingPercent == 12,
            "explicit selection of a hidden client still resolves")
        expect(
            QuotaResolver.resolve(payload: quotaPayload, selection: "auto", excluding: [])?
                .clientId == tightest?.clientId,
            "empty exclusion is byte-identical to the default auto pick")
        // Exclusion vs no-data disambiguation (issue #36 R8): resolve returning
        // nil because EVERY candidate is excluded is distinguishable from nil
        // for no payload / no healthy window, so the tray suppresses a stale
        // hidden cache only in the former.
        expect(
            QuotaResolver.excludedAllCandidates(
                payload: quotaPayload, selection: "auto", excluding: ["codex", "claude"]),
            "excludedAllCandidates true when the only healthy clients are all hidden")
        expect(
            !QuotaResolver.excludedAllCandidates(
                payload: quotaPayload, selection: "auto", excluding: ["claude"]),
            "excludedAllCandidates false while a visible candidate survives")
        expect(
            !QuotaResolver.excludedAllCandidates(
                payload: duplicatePayload, selection: "dupe|Ambiguous", excluding: ["dupe"]),
            "unresolved explicit selection does not acquire Auto exclusion semantics")
        expect(
            !QuotaResolver.excludedAllCandidates(payload: nil, selection: "auto", excluding: ["claude"]),
            "excludedAllCandidates false with no payload (fetch-failure keeps the cache)")
        expect(
            !QuotaResolver.excludedAllCandidates(
                payload: quotaPayload, selection: "claude|session.v1", excluding: ["claude"]),
            "excludedAllCandidates false for an explicit selection")
        expect(
            !QuotaResolver.excludedAllCandidates(payload: quotaPayload, selection: "auto", excluding: []),
            "excludedAllCandidates false for an empty exclusion")

        // Year picker visibility (issue #36): years in which only hidden clients
        // had activity drop from the picker. Fixture: vis active in 2025, hid
        // only in 2026 → hiding hid leaves {2025} visible.
        let yearJSON = """
        {"meta":{"generatedAt":"now","version":"1","dateRange":{"start":"2025-06-01","end":"2026-06-01"}},
         "summary":{"totalTokens":0,"totalCost":0,"totalDays":0,"activeDays":0,"averagePerDay":0,
                    "maxCostInSingleDay":0,"clients":["vis","hid"],"models":[]},
         "years":[],
         "contributions":[
           {"date":"2025-06-01","totals":{"tokens":10,"cost":1,"messages":1},"intensity":1,
            "tokenBreakdown":{"input":10,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0},
            "clients":[{"client":"vis","modelId":"m","providerId":"p","cost":1,"messages":1,
             "tokens":{"input":10,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0}}]},
           {"date":"2026-06-01","totals":{"tokens":10,"cost":1,"messages":1},"intensity":1,
            "tokenBreakdown":{"input":10,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0},
            "clients":[{"client":"hid","modelId":"m","providerId":"p","cost":1,"messages":1,
             "tokens":{"input":10,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0}}]}
         ]}
        """
        let yearPayload = try! JSONDecoder().decode(UsagePayload.self, from: Data(yearJSON.utf8))
        let visYears = UsageStats.yearsWithVisibleActivity(
            contributions: yearPayload.contributions, hidden: ["hid"])
        expect(visYears == ["2025"], "year picker drops a year only hidden clients used")
        expect(
            UsageStats.yearsWithVisibleActivity(contributions: yearPayload.contributions, hidden: [])
                == ["2025", "2026"],
            "no hidden clients keeps every active year")
        // Auto-clear a hidden-only scoped year (issue #36 R8): a year-scoped
        // payload whose only stripe is a hidden client signals needs-clear; any
        // visible stripe keeps it. (2026 in the fixture is hid-only.)
        let scoped2026 = yearPayload.contributions.filter { $0.date.hasPrefix("2026") }
        expect(!UsageStats.hasVisibleActivity(contributions: scoped2026, hidden: ["hid"]),
            "hidden-only scoped year has no visible activity (auto-clear)")
        expect(UsageStats.hasVisibleActivity(contributions: scoped2026, hidden: []),
            "a visible stripe keeps the scoped year")

        // Limits-card drag reorder: direction-aware insert (down → after the
        // target, up → before it) so single-step moves both work.
        let order = ["a", "b", "c", "d"]
        expect(AgentLimitsCard.reorder(order, from: "a", to: "b") == ["b", "a", "c", "d"], "reorder one step down")
        expect(AgentLimitsCard.reorder(order, from: "d", to: "c") == ["a", "b", "d", "c"], "reorder one step up")
        expect(AgentLimitsCard.reorder(order, from: "a", to: "d") == ["b", "c", "d", "a"], "reorder to the end")
        expect(AgentLimitsCard.reorder(order, from: "d", to: "a") == ["d", "a", "b", "c"], "reorder to the front")
        expect(AgentLimitsCard.reorder(order, from: "a", to: "a") == order, "reorder onto itself is a no-op")
        expect(AgentLimitsCard.reorder(order, from: "x", to: "b") == order, "reorder unknown id is a no-op")

        // mergeReorder: dragging within a visible SUBSET must not drop the
        // off-screen ids from the shared tab-order key. Non-visible ids keep
        // their exact slots; the visible slots refill in the new order.
        expect(
            ClientRegistry.mergeReorder(
                full: ["g", "a", "c", "x"], visible: ["c", "x"], from: "x", to: "c")
                == ["g", "a", "x", "c"],
            "mergeReorder keeps non-visible ids in place")
        // A visible id not yet in the saved order appends at the end.
        expect(
            ClientRegistry.mergeReorder(
                full: ["a"], visible: ["a", "z"], from: "a", to: "a")
                == ["a", "z"],
            "mergeReorder appends visible ids absent from full")
        // A no-op drag leaves the full order untouched.
        expect(
            ClientRegistry.mergeReorder(
                full: ["a", "b", "c"], visible: ["a", "b", "c"], from: "a", to: "a")
                == ["a", "b", "c"],
            "mergeReorder no-op leaves full order unchanged")
        // Empty saved order → just the reordered visible sequence.
        expect(
            ClientRegistry.mergeReorder(
                full: [], visible: ["a", "b"], from: "a", to: "b")
                == ["b", "a"],
            "mergeReorder with empty full writes the visible sequence")

        // A fresh order key still needs the hidden present-client slots before
        // the visible subset is merged. Otherwise re-enabling the hidden tab
        // would append it after every reordered visible tab.
        expect(
            ClientRegistry.mergeReorder(
                full: DashboardTabs.completeOrder(
                    [], present: ["claude", "codex", "gemini"]),
                visible: ["claude", "gemini"], from: "gemini", to: "claude")
                == ["gemini", "codex", "claude"],
            "top-tab reorder preserves an unsaved hidden client slot")

        // Top tab-bar drag reorder: the drop line sits on the edge the
        // direction-aware insert will use (right → after the target, left →
        // before it). Overview is not in `clients`, so it can never be a drop
        // target and no client can be dragged ahead of it.
        let tabIds = ["codex", "claude", "opencode"]
        expect(
            DashboardTabs.dropEdge(
                dragId: "codex", overId: "opencode", tabId: "opencode", in: tabIds) == .trailing,
            "dragging right marks the target's trailing edge")
        expect(
            DashboardTabs.dropEdge(
                dragId: "opencode", overId: "codex", tabId: "codex", in: tabIds) == .leading,
            "dragging left marks the target's leading edge")
        expect(
            DashboardTabs.dropEdge(
                dragId: "codex", overId: "claude", tabId: "opencode", in: tabIds) == nil,
            "only the hovered tab draws a drop line")
        expect(
            DashboardTabs.dropEdge(
                dragId: nil, overId: "claude", tabId: "claude", in: tabIds) == nil,
            "no drop line without an active drag")
        expect(
            DashboardTabs.dropEdge(
                dragId: "codex", overId: "overview", tabId: "overview", in: tabIds) == nil,
            "Overview is never a drop target")

        // knownLimitsClients (the hoisted universe): present clients with a
        // known limit, unioned with quota-snapshot holders (dedup, ordered).
        expect(
            ClientRegistry.knownLimitsClients(
                present: ["cursor", "claude"], quotaIds: ["antigravity"],
                placeholders: ["codex", "claude", "gemini"])
                == ["claude", "antigravity"],
            "knownLimitsClients drops no-limit present ids, keeps quota-only ids")

        // CSV id-set parse helper: empty string → empty set; commas split.
        expect(ClientRegistry.parseIdSet("").isEmpty, "parseIdSet empty string is empty")
        expect(
            ClientRegistry.parseIdSet("a,b,a") == Set(["a", "b"]),
            "parseIdSet splits and dedups")

        // Tray totals with hidden clients excluded (issue #35). Fixture: two
        // days, two clients (claude/codex), "today" = 2026-07-01. Client stripe
        // tokens = input+output+cacheRead+cacheWrite+reasoning.
        //   today  claude 150 tok $1.5 · codex 200 tok $2.0  (day totals 350/$3.5)
        //   06-01  claude 300 tok $3.0 · codex 400 tok $4.0  (day totals 700/$7.0)
        //   summary 1050 tok / $10.5
        let trayJSON = """
        {"meta":{"generatedAt":"now","version":"1","dateRange":{"start":"2026-06-01","end":"2026-07-01"}},
         "summary":{"totalTokens":1050,"totalCost":10.5,"totalDays":2,"activeDays":2,
                    "averagePerDay":5.25,"maxCostInSingleDay":7.0,"clients":["claude","codex"],"models":[]},
         "years":[],
         "contributions":[
           {"date":"2026-06-01","totals":{"tokens":700,"cost":7.0,"messages":2},"intensity":2,
            "tokenBreakdown":{"input":700,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0},
            "clients":[
              {"client":"claude","modelId":"m","providerId":"p","cost":3.0,"messages":1,
               "tokens":{"input":300,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0}},
              {"client":"codex","modelId":"m","providerId":"p","cost":4.0,"messages":1,
               "tokens":{"input":400,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0}}]},
           {"date":"2026-07-01","totals":{"tokens":350,"cost":3.5,"messages":2},"intensity":1,
            "tokenBreakdown":{"input":300,"output":50,"cacheRead":0,"cacheWrite":0,"reasoning":0},
            "clients":[
              {"client":"claude","modelId":"m","providerId":"p","cost":1.5,"messages":1,
               "tokens":{"input":100,"output":50,"cacheRead":0,"cacheWrite":0,"reasoning":0}},
              {"client":"codex","modelId":"m","providerId":"p","cost":2.0,"messages":1,
               "tokens":{"input":200,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0}}]}
         ]}
        """
        let trayPayload = try! JSONDecoder().decode(UsagePayload.self, from: Data(trayJSON.utf8))
        let today = "2026-07-01"
        // (a) Empty hidden set == unfiltered totals (byte-identical fast path).
        let unfiltered = trayPayload.trayTotals(hidden: [], today: today)
        expect(unfiltered.totalTokens == trayPayload.summary.totalTokens
            && unfiltered.totalCost == trayPayload.summary.totalCost,
            "tray empty-hidden totals equal summary")
        expect(unfiltered.todayTokens == 350 && unfiltered.todayCost == 3.5,
            "tray empty-hidden today equals contribution totals")
        // (b) Hiding one client subtracts exactly that client's stripes.
        let noCodex = trayPayload.trayTotals(hidden: ["codex"], today: today)
        expect(noCodex.totalTokens == unfiltered.totalTokens - 600
            && noCodex.totalCost == unfiltered.totalCost - 6.0,
            "tray hiding a client drops its total stripes")
        expect(noCodex.todayTokens == unfiltered.todayTokens - 200
            && noCodex.todayCost == unfiltered.todayCost - 2.0,
            "tray hiding a client drops its today stripes")
        // (c) All clients hidden -> zeros.
        let allHidden = trayPayload.trayTotals(hidden: ["claude", "codex"], today: today)
        expect(allHidden.totalTokens == 0 && allHidden.totalCost == 0
            && allHidden.todayTokens == 0 && allHidden.todayCost == 0,
            "tray all-hidden totals are zero")
        // Empty selection zeros the stats aggregate too (issue #36 Fix 2): the
        // lens views now filter strictly, so an all-hidden slice (clientIds=[])
        // shows nothing everywhere instead of leaking through an empty-allowlist
        // "show all" — consistent with DayBars/UsageStats' strict membership.
        let emptyStats = UsageStats(payload: trayPayload, selectedClients: [])
        expect(emptyStats.totalTokens == 0 && emptyStats.totalCost == 0 && emptyStats.activeDays == 0,
            "empty selection zeros the stats aggregate")

        // Saturating token folds (issue #36 Fix 4): corrupt Antigravity lanes
        // can be Int64.max-clamped by the Rust side; the Swift re-sums must
        // saturate, not trap, and stay byte-identical for normal values.
        expect(Int64.max.saturatingAdding(Int64.max) == .max, "saturating add clamps at Int64.max")
        expect(Int64.max.saturatingAdding(1) == .max, "saturating add caps a small overflow")
        expect(Int64.min.saturatingAdding(-1) == .min, "saturating add clamps at Int64.min")
        expect((100 as Int64).saturatingAdding(50) == 150, "saturating add is exact without overflow")
        let maxLanes = try! JSONDecoder().decode(
            TokenBreakdown.self,
            from: Data(#"{"input":9223372036854775807,"output":9223372036854775807,"cacheRead":0,"cacheWrite":0,"reasoning":0}"#.utf8))
        expect(maxLanes.total == .max, "TokenBreakdown.total saturates two Int64.max lanes")
        let normalLanes = try! JSONDecoder().decode(
            TokenBreakdown.self,
            from: Data(#"{"input":100,"output":50,"cacheRead":10,"cacheWrite":5,"reasoning":2}"#.utf8))
        expect(normalLanes.total == 167, "TokenBreakdown.total is exact for normal lanes")
        // UsageStats' day/total accumulators (the filtered Overview/Stats path)
        // must saturate too — a single Int64.max-clamped stripe folded with a
        // normal one renders a pinned total, never a trapping crash.
        let satJSON = """
        {"meta":{"generatedAt":"now","version":"1","dateRange":{"start":"2026-07-01","end":"2026-07-01"}},
         "summary":{"totalTokens":0,"totalCost":0,"totalDays":1,"activeDays":1,"averagePerDay":0,
                    "maxCostInSingleDay":0,"clients":["big","small"],"models":[]},
         "years":[],
         "contributions":[
           {"date":"2026-07-01","totals":{"tokens":0,"cost":2,"messages":2},"intensity":1,
            "tokenBreakdown":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0},
            "clients":[
              {"client":"big","modelId":"m","providerId":"p","cost":1,"messages":1,
               "tokens":{"input":9223372036854775807,"output":9223372036854775807,"cacheRead":0,"cacheWrite":0,"reasoning":0}},
              {"client":"small","modelId":"m","providerId":"p","cost":1,"messages":1,
               "tokens":{"input":100,"output":50,"cacheRead":0,"cacheWrite":0,"reasoning":0}}]}
         ]}
        """
        let satPayload = try! JSONDecoder().decode(UsagePayload.self, from: Data(satJSON.utf8))
        let satAll = UsageStats(payload: satPayload, selectedClients: ["big", "small"])
        expect(satAll.totalTokens == .max && satAll.perDayMap["2026-07-01"]?.tokens == .max
            && satAll.maxTokens == .max,
            "UsageStats saturates an Int64.max stripe instead of trapping")
        let satSmall = UsageStats(payload: satPayload, selectedClients: ["small"])
        expect(satSmall.totalTokens == 150 && satSmall.perDayMap["2026-07-01"]?.tokens == 150,
            "UsageStats is exact for normal stripes")

        // Monthly lens (plan 2026-07-15): month-level date formatter.
        expect(Format.monthYear("2026-07") == "Jul 2026", "monthYear formats YYYY-MM")
        expect(Format.monthYear("2025-12") == "Dec 2025", "monthYear formats December")
        expect(Format.monthYear("garbage") == "garbage", "monthYear passes malformed input through")
        expect(Format.monthYear("2026-13") == "2026-13", "monthYear rejects month 13")

        // Monthly lens bucketing (plan 2026-07-15): group by the FULL
        // "YYYY-MM" prefix (never month-of-year), strict client allowlist,
        // saturating folds, drill-down merges model slices across days.
        let monthlyJSON = """
        {"meta":{"generatedAt":"now","version":"1","dateRange":{"start":"2025-12-31","end":"2026-01-02"}},
         "summary":{"totalTokens":0,"totalCost":0,"totalDays":3,"activeDays":3,"averagePerDay":0,
                    "maxCostInSingleDay":0,"clients":["a","b"],"models":[]},
         "years":[],
         "contributions":[
           {"date":"2025-12-31","totals":{"tokens":0,"cost":1,"messages":1},"intensity":1,
            "tokenBreakdown":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0},
            "clients":[
              {"client":"a","modelId":"m1","providerId":"p","cost":1,"messages":1,
               "tokens":{"input":100,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0}}]},
           {"date":"2026-01-01","totals":{"tokens":0,"cost":3,"messages":2},"intensity":1,
            "tokenBreakdown":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0},
            "clients":[
              {"client":"a","modelId":"m1","providerId":"p","cost":1,"messages":1,
               "tokens":{"input":40,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0}},
              {"client":"b","modelId":"m9","providerId":"p","cost":2,"messages":1,
               "tokens":{"input":7,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0}}]},
           {"date":"2026-01-02","totals":{"tokens":0,"cost":1,"messages":1},"intensity":1,
            "tokenBreakdown":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0},
            "clients":[
              {"client":"a","modelId":"m1","providerId":"p","cost":1,"messages":1,
               "tokens":{"input":9223372036854775807,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0}}]}
         ]}
        """
        let monthlyPayload = try! JSONDecoder().decode(UsagePayload.self, from: Data(monthlyJSON.utf8))
        let mRows = MonthlyView.monthRows(payload: monthlyPayload, clientIds: ["a"])
        expect(mRows.count == 2 && mRows[0].month == "2026-01" && mRows[1].month == "2025-12",
            "monthly buckets split at the year boundary, most recent first")
        expect(mRows[1].tokens == 100 && mRows[1].messages == 1,
            "december totals only december")
        expect(mRows[0].tokens == .max,
            "monthly token fold saturates an Int64.max stripe")
        expect(mRows[0].cost == 2.0 && mRows[0].messages == 2,
            "hidden client b is excluded from january totals")
        expect(MonthlyView.monthRows(payload: monthlyPayload, clientIds: []).isEmpty,
            "empty client selection shows no months")
        let mSlices = MonthlyView.modelSlices(
            for: mRows[0], clientIds: ["a"], colors: ModelColorMap(report: nil))
        expect(
            mSlices.count == 1 && mSlices[0].key == "m1|p"
                && mSlices[0].tokens == .max && mSlices[0].input == .max
                && mSlices[0].output == 0,
            "drill-down merges the month's model token lanes across days with saturation")
        expect(MonthlyView.modelSlices(
                for: mRows[0], clientIds: ["a", "b"], colors: ModelColorMap(report: nil)).count == 2,
            "drill-down shows client b's model when b is selected")

        // Message-only activity (PR #54 review r3595383789): a contribution
        // with messages but zero tokens and zero cost must still surface —
        // some parsers emit message-count-only rows. Prior guard was
        // `tokens > 0 || cost > 0`, which dropped this month entirely.
        let messageOnlyJSON = """
        {"meta":{"generatedAt":"now","version":"1","dateRange":{"start":"2026-01-01","end":"2026-01-01"}},
         "summary":{"totalTokens":0,"totalCost":0,"totalDays":1,"activeDays":1,"averagePerDay":0,
                    "maxCostInSingleDay":0,"clients":["codex"],"models":[]},
         "years":[],
         "contributions":[
           {"date":"2026-01-01","totals":{"tokens":0,"cost":0,"messages":5},"intensity":0,
            "turnsByClient":{"codex":7},
            "tokenBreakdown":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0},
            "clients":[
              {"client":"codex","modelId":"m1","providerId":"p","cost":0,"messages":5,
               "tokens":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0}}]}
         ]}
        """
        let messageOnlyPayload = try! JSONDecoder().decode(UsagePayload.self, from: Data(messageOnlyJSON.utf8))
        let moRows = MonthlyView.monthRows(payload: messageOnlyPayload, clientIds: ["codex"])
        expect(moRows.count == 1 && moRows[0].messages == 5 && moRows[0].tokens == 0 && moRows[0].cost == 0,
            "a message-only month (zero tokens, zero cost) still surfaces in the Monthly lens")
        let monthlyMessageOnlySlice = moRows.first.flatMap {
            MonthlyView.modelSlices(
                for: $0, clientIds: ["codex"], colors: ModelColorMap(report: nil)
            ).first
        }
        expect(
            monthlyMessageOnlySlice?.key == "m1|p" && monthlyMessageOnlySlice?.tokens == 0
                && monthlyMessageOnlySlice?.cost == 0,
            "a message-only month retains its model drill-down")
        expect(
            UsageStats.hasVisibleActivity(
                contributions: messageOnlyPayload.contributions, hidden: []
            ) && UsageStats.yearsWithVisibleActivity(
                contributions: messageOnlyPayload.contributions, hidden: []
            ) == ["2026"],
            "message-only activity keeps its selected year visible")
        let messageOnlyStats = UsageStats(
            payload: messageOnlyPayload, selectedClients: ["codex"])
        expect(
            messageOnlyStats.activeDays == 1
                && messageOnlyStats.perDayMap["2026-01-01"]?.tokens == 0
                && messageOnlyStats.perDayMap["2026-01-01"]?.hasMessages == true
                && messageOnlyStats.totalTokens == 0 && messageOnlyStats.totalCost == 0,
            "shared usage stats count a selected message-only day as active")
        expect(
            UsageStats(payload: messageOnlyPayload, selectedClients: []).activeDays == 0,
            "shared usage stats do not count an unselected message-only day")

        // Daily/Monthly turn counts reuse the existing local-hour report, but
        // only after strict calendar-key validation and only for Codex/Claude.
        let turnReportJSON = """
        {"entries":[
          {"hour":"2025-12-31 23:00","clients":["codex"],"models":["m"],
           "input":0,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0,
           "total":0,"messageCount":0,"turnCount":2,"cost":0},
          {"hour":"2026-01-01 08:00","clients":["codex"],"models":["m"],
           "input":0,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0,
           "total":0,"messageCount":0,"turnCount":3,"cost":0},
          {"hour":"2026-01-01 09:00","clients":["claude"],"models":["m"],
           "input":0,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0,
           "total":0,"messageCount":0,"turnCount":4,"cost":0},
          {"hour":"2026-02-01 00:00","clients":["claude"],"models":["m"],
           "input":0,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0,
           "total":0,"messageCount":0,"turnCount":0,"cost":0},
          {"hour":"2026-02-30 00:00","clients":["codex"],"models":["m"],
           "input":0,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0,
           "total":0,"messageCount":0,"turnCount":99,"cost":0},
          {"hour":"not-an-hour","clients":["codex"],"models":["m"],
           "input":0,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0,
           "total":0,"messageCount":0,"turnCount":99,"cost":0}
        ],"totalCost":0}
        """
        let turnReport = try! JSONDecoder().decode(
            HourlyReport.self, from: Data(turnReportJSON.utf8))
        // `supportedTurnClients` decides which clients Daily/Monthly sum turns
        // for and which names the "Turns · X only" subtitle reports. Its only
        // coverage was removed with the hourly folds it happened to sit beside;
        // an unsupported client contributing nothing is now harmless, but
        // wrongly EXCLUDING codex or claude would silently undercount with no
        // test turning red.
        expect(
            PopoverView.supportedTurnClients(["gemini", "claude", "opencode", "codex"])
                == ["claude", "codex"],
            "the turn scope keeps only the supported clients, in the order given")
        expect(
            PopoverView.supportedTurnClients(["gemini", "opencode"]).isEmpty
                && PopoverView.supportedTurnClients([]).isEmpty,
            "a slice with no supported client yields an empty turn scope")
        expect(
            TurnCountBuckets.scope(["codex"]) == "Turns · Codex only"
                && TurnCountBuckets.scope([]) == nil,
            "the turn subtitle names the scope it actually summed")

        // LP2A — turns now ride the graph payload. What has to hold is that the
        // per-client map is respected exactly: a client outside the supported
        // turn set contributes nothing, and a hidden one is subtractable —
        // which is precisely what a single per-day total could not express.
        let turnsPayload = DemoData.payload(for: nil)
        let turnsDay = turnsPayload.contributions.first { ($0.turnsByClient ?? [:]).count > 1 }
        expect(
            turnsDay != nil,
            "the demo payload carries a per-client turn map (without this every "
                + "assertion below would pass on absent data)")
        if let turnsDay, let map = turnsDay.turnsByClient {
            let present = map.keys.sorted()
            let first = present[0]
            let both = turnsDay.turns(for: present)
            let single = turnsDay.turns(for: [first])
            let expectedTotal = present.reduce(Int64(0)) { $0 + (map[$1] ?? 0) }
            expect(
                both == expectedTotal && single == map[first],
                "a day's turns are the sum over exactly the requested clients")
            expect(
                turnsDay.turns(for: present.dropFirst().map { $0 })
                    == expectedTotal - (map[first] ?? 0),
                "dropping a client subtracts exactly its own turns — the reason the "
                    + "engine keys the map by client instead of emitting one daily total")
            expect(
                turnsDay.turns(for: ["not-a-client"]) == 0,
                "an unknown client contributes zero rather than falling back to a total")
            expect(
                turnsDay.turns(for: []) == nil,
                "an empty selection is 'nothing selected', not 'zero turns'")
        }
        // Monthly is the same map summed across the month's days.
        let monthlyTurnRows = MonthlyView.monthRows(
            payload: turnsPayload, clientIds: ClientRegistry.allIds,
            turnClientIds: ["codex", "claude"])
        let monthlyTurnsExpected: Int64 = turnsPayload.contributions.reduce(Int64(0)) {
            $0 + ($1.turns(for: ["codex", "claude"]) ?? 0)
        }
        expect(
            monthlyTurnRows.reduce(Int64(0)) { $0 + ($1.turns ?? 0) } == monthlyTurnsExpected,
            "the monthly rows sum each day's turns for the same client slice")

        let dailyMessageOnlyView = DailyView(
            payload: messageOnlyPayload, clientIds: ["codex"],
            turnClientIds: ["codex", "claude"], colors: ModelColorMap(report: nil)
        )
        let dailyMessageOnlyRows = dailyMessageOnlyView.rows
        expect(
            dailyMessageOnlyRows.count == 1 && dailyMessageOnlyRows[0].messages == 5
                && dailyMessageOnlyRows[0].tokens == 0 && dailyMessageOnlyRows[0].cost == 0
                && dailyMessageOnlyRows[0].turns == 7,
            "Daily retains a message-only day and attaches its positive turn count")
        let dailyMessageOnlySlice = dailyMessageOnlyRows.first.flatMap {
            dailyMessageOnlyView.models(for: $0.contribution).first
        }
        expect(
            dailyMessageOnlySlice?.key == "m1|p" && dailyMessageOnlySlice?.tokens == 0
                && dailyMessageOnlySlice?.cost == 0,
            "a message-only Daily row retains its model drill-down")

        let dashboardYearDefaultsKey = "tokenbar.dashboard.year"
        let savedAttributionDashboardYear = UserDefaults.standard.object(forKey: dashboardYearDefaultsKey)
        let turnTransitionChecks = awaitMainActorValue { () async -> [String: Bool] in
            let yearA = "2037"
            let yearB = "2038"
            let clients = ["codex", "claude"]

            // A superseded A request must not commit after the model moves to B.
            let staleSource = ControlledTurnUsageDataSource()
            let staleModel = DashboardModel(source: staleSource, initialYear: yearA)
            await staleModel.load()
            await staleSource.blockHourly(year: yearA)
            let staleTask = Task {
                await staleModel.ensureData(for: .hourly, clients: clients)
            }
            let stalePending = await waitUntil {
                await staleSource.hasPendingHourly(year: yearA)
            }
            await staleModel.setYear(yearB)
            await staleSource.releaseHourly(year: yearA)
            await staleTask.value
            let staleSuppressed = await staleModel.hourlyReport(for: clients) == nil
            await staleModel.ensureData(for: .hourly, clients: clients)
            let matchingBAfterStale = await staleModel.hourlyReport(for: clients) != nil

            // The inverse ordering is also fail-closed: B's hourly report may
            // arrive while graph A is still displayed, but remains hidden until
            // graph B commits.
            let inverseSource = ControlledTurnUsageDataSource()
            let inverseModel = DashboardModel(source: inverseSource, initialYear: yearA)
            await inverseModel.load()
            await inverseModel.ensureData(for: .hourly, clients: clients)
            let initialAVisible = await inverseModel.hourlyReport(for: clients) != nil
            await inverseSource.blockGraph(year: yearB)
            let switchTask = Task { await inverseModel.setYear(yearB) }
            let graphBPending = await waitUntil {
                await inverseSource.hasPendingGraph(year: yearB)
            }
            let oldReportSuppressed = await inverseModel.hourlyReport(for: clients) == nil
            await inverseModel.ensureData(for: .hourly, clients: clients)
            await inverseSource.releaseGraph(year: yearB)
            await switchTask.value
            let matchingBVisible = await inverseModel.hourlyReport(for: clients) != nil

            // The phantom-slice guard: `setYear` moves `year` synchronously
            // while the payload catches up only when reload commits, so the
            // model task can fire with a new year against the previous
            // payload. Scanning for that pairing issues a report the year
            // guard must then discard. Blocking the graph holds the model in
            // exactly that window.
            let phantomSource = ControlledTurnUsageDataSource()
            let phantomModel = DashboardModel(source: phantomSource, initialYear: yearA)
            await phantomModel.load()
            await phantomSource.blockGraph(year: yearB)
            let phantomSwitch = Task { await phantomModel.setYear(yearB) }
            _ = await waitUntil { await phantomSource.hasPendingGraph(year: yearB) }
            let phantomCallsBefore = await phantomSource.modelCallCount()
            await phantomModel.ensureModelData(for: .overview)
            let phantomIssuedNoScan =
                await phantomSource.modelCallCount() == phantomCallsBefore
            // Issuing nothing is only half of it. The cards distinguish
            // "loading" from "completed and found nothing" by this flag alone,
            // so leaving it down here made Models and Overview claim the new
            // year had no model usage for the whole graph reload.
            let phantomReadsAsLoading = await phantomModel.modelLoading
            await phantomSource.releaseGraph(year: yearB)
            await phantomSwitch.value

            // Codex P2 — reopening the popover must not put the model scan
            // back beside the graph. A restored snapshot makes the dashboard
            // renderable before `load()` fetches anything, so the model task
            // has a real key on its first body evaluation and fires at once.
            // The "no model scan until a payload commits" property therefore
            // held only for a first-ever open; a reopen whose snapshot carries
            // no current model report is the common case that broke it.
            let reopenYear = "2041"
            let reopenSource = ControlledTurnUsageDataSource()
            let reopenSeed = DashboardModel(
                cachesSnapshot: true, source: reopenSource, initialYear: reopenYear)
            await reopenSeed.load()
            // Seeded from a session that never opened a model lens, so the
            // snapshot carries a payload but no report.
            let seededWithoutModel = await reopenSource.modelCallCount() == 0
            await reopenSource.blockGraph(year: reopenYear)
            let reopened = DashboardModel(
                cachesSnapshot: true, source: reopenSource, initialYear: reopenYear)
            let reopenRestored = reopened.payload != nil && reopened.modelReport == nil
            let reopenLoad = Task { await reopened.load() }
            _ = await waitUntil { await reopenSource.hasPendingGraph(year: reopenYear) }
            let reopenLens = Task { await reopened.ensureModelData(for: .overview) }
            let reopenRaced = await waitUntil { await reopenSource.modelCallCount() > 0 }
            // Folds in the fixture's own health: without confirming the snapshot
            // really restored payload-without-model, "did not race" would also
            // hold on a reopen that never reached the gate at all.
            let reopenDidNotRace = seededWithoutModel && reopenRestored && !reopenRaced
            // Codex P2 — deferring the scan must not read as an answered
            // "none". The restored snapshot is already `.ready`, so the model
            // cards are on screen for the whole wait above; with the flag down
            // they render "No model usage in this range" for the length of a
            // cold scan, reporting a deferred read as a finished one.
            let reopenLoadingWhileDeferred = reopened.modelLoading
            await reopenSource.releaseGraph(year: reopenYear)
            await reopenLoad.value
            await reopenLens.value
            // Deferring must not mean dropping: the report still arrives.
            let reopenModelArrived = await reopened.modelReport != nil

            // Codex P2 — a manual refresh must share the same gate. Only the
            // initial load installed it, and the reasoning that excused refresh
            // ("the slice key cannot move while it runs, so no model task
            // fires") covered one trigger of two: the task is keyed on the LENS
            // as well as the slice, so opening Overview mid-refresh raises a
            // request with the key standing still.
            let refreshGateYear = "2042"
            let refreshGateSource = ControlledTurnUsageDataSource()
            let refreshGateModel = DashboardModel(
                source: refreshGateSource, initialYear: refreshGateYear)
            await refreshGateModel.load()
            // Control: the graph-only load leaves no report, so the lens below
            // has a real scan to issue rather than an idempotent no-op.
            let refreshGateCallsBefore = await refreshGateSource.modelCallCount()
            let refreshGateNeedsModel =
                refreshGateModel.modelReport == nil && refreshGateCallsBefore == 0
            await refreshGateSource.blockGraph(year: refreshGateYear)
            let refreshGateTask = Task { await refreshGateModel.refresh() }
            _ = await waitUntil { await refreshGateSource.hasPendingGraph(year: refreshGateYear) }
            let refreshGateLens = Task {
                await refreshGateModel.ensureModelData(for: .overview)
            }
            let refreshGateRaced = await waitUntil {
                await refreshGateSource.modelCallCount() > 0
            }
            // Folds in the fixture's own health: without confirming the refresh
            // really started with no model report, "did not race" would also
            // hold on a request that was never issued.
            let refreshGateDeferred = refreshGateNeedsModel && !refreshGateRaced
            await refreshGateSource.releaseGraph(year: refreshGateYear)
            await refreshGateTask.value
            await refreshGateLens.value
            let refreshGateRacingCalls = await refreshGateSource.modelCallsRacingGraph()
            let refreshGateModelArrived =
                refreshGateModel.modelReport != nil && refreshGateRacingCalls == 0

            // Codex P2 — the poll's retry restated the staleness rule and got
            // it wrong. A failure that lands while a LAST-GOOD report is
            // displayed keeps that report, so `modelReport == nil` was false
            // and the retry never fired: the cards sat on generation A's models
            // beside a chart that had moved to B, with no spinner and no error.
            // Every graph call here returns a new generation, so the refresh
            // genuinely moves the committed slice out from under the report.
            let staleGenSource = ControlledTurnUsageDataSource()
            await staleGenSource.advanceGraphGenerationPerCall()
            let staleGenModel = DashboardModel(source: staleGenSource, initialYear: nil)
            await staleGenModel.load()
            await staleGenModel.ensureModelData(for: .overview)
            let staleGenGenerationBefore = staleGenModel.payload?.meta.generatedAt
            let staleGenCallsBeforeRefresh = await staleGenSource.modelCallCount()
            await staleGenSource.failNextModel()
            await staleGenModel.refresh()
            let staleGenCallsAfterRefresh = await staleGenSource.modelCallCount()
            let staleGenGenerationAdvanced =
                staleGenModel.payload?.meta.generatedAt != staleGenGenerationBefore
            let staleGenRefreshRetried =
                staleGenCallsAfterRefresh == staleGenCallsBeforeRefresh + 1
            await staleGenModel.retryMissingModelForTest()
            let staleGenCallsAfterRetry = await staleGenSource.modelCallCount()
            let staleGenRetried = staleGenCallsAfterRetry == staleGenCallsAfterRefresh + 1
            await staleGenModel.retryMissingModelForTest()
            let staleGenCurrent =
                await staleGenSource.modelCallCount() == staleGenCallsAfterRetry

            // A reopen that commits a new generation scans the model exactly
            // once, for the committed slice.
            //
            // This does NOT discriminate where the gate opens. Codex raised
            // that the fetch-gated version let the waiter resume before
            // `apply()` and scan a generation about to be superseded; moving
            // the commit inside the gated task makes the ordering structural.
            // But the fetch-gated version was mutated back in and survived
            // three runs — both waiters register on the same task, and the
            // fetch's owner registers first, so it commits first in practice.
            // The language does not guarantee that; the fix removes the
            // reliance rather than a reproduced defect. What this assertion is
            // good for is catching a double scan arriving by any route.
            let commitGenSource = ControlledTurnUsageDataSource()
            await commitGenSource.advanceGraphGenerationPerCall()
            let commitGenSeed = DashboardModel(
                cachesSnapshot: true, source: commitGenSource, initialYear: nil)
            await commitGenSeed.load()
            let seededKey = commitGenSeed.committedSliceKey
            await commitGenSource.blockGraph(year: nil)
            let commitGenModel = DashboardModel(
                cachesSnapshot: true, source: commitGenSource, initialYear: nil)
            let commitGenLoad = Task { await commitGenModel.load() }
            _ = await waitUntil { await commitGenSource.hasPendingGraph(year: nil) }
            let commitGenLens = Task { await commitGenModel.ensureModelData(for: .overview) }
            await commitGenSource.releaseGraph(year: nil)
            await commitGenLoad.value
            await commitGenLens.value
            let commitGenAdvanced = commitGenModel.committedSliceKey != seededKey
            let commitGenScannedOnce = await commitGenSource.modelCallCount() == 1

            // Codex P2 — a restored payload is not a committed one. When the
            // reopen's graph fetch fails, `try?` leaves the restored payload
            // standing; scanning against it puts a reading of now beside a
            // chart from the previous session, tagged as if they agreed.
            // `tb_model_report` takes a year and nothing else, so the scan is
            // always current logs — the generation is a cache identity, not a
            // filter. Before the split, a throwing graph discarded the model
            // with it, so this was the branch's own regression.
            let failGraphSource = ControlledTurnUsageDataSource()
            await failGraphSource.advanceGraphGenerationPerCall()
            // Its own year: `lastSnapshot` is process-static and keyed on the
            // year alone, so an all-time seed here would inherit — and re-cache
            // — the model report an earlier all-time fixture published, leaving
            // the control below unable to observe an absent report.
            let failGraphYear = "2043"
            let failGraphSeed = DashboardModel(
                cachesSnapshot: true, source: failGraphSource, initialYear: failGraphYear)
            await failGraphSeed.load()
            let failGraphReopened = DashboardModel(
                cachesSnapshot: true, source: failGraphSource, initialYear: failGraphYear)
            let failGraphRestored =
                failGraphReopened.payload != nil && failGraphReopened.modelReport == nil
            await failGraphSource.failNextGraph()
            await failGraphReopened.load()
            let failGraphCallsBefore = await failGraphSource.modelCallCount()
            await failGraphReopened.ensureModelData(for: .overview)
            let failGraphCallsAfter = await failGraphSource.modelCallCount()
            // Folds in the fixture's own health: without confirming the reopen
            // really restored a renderable payload, "no scan issued" would also
            // hold on an empty dashboard with nothing to scan against.
            let failGraphIssuedNoScan =
                failGraphRestored && failGraphCallsAfter == failGraphCallsBefore
            // Absent, but the answer is not "none": the cards must read as
            // loading rather than claim the range has no model usage.
            let failGraphReadsAsLoading = failGraphReopened.modelLoading
            // A later successful commit heals it — the guard defers the scan,
            // it does not abandon it.
            await failGraphReopened.load()
            await failGraphReopened.ensureModelData(for: .overview)
            let failGraphHealed = failGraphReopened.modelReport != nil

            // Codex P2 — an overtaken fetch must not report failure over a
            // newer commit. `load()` for year A can still be in flight when the
            // user picks year B (the phantom-slice guards exist for exactly
            // that overlap); if B commits first and A then fails, an
            // unconditional flag marks the DISPLAYED slice failed and strands
            // its model cards on a spinner until the next successful poll.
            let overtakeA = "2044"
            let overtakeB = "2045"
            let overtakeSource = ControlledTurnUsageDataSource()
            let overtakeModel = DashboardModel(source: overtakeSource, initialYear: overtakeA)
            await overtakeSource.blockGraph(year: overtakeA)
            let overtakeLoad = Task { await overtakeModel.load() }
            _ = await waitUntil { await overtakeSource.hasPendingGraph(year: overtakeA) }
            // B overtakes and commits while A is still parked.
            await overtakeModel.setYear(overtakeB)
            await overtakeSource.failPendingGraph(year: overtakeA)
            await overtakeLoad.value
            await overtakeModel.ensureModelData(for: .overview)
            let overtakeServedB = overtakeModel.modelReport != nil

            // Codex P2 — the same ownership rule has to cover SUCCESS. Two
            // same-year fetches overlap when a manual Refresh starts while
            // `load()` is still running; the year guards cannot separate them,
            // so an older result landing second rolled the dashboard and the
            // reopen snapshot back to its payload.
            // The fixture year must MATCH the injected "today", or
            // `DemoData.dates(for:today:)` clamps the range to that year's 31
            // December and both releases carry an identical `generatedAt` —
            // the day argument would have no effect and the ordering below
            // would be unobservable.
            let rollbackYear = "2037"
            let rollbackSource = ControlledTurnUsageDataSource()
            let rollbackModel = DashboardModel(source: rollbackSource, initialYear: rollbackYear)
            await rollbackSource.blockGraph(year: rollbackYear)
            let rollbackLoad = Task { await rollbackModel.load() }
            _ = await waitUntil { await rollbackSource.pendingGraphCount(year: rollbackYear) == 1 }
            let rollbackRefresh = Task { await rollbackModel.refresh() }
            let rollbackBothParked = await waitUntil {
                await rollbackSource.pendingGraphCount(year: rollbackYear) == 2
            }
            // The later fetch commits first.
            await rollbackSource.releaseGraph(year: rollbackYear, index: 1, day: 9)
            _ = await waitUntil {
                await MainActor.run { rollbackModel.committedSliceKey.contains("2037-06-19") }
            }
            let rollbackNewerCommitted =
                rollbackModel.committedSliceKey.contains("2037-06-19")
            // The earlier one lands afterwards and must not take the slice back.
            await rollbackSource.releaseGraph(year: rollbackYear, index: 0, day: 1)
            await rollbackLoad.value
            await rollbackRefresh.value
            // Folds in the fixture's own health: without confirming both fetches
            // really overlapped, landing on "2037-06-19" would also hold if only
            // one fetch ever ran.
            let rollbackHeldNewer =
                rollbackBothParked && rollbackModel.committedSliceKey.contains("2037-06-19")

            // Codex P2 — a superseded fetch settles nothing, so waking on it is
            // not the same as waking on a committed slice. The waiter has to
            // follow the chain: it captured the older task, that task returns
            // without committing, and scanning then would put a model scan
            // beside the newer graph fetch still running.
            let chainYear = "2047"
            let chainSource = ControlledTurnUsageDataSource()
            let chainSeed = DashboardModel(
                cachesSnapshot: true, source: chainSource, initialYear: chainYear)
            await chainSeed.load()
            let chainModel = DashboardModel(
                cachesSnapshot: true, source: chainSource, initialYear: chainYear)
            // A restored payload is what lets the model request reach the gate at
            // all — without one it returns at the slice guard and never waits.
            let chainRestored = chainModel.payload != nil && chainModel.modelReport == nil
            await chainSource.blockGraph(year: chainYear)
            let chainLoad = Task { await chainModel.load() }
            _ = await waitUntil { await chainSource.pendingGraphCount(year: chainYear) == 1 }
            // Captures the OLDER task, before the refresh below supersedes it.
            let chainLens = Task { await chainModel.ensureModelData(for: .overview) }
            let chainRefresh = Task { await chainModel.refresh() }
            let chainBothParked = await waitUntil {
                await chainSource.pendingGraphCount(year: chainYear) == 2
            }
            // The older fetch completes and commits nothing.
            await chainSource.releaseGraph(year: chainYear, index: 0, day: 3)
            let chainRaced = await waitUntil { await chainSource.modelCallCount() > 0 }
            // Folds in the fixture's own health: without confirming a payload was
            // restored and both fetches actually overlapped, "did not race" would
            // also hold on a request that never reached the gate.
            let chainDidNotRace = chainRestored && chainBothParked && !chainRaced
            await chainSource.releaseGraph(year: chainYear, index: 0, day: 7)
            await chainLoad.value
            await chainRefresh.value
            await chainLens.value
            let chainArrived = chainModel.modelReport != nil
            let chainNeverRacedGraph = await chainSource.modelCallsRacingGraph() == 0

            // Same rule one level out: a superseded RELOAD settled nothing, so
            // its lazy-lens re-fetch would put an hourly scan beside the graph
            // fetch that overtook it. Blocking hourly makes the re-fetch
            // observable as a parked request rather than needing a counter.
            let lazyYear = "2048"
            let lazyClients = ["codex", "claude"]
            let lazySource = ControlledTurnUsageDataSource()
            let lazyModel = DashboardModel(source: lazySource, initialYear: lazyYear)
            await lazyModel.load()
            await lazyModel.ensureData(for: .hourly, clients: lazyClients)
            // Control: reload only re-fetches a lens it already holds, so
            // without this the assertion below would pass on a lens that could
            // never have been re-fetched at all.
            let lazySeeded = await lazyModel.hourlyReport(for: lazyClients) != nil
            await lazySource.blockGraph(year: lazyYear)
            let lazyRefresh = Task { await lazyModel.refresh() }
            _ = await waitUntil { await lazySource.pendingGraphCount(year: lazyYear) == 1 }
            let lazyLoad = Task { await lazyModel.load() }
            let lazyBothParked = await waitUntil {
                await lazySource.pendingGraphCount(year: lazyYear) == 2
            }
            await lazySource.blockHourly(year: lazyYear)
            // The refresh is now the older, overtaken fetch.
            await lazySource.releaseGraph(year: lazyYear, index: 0, day: 3)
            let lazyRefetched = await waitUntil {
                await lazySource.hasPendingHourly(year: lazyYear)
            }
            // Folds in the fixture's own health: without confirming the lens was
            // already seeded and both fetches actually overlapped, "held back"
            // would also hold on a lens that was never re-fetchable at all.
            let lazyHeldBack = lazySeeded && lazyBothParked && !lazyRefetched
            await lazySource.releaseGraph(year: lazyYear, index: 0, day: 7)
            await lazySource.releaseHourly(year: lazyYear)
            await lazyRefresh.value
            await lazyLoad.value

            // Codex P2 — the task key must change when the committed slice
            // changes, even when two slices share a payload generation. An
            // all-years payload and a current-year payload are both dated
            // today, so a key built from the REQUESTED year moved at the moment
            // of intent and then sat still when the new payload committed: the
            // task never re-fired and no model request followed.
            let sameGenSource = ControlledTurnUsageDataSource()
            let sameGenModel = DashboardModel(source: sameGenSource, initialYear: nil)
            await sameGenModel.load()
            let allYearsKey = sameGenModel.committedSliceKey
            let allYearsGeneration = sameGenModel.payload?.meta.generatedAt
            let thisYear = String(Format.todayKey().prefix(4))
            // Sample the key DURING the switch, before the new payload commits.
            // Measured only after `setYear` returns, `year` and
            // `acceptedPayloadYear` already agree and a key built from either
            // one looks identical — which is exactly why the defect survived a
            // terminal-state assertion.
            await sameGenSource.blockGraph(year: thisYear)
            let sameGenSwitch = Task { await sameGenModel.setYear(thisYear) }
            _ = await waitUntil { await sameGenSource.hasPendingGraph(year: thisYear) }
            let midSwitchKey = sameGenModel.committedSliceKey
            await sameGenSource.releaseGraph(year: thisYear)
            await sameGenSwitch.value
            let thisYearKey = sameGenModel.committedSliceKey
            let thisYearGeneration = sameGenModel.payload?.meta.generatedAt
            // The key must not move until the payload does: moving at the
            // moment of intent is what left it unchanged at commit time.
            let keyHeldUntilCommit = midSwitchKey == allYearsKey
            // Folds in the fixture's own health: without confirming the two
            // slices really share a generation, "key changed" would also hold
            // on the boring case where they never collided in the first place.
            let generationsCollide =
                allYearsGeneration != nil && allYearsGeneration == thisYearGeneration
            let keyChangedDespiteCollision =
                generationsCollide && allYearsKey != thisYearKey

            // #199 — a manual refresh must heal a model request that failed
            // transiently, without waiting for the next 60-second poll.
            let healSource = ControlledTurnUsageDataSource()
            await healSource.advanceGraphGenerationPerCall()
            let healModel = DashboardModel(source: healSource, initialYear: yearA)
            await healModel.load()
            let healGenerationBefore = healModel.payload?.meta.generatedAt
            await healSource.failNextModel()
            await healModel.ensureModelData(for: .overview)
            let healCallsAfterFailure = await healSource.modelCallCount()
            let failedLeftEmpty =
                healModel.modelReport == nil && healCallsAfterFailure == 1
            await healModel.refresh()
            let healCallsAfterRefresh = await healSource.modelCallCount()
            let healPriorities = await healSource.modelCallPriorities()
            let healGenerationAdvanced =
                healModel.payload?.meta.generatedAt != healGenerationBefore
            let healRefreshRetriedOnce = healCallsAfterRefresh == healCallsAfterFailure + 1
            let healRefreshPriority =
                healPriorities.count == healCallsAfterRefresh
                    && healPriorities.last == .userInitiated
            let healedAfterRefresh = healModel.modelReport != nil
            // A second retry must be an idempotent no-op, proving the refresh
            // published for the committed generation rather than merely any report.
            await healModel.retryMissingModelForTest()
            let healCurrentAfterRefresh =
                await healSource.modelCallCount() == healCallsAfterRefresh

            // A reload may call the shared seam unconditionally; modelWanted is
            // what keeps a graph-only dashboard from paying for a model scan.
            let neverWantedSource = ControlledTurnUsageDataSource()
            await neverWantedSource.advanceGraphGenerationPerCall()
            let neverWantedModel = DashboardModel(source: neverWantedSource, initialYear: yearA)
            await neverWantedModel.load()
            let neverWantedGenerationBefore = neverWantedModel.payload?.meta.generatedAt
            let neverWantedCallsBefore = await neverWantedSource.modelCallCount()
            await neverWantedModel.refresh()
            let neverWantedGenerationAdvanced =
                neverWantedModel.payload?.meta.generatedAt != neverWantedGenerationBefore
            let neverWantedCallsAfter = await neverWantedSource.modelCallCount()
            let neverWantedSkippedModel =
                neverWantedCallsBefore == 0
                    && neverWantedCallsAfter == 0
                    && neverWantedModel.modelReport == nil

            // Codex P1 — switching lens mid-scan must still publish. SwiftUI
            // cancels the lens-keyed task on the switch, so if the cancelled
            // task owns publication and the re-entrant one merely coalesces
            // and returns, nobody publishes and the new lens sits empty.
            let handoffSource = ControlledTurnUsageDataSource()
            let handoffModel = DashboardModel(source: handoffSource, initialYear: yearA)
            await handoffModel.load()
            await handoffSource.blockModel()
            let overviewTask = Task { await handoffModel.ensureModelData(for: .overview) }
            _ = await waitUntil { await handoffSource.pendingModelCount() > 0 }
            overviewTask.cancel()
            let modelsTask = Task { await handoffModel.ensureModelData(for: .models) }
            _ = await waitUntil { await handoffSource.pendingModelCount() > 0 }
            await handoffSource.releaseModel()
            await overviewTask.value
            await modelsTask.value
            let survivesLensSwitch = await handoffModel.modelReport != nil

            // #190 — the newest popover model owns the process-static reopen
            // snapshot. A retired model may still finish its unstructured model
            // scan and a live-data poll, but neither completion may overwrite the
            // payload or trace a newly opened model already committed.
            func snapshotPayload(version: String, year: String) -> UsagePayload {
                let encoded = try! JSONEncoder().encode(DemoData.payload(for: year))
                var object = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
                var meta = object["meta"] as! [String: Any]
                meta["version"] = version
                object["meta"] = meta
                let tagged = try! JSONSerialization.data(withJSONObject: object)
                return try! JSONDecoder().decode(UsagePayload.self, from: tagged)
            }
            func snapshotTrace(client: String, tokens: Int64) -> [TraceBucket] {
                [TraceBucket(
                    client: client, agent: "snapshot-fixture", model: "snapshot-fixture",
                    tokens: tokens, messages: 1, tokensPerMin: Double(tokens))]
            }

            let snapshotYear = "2050"
            let retiredPayload = snapshotPayload(version: "snapshot-retired", year: snapshotYear)
            let currentPayload = snapshotPayload(version: "snapshot-current", year: snapshotYear)
            let retiredTrace = snapshotTrace(client: "snapshot-retired", tokens: 1)
            let currentTrace = snapshotTrace(client: "snapshot-current", tokens: 2)
            let snapshotMarkersDiffer =
                retiredPayload.meta.version != currentPayload.meta.version
            let snapshotGenerationsCollide =
                retiredPayload.meta.generatedAt == currentPayload.meta.generatedAt

            let retiredSnapshotSource = ControlledTurnUsageDataSource()
            await retiredSnapshotSource.forceNextGraphPayload(retiredPayload)
            let retiredSnapshotModel = DashboardModel(
                cachesSnapshot: true, source: retiredSnapshotSource, initialYear: snapshotYear)
            await retiredSnapshotModel.load()
            let retiredSnapshotSeeded =
                retiredSnapshotModel.payload?.meta.version == retiredPayload.meta.version
            await retiredSnapshotSource.blockModel()
            await retiredSnapshotSource.blockTrace()
            let retiredModelTask = Task {
                await retiredSnapshotModel.ensureModelData(for: .overview)
            }
            let retiredTraceTask = Task { await retiredSnapshotModel.pollTrace() }
            let retiredModelParked = await waitUntil {
                await retiredSnapshotSource.pendingModelCount() == 1
            }
            let retiredTraceParked = await waitUntil {
                await retiredSnapshotSource.hasPendingTrace()
            }

            let currentSnapshotSource = ControlledTurnUsageDataSource()
            await currentSnapshotSource.forceNextGraphPayload(currentPayload)
            await currentSnapshotSource.forceNextTrace(currentTrace)
            let currentSnapshotModel = DashboardModel(
                cachesSnapshot: true, source: currentSnapshotSource, initialYear: snapshotYear)
            await currentSnapshotModel.load()
            let currentTraceTask = Task { await currentSnapshotModel.pollTrace() }
            let currentTracePublished = await waitUntil {
                await MainActor.run {
                    currentSnapshotModel.trace.first?.client == "snapshot-current"
                }
            }
            currentTraceTask.cancel()
            await currentTraceTask.value
            // Folds in the fixture's own health: without confirming the two
            // payloads carry distinguishable markers on a colliding generation
            // and that the retired snapshot really seeded first, a version match
            // here could be satisfied by timestamp ordering instead of true
            // reopen-ownership.
            let currentSnapshotCommitted =
                snapshotMarkersDiffer && snapshotGenerationsCollide && retiredSnapshotSeeded
                && currentSnapshotModel.payload?.meta.version == currentPayload.meta.version
                && currentTracePublished
                && currentSnapshotModel.modelReport == nil

            await retiredSnapshotSource.releaseModel()
            await retiredModelTask.value
            await retiredSnapshotSource.releaseTrace(retiredTrace)
            let retiredTracePublished = await waitUntil {
                await MainActor.run {
                    retiredSnapshotModel.trace.first?.client == "snapshot-retired"
                }
            }
            retiredTraceTask.cancel()
            await retiredTraceTask.value
            let retiredSnapshotWritersSettled =
                retiredSnapshotModel.modelReport != nil && retiredTracePublished

            let snapshotReopen = DashboardModel(
                cachesSnapshot: true, source: ControlledTurnUsageDataSource(),
                initialYear: snapshotYear)
            let snapshotReopenKeptCurrentPayload =
                snapshotReopen.payload?.meta.version == currentPayload.meta.version
            let snapshotReopenKeptCurrentTrace =
                snapshotReopen.trace.first?.client == "snapshot-current"
            let snapshotReopenRejectedRetiredModel = snapshotReopen.modelReport == nil

            // A year switch must drop the previous year's model report. Two
            // sites enforce it — `setYear` calls `invalidateModel()`, and
            // `apply()` discards a report whose `modelYear` disagrees with the
            // committed payload — so each masks the other under single-site
            // mutation, and neither was covered. Without both, switching year
            // leaves the old year's models rendered in Overview and Models.
            let yearModelSource = ControlledTurnUsageDataSource()
            let yearModelModel = DashboardModel(source: yearModelSource, initialYear: yearA)
            await yearModelModel.load()
            await yearModelModel.ensureModelData(for: .overview)
            let modelHeldForA = await yearModelModel.modelReport != nil
            await yearModelModel.setYear(yearB)
            // Folds in the fixture's own health: without confirming A actually
            // held a report first, "dropped" would also hold on a model that
            // was never fetched at all.
            let modelDroppedAfterSwitch = await yearModelModel.modelReport == nil
            let modelDroppedOnYearSwitch = modelHeldForA && modelDroppedAfterSwitch

            // LP2A — Daily/Monthly no longer request any lazy report; their
            // turns ride the graph payload. Blocking hourly and driving both
            // lenses proves the request is gone rather than merely fast.
            let noHourlySource = ControlledTurnUsageDataSource()
            let noHourlyModel = DashboardModel(source: noHourlySource, initialYear: yearA)
            await noHourlyModel.load()
            await noHourlySource.blockHourly(year: yearA)
            // Driven in Tasks and probed, not awaited: if the request came back
            // these would park on the blocked source forever, and a hung suite
            // is a far worse failure signal than a red assertion.
            let dailyDrive = Task { await noHourlyModel.ensureData(for: .daily, clients: clients) }
            let monthlyDrive = Task {
                await noHourlyModel.ensureData(for: .monthly, clients: clients)
            }
            let hourlyReappeared = await waitUntil {
                await noHourlySource.hasPendingHourly(year: yearA)
            }
            let emptyDidNotFetch = !hourlyReappeared
            await noHourlySource.releaseHourly(year: yearA)
            await dailyDrive.value
            await monthlyDrive.value

            // LP2B — the graph must not share its scan window with the model.
            // With the graph blocked, load() is still in flight; a model request
            // arriving now is precisely the contention that made first paint
            // 5x slower warm and 2.5x slower cold on a real corpus.
            let deferSource = ControlledTurnUsageDataSource()
            let deferModel = DashboardModel(source: deferSource, initialYear: yearA)
            await deferSource.blockGraph(year: yearA)
            let deferLoad = Task { await deferModel.load() }
            let deferGraphPending = await waitUntil {
                await deferSource.hasPendingGraph(year: yearA)
            }
            // Drive the model-dependent lens while the graph is still blocked.
            // Probed rather than awaited: the request no longer returns early,
            // it waits for the base load, so awaiting it here would park until
            // the release below and hang the suite instead of failing it.
            let deferLens = Task { await deferModel.ensureModelData(for: .overview) }
            let modelRaced = await waitUntil { await deferSource.modelCallCount() > 0 }
            let noModelDuringGraph = !modelRaced
            await deferSource.releaseGraph(year: yearA)
            await deferLoad.value
            // Sampled between the graph landing and the deferred request
            // finishing: the dashboard must already be renderable on the graph
            // alone, which is the whole point of taking the model off this path.
            let readyWithoutModel = await deferModel.modelReport == nil
            await deferLens.value
            let phaseReadyBeforeModel = await {
                if case .ready = await deferModel.phase { return true }
                return false
            }()
            // Now the payload has committed, the same call fetches once.
            await deferModel.ensureModelData(for: .overview)
            let modelArrives = await deferModel.modelReport != nil
            let fetchedOnce = await deferSource.modelCallCount() == 1
            // Idempotent per committed generation: a re-render must not refetch.
            await deferModel.ensureModelData(for: .overview)
            let noRefetch = await deferSource.modelCallCount() == 1
            let neverRacedGraph = await deferSource.modelCallsRacingGraph() == 0

            // Daily/Monthly do not depend on the model report at all.
            let dailySource = ControlledTurnUsageDataSource()
            let dailyModel = DashboardModel(source: dailySource, initialYear: yearA)
            await dailyModel.load()
            await dailyModel.ensureModelData(for: .daily)
            await dailyModel.ensureModelData(for: .monthly)
            let lensesSkipModel = await dailySource.modelCallCount() == 0

            // F1 regression — a graph refresh must not fan out into two
            // concurrent model scans. The reload retry parks first, then the
            // generation-keyed view task re-fires and must adopt that same scan.
            let refreshSource = ControlledTurnUsageDataSource()
            await refreshSource.advanceGraphGenerationPerCall()
            let refreshModel = DashboardModel(source: refreshSource, initialYear: nil)
            await refreshModel.load()
            await refreshModel.ensureModelData(for: .overview)
            let beforeRefresh = await refreshSource.modelCallCount()
            await refreshSource.blockModel()
            let refreshTask = Task { await refreshModel.refresh() }
            let sawInFlight = await waitUntil {
                await refreshSource.pendingModelCount() == 1
            }
            let refireArrivals = MainActorArrivalGate(target: 1)
            let refireTask = Task { @MainActor in
                refireArrivals.arrive()
                await refreshModel.ensureModelData(for: .overview)
            }
            await refireArrivals.waitForTarget()
            let pendingAfterRefire = await refreshSource.pendingModelCount()
            await refreshSource.releaseModel()
            await refreshTask.value
            await refireTask.value
            let afterRefresh = await refreshSource.modelCallCount()
            // EXACTLY one scan per graph commit. The parked/refire controls make
            // this distinguish coalescing from both zero work and a second scan.
            let oneScanPerCommit =
                sawInFlight
                    && pendingAfterRefire == 1
                    && (afterRefresh - beforeRefresh) == 1
                    && refreshModel.modelReport != nil

            // The retry above is a new suspension point. If its parent refresh is
            // cancelled while the unstructured scan finishes, it must not continue
            // into the already-loaded lazy lenses afterwards.
            let cancelSource = ControlledTurnUsageDataSource()
            await cancelSource.advanceGraphGenerationPerCall()
            let cancelModel = DashboardModel(source: cancelSource, initialYear: yearA)
            let cancelClients = ["claude"]
            await cancelModel.load()
            await cancelModel.ensureModelData(for: .overview)
            await cancelModel.ensureData(for: .hourly, clients: cancelClients)
            let cancelHourlySeeded =
                await cancelModel.hourlyReport(for: cancelClients) != nil
            let cancelHourlyCallsBefore = await cancelSource.hourlyCallCount()
            await cancelSource.blockModel()
            let cancelRefresh = Task { await cancelModel.refresh() }
            let cancelRetryParked = await waitUntil {
                await cancelSource.pendingModelCount() == 1
            }
            cancelRefresh.cancel()
            await cancelSource.releaseModel()
            await cancelRefresh.value
            // Folds in the fixture's own health: without confirming hourly was
            // already seeded and the retry really parked mid-flight, "unchanged"
            // would also hold on a lens that had nothing to skip.
            let cancelHourlyCallsAfter = await cancelSource.hourlyCallCount()
            let cancelSkippedLazy =
                cancelHourlySeeded && cancelRetryParked
                    && cancelHourlyCallsAfter == cancelHourlyCallsBefore

            // Re-entry during an in-flight scan must join it, not start a
            // second. Both triggers are ordinary interaction: expanding another
            // Daily/Monthly row, or switching Overview→Models mid-scan.
            let reentrySource = ControlledTurnUsageDataSource()
            let reentryModel = DashboardModel(source: reentrySource, initialYear: yearA)
            await reentryModel.load()
            await reentrySource.blockModel()
            let firstEntry = Task { await reentryModel.ensureModelColors() }
            let firstEntryParked = await waitUntil {
                await reentrySource.pendingModelCount() > 0
            }
            let reentryArrivals = MainActorArrivalGate(target: 2)
            let secondEntry = Task { @MainActor in
                reentryArrivals.arrive()
                await reentryModel.ensureModelColors()
            }
            let thirdEntry = Task { @MainActor in
                reentryArrivals.arrive()
                await reentryModel.ensureModelData(for: .models)
            }
            await reentryArrivals.waitForTarget()
            let pendingAfterReentry = await reentrySource.pendingModelCount()
            let coalescedWhileInFlight = firstEntryParked && pendingAfterReentry == 1
            await reentrySource.releaseModel()
            await firstEntry.value
            await secondEntry.value
            await thirdEntry.value
            let reentryScans = await reentrySource.modelCallCount()
            let reentryCoalesced = coalescedWhileInFlight && reentryScans == 1
            // The coalesced request must still publish — collapsing re-entry is
            // only correct if the surviving scan actually lands.
            let coalescedStillPublished = await reentryModel.modelReport != nil

            // A snapshot whose model lags its payload must refetch on the first
            // model lens; storing only the payload's generation would silently
            // present a stale report as current.
            let lagSource = ControlledTurnUsageDataSource()
            await lagSource.advanceGraphGenerationPerCall()
            let lagSeed = DashboardModel(
                cachesSnapshot: true, source: lagSource, initialYear: nil)
            await lagSeed.load()
            await lagSeed.ensureModelData(for: .overview)
            let lagSeedGeneration = lagSeed.payload?.meta.generatedAt
            let lagSeedCalls = await lagSource.modelCallCount()
            // Move the graph on, but fail the refresh's own retry so the snapshot
            // really carries payload B beside last-good model A.
            await lagSource.failNextModel()
            await lagSeed.refresh()
            let lagSeedCallsAfterRefresh = await lagSource.modelCallCount()
            let lagSeedAdvanced = lagSeed.payload?.meta.generatedAt != lagSeedGeneration
            let lagSeedRetryFailed =
                lagSeedCallsAfterRefresh == lagSeedCalls + 1
                    && lagSeed.modelReport != nil
            let lagRestored = DashboardModel(
                cachesSnapshot: true, source: lagSource, initialYear: nil)
            // The restore really carries the lagging last-good report; its
            // recorded generation, not its presence, is what makes the first
            // model lens refetch it.
            let lagRestoredNeedsGate =
                lagRestored.payload != nil && lagRestored.modelReport != nil
            // LP3 precondition: `ensureModelData`/`ensureModelColors` require
            // `load()` to have been called first, or the restore gate a lag
            // installs hangs forever. `pauseGraphAdvance()` holds this load to
            // the SAME generation the snapshot already carries.
            await lagSource.pauseGraphAdvance()
            let lagGenerationBeforeLoad = lagRestored.payload?.meta.generatedAt
            await lagRestored.load()
            await lagSource.resumeGraphAdvance()
            // Folds in the fixture's own health: without confirming the restore
            // really carried a payload and a report, "generation unchanged"
            // would also hold on a load that had nothing to hold.
            let lagLoadHeldGeneration =
                lagRestoredNeedsGate
                    && lagRestored.payload?.meta.generatedAt == lagGenerationBeforeLoad
            let lagCallsBeforeEnsure = await lagSource.modelCallCount()
            await lagRestored.ensureModelData(for: .overview)
            // Folds in the fixture's own health: without confirming the seed
            // actually advanced its generation and its own retry genuinely
            // failed, "count increased by one" would also hold on a plain
            // first-ever scan that has nothing to do with a lagging report.
            let lagCallsAfterEnsure = await lagSource.modelCallCount()
            let lagRefetched =
                lagSeedAdvanced && lagSeedRetryFailed
                    && lagCallsAfterEnsure == lagCallsBeforeEnsure + 1

            // A genuinely newer slice must supersede, not be swallowed by the
            // coalescing guard. Without this a guard of the shape
            // `if modelInFlight != nil { return }` would look correct.
            let supersedeSource = ControlledTurnUsageDataSource()
            await supersedeSource.advanceGraphGenerationPerCall()
            // A concrete year, not nil: `lastSnapshot` is process-static and an
            // earlier check in this same function seeds it for the all-time
            // slice, which this model would otherwise restore — masking the
            // first request entirely. The advancing fixture days live in 2037,
            // so a 2037 filter still moves `generatedAt` per graph call.
            let supersedeModel = DashboardModel(source: supersedeSource, initialYear: yearA)
            await supersedeModel.load()
            await supersedeSource.blockModel()
            let staleScan = Task { await supersedeModel.ensureModelData(for: .overview) }
            _ = await waitUntil { await supersedeSource.pendingModelCount() == 1 }
            // The refresh itself starts the newer generation's retry and waits on
            // it. A view-task refire must adopt that successor, not start a third.
            let supersedeRefresh = Task { await supersedeModel.refresh() }
            let bothInFlight = await waitUntil {
                await supersedeSource.pendingModelCount() == 2
            }
            let supersedeRefireArrivals = MainActorArrivalGate(target: 1)
            let newerScan = Task { @MainActor in
                supersedeRefireArrivals.arrive()
                await supersedeModel.ensureModelData(for: .overview)
            }
            await supersedeRefireArrivals.waitForTarget()
            let pendingAfterSupersedeRefire =
                await supersedeSource.pendingModelCount()
            // Retire only the superseded scan. Its completion must not clear
            // the loading flag, which still belongs to the scan replacing it.
            await supersedeSource.releaseOneModel()
            await staleScan.value
            let loadingHeldBySuccessor = supersedeModel.modelLoading
            await supersedeSource.releaseModel()
            await supersedeRefresh.value
            await newerScan.value
            let supersedeCalls = await supersedeSource.modelCallCount()
            let newerSliceSupersedes =
                bothInFlight
                    && pendingAfterSupersedeRefire == 2
                    && supersedeCalls == 2

            // ABA — the in-flight slot must be released by the scan that owns
            // it, not by any scan carrying an equal identity value. A year
            // round-trip during a scan reproduces the equal-value collision
            // because tb_graph's 30s cache returns the same payload, so the
            // generation is unchanged.
            let abaSource = ControlledTurnUsageDataSource()
            let abaModel = DashboardModel(source: abaSource, initialYear: yearA)
            await abaModel.load()
            await abaSource.blockModel()
            let abaFirst = Task { await abaModel.ensureModelColors() }
            _ = await waitUntil { await abaSource.pendingModelCount() > 0 }
            await abaModel.setYear(yearB)
            await abaModel.setYear(yearA)
            let abaSecond = Task { await abaModel.ensureModelColors() }
            _ = await waitUntil { await abaSource.pendingModelCount() >= 2 }
            // Retire only the stale scan and let it finish unwinding. If it
            // releases the live scan's slot, the next ordinary re-entry starts a
            // third concurrent scan.
            await abaSource.releaseOneModel()
            await abaFirst.value
            let abaThird = Task { await abaModel.ensureModelColors() }
            // Wait for the outcome instead of sampling immediately: the third
            // task had not been scheduled yet when this read the counter, so
            // the assertion passed even with the defect restored.
            let abaThirdStarted = await waitUntil { await abaSource.modelCallCount() >= 3 }
            let abaNoThirdScan = !abaThirdStarted
            await abaSource.releaseModel()
            await abaSecond.value
            await abaThird.value

            // modelLoading is the only thing keeping the model cards from
            // reading "No model usage in this range" mid-scan, and nothing
            // asserted it until now.
            let loadingSource = ControlledTurnUsageDataSource()
            let loadingModel = DashboardModel(source: loadingSource, initialYear: yearA)
            await loadingModel.load()
            await loadingSource.blockModel()
            let loadingTask = Task { await loadingModel.ensureModelData(for: .models) }
            _ = await waitUntil { await loadingSource.pendingModelCount() > 0 }
            let loadingTrueInFlight = await loadingModel.modelLoading
            await loadingSource.releaseModel()
            await loadingTask.value
            let loadingFalseAfter = await loadingModel.modelLoading == false

            // F2 regression — Daily/Monthly render a per-model drill-down whose
            // dots are tinted from the model report. Expanding a row must be
            // able to populate the colour map, or every model of one provider
            // collapses onto the same rank-0 shade.
            let colorSource = ControlledTurnUsageDataSource()
            let colorModel = DashboardModel(source: colorSource, initialYear: yearA)
            await colorModel.load()
            await colorModel.ensureModelData(for: .daily)
            let entriesForColor = DemoData.modelReport(for: yearA).entries
                .sorted { $0.cost > $1.cost }
            let colorProbe: (String, String) -> String = { provider, name in
                colorModel.colors.color(provider, name)
            }
            let flatBeforeExpand: Bool = {
                guard entriesForColor.count >= 2 else { return true }
                let a = colorProbe(entriesForColor[0].provider, entriesForColor[0].model)
                let b = colorProbe(entriesForColor[1].provider, entriesForColor[1].model)
                return a == b
            }()
            await colorModel.ensureModelColors()
            let gradedAfterExpand: Bool = {
                guard entriesForColor.count >= 2 else { return true }
                let sameProvider = entriesForColor.first { entry in
                    entry.provider == entriesForColor[0].provider
                        && entry.model != entriesForColor[0].model
                }
                guard let sameProvider else { return true }
                let a = colorProbe(entriesForColor[0].provider, entriesForColor[0].model)
                let b = colorProbe(sameProvider.provider, sameProvider.model)
                return a != b
            }()

            return [
                "deferGraphPending": deferGraphPending,
                "noModelDuringGraph": noModelDuringGraph,
                "readyWithoutModel": readyWithoutModel,
                "phaseReadyBeforeModel": phaseReadyBeforeModel,
                "modelArrives": modelArrives,
                "fetchedOnce": fetchedOnce,
                "noRefetch": noRefetch,
                "neverRacedGraph": neverRacedGraph,
                "lensesSkipModel": lensesSkipModel,
                "survivesLensSwitch": survivesLensSwitch,
                "retiredSnapshotWritersParked": retiredModelParked && retiredTraceParked,
                "currentSnapshotCommitted": currentSnapshotCommitted,
                "retiredSnapshotWritersSettled": retiredSnapshotWritersSettled,
                "snapshotReopenKeptCurrentPayload": snapshotReopenKeptCurrentPayload,
                "snapshotReopenKeptCurrentTrace": snapshotReopenKeptCurrentTrace,
                "snapshotReopenRejectedRetiredModel": snapshotReopenRejectedRetiredModel,
                "failedLeftEmpty": failedLeftEmpty,
                "reopenDidNotRace": reopenDidNotRace,
                "reopenLoadingWhileDeferred": reopenLoadingWhileDeferred,
                "reopenModelArrived": reopenModelArrived,
                "refreshGateDeferred": refreshGateDeferred,
                "refreshGateModelArrived": refreshGateModelArrived,
                "staleGenGenerationAdvanced": staleGenGenerationAdvanced,
                "staleGenRefreshRetried": staleGenRefreshRetried,
                "staleGenRetried": staleGenRetried,
                "staleGenCurrent": staleGenCurrent,
                "commitGenAdvanced": commitGenAdvanced,
                "commitGenScannedOnce": commitGenScannedOnce,
                "failGraphIssuedNoScan": failGraphIssuedNoScan,
                "failGraphReadsAsLoading": failGraphReadsAsLoading,
                "failGraphHealed": failGraphHealed,
                "overtakeServedB": overtakeServedB,
                "rollbackNewerCommitted": rollbackNewerCommitted,
                "rollbackHeldNewer": rollbackHeldNewer,
                "chainDidNotRace": chainDidNotRace,
                "chainArrived": chainArrived,
                "chainNeverRacedGraph": chainNeverRacedGraph,
                "lazyHeldBack": lazyHeldBack,
                "keyHeldUntilCommit": keyHeldUntilCommit,
                "keyChangedDespiteCollision": keyChangedDespiteCollision,
                "healGenerationAdvanced": healGenerationAdvanced,
                "healRefreshRetriedOnce": healRefreshRetriedOnce,
                "healRefreshPriority": healRefreshPriority,
                "healedAfterRefresh": healedAfterRefresh,
                "healCurrentAfterRefresh": healCurrentAfterRefresh,
                "neverWantedGenerationAdvanced": neverWantedGenerationAdvanced,
                "neverWantedSkippedModel": neverWantedSkippedModel,
                "phantomIssuedNoScan": phantomIssuedNoScan,
                "phantomReadsAsLoading": phantomReadsAsLoading,
                "modelDroppedOnYearSwitch": modelDroppedOnYearSwitch,
                "oneScanPerCommit": oneScanPerCommit,
                "cancelSkippedLazy": cancelSkippedLazy,
                "flatBeforeExpand": flatBeforeExpand,
                "gradedAfterExpand": gradedAfterExpand,
                "reentryCoalesced": reentryCoalesced,
                "coalescedStillPublished": coalescedStillPublished,
                "lagLoadHeldGeneration": lagLoadHeldGeneration,
                "lagRefetched": lagRefetched,
                "newerSliceSupersedes": newerSliceSupersedes,
                "loadingHeldBySuccessor": loadingHeldBySuccessor,
                "abaNoThirdScan": abaNoThirdScan,
                "loadingTrueInFlight": loadingTrueInFlight,
                "loadingFalseAfter": loadingFalseAfter,
                "stalePending": stalePending,
                "staleSuppressed": staleSuppressed,
                "matchingBAfterStale": matchingBAfterStale,
                "initialAVisible": initialAVisible,
                "graphBPending": graphBPending,
                "oldReportSuppressed": oldReportSuppressed,
                "matchingBVisible": matchingBVisible,
                "emptyDidNotFetch": emptyDidNotFetch,
            ]
        }
        if let savedAttributionDashboardYear {
            UserDefaults.standard.set(savedAttributionDashboardYear, forKey: dashboardYearDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: dashboardYearDefaultsKey)
        }
        expect(
            turnTransitionChecks?["stalePending"] == true
                && turnTransitionChecks?["staleSuppressed"] == true
                && turnTransitionChecks?["matchingBAfterStale"] == true,
            "a superseded old-year hourly request cannot publish into the new year")
        expect(
            turnTransitionChecks?["initialAVisible"] == true
                && turnTransitionChecks?["graphBPending"] == true
                && turnTransitionChecks?["oldReportSuppressed"] == true
                && turnTransitionChecks?["matchingBVisible"] == true,
            "the Hourly lens shows a report only for the year it was fetched for")
        expect(
            turnTransitionChecks?["deferGraphPending"] == true
                && turnTransitionChecks?["noModelDuringGraph"] == true
                && turnTransitionChecks?["neverRacedGraph"] == true,
            "the model report is never requested while the graph scan is in flight")
        expect(
            turnTransitionChecks?["readyWithoutModel"] == true
                && turnTransitionChecks?["phaseReadyBeforeModel"] == true,
            "the dashboard reaches .ready on the graph alone, without the model")
        expect(
            turnTransitionChecks?["modelArrives"] == true
                && turnTransitionChecks?["fetchedOnce"] == true
                && turnTransitionChecks?["noRefetch"] == true,
            "a committed payload fetches the model exactly once per generation")
        expect(
            turnTransitionChecks?["modelDroppedOnYearSwitch"] == true,
            "a year switch drops the previous year's model report instead of leaving it "
                + "rendered beside the new year's graph")
        expect(
            turnTransitionChecks?["reopenDidNotRace"] == true
                && turnTransitionChecks?["reopenModelArrived"] == true,
            "reopening onto a model lens waits for the base load instead of scanning beside "
                + "it, and still receives its report")
        expect(
            turnTransitionChecks?["reopenLoadingWhileDeferred"] == true,
            "a deferred model request reads as loading, not as \"no model usage\" — the "
                + "restored dashboard is already showing those cards while it waits")
        expect(
            turnTransitionChecks?["refreshGateDeferred"] == true
                && turnTransitionChecks?["refreshGateModelArrived"] == true,
            "a lens opened during a manual refresh waits for that refresh's graph fetch "
                + "instead of scanning beside it, and still receives its report")
        expect(
            turnTransitionChecks?["staleGenGenerationAdvanced"] == true
                && turnTransitionChecks?["staleGenRefreshRetried"] == true,
            "the stale-model fixture advances the graph and attempts the refresh retry")
        expect(
            turnTransitionChecks?["staleGenRetried"] == true
                && turnTransitionChecks?["staleGenCurrent"] == true,
            "the shared retry heals a last-good report that lags the committed generation "
                + "and becomes idempotent once the current report lands")
        expect(
            turnTransitionChecks?["commitGenAdvanced"] == true,
            "the commit-order fixture really moves the generation on reopen")
        expect(
            turnTransitionChecks?["commitGenScannedOnce"] == true,
            "a reopen whose graph commits a new generation scans the model exactly once "
                + "(a double-scan guard — it does not discriminate where the gate opens; "
                + "see the comment at the fixture)")
        expect(
            turnTransitionChecks?["failGraphIssuedNoScan"] == true
                && turnTransitionChecks?["failGraphReadsAsLoading"] == true,
            "a model request issues no scan against a restored payload whose refresh "
                + "failed, and reads as loading rather than as no model usage")
        expect(
            turnTransitionChecks?["failGraphHealed"] == true,
            "the next successful commit releases that deferral — the guard defers the "
                + "model scan, it does not abandon it")
        expect(
            turnTransitionChecks?["overtakeServedB"] == true,
            "a stale graph fetch that fails after a newer slice committed does not mark "
                + "that newer slice failed — its model request still runs")
        expect(
            turnTransitionChecks?["rollbackNewerCommitted"] == true,
            "the rollback fixture really commits the later of two same-year fetches first")
        expect(
            turnTransitionChecks?["rollbackHeldNewer"] == true,
            "an overtaken graph fetch that succeeds does not commit — the dashboard and "
                + "the reopen snapshot keep the newer slice instead of rolling back")
        expect(
            turnTransitionChecks?["chainDidNotRace"] == true
                && turnTransitionChecks?["chainNeverRacedGraph"] == true,
            "a model waiter woken by a SUPERSEDED fetch keeps waiting for the one that "
                + "overtook it instead of scanning beside a graph fetch still running")
        expect(
            turnTransitionChecks?["chainArrived"] == true,
            "following that chain still delivers the report once the newer fetch commits")
        expect(
            turnTransitionChecks?["lazyHeldBack"] == true,
            "a superseded reload does not re-fetch its lazy lenses — the fetch that "
                + "overtook it owns the slice and refreshes them itself")
        expect(
            turnTransitionChecks?["keyChangedDespiteCollision"] == true,
            "the model task key still changes when the committed slice changes under a "
                + "shared generation, so the new slice actually requests its report")
        expect(
            turnTransitionChecks?["keyHeldUntilCommit"] == true,
            "the key does not move on the requested year alone — moving at the moment of "
                + "intent is what left it unchanged when the payload finally committed")
        expect(
            turnTransitionChecks?["failedLeftEmpty"] == true
                && turnTransitionChecks?["healGenerationAdvanced"] == true,
            "the manual-heal fixture starts from a real transient model failure and commits "
                + "a newer graph generation on Refresh")
        expect(
            turnTransitionChecks?["healRefreshRetriedOnce"] == true,
            "manual Refresh retries a wanted stale model exactly once before it returns")
        expect(
            turnTransitionChecks?["healRefreshPriority"] == true,
            "manual Refresh issues its model retry at userInitiated priority")
        expect(
            turnTransitionChecks?["healedAfterRefresh"] == true
                && turnTransitionChecks?["healCurrentAfterRefresh"] == true,
            "manual Refresh returns with the model report healed for the committed generation")
        expect(
            turnTransitionChecks?["neverWantedGenerationAdvanced"] == true
                && turnTransitionChecks?["neverWantedSkippedModel"] == true,
            "manual Refresh advances the graph without scanning models a lens never requested")
        expect(
            turnTransitionChecks?["survivesLensSwitch"] == true,
            "a lens switch during a model scan still publishes — the cancelled task must "
                + "not take the only publication path with it")
        expect(
            turnTransitionChecks?["retiredSnapshotWritersParked"] == true
                && turnTransitionChecks?["currentSnapshotCommitted"] == true,
            "a retired model and trace writer are both parked before a newly opened model "
                + "restores the old snapshot and commits its replacement")
        expect(
            turnTransitionChecks?["retiredSnapshotWritersSettled"] == true,
            "both retired writers really finish after the replacement snapshot commits — "
                + "the fixture does not pass by cancelling or abandoning them")
        expect(
            turnTransitionChecks?["snapshotReopenKeptCurrentPayload"] == true,
            "late model publication from a retired dashboard cannot roll back the newest "
                + "reopen snapshot's payload")
        expect(
            turnTransitionChecks?["snapshotReopenRejectedRetiredModel"] == true,
            "a retired dashboard's late model report cannot enter the newest reopen snapshot")
        expect(
            turnTransitionChecks?["snapshotReopenKeptCurrentTrace"] == true,
            "late live-data publication from a retired dashboard cannot replace the newest "
                + "reopen snapshot's trace")
        expect(
            turnTransitionChecks?["phantomIssuedNoScan"] == true,
            "no model scan is issued for a phantom slice — a new year paired with the "
                + "payload it has not replaced yet")
        expect(
            turnTransitionChecks?["phantomReadsAsLoading"] == true,
            "during a year switch the model reads as loading, never as an empty result — "
                + "the cards would otherwise claim the new year has no model usage")
        expect(
            turnTransitionChecks?["lensesSkipModel"] == true,
            "Daily/Monthly never request the model report on activation")
        expect(
            turnTransitionChecks?["oneScanPerCommit"] == true,
            "a graph refresh issues exactly one model scan — never two racing ones, "
                + "and never zero (a moved generation must refetch)")
        expect(
            turnTransitionChecks?["cancelSkippedLazy"] == true,
            "a refresh cancelled while its model retry is parked does not continue into "
                + "already-loaded lazy lenses after that retry settles")
        expect(
            turnTransitionChecks?["reentryCoalesced"] == true
                && turnTransitionChecks?["coalescedStillPublished"] == true,
            "re-entry during an in-flight model scan joins it instead of starting a second")
        expect(
            turnTransitionChecks?["lagLoadHeldGeneration"] == true,
            "the lag fixture restores the same payload generation without treating its stale "
                + "model report as current")
        expect(
            turnTransitionChecks?["lagRefetched"] == true,
            "a restored snapshot whose model lags its payload refetches instead of "
                + "presenting the stale report as current")
        expect(
            turnTransitionChecks?["newerSliceSupersedes"] == true,
            "coalescing joins only the identical slice — a moved generation still "
                + "starts its own scan instead of being swallowed by the guard")
        expect(
            turnTransitionChecks?["abaNoThirdScan"] == true,
            "a stale scan cannot release a live scan's in-flight slot — the year "
                + "round-trip that gives both the same identity value must not open a third scan")
        expect(
            turnTransitionChecks?["loadingTrueInFlight"] == true
                && turnTransitionChecks?["loadingFalseAfter"] == true
                && turnTransitionChecks?["loadingHeldBySuccessor"] == true,
            "modelLoading is true for the duration of a scan and clears when it lands — "
                + "it is the only thing keeping the cards off the empty copy mid-fetch")

        // The chain that actually gets a deferred model onto the screen is view
        // wiring, and a UI-free test cannot press a SwiftUI Button. Deleting any
        // link left every runtime assertion above green, so the tree this binary
        // was built from is read directly — the same technique the Discord
        // section uses for "declared in exactly one place".
        func lp2bSource(_ name: String) -> String {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // Sources/TokenBar
            for sub in ["", "Views/"] {
                let url = root.appendingPathComponent(sub + name)
                if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
            }
            return ""
        }
        let lp2bDaily = lp2bSource("DailyView.swift")
        let lp2bMonthly = lp2bSource("MonthlyView.swift")
        let lp2bPopover = lp2bSource("PopoverView.swift")
        expect(
            !lp2bDaily.isEmpty && !lp2bMonthly.isEmpty && !lp2bPopover.isEmpty,
            "the LP2B source scan found its three files (without this every wiring "
                + "assertion below would pass on empty strings)")
        expect(
            lp2bDaily.contains("if !isOpen { onExpand?() }")
                && lp2bMonthly.contains("if !isOpen { onExpand?() }"),
            "Daily and Monthly request the model colour map when a row opens")
        expect(
            lp2bPopover.components(separatedBy: "onExpand: { Task { await model.ensureModelColors() } }")
                .count - 1 == 2,
            "PopoverView wires that callback for both lenses, not just one")
        // Pin the model task by its id components AND its body, but tolerate
        // reformatting: an earlier version matched the whole multi-line literal
        // including indentation, so a purely cosmetic rewrap turned it red.
        // Matching a substring alone is the opposite failure — the sibling
        // hidden-client task on the next line carries the same generation
        // interpolation, which let the id lose its generation unnoticed. So
        // strip whitespace entirely, then require the exact id triple next to
        // the call it guards — that survives any rewrap while still pinning
        // every component of the key.
        let lp2bFlat = lp2bPopover.filter { !$0.isWhitespace }
        let lp2bModelTask = #".task(id:"\(activeViewRaw)|\(model.committedSliceKey)"){"#
            + "awaitmodel.ensureModelData(for:activeView.wrappedValue)}"
        expect(
            lp2bFlat.contains(lp2bModelTask),
            "the model task is keyed on the COMMITTED slice, not the requested year — "
                + "the requested year changes before the payload does, so a slice sharing "
                + "the previous generation would never re-fire")
        expect(
            turnTransitionChecks?["flatBeforeExpand"] == true
                && turnTransitionChecks?["gradedAfterExpand"] == true,
            "expanding a Daily/Monthly row populates the model colour map")
        // The old Daily/Monthly contract — "suppress turns until the payload and
        // the hourly report agree on the year" — has no successor assertion on
        // purpose. Turns now come from the very contribution the row is built
        // from, so a row's messages and its turns cannot describe different
        // years; the failure mode is removed by construction rather than
        // guarded at runtime. What remains testable is that the request is gone.
        expect(
            turnTransitionChecks?["emptyDidNotFetch"] == true,
            "Daily and Monthly request no hourly report at all — their turns come "
                + "from the graph payload")

        let hourlyCacheChecks = awaitMainActorValue { () async -> [String: Bool] in
            let year = "2047"
            let turnClients = ["codex", "claude"]
            let hourlyClients = ["codex", "claude", "gemini"]

            func fingerprint(_ report: HourlyReport?) -> String? {
                guard let report else { return nil }
                let entries = report.entries.map {
                    "\($0.hour)|\($0.clients.joined(separator: ","))|\($0.total)|"
                        + "\($0.messageCount)|\($0.turnCount)|\($0.cost)"
                }.joined(separator: ";")
                return "\(entries)|\(report.totalCost)"
            }

            func report(client: String, turns: Int) -> HourlyReport {
                let json: [String: Any] = [
                    "entries": [[
                        "hour": "2047-01-01 00:00", "clients": [client],
                        "models": ["fixture"], "input": 0, "output": 0,
                        "cacheRead": 0, "cacheWrite": 0, "reasoning": 0,
                        "total": turns, "messageCount": turns, "turnCount": turns,
                        "cost": Double(turns),
                    ]],
                    "totalCost": Double(turns),
                ]
                let data = try! JSONSerialization.data(withJSONObject: json)
                return try! JSONDecoder().decode(HourlyReport.self, from: data)
            }

            @MainActor func blockedModel(
                source: ControlledTurnUsageDataSource,
                cachesSnapshot: Bool = true,
                view: AppView,
                clients: [String]
            ) async -> (DashboardModel, Task<Void, Never>, Bool) {
                await source.blockHourly(year: year)
                let model = DashboardModel(
                    cachesSnapshot: cachesSnapshot, source: source, initialYear: year)
                await model.load()
                let task = Task { await model.ensureData(for: view, clients: clients) }
                let pending = await waitUntil { await source.hasPendingHourly(year: year) }
                return (model, task, pending)
            }

            let originalA = report(client: "a", turns: 1)
            let originalB = report(client: "b", turns: 2)
            let refreshedA = report(client: "a-new", turns: 3)
            let nonOwnerB = report(client: "local", turns: 4)
            let fixturesDistinct = Set([
                fingerprint(originalA), fingerprint(originalB), fingerprint(refreshedA),
                fingerprint(nonOwnerB),
            ]).count == 4

            // Seed two distinct popover-owned slices under the same year.
            let seedSource = ControlledTurnUsageDataSource(hourlyResponses: [
                Set(turnClients): originalA,
                Set(hourlyClients): originalB,
            ])
            let seedModel = DashboardModel(
                cachesSnapshot: true, source: seedSource, initialYear: year)
            await seedModel.load()
            await seedModel.ensureData(for: .hourly, clients: turnClients)
            await seedModel.ensureData(for: .hourly, clients: hourlyClients)

            // A fresh popover restores A before its deliberately blocked
            // refresh completes, then the accepted newer result replaces A.
            let refreshSource = ControlledTurnUsageDataSource(hourlyResponses: [
                Set(turnClients): refreshedA,
            ])
            let (refreshModel, refreshTask, _) = await blockedModel(
                source: refreshSource, view: .hourly, clients: turnClients)
            let restoredABeforeRefresh =
                fingerprint(refreshModel.hourlyReport(for: turnClients)) == fingerprint(originalA)
            await refreshSource.releaseHourly(year: year)
            await refreshTask.value
            let acceptedRefreshVisible =
                fingerprint(refreshModel.hourlyReport(for: turnClients)) == fingerprint(refreshedA)

            // Fresh owners prove A's replacement did not overwrite sibling B.
            let verifyASource = ControlledTurnUsageDataSource(hourlyResponses: [
                Set(turnClients): refreshedA,
            ])
            let (verifyAModel, verifyATask, _) = await blockedModel(
                source: verifyASource, view: .hourly, clients: turnClients)
            let refreshedARestored =
                fingerprint(verifyAModel.hourlyReport(for: turnClients)) == fingerprint(refreshedA)
            await verifyASource.releaseHourly(year: year)
            await verifyATask.value

            let verifyBSource = ControlledTurnUsageDataSource(hourlyResponses: [
                Set(hourlyClients): originalB,
            ])
            let (verifyBModel, verifyBTask, _) = await blockedModel(
                source: verifyBSource, view: .hourly, clients: hourlyClients)
            let siblingBPreserved =
                fingerprint(verifyBModel.hourlyReport(for: hourlyClients)) == fingerprint(originalB)
            await verifyBSource.releaseHourly(year: year)
            await verifyBTask.value

            // An unseen client key cannot borrow either cached slice.
            let unseenClients = ["codex"]
            let unseenSource = ControlledTurnUsageDataSource(hourlyResponses: [
                Set(unseenClients): nonOwnerB,
            ])
            let (unseenModel, unseenTask, unseenPending) = await blockedModel(
                source: unseenSource, view: .hourly, clients: unseenClients)
            // Folds in the fixture's own health: without confirming the fetch
            // really parked mid-flight, "stayed empty" would also hold on a
            // request that had already resolved some other way.
            let unseenStayedEmpty =
                unseenPending && unseenModel.hourlyReport(for: unseenClients) == nil
            await unseenSource.releaseHourly(year: year)
            await unseenTask.value

            // Non-owners neither read A nor replace it with their local B.
            let nonOwnerSource = ControlledTurnUsageDataSource(hourlyResponses: [
                Set(turnClients): nonOwnerB,
            ])
            let (nonOwnerModel, nonOwnerTask, nonOwnerPending) = await blockedModel(
                source: nonOwnerSource, cachesSnapshot: false,
                view: .hourly, clients: turnClients)
            // Folds in the fixture's own health: without confirming the fetch
            // really parked mid-flight, "did not read" would also hold on a
            // request that had already resolved some other way.
            let nonOwnerDidNotRead =
                nonOwnerPending && nonOwnerModel.hourlyReport(for: turnClients) == nil
            await nonOwnerSource.releaseHourly(year: year)
            await nonOwnerTask.value
            let nonOwnerReceivedLocalB =
                fingerprint(nonOwnerModel.hourlyReport(for: turnClients)) == fingerprint(nonOwnerB)

            let ownerAfterSource = ControlledTurnUsageDataSource(hourlyResponses: [
                Set(turnClients): refreshedA,
            ])
            let (ownerAfterModel, ownerAfterTask, _) = await blockedModel(
                source: ownerAfterSource, view: .hourly, clients: turnClients)
            let nonOwnerDidNotWrite =
                fingerprint(ownerAfterModel.hourlyReport(for: turnClients)) == fingerprint(refreshedA)
            await ownerAfterSource.releaseHourly(year: year)
            await ownerAfterTask.value

            // Six more keys bring the cache to nine total slices; the fixed
            // eight-entry FIFO must evict A, which was inserted first.
            for suffix in 0..<6 {
                let extraYear = "205\(suffix)"
                let extraModel = DashboardModel(
                    cachesSnapshot: true, source: seedSource, initialYear: extraYear)
                await extraModel.load()
                await extraModel.ensureData(for: .hourly, clients: turnClients)
            }
            let evictionSource = ControlledTurnUsageDataSource(hourlyResponses: [
                Set(turnClients): refreshedA,
            ])
            await evictionSource.blockHourly(year: year)
            let evictionModel = DashboardModel(
                cachesSnapshot: true, source: evictionSource, initialYear: year)
            await evictionModel.load()
            let evictionTask = Task {
                await evictionModel.ensureData(for: .hourly, clients: turnClients)
            }
            let evictionPending = await waitUntil {
                await evictionSource.hasPendingHourly(year: year)
            }
            // Folds in the fixture's own health: without confirming the fetch
            // really parked mid-flight, "evicted" would also hold on a request
            // that had already resolved some other way.
            let oldestEvicted =
                evictionPending && evictionModel.hourlyReport(for: turnClients) == nil
            await evictionSource.releaseHourly(year: year)
            await evictionTask.value

            return [
                "fixturesDistinct": fixturesDistinct,
                "restoredABeforeRefresh": restoredABeforeRefresh,
                "acceptedRefreshVisible": acceptedRefreshVisible,
                "refreshedARestored": refreshedARestored,
                "siblingBPreserved": siblingBPreserved,
                "unseenStayedEmpty": unseenStayedEmpty,
                "nonOwnerDidNotRead": nonOwnerDidNotRead,
                "nonOwnerReceivedLocalB": nonOwnerReceivedLocalB,
                "nonOwnerDidNotWrite": nonOwnerDidNotWrite,
                "oldestEvicted": oldestEvicted,
            ]
        }
        expect(
            hourlyCacheChecks?["fixturesDistinct"] == true,
            "the region's report fixtures fingerprint as four distinct values — without "
                + "this every fingerprint comparison below could pass on a collision")
        expect(
            hourlyCacheChecks?["restoredABeforeRefresh"] == true
                && hourlyCacheChecks?["acceptedRefreshVisible"] == true,
            "hourly cache restores immediately and an accepted refresh replaces its exact key")
        expect(
            hourlyCacheChecks?["refreshedARestored"] == true
                && hourlyCacheChecks?["siblingBPreserved"] == true,
            "hourly cache keeps refreshed turn and all-client slices independent")
        expect(
            hourlyCacheChecks?["unseenStayedEmpty"] == true,
            "hourly cache never restores a report under an unseen client key")
        expect(
            hourlyCacheChecks?["nonOwnerDidNotRead"] == true
                && hourlyCacheChecks?["nonOwnerReceivedLocalB"] == true
                && hourlyCacheChecks?["nonOwnerDidNotWrite"] == true,
            "non-owning dashboard models neither read nor replace the popover hourly cache")
        expect(
            hourlyCacheChecks?["oldestEvicted"] == true,
            "hourly cache evicts its oldest slice after reaching eight entries")

        // Tab order (plan 2026-07-16): Monthly leads Daily in the tab row.
        expect(AppView.allCases.map(\.rawValue) ==
            ["overview", "quota", "models", "monthly", "daily", "hourly", "stats", "agents"],
            "tab row leads with Monthly, ahead of Daily, and Quota follows Overview")

        // View-tabs visibility (plan 2026-07-16, generalized): any of the
        // five toggleable lenses can be hidden independently; Overview and
        // Models are fixed anchors, never in AppView.toggleable.
        expect(AppView.toggleable == [.quota, .monthly, .daily, .hourly, .stats, .agents],
            "toggleable lenses are fixed order, excluding Overview and Models")
        expect(AppView.visible(hiddenRaw: "") == AppView.allCases,
            "no hidden lenses shows every lens")
        expect(AppView.visible(hiddenRaw: "monthly,hourly") ==
            AppView.allCases.filter { $0 != .monthly && $0 != .hourly },
            "hiding two lenses removes exactly those two, order otherwise unchanged")
        expect(AppView.effective(.monthly, hiddenRaw: "monthly") == .overview,
            "a hidden lens falls back to overview")
        expect(AppView.effective(.monthly, hiddenRaw: "") == .monthly,
            "a visible lens is unaffected")
        expect(AppView.effective(.daily, hiddenRaw: "monthly") == .daily,
            "hiding one lens doesn't affect another")
        // Hardening (code review, plan 2026-07-16): only `toggleable` lenses
        // are ever actually hideable, even if the persisted raw string is
        // tampered with out-of-band (e.g. a manually edited UserDefaults
        // value) to contain "overview" or "models" — Overview must always
        // remain the guaranteed fallback target.
        expect(AppView.visible(hiddenRaw: "overview,models") == AppView.allCases,
            "overview and models can never be hidden, even via a tampered raw string")
        expect(AppView.effective(.overview, hiddenRaw: "overview") == .overview,
            "overview is never subject to the hidden-lens fallback")

        // Filtered activity, DayBars windows, tooltip placement, and chart geometry.
        // Hidden later activity cannot extend selected streaks or shift token/cost
        // bars; a message-only day stays activity but does not move the metric window.
        func activityDay(_ client: String, _ date: String, tokens: Int64 = 10, cost: Double = 1) -> String {
            "{\"date\":\"\(date)\",\"totals\":{\"tokens\":\(tokens),\"cost\":\(cost),\"messages\":1},\"intensity\":\(tokens > 0 ? 1 : 0),\"tokenBreakdown\":{\"input\":\(tokens),\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"reasoning\":0},\"clients\":[{\"client\":\"\(client)\",\"modelId\":\"m\",\"providerId\":\"p\",\"cost\":\(cost),\"messages\":1,\"tokens\":{\"input\":\(tokens),\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"reasoning\":0}}]}"
        }
        func activityPayload(end: String, days: [String]) -> UsagePayload {
            try! JSONDecoder().decode(UsagePayload.self, from: Data("{\"meta\":{\"generatedAt\":\"now\",\"version\":\"1\",\"dateRange\":{\"start\":\"2026-07-01\",\"end\":\"\(end)\"}},\"summary\":{\"totalTokens\":0,\"totalCost\":0,\"totalDays\":0,\"activeDays\":0,\"averagePerDay\":0,\"maxCostInSingleDay\":0,\"clients\":[\"vis\",\"hid\"],\"models\":[]},\"years\":[],\"contributions\":[\(days.joined(separator: ","))]}".utf8))
        }
        let visDays = (1...3).map { activityDay("vis", String(format: "2026-07-%02d", $0)) }
        let withHidden = activityPayload(end: "2026-07-05", days: visDays + [activityDay("hid", "2026-07-05")])
        let noHidden = activityPayload(end: "2026-07-03", days: visDays)
        let messageTail = activityPayload(end: "2026-07-31", days: [
            activityDay("vis", "2026-07-01"), activityDay("vis", "2026-07-31", tokens: 0, cost: 0)])
        struct ActivityCase { let name: String; let payload: UsagePayload; let end: String; let current: Int; let longest: Int; let average: Double? }
        for c in [
            ActivityCase(name: "hidden later activity does not extend selected streak/range/average", payload: withHidden, end: "2026-07-03", current: 3, longest: 3, average: 1),
            ActivityCase(name: "a trailing message-only day remains current activity", payload: messageTail, end: "2026-07-31", current: 1, longest: 1, average: nil),
        ] {
            let stats = UsageStats(payload: c.payload, selectedClients: ["vis"])
            expect(stats.dateRange.end == c.end && stats.streaks.current == c.current && stats.streaks.longest == c.longest && (c.average.map { stats.averagePerDay == $0 } ?? true), c.name)
        }
        let visFiltered = UsageStats(payload: withHidden, selectedClients: ["vis"])
        let visAlone = UsageStats(payload: noHidden, selectedClients: ["vis"])
        expect(visFiltered.streaks.current == visAlone.streaks.current && visFiltered.streaks.longest == visAlone.streaks.longest && visFiltered.dateRange.end == visAlone.dateRange.end, "filtered stats equal a payload without the hidden client")

        let chartPayload = activityPayload(end: "2026-07-05", days: [activityDay("vis", "2026-07-03"), activityDay("hid", "2026-07-05")])
        let chartColors = ModelColorMap(report: nil)
        struct DayBarCase { let name: String; let payload: UsagePayload; let rangeEnd: String; let fallback: String; let last: String; let hasTokens: Bool }
        for c in [
            DayBarCase(name: "hidden later activity does not push selected usage out of the window", payload: chartPayload, rangeEnd: "2026-07-05", fallback: "2026-07-09", last: "2026-07-03", hasTokens: true),
            DayBarCase(name: "a later message-only day does not shift the token/cost window", payload: messageTail, rangeEnd: "2026-07-31", fallback: "2026-07-31", last: "2026-07-01", hasTokens: true),
            DayBarCase(name: "empty series uses endFallback when rangeEnd is empty", payload: activityPayload(end: "2026-07-09", days: []), rangeEnd: "", fallback: "2026-07-09", last: "2026-07-09", hasTokens: false),
        ] {
            let bars = DayBars.build(payload: c.payload, clientIds: ["vis"], stackBy: .agent, colors: chartColors, rangeEnd: c.rangeEnd, endFallback: c.fallback)
            expect(bars.count == DayBars.window && bars.last?.date == c.last && ((bars.last?.totalTokens ?? 0) > 0) == c.hasTokens, c.name)
        }

        let viewport = CGRect(x: 100, y: 200, width: 400, height: 300)
        let chartFrame = CGRect(x: 120, y: 250, width: 360, height: 150)
        let tip = CGSize(width: 210, height: 120)
        struct TooltipCase { let name: String; let anchor: CGPoint; let size: CGSize; let viewport: CGRect?; let width: CGFloat?; let height: CGFloat?; let matchNil: Bool }
        for c in [
            TooltipCase(name: "upper-half places below the cursor", anchor: CGPoint(x: 180, y: 30), size: tip, viewport: viewport, width: nil, height: 42, matchNil: false),
            TooltipCase(name: "lower-half places above the cursor", anchor: CGPoint(x: 180, y: 140), size: tip, viewport: viewport, width: nil, height: 8, matchNil: false),
            TooltipCase(name: "lower-half dodges above even with room below", anchor: CGPoint(x: 180, y: 100), size: tip, viewport: viewport, width: nil, height: -32, matchNil: false),
            TooltipCase(name: "clamps to the side with more visible space", anchor: CGPoint(x: 180, y: 110), size: CGSize(width: 210, height: 260), viewport: viewport, width: nil, height: -46, matchNil: false),
            TooltipCase(name: "clamps a near-edge anchor horizontally", anchor: CGPoint(x: 2, y: 30), size: tip, viewport: viewport, width: 0, height: nil, matchNil: false),
            TooltipCase(name: "viewport-taller tooltip pins to the visible top inset", anchor: CGPoint(x: 180, y: 30), size: CGSize(width: 210, height: 400), viewport: viewport, width: nil, height: -46, matchNil: false),
            TooltipCase(name: "stale non-intersecting viewport falls back to container-only", anchor: CGPoint(x: 180, y: 30), size: tip, viewport: CGRect(x: 100, y: 0, width: 400, height: 80), width: nil, height: nil, matchNil: true),
            TooltipCase(name: "partial-overlap stale viewport that misses the anchor falls back", anchor: CGPoint(x: 180, y: 100), size: tip, viewport: CGRect(x: 100, y: 200, width: 400, height: 80), width: nil, height: nil, matchNil: true),
        ] {
            let got = PopoverTooltipPlacement.offset(anchor: c.anchor, tooltipSize: c.size, containerFrame: chartFrame, viewport: c.viewport)
            let nilViewport = c.matchNil ? PopoverTooltipPlacement.offset(anchor: c.anchor, tooltipSize: c.size, containerFrame: chartFrame, viewport: nil) : nil
            expect((c.width.map { got?.width == $0 } ?? true) && (c.height.map { got?.height == $0 } ?? true) && (!c.matchNil || got?.height == nilViewport?.height), "tooltip: \(c.name)")
        }

        let chartWidth: CGFloat = 360
        let barGap = UsageChartGeometry.gap
        let barWidth = (chartWidth - barGap * 2) / 3
        let frames = (0..<3).map { UsageChartGeometry.barFrame(index: $0, barWidth: barWidth) }
        expect(frames[0].minX == 0 && frames[1].minX - frames[0].maxX == barGap && abs(frames[2].maxX - chartWidth) < 0.0001, "chart bar frames fill the width with documented gaps")
        for c in [
            (name: "in-bar hits that bar", x: frames[1].midX, expected: Optional(1)),
            (name: "gap pixels floor-attach to the left bar", x: frames[0].maxX + barGap / 2, expected: Optional(0)),
            (name: "leading edge hits its own index", x: frames[1].minX, expected: Optional(1)),
            (name: "trailing edge stays on that bar", x: frames[1].maxX, expected: Optional(1)),
            (name: "past the last stride is out of range", x: frames[2].maxX + barGap + 1, expected: nil),
        ] as [(name: String, x: CGFloat, expected: Int?)] {
            expect(UsageChartGeometry.barIndex(atX: c.x, barWidth: barWidth, count: 3) == c.expected, c.name)
        }

        let modelWidths = ModelBarGeometry.widths(
            values: [1_000_000, 1, 1, 1, 1], totalWidth: 120)
        let renderedModelWidth = modelWidths.reduce(0, +)
            + ModelBarGeometry.gap * CGFloat(modelWidths.count - 1)
        expect(
            abs(renderedModelWidth - 120) < 0.0001
                && modelWidths.dropFirst().allSatisfy { $0 >= 1 },
            "model bar widths preserve tiny segments without trailing overflow")

        // Synthetic --demo source: one fixture must drive every usage lens,
        // quota card, trace row, tray rate, and year selection without a live
        // FFI call. The fixture itself is the only data definition here.
        let demoSource = UsageDataSources.make(arguments: ["TokenBar", "--demo"])
        let liveSource = UsageDataSources.make(arguments: ["TokenBar"])
        expect(demoSource is DemoUsageDataSource, "usage source factory selects demo mode")
        expect(liveSource is LiveUsageDataSource, "usage source factory selects live mode")
        expect(!demoSource.allowsQuotaCachePersistence, "demo source disables quota cache persistence")
        expect(liveSource.allowsQuotaCachePersistence, "live source allows quota cache persistence")

        let demoPayload = DemoData.payload
        let demoDates = demoPayload.contributions.map(\.date)
        let demoDayNumbers = demoDates.compactMap { ISODay($0)?.number }
        let consecutive = zip(demoDayNumbers, demoDayNumbers.dropFirst())
            .allSatisfy { $1 == $0 + 1 }
        expect(
            demoDates.count == 14 && demoDates == demoDates.sorted() && consecutive,
            "demo graph has 14 sorted consecutive days")
        expect(
            demoPayload.contributions.allSatisfy { $0.clients.count == ClientRegistry.allIds.count },
            "demo graph carries every registered client on every day")

        let contributionTokens = demoPayload.contributions.reduce(Int64(0)) {
            $0.saturatingAdding($1.totals.tokens)
        }
        let contributionCost = demoPayload.contributions.reduce(0.0) { $0 + $1.totals.cost }
        expect(
            contributionTokens == demoPayload.summary.totalTokens
                && abs(contributionCost - demoPayload.summary.totalCost) < 0.000_000_001,
            "demo summary totals equal contribution totals")

        let summaryClients = Set(demoPayload.summary.clients)
        let contributionClients = Set(
            demoPayload.contributions.flatMap { $0.clients.map(\.client) })
        let quota = DemoData.agentUsage
        let quotaClients = Set(quota.agents.map(\.clientId))
        let registryClients = Set(ClientRegistry.allIds)
        expect(
            summaryClients == registryClients && contributionClients == registryClients
                && quotaClients == registryClients,
            "demo summary contributions and quota share the client set")
        expect(
            quota.agents.count == ClientRegistry.allIds.count
                && quota.agents.allSatisfy { agent in
                    let windows = agent.uniqueCardWindows
                    return windows.count == 2
                        && windows[0].cardId == "session.v1"
                        && windows[1].cardId == "weekly.v1"
                },
            "demo quota cards use unique canonical window identities")

        let firstDemoWindows = quota.agents.first?.uniqueCardWindows ?? []
        let secondDemoWindows = quota.agents.dropFirst().first?.uniqueCardWindows ?? []
        let demoLearningDuration = firstDemoWindows.first
        let demoLearningHistory = firstDemoWindows.dropFirst().first
        let demoAvailable = secondDemoWindows.first
        let demoUnavailable = secondDemoWindows.dropFirst().first
        expect(
            firstDemoWindows.count == 2
                && demoLearningDuration?.paceStatus.state == .learningDuration
                && demoLearningDuration?.durationSeconds == nil
                && demoLearningDuration?.windowMinutes == nil
                && demoLearningDuration?.paceStatus.durationSource == .observed
                && demoLearningHistory?.paceStatus.state == .learningHistory
                && demoLearningHistory?.durationSeconds == 604_800
                && demoLearningHistory?.windowMinutes == 10_080
                && demoLearningHistory?.historicalPace == nil,
            "demo fixture exposes learning-duration and learning-history rows")
        expect(
            secondDemoWindows.count == 2
                && demoAvailable?.paceStatus.state == .available
                && demoAvailable?.durationSeconds == 18_000
                && demoAvailable?.historicalPace?.expectedUsedPercent == 35
                && demoUnavailable?.paceStatus.state == .unavailable
                && demoUnavailable?.paceStatus.reason == .missingReset
                && demoUnavailable?.resetsAt == nil,
            "demo fixture exposes historical-available and typed-unavailable rows")

        let demoLearningEstimate = demoLearningHistory.flatMap {
            UsagePace.compute(window: $0, mode: .historical)
        }
        let demoHistoricalAhead = demoAvailable.flatMap {
            UsagePace.compute(window: $0, mode: .historical)
        }
        expect(
            demoLearningEstimate?.basis == .linear
                && demoLearningEstimate?.isHistoricalDeficit == false,
            "demo learning-history estimate stays a Linear basis in the parity contract")
        expect(
            demoHistoricalAhead?.basis == .historical
                && demoHistoricalAhead?.stage.isDeficit == true
                && demoHistoricalAhead?.isHistoricalDeficit == true,
            "demo available row is a historical deficit acceptance fixture")
        expect(
            demoLearningDuration.flatMap {
                UsagePace.compute(window: $0, mode: .historical)
            } == nil
                && demoUnavailable.flatMap {
                    UsagePace.compute(window: $0, mode: .historical)
                } == nil,
            "demo learning-duration and unavailable rows suppress projections")
        expect(
            quota.agents.dropFirst(2).allSatisfy { agent in
                agent.uniqueCardWindows.allSatisfy {
                    $0.paceStatus.state == .learningHistory
                        && $0.paceStatus.durationSource == .contract
                        && $0.paceStatus.completeCycles == 0
                        && $0.historicalPace == nil
                }
            },
            "remaining demo quota cards stay on canonical learning-history fixtures")

        let modelReport = DemoData.modelReport
        let hourlyReport = DemoData.hourlyReport
        let agentsReport = DemoData.agentsReport
        let trace = DemoData.trace(windowSecs: 600)
        let modelClients = Set(modelReport.entries.map(\.client))
        let hourlyClients = Set(hourlyReport.entries.flatMap(\.clients))
        let agentClients = Set(agentsReport.entries.flatMap(\.clients))
        let traceClients = Set(trace.map(\.client))
        let hourlyKeys = hourlyReport.entries.map(\.hour)
        expect(
            Set(hourlyKeys).count == hourlyKeys.count && hourlyKeys == hourlyKeys.sorted()
                && hourlyReport.entries.allSatisfy {
                    $0.clients == $0.clients.sorted() && $0.models == $0.models.sorted()
                },
            "demo hourly buckets are unique and sorted")
        expect(
            !modelReport.entries.isEmpty && !hourlyReport.entries.isEmpty
                && !agentsReport.entries.isEmpty && !trace.isEmpty,
            "demo reports and trace are non-empty")
        expect(
            modelClients == registryClients && hourlyClients == registryClients
                && agentClients == registryClients && traceClients == registryClients,
            "demo report and trace ids are registered clients")

        let selectedClient = ClientRegistry.allIds.first ?? ""
        var graphInput: Int64 = 0
        var graphOutput: Int64 = 0
        var graphCacheRead: Int64 = 0
        var graphCacheWrite: Int64 = 0
        var graphReasoning: Int64 = 0
        var graphMessages = 0
        var graphCost = 0.0
        for contribution in demoPayload.contributions {
            for client in contribution.clients where client.client == selectedClient {
                graphInput += client.tokens.input
                graphOutput += client.tokens.output
                graphCacheRead += client.tokens.cacheRead
                graphCacheWrite += client.tokens.cacheWrite
                graphReasoning += client.tokens.reasoning
                graphMessages += client.messages
                graphCost += client.cost
            }
        }
        let selectedHourly = DemoData.hourlyReport(for: nil, clients: [selectedClient])
        let hourlyInput = selectedHourly.entries.reduce(Int64(0)) { $0 + $1.input }
        let hourlyOutput = selectedHourly.entries.reduce(Int64(0)) { $0 + $1.output }
        let hourlyCacheRead = selectedHourly.entries.reduce(Int64(0)) { $0 + $1.cacheRead }
        let hourlyCacheWrite = selectedHourly.entries.reduce(Int64(0)) { $0 + $1.cacheWrite }
        let hourlyReasoning = selectedHourly.entries.reduce(Int64(0)) { $0 + $1.reasoning }
        let hourlyMessages = selectedHourly.entries.reduce(0) { $0 + $1.messageCount }
        let hourlyCost = selectedHourly.entries.reduce(0.0) { $0 + $1.cost }
        expect(
            graphInput == hourlyInput && graphOutput == hourlyOutput
                && graphCacheRead == hourlyCacheRead && graphCacheWrite == hourlyCacheWrite
                && graphReasoning == hourlyReasoning && graphMessages == hourlyMessages
                && abs(graphCost - hourlyCost) < 0.000_000_001,
            "selected demo hourly totals equal graph client rows")

        expect(
            quota.agents.allSatisfy { agent in
                !agent.windows.isEmpty && agent.windows.allSatisfy { window in
                    let durationShapeIsValid = switch window.paceStatus.state {
                    case .learningHistory, .available:
                        (window.windowMinutes ?? 0) > 0
                    case .learningDuration, .unavailable, .legacyMissing:
                        window.windowMinutes == nil
                    }
                    return durationShapeIsValid
                        && window.usedPercent >= 0 && window.remainingPercent > 0
                        && abs(window.usedPercent + window.remainingPercent - 100) < 0.000_001
                }
            },
            "demo quota windows have valid duration and percentage shapes")
        let rawDemoRate = DemoData.tokensPerMin
        let traceRate = trace.reduce(0.0) { $0 + $1.tokensPerMin }
        let selectedTraceRate = trace.first { $0.client == selectedClient }?.tokensPerMin ?? 0
        let hiddenTraceRate = TraceBucket.totalRate(trace, hidden: [selectedClient])
        let allHiddenTraceRate = TraceBucket.totalRate(trace, hidden: registryClients)
        expect(
            rawDemoRate > 0 && trace.allSatisfy { $0.tokensPerMin > 0 }
                && abs(rawDemoRate - traceRate) < 0.000_001
                && abs(hiddenTraceRate - (rawDemoRate - selectedTraceRate)) < 0.000_001
                && allHiddenTraceRate == 0,
            "demo raw rate equals trace and hidden-client reductions")

        let currentYear = String(Format.todayKey().prefix(4))
        let currentPayload = DemoData.payload(for: currentYear)
        let otherYear = String((Int(currentYear) ?? 2000) - 1)
        let otherPayload = DemoData.payload(for: otherYear)
        expect(
            demoPayload.contributions.last?.date == Format.todayKey()
                && currentPayload.contributions.last?.date == Format.todayKey(),
            "demo nil and current-year windows end today")
        expect(
            otherPayload.contributions.count == 14
                && otherPayload.contributions.allSatisfy { $0.date.hasPrefix(otherYear) }
                && otherPayload.years.contains { $0.year == otherYear },
            "demo non-current year stays within the selected year")

        let demoJan1 = DemoData.dates(for: "2024", today: "2024-01-01")
        let demoJan13 = DemoData.dates(for: "2024", today: "2024-01-13")
        let demoJan14 = DemoData.dates(for: "2024", today: "2024-01-14")
        let rollingJan1 = DemoData.dates(for: nil, today: "2024-01-01")
        let leapDay = DemoData.dates(for: "2024", today: "2024-02-29")
        let priorYear = DemoData.dates(for: "2023", today: "2024-02-29")
        let invalidYear = DemoData.dates(for: "not-a-year", today: "2024-02-29")
        expect(
            demoJan1.count == 1 && demoJan1.last == "2024-01-01"
                && demoJan13.count == 13 && demoJan13.last == "2024-01-13"
                && demoJan14.count == 14 && demoJan14.last == "2024-01-14",
            "demo current-year dates clamp at January 1")
        expect(
            rollingJan1.count == 14 && rollingJan1.last == "2024-01-01"
                && rollingJan1.first?.hasPrefix("2023-") == true,
            "demo all-years dates retain the rolling cross-year window")
        expect(
            leapDay.count == 14 && leapDay.contains("2024-02-29")
                && priorYear.count == 14 && priorYear.allSatisfy { $0.hasPrefix("2023-") }
                && invalidYear.count == 14 && invalidYear.last == "2024-02-29",
            "demo date helper handles leap and invalid years")

        let sourcedPayload = awaitValue {
            try await demoSource.graph(year: nil, priority: .userInitiated)
        }
        let sourcedRefresh = awaitValue {
            try await demoSource.refreshGraph(year: nil, priority: .userInitiated)
        }
        let sourcedModels = awaitValue {
            try await demoSource.modelReport(year: nil, priority: .userInitiated)
        }
        let sourcedHourly = awaitValue {
            try await demoSource.hourlyReport(
                year: nil, clients: nil, priority: .userInitiated)
        }
        let sourcedAgents = awaitValue {
            try await demoSource.agentsReport(
                year: nil, clients: nil, priority: .userInitiated)
        }
        let sourcedQuota = awaitValue { try await demoSource.agentUsage() }
        let sourcedTrace = awaitValue { try await demoSource.usageTrace(windowSecs: 600) }
        let sourcedRate = awaitValue { try await demoSource.tokensPerMin() }
        expect(
            sourcedPayload?.summary.totalTokens == demoPayload.summary.totalTokens
                && sourcedRefresh?.summary.totalCost == demoPayload.summary.totalCost,
            "demo source graph and refresh read synthetic data")
        expect(
            sourcedModels?.entries.isEmpty == false && sourcedHourly?.entries.isEmpty == false
                && sourcedAgents?.entries.isEmpty == false && sourcedQuota?.agents.isEmpty == false
                && sourcedTrace?.isEmpty == false && (sourcedRate ?? 0) > 0,
            "demo source serves every usage API")

        // FFI envelope/error contract (hermetic; no FFI allocation or live data).
        for (label, passed) in TBCore.envelopeContractChecks() {
            expect(passed, "envelope: \(label)")
        }
        // The one live FFI call this suite makes, and deliberately so: it is the
        // only way to prove `tb_quota_curve` links, matches its header signature,
        // and returns the documented error rather than a curve for a series this
        // process never bound. It reaches no credential, network, or history I/O
        // — the binding lookup fails first — so it stays hermetic. The smoke gate
        // asserts the same contract against the shipping binary.
        // Generation 0 reaches the binding lookup only because this process has
        // published nothing, which leaves the table's generation at 0 and skips
        // the expiry check. If a case above ever calls `agentUsage()` first, pass
        // its `publicationGeneration` here instead — otherwise this silently
        // starts testing the expiry branch. The exact message is what makes that
        // substitution visible rather than silent.
        do {
            let curve = try TBCore.quotaCurve(
                clientId: "__selftest__", accountKey: nil, windowKey: "__selftest__", generation: 0)
            expect(false, "unbound quota curve fails closed (got \(curve == nil ? "null" : "a curve"))")
        } catch let TBCoreError.bridge(message) {
            expect(
                message == "quota curve binding is unavailable",
                "unbound quota curve fails closed (got \"\(message)\")")
        } catch {
            expect(false, "unbound quota curve fails closed (got \(error))")
        }

        for (label, passed) in TBCore.quotaCurveContractChecks() {
            expect(passed, "quota curve: \(label)")
        }
        for (label, passed) in TBCore.filterParityContractChecks() {
            expect(passed, "filter parity: \(label)")
        }

        // MARK: - FLAT-HEATMAP (contract suite; decision table in issue #157)
        //
        // Six contracts, one table/grid each, replacing the append-only
        // per-round matrices: metric (C1), date/cutoff (C2), hit testing (C3),
        // scroll/hover lifecycle (C4), layout/ring bounds (C5), chart-view (C6).

        // C1 — metric semantics: independent tokens/cost maxima, a future day
        // excluded from both, a cost>0/tokens==0 day is data under Price only.
        let metricGrid = buildGrid(
            year: "2026",
            perDayMap: [
                "2026-03-01": PerDay(date: "2026-03-01", tokens: 1000, cost: 1, intensity: 1),
                "2026-03-08": PerDay(date: "2026-03-08", tokens: 10, cost: 100, intensity: 1),
                "2026-05-05": PerDay(date: "2026-05-05", tokens: 0, cost: 5, intensity: 1),
                "2026-08-15": PerDay(date: "2026-08-15", tokens: 999_999, cost: 9999, intensity: 1),
            ])
        let metricCutoff = "2026-07-29"
        let tokenMaxDay = metricGrid.cells.first { $0.date == "2026-03-01" }!
        let costMaxDay = metricGrid.cells.first { $0.date == "2026-03-08" }!
        let costOnlyDay = metricGrid.cells.first { $0.date == "2026-05-05" }!
        let maxTok = ContributionHeatmap.maxValue(metricGrid, metric: .tokens, cutoff: metricCutoff)
        let maxCost = ContributionHeatmap.maxValue(metricGrid, metric: .cost, cutoff: metricCutoff)
        expect(
            maxTok == 1000 && maxCost == 100
                && ContributionHeatmap.hasData(costOnlyDay, metric: .cost)
                && !ContributionHeatmap.hasData(costOnlyDay, metric: .tokens),
            "tokens/cost maxima are independent, exclude the future day past cutoff, and a cost-only day "
                + "is data under Price but not Tokens (never `cell.active`, which is tokens-only)")
        expect(
            HeatmapLayout.level(value: ContributionHeatmap.value(tokenMaxDay, metric: .tokens), max: maxTok) == 4
                && HeatmapLayout.level(value: ContributionHeatmap.value(costMaxDay, metric: .cost), max: maxCost) == 4
                && HeatmapLayout.level(value: ContributionHeatmap.value(costMaxDay, metric: .tokens), max: maxTok) < 4,
            "each metric's top day hits full intensity under its own max; the cost-max day isn't the tokens-max day")
        expect(
            HeatmapLayout.level(value: 75, max: 100) == 4 && HeatmapLayout.level(value: 50, max: 100) == 3
                && HeatmapLayout.level(value: 25, max: 100) == 2 && HeatmapLayout.level(value: 1, max: 100) == 1
                && HeatmapLayout.level(value: 0, max: 100) == 0 && HeatmapLayout.level(value: 10, max: 0) == 0,
            "five-level intensity thresholds match >=0.75/0.5/0.25/>0/else")
        // The grid must read the same, already client-filtered `stats.perDayMap`
        // UsageChartCard hands ContributionGraph3D, not the unfiltered total.
        let heatJSON = """
        {"meta":{"generatedAt":"now","version":"1","dateRange":{"start":"2026-01-01","end":"2026-01-01"}},
         "summary":{"totalTokens":0,"totalCost":0,"totalDays":1,"activeDays":1,"averagePerDay":0,
         "maxCostInSingleDay":0,"clients":["a","b"],"models":[]},"years":[],"contributions":[
         {"date":"2026-01-01","totals":{"tokens":0,"cost":0,"messages":0},"intensity":1,
         "tokenBreakdown":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0},"clients":[
         {"client":"a","modelId":"m","providerId":"p","cost":2,"messages":1,
          "tokens":{"input":100,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0}},
         {"client":"b","modelId":"m","providerId":"p","cost":3,"messages":1,
          "tokens":{"input":50,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0}}]}]}
        """
        let heatPayload = try! JSONDecoder().decode(UsagePayload.self, from: Data(heatJSON.utf8))
        let heatStats = UsageStats(payload: heatPayload, selectedClients: ["a"])
        let heatCellA = buildGrid(year: "2026", perDayMap: heatStats.perDayMap).cells.first { $0.date == "2026-01-01" }
        expect(
            heatCellA?.tokens == 100 && heatCellA?.cost == 2
                && (heatCellA?.tokens ?? 0) != 150 && (heatCellA?.cost ?? 0) != 5,
            "heatmap cell matches the filtered UsageStats value for the selected client, not the two-client total")
        // C2 — date/cutoff semantics: one grid per year-class proving
        // `cutoffDate`, renderable cells, the last renderable column (layout
        // width/month labels derive from this, not `grid.cols` — round 3), and
        // content width all agree.
        let cutoffToday = "2026-07-29"
        let currentGrid = buildGrid(year: "2026", perDayMap: [:])
        let currentCutoff = ContributionHeatmap.cutoffDate(year: "2026", today: cutoffToday)
        let currentTodayCell = currentGrid.cells.first { $0.date == cutoffToday }!
        // September, not August: July 29 and Aug 1 share a Sun-Sat column,
        // which would make the "later column" half vacuously true regardless.
        let currentSeptCell = currentGrid.cells.first { $0.date == "2026-09-01" }!
        let currentRenderable = currentGrid.cells
            .filter { ContributionHeatmap.isRenderable($0, cutoff: currentCutoff) }.map(\.date)
        let currentLastCol = ContributionHeatmap.lastRenderableCol(currentGrid, cutoff: currentCutoff)
        let currentLabelCols = ContributionHeatmap.monthLabelCols(grid: currentGrid, cutoff: currentCutoff).map(\.col)
        expect(
            currentCutoff == cutoffToday
                && currentRenderable.max() == cutoffToday && !currentRenderable.contains("2026-07-30")
                && currentLastCol == currentTodayCell.col && currentLastCol < currentSeptCell.col
                && currentLabelCols.contains(currentGrid.cells.first { $0.date == "2026-07-01" }!.col)
                && !currentLabelCols.contains(currentSeptCell.col),
            "the current year clips at today: cutoff, renderable cells, last renderable column, and month "
                + "labels all stop there, not at the end of the year or `grid.cols`")
        expect(
            ContributionHeatmap.cutoffDate(year: "2026", today: cutoffToday)
                != ContributionHeatmap.cutoffDate(year: "2026", today: "2026-07-30")
                && ContributionHeatmap.cutoffDate(year: "2026", today: "2026-07-30") == "2026-07-30",
            "consecutive calendar days in the current year produce distinct cutoffs, so a popover left open across midnight re-scrolls")
        let pastGrid = buildGrid(year: "2025", perDayMap: [:])
        let pastCutoff = ContributionHeatmap.cutoffDate(year: "2025", today: cutoffToday)
        let futureGrid = buildGrid(year: "2027", perDayMap: [:])
        let futureCutoff = ContributionHeatmap.cutoffDate(year: "2027", today: cutoffToday)
        let pastRenderableMax = pastGrid.cells.filter { ContributionHeatmap.isRenderable($0, cutoff: pastCutoff) }.map(\.date).max()
        expect(
            pastCutoff == "2025-12-31" && pastRenderableMax == "2025-12-31"
                && ContributionHeatmap.lastRenderableCol(pastGrid, cutoff: pastCutoff) == pastGrid.cols - 1,
            "a past year cuts off at, renders through, and spans the full grid width to its own Dec 31")
        expect(
            futureCutoff == cutoffToday
                && ContributionHeatmap.lastRenderableCol(futureGrid, cutoff: futureCutoff) == -1
                && ContributionHeatmap.contentWidth(visibleCols: 0, monthLabelCols: []) == 0
                && ContributionHeatmap.contentWidth(visibleCols: 3, monthLabelCols: []) > 0,
            "a future year clips at today too (not its own Dec 31), so it has zero renderable columns and "
                + "zero width — never negative width from `0 * step - gap`")
        // Calendar boundaries: `buildGrid` clamps to `max(53, …)`, and a leap
        // day steps correctly through pure ISODay arithmetic (no Calendar).
        let leapCell = buildGrid(
            year: "2028", perDayMap: ["2028-02-29": PerDay(date: "2028-02-29", tokens: 1, cost: 0, intensity: 1)])
            .cells.first { $0.date == "2028-02-29" }
        expect(
            buildGrid(year: "2026", perDayMap: [:]).cols == 53 && buildGrid(year: "2028", perDayMap: [:]).cols == 54
                && leapCell?.inYear == true && leapCell?.active == true,
            "2026 uses 53 columns, 2028 needs a 54th, and Feb 29 is a valid in-year active cell")
        // C3 — hit testing: `cellAt` is production's own point -> `grid.cells`
        // index resolver (static so SelfTest calls it directly, not a copy of
        // its coordinate math). One class each: in a cell, a horizontal gap, a
        // vertical gap, out of bounds — the last anchored to `cutoff`-derived
        // `visibleCols`, doubling as proof hit testing honors that cutoff too.
        struct HeatmapHitCase { let name: String; let point: CGPoint; let expected: Int? }
        let hitVisibleCols = currentLastCol + 1
        let hitCol = 2, hitRow = 3
        let hitCellRect = HeatmapLayout.rect(col: hitCol, row: hitRow)
        for c in [
            HeatmapHitCase(name: "inside a cell resolves to that cell", point: CGPoint(x: hitCellRect.minX + 1, y: hitCellRect.minY + 1), expected: hitCol * 7 + hitRow),
            HeatmapHitCase(name: "a horizontal gap point is a dead zone", point: CGPoint(x: hitCellRect.maxX + 1, y: hitCellRect.minY + 1), expected: nil),
            HeatmapHitCase(name: "a vertical gap point is a dead zone", point: CGPoint(x: hitCellRect.minX + 1, y: hitCellRect.maxY + 1), expected: nil),
            HeatmapHitCase(name: "past the last renderable column is out of bounds", point: CGPoint(x: HeatmapLayout.rect(col: hitVisibleCols, row: 0).minX + 1, y: HeatmapLayout.gridTop + 1), expected: nil),
            HeatmapHitCase(name: "leading cell edge is inside the cell", point: CGPoint(x: hitCellRect.minX, y: hitCellRect.minY), expected: hitCol * 7 + hitRow),
            HeatmapHitCase(name: "trailing cell edge is the gap, not the cell", point: CGPoint(x: hitCellRect.maxX, y: hitCellRect.minY + 1), expected: nil),
            HeatmapHitCase(name: "next cell leading edge resolves to the next column", point: CGPoint(x: HeatmapLayout.rect(col: hitCol + 1, row: hitRow).minX, y: hitCellRect.minY), expected: (hitCol + 1) * 7 + hitRow),
        ] {
            expect(
                ContributionHeatmap.cellAt(c.point, grid: currentGrid, visibleCols: hitVisibleCols) == c.expected,
                "hit test: \(c.name)")
        }
        // C4 — scroll/hover lifecycle. `shouldClearHoverOnOriginChange`: an
        // unchanged origin never clears (else hover could never be
        // established, since every geometry pass would zero it); a real move
        // does.
        struct HeatmapOriginCase { let name: String; let old: CGPoint; let new: CGPoint; let clears: Bool }
        for c in [
            HeatmapOriginCase(name: "unchanged origin", old: CGPoint(x: 10, y: 20), new: CGPoint(x: 10, y: 20), clears: false),
            HeatmapOriginCase(name: "horizontal move", old: CGPoint(x: 10, y: 20), new: CGPoint(x: 40, y: 20), clears: true),
            HeatmapOriginCase(name: "vertical move", old: CGPoint(x: 10, y: 20), new: CGPoint(x: 10, y: 5), clears: true),
        ] {
            expect(
                ContributionHeatmap.shouldClearHoverOnOriginChange(old: c.old, new: c.new) == c.clears,
                "hover lifecycle: \(c.name)")
        }
        // Round 8 (perf): `contentOrigin` is measured anchored to the OUTER
        // container, not `.global` — a shared ancestor's vertical scroll
        // shifts content's and container's `.global` by the SAME delta and
        // cancels out; a genuine horizontal scroll of this content does not.
        func relative(content: CGPoint, container: CGPoint) -> CGPoint {
            CGPoint(x: content.x - container.x, y: content.y - container.y)
        }
        let contentGlobal = CGPoint(x: 40, y: 320)
        let containerGlobal = CGPoint(x: 20, y: 300)
        let ancestorShift: CGFloat = 150
        let relBefore = relative(content: contentGlobal, container: containerGlobal)
        let relAfterAncestor = relative(
            content: CGPoint(x: contentGlobal.x, y: contentGlobal.y - ancestorShift),
            container: CGPoint(x: containerGlobal.x, y: containerGlobal.y - ancestorShift))
        let relAfterHScroll = relative(content: CGPoint(x: contentGlobal.x - 60, y: contentGlobal.y), container: containerGlobal)
        expect(
            relBefore == relAfterAncestor
                && !ContributionHeatmap.shouldClearHoverOnOriginChange(old: relBefore, new: relAfterAncestor)
                && relBefore != relAfterHScroll
                && ContributionHeatmap.shouldClearHoverOnOriginChange(old: relBefore, new: relAfterHScroll),
            "a shared ancestor translation leaves the container-relative origin unchanged and does not "
                + "clear hover, while a genuine horizontal content scroll changes it and does clear "
                + "(mutation: using only one side's global delta would fail the first half)")
        // The tooltip anchors on the outer container's origin, not a position
        // frozen inside the scrolled/clipped content.
        expect(
            ContributionHeatmap.tooltipAnchor(cellCenter: CGPoint(x: 50, y: 20), contentOrigin: .zero)
                == CGPoint(x: 50, y: 20)
                && ContributionHeatmap.tooltipAnchor(cellCenter: CGPoint(x: 50, y: 20), contentOrigin: CGPoint(x: -300, y: 0))
                == CGPoint(x: -250, y: 20),
            "the tooltip anchor tracks the content's origin in the outer container's coordinate space")
        // FIX 2: a horizontal wheel-redirect already parked at an edge reports
        // "not consumed" so the dashboard's own vertical ScrollView sees it.
        struct HeatmapWheelCase { let name: String; let originX: CGFloat; let step: CGFloat; let newX: CGFloat; let moved: Bool }
        for c in [
            HeatmapWheelCase(name: "trailing edge, further trailing", originX: 500, step: -20, newX: 500, moved: false),
            HeatmapWheelCase(name: "leading edge, further leading", originX: 0, step: 20, newX: 0, moved: false),
            HeatmapWheelCase(name: "a step that actually moves the origin", originX: 100, step: 20, newX: 80, moved: true),
        ] {
            let r = HorizontalWheelScroll.clampedScroll(originX: c.originX, step: c.step, maxX: 500)
            expect(r.newOriginX == c.newX && r.moved == c.moved, "wheel edge: \(c.name)")
        }
        // C5 — layout/ring bounds. The hover ring reaches `hoverRingReach`
        // beyond its cell on every side; `gridLeading`/`gridTop`/
        // `contentWidth`/`contentHeight` reserve exactly that room, so a ring
        // on any edge cell is never clipped. `ringGridHeight` mirrors
        // `ContributionHeatmap`'s private `gridHeight`, built only from
        // `HeatmapLayout`'s public constants.
        let ringVisibleCols = 6
        let ringContentWidth = ContributionHeatmap.contentWidth(visibleCols: ringVisibleCols, monthLabelCols: [])
        let ringContentHeight = HeatmapLayout.gridTop + 7 * HeatmapLayout.step - HeatmapLayout.gap + HeatmapLayout.hoverRingReach
        struct HeatmapRingCase { let name: String; let col: Int; let row: Int }
        for c in [
            HeatmapRingCase(name: "leading column", col: 0, row: 3),
            HeatmapRingCase(name: "trailing column", col: ringVisibleCols - 1, row: 3),
            HeatmapRingCase(name: "top row", col: 3, row: 0),
            HeatmapRingCase(name: "bottom row", col: 3, row: 6),
        ] {
            let rect = HeatmapLayout.rect(col: c.col, row: c.row)
            let reach = HeatmapLayout.hoverRingReach
            expect(
                rect.minX - reach >= 0 && rect.maxX + reach <= ringContentWidth
                    && rect.minY - reach >= 0 && rect.maxY + reach <= ringContentHeight,
                "ring bounds: \(c.name) fits within the content frame")
        }
        // FIX 2: contentWidth gains the trailing margin ONLY when the LAST
        // renderable column itself has a month label.
        let ringBaseWidth = ContributionHeatmap.contentWidth(visibleCols: 5, monthLabelCols: [])
        expect(
            ContributionHeatmap.contentWidth(visibleCols: 5, monthLabelCols: [(col: 4, label: "Sep")])
                == ringBaseWidth + HeatmapLayout.lastColumnLabelMargin
                && ContributionHeatmap.contentWidth(visibleCols: 5, monthLabelCols: [(col: 2, label: "Jul")]) == ringBaseWidth,
            "a month label on the last renderable column adds the named trailing margin; any other column adds none")
        // C6 — chart-view integration. Legacy persisted values still decode,
        // and the cmd-G cycle closes: Bars -> Heatmap -> 3D -> Bars.
        expect(
            ChartView(raw: "2d") == .bars && ChartView(raw: "3d") == .threeD && ChartView(raw: "heat") == .heatmap
                && ChartView(raw: "garbage") == .bars
                && ChartView.bars.next == .heatmap && ChartView.heatmap.next == .threeD
                && ChartView.threeD.next == .bars && ChartView.bars.next.next.next == .bars,
            "legacy '2d'/'3d' decode unchanged, 'heat' maps to Heatmap, an unknown value falls back to "
                + "Bars, and cmd-G cycles Bars -> Heatmap -> 3D -> Bars, three presses returning to start")
        // MARK: - Tray frame aspect (append-only section)

        // `anim-parrot` art is 48x36. `loadFrames` used to assign 18x18
        // unconditionally, stretching it vertically wherever `NSImage.size`
        // is what renders — `button.image`, i.e. static tray mode and the
        // Settings preview. The animation never showed it, because
        // `rasterizedFrame` fits by the representation's PIXEL size and
        // ignores the logical size, so the two paths disagreed about the
        // same asset. These assert the two now agree.
        func trayArt(_ directory: String) -> NSImage? {
            Bundle.tokenBarResources.url(
                forResource: "frame-00", withExtension: "png", subdirectory: directory
            ).flatMap(NSImage.init(contentsOf:))
        }
        let parrotArt = trayArt("anim-parrot")
        let catArt = trayArt("anim-cat2")
        expect(parrotArt != nil && catArt != nil, "tray frame art loads")

        if let parrot = parrotArt.map({ art -> NSImage in
            art.size = TrayAnimator.barSize(for: art)
            return art
        }) {
            // 48x36 fitted into 18x18 is 18x13.5, not 18x18.
            expect(
                abs(parrot.size.width - 18) < 0.01 && abs(parrot.size.height - 13.5) < 0.01,
                "non-square tray art keeps its aspect ratio (mutation: assigning the 18x18 box "
                    + "unconditionally, as before, makes this 18x18 and fails)")
            // The distortion this guards against: a stretched frame reports a
            // 1:1 logical box for art that is 4:3.
            expect(
                abs(parrot.size.width / parrot.size.height - 48.0 / 36.0) < 0.01,
                "the logical box matches the art's own 4:3 ratio")
        }
        if let cat = catArt {
            // Square art is unchanged by the fix — a no-trigger guard case.
            let size = TrayAnimator.barSize(for: cat)
            expect(
                abs(size.width - 18) < 0.01 && abs(size.height - 18) < 0.01,
                "square tray art still fills the full 18x18 box")
        }
        // The raster path must stay driven by pixels, not by the logical size
        // we just changed — otherwise this fix would silently resize the
        // animation too.
        //
        // `rasterizedFrameMetricsForTesting` is declared `#if DEBUG`, and
        // `scripts/bundle.sh` builds with `swift build -c release`, so an
        // unguarded call here compiles under `make build`/`make selftest`/CI
        // — all debug — and then fails the release build at tag time. The
        // older raster assertions above sit in their own `#if DEBUG` block
        // for exactly this reason.
#if DEBUG
        if let parrot = parrotArt {
            let raster = StatusItemAnimationSurface.rasterizedFrameMetricsForTesting(parrot, scale: 2)
            expect(
                raster?.pixelSize == CGSize(width: 36, height: 36),
                "the animation raster is still a square 18pt box at 2x, unaffected by the logical size")
        }
#endif

        // MARK: - Discord Rich Presence payload (DISCORD-PRESENCE M1)
        //
        // Published to a third party on a public profile: privacy regression
        // guards, not display tests. Every assertion goes through
        // `DiscordPresence.payload(...)` — the published bytes.
        func dpGraph(_ json: String) -> UsagePayload {
            try! JSONDecoder().decode(UsagePayload.self, from: Data(json.utf8))
        }
        func dpDay(_ date: String, _ tokens: Int64, _ cost: Double, _ stripes: String) -> String {
            """
            {"date":"\(date)","totals":{"tokens":\(tokens),"cost":\(cost),"messages":1},
             "intensity":1,
             "tokenBreakdown":{"input":\(tokens),"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0},
             "clients":[\(stripes)]}
            """
        }
        func dpStripe(
            _ client: String, _ tokens: Int64, _ cost: Double,
            model: String = "m", provider: String = "p"
        ) -> String {
            """
            {"client":"\(client)","modelId":"\(model)","providerId":"\(provider)",
             "cost":\(cost),"messages":1,
             "tokens":{"input":\(tokens),"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0}}
            """
        }
        func dpPayload(_ days: String, summaryTokens: Int64 = 0, summaryCost: Double = 0) -> String {
            """
            {"meta":{"generatedAt":"now","version":"1",
                     "dateRange":{"start":"2026-08-04","end":"2026-08-04"}},
             "summary":{"totalTokens":\(summaryTokens),"totalCost":\(summaryCost),"totalDays":1,
                        "activeDays":1,"averagePerDay":0,"maxCostInSingleDay":0,
                        "clients":[],"models":[]},
             "years":[],"contributions":[\(days)]}
            """
        }
        let dpToday = "2026-08-04"
        /// The default composition, which reproduces exactly what was published
        /// before composition existed — so every assertion written against the
        /// old single shape keeps testing the same bytes.
        let dpAllComponents = DiscordPresence.defaultComponents

        // Hidden clients are excluded from the published totals. The day-level
        // `totals` (1.2M) differs from the visible-only sum (200K) on purpose: a
        // builder reading `totals`/`tokenBreakdown` cannot subtract a client.
        let dpHiddenGraph = dpGraph(dpPayload(dpDay(
            dpToday, 1_200_000, 6.0,
            dpStripe("claude", 1_000_000, 5.0) + "," + dpStripe("codex", 200_000, 1.0))))
        let dpHidden = DiscordPresence.payload(
            graph: dpHiddenGraph, hidden: ["claude"], today: dpToday, costStyle: .banded, components: dpAllComponents)
        expect(
            dpHidden?.details == "200K tokens today"
                && dpHidden.map { !$0.fields.values.joined().contains("1.2M") } == true,
            "published tokens are the visible-only sum, and the mixed day-level total reaches "
                + "no field (mutation: reading the day-level totals publishes 1.2M)")
        expect(dpHidden?.state.contains("Codex") == true
            && dpHidden?.state.contains("Claude Code") == false,
            "the top client skips the hidden client (mutation: dropping the hidden filter from "
                + "the fold publishes Claude Code)")

        // Outbound allowlist, at the PRODUCER. The busiest stripe by far is an
        // UNREGISTERED id whose suffix comes from a local config file; a
        // registered client sits underneath it with a fifth of the tokens, and
        // a second unregistered id is hidden as well. Under a positive filter
        // the secret contributes nothing at all — not a neutral label, not a
        // token, not a cent — so the registered client is what publishes.
        //
        // This is the fixture the complement design fails: `hidden ∪ (allIds −
        // {selected})` cannot subtract an id it has never heard of, so
        // `cc-mirror/SECRET_VARIANT` would survive and, being the largest,
        // would take the label.
        let dpSecretGraph = dpGraph(dpPayload(dpDay(
            dpToday, 1_400_000, 12.0,
            dpStripe("cc-mirror/SECRET_VARIANT", 900_000, 9.0,
                model: "SECRET_MODEL", provider: "SECRET_PROVIDER")
                + "," + dpStripe("claude", 200_000, 1.0)
                + "," + dpStripe("SECRET_HIDDEN", 300_000, 2.0,
                    model: "SECRET_MODEL2", provider: "SECRET_PROVIDER2"))))
        let dpSecret = DiscordPresence.payload(
            graph: dpSecretGraph, hidden: ["SECRET_HIDDEN"], today: dpToday, costStyle: .banded, components: dpAllComponents)
        let dpSecretText = dpSecret.map { Array($0.fields.values).joined(separator: "|") } ?? ""
        expect(
            dpSecret?.details == "200K tokens today"
                && dpSecret?.state.hasPrefix("Claude Code") == true
                && !dpSecretText.contains("SECRET_"),
            "an unregistered id reaches neither the figures nor the label — the registered "
                + "client publishes its own 200K, not the 1.1M the day holds "
                + "(mutation: a complement filter cannot subtract an id it has never heard of, "
                + "so cc-mirror/SECRET_VARIANT survives and takes the label)")
        expect(!dpSecretText.contains("/"),
            "no path-like segment is published (mutation: adding any raw-id or path field to "
                + "Payload.fields fails here)")
        // Pinned by KEY on `fields`, which is what the transport serializes.
        // Asserting over anything else reopens the gap that let a computed
        // `startTimestamp` through.
        expect(dpSecret.map { Set($0.fields.keys) } == ["details", "state", "largeImageKey"],
            "exactly three named fields are published (mutation: adding a key to Payload.fields, "
                + "or dropping one, fails here)")
        // The neutral label is now unreachable from `payload()` — kept in
        // `safeClientLabel` as defence, asserted here as dead. A graph of only
        // unregistered ids publishes nothing rather than "an AI tool".
        expect(
            DiscordPresence.payload(
                graph: dpGraph(dpPayload(dpDay(
                    dpToday, 500_000, 5.0,
                    dpStripe("cc-mirror/one", 300_000, 3.0) + ","
                        + dpStripe("brand-new-agent", 200_000, 2.0)))),
                hidden: [], today: dpToday, costStyle: .banded,
                components: dpAllComponents) == nil,
            "a graph holding only unregistered ids publishes nothing at all, so the neutral "
                + "label cannot reach the wire (mutation: filtering only at the label leaves "
                + "their tokens and cost in the figures under `an AI tool`)")

        // Published granularity: neither the raw token count nor cent-precision
        // cost may survive.
        let dpGrainGraph = dpGraph(dpPayload(dpDay(
            dpToday, 1_234_567, 7.89, dpStripe("claude", 1_234_567, 7.89))))
        let dpGrain = DiscordPresence.payload(
            graph: dpGrainGraph, hidden: [], today: dpToday, costStyle: .banded, components: dpAllComponents)
        let dpGrainText = dpGrain.map { Array($0.fields.values).joined(separator: "|") } ?? ""
        expect(dpGrain?.details == "1.2M tokens today" && !dpGrainText.contains("1234567"),
            "tokens publish as a compact string and the raw count reaches no field "
                + "(mutation: String(todayTokens) fails here)")
        expect(dpGrain?.state.hasSuffix("<$10") == true && !dpGrainText.contains("7.89"),
            "cost publishes as a coarse band and cents reach no field "
                + "(mutation: Format.usd fails here)")

        // Equality on every boundary, non-finite included: those must land in
        // the LOWEST band. "Returns a finite band" passes on an implementation
        // that hands a zero-cost day to the top one.
        let dpBands: [(Double, String)] = [
            (.nan, "<$10"), (.infinity, "<$10"), (-.infinity, "<$10"),
            (-1, "<$10"), (0, "<$10"), (9.99, "<$10"),
            (10, "$10-50"), (49.99, "$10-50"),
            (50, "$50-100"), (99.99, "$50-100"),
            (100, "$100-250"), (249.99, "$100-250"),
            (250, "$250-500"), (499.99, "$250-500"),
            (500, "$500-1000"), (999.99, "$500-1000"),
            (1000, "$1000+"), (1e6, "$1000+"),
        ]
        for (cost, band) in dpBands {
            expect(DiscordPresence.costBucket(cost) == band,
                "cost \(cost) bands as \(band) "
                    + "(mutation: shifting a bound, flipping one to exclusive, or dropping the "
                    + "isFinite guard, fails here)")
        }

        // Whole-dollar mode is a total function. `Int(.infinity)` and
        // `Int(1e308)` trap rather than fail, and a trap reaches no verdict at
        // all, so the assertion must be reachable past the conversion.
        let dpDollars: [(Double, String)] = [
            (.nan, "$0"), (.infinity, "$0"), (-.infinity, "$0"),
            (-5, "$0"), (0, "$0"), (0.4, "$0"), (0.5, "$1"),
            (7.89, "$8"), (1500.2, "$1500"),
            (999_999.4, "$999999"),
            // The boundary the cap is judged at. Before the rounding moved
            // ahead of the comparison these rendered a bare `$1000000`.
            (999_999.5, "$1000000+"), (1e6.nextDown, "$1000000+"),
            (1e6, "$1000000+"), (1e308, "$1000000+"),
        ]
        for (cost, text) in dpDollars {
            expect(DiscordPresence.wholeDollars(cost) == text,
                "cost \(cost) renders as \(text) "
                    + "(mutation: `\"$\" + Int(max(0, cost).rounded())` traps here rather than "
                    + "failing, because max() folds only NaN and -infinity)")
        }

        // The two cost modes must DISAGREE on one fixture, asserted as equality
        // on both: "banded has no 7.89" and "dollars has no '.'" are true of
        // BOTH modes, so a build ignoring the parameter passed them.
        let dpModeGraph = dpGraph(dpPayload(dpDay(
            dpToday, 12_000, 7.89, dpStripe("claude", 12_000, 7.89))))
        let dpBanded = DiscordPresence.payload(
            graph: dpModeGraph, hidden: [], today: dpToday, costStyle: .banded, components: dpAllComponents)
        let dpExact = DiscordPresence.payload(
            graph: dpModeGraph, hidden: [], today: dpToday, costStyle: .wholeDollars, components: dpAllComponents)
        expect(
            dpBanded?.state == "Claude Code · <$10" && dpExact?.state == "Claude Code · $8"
                && dpBanded.map { !$0.fields.values.joined().contains("7.89") } == true
                && dpExact.map { !$0.fields.values.joined().contains("7.89") } == true,
            "the two cost modes render the same fixture differently and neither publishes cents "
                + "(mutation: ignoring costStyle and always rendering one of them fails here)")

        // Which cost-mode change retires earlier work. Coarsening the figure
        // makes anything computed before it stale — writing one of those after
        // the change puts the precise figure back on the profile. Adding
        // precision invalidates nothing.
        expect(AppDelegate.costStyleChange(previous: .wholeDollars, current: .banded) == .reducing,
            "turning the figure back into a range retires work computed before it "
                + "(mutation: returning .none lets the precise figure be written afterwards)")
        expect(AppDelegate.costStyleChange(previous: .banded, current: .wholeDollars)
            == .increasing,
            "adding precision invalidates nothing computed before it")
        expect(AppDelegate.costStyleChange(previous: .banded, current: .banded) == .none,
            "no cost-mode change is neither")
        expect(DiscordIPC.VisibilityChange.increasing.combined(with: .reducing) == .reducing
            && DiscordIPC.VisibilityChange.reducing.combined(with: .increasing) == .reducing
            && DiscordIPC.VisibilityChange.none.combined(with: .increasing) == .increasing
            && DiscordIPC.VisibilityChange.none.combined(with: .none) == .none,
            "a turn that both hides and adds precision is a reduction, order-independently, and "
                + "combining invents no change neither side reported")

        // The two inputs where the SHARED tray formatter publishes an exact
        // figure: `Format.compactTokens` returns `String(count)` below 1000 and
        // for negatives. Negative totals are reachable — the aggregator clamps
        // per lane, so the re-summed slow path can go negative.
        let dpSmall = DiscordPresence.payload(
            graph: dpGraph(dpPayload(dpDay(dpToday, 850, 0.4, dpStripe("claude", 850, 0.4)))),
            hidden: [], today: dpToday, costStyle: .banded, components: dpAllComponents)
        let dpNegative = DiscordPresence.payload(
            graph: dpGraph(dpPayload(dpDay(
                dpToday, 0, 1.0,
                dpStripe("claude", -1_234_567, 0.0) + "," + dpStripe("codex", 1_000, 1.0)))),
            hidden: ["nobody"], today: dpToday, costStyle: .banded, components: dpAllComponents)
        expect(
            dpSmall?.details == "<1K tokens today"
                && dpNegative.map { !$0.fields.values.joined().contains("1233567") } ?? true,
            "a light day publishes a band and a negative total publishes no signed digits "
                + "(mutation: calling Format.compactTokens directly publishes \"850\")")

        // Three inputs that publish nothing: an idle day (no "machine is on"
        // beacon), a day absent from the graph, and an overflowed cost — JSON
        // cannot express NaN, but two finite stripes sum to +inf.
        let dpSilent: [(String, DiscordPresence.Payload?)] = [
            ("zero usage", DiscordPresence.payload(
                graph: dpGraph(dpPayload(dpDay(dpToday, 0, 0, dpStripe("claude", 0, 0)))),
                hidden: [], today: dpToday, costStyle: .banded, components: dpAllComponents)),
            ("a day with no contribution", DiscordPresence.payload(
                graph: dpGrainGraph, hidden: [], today: "2099-01-01", costStyle: .banded, components: dpAllComponents)),
            ("an overflowed cost", DiscordPresence.payload(
                graph: dpGraph(dpPayload(dpDay(
                    dpToday, 10, 1e308,
                    dpStripe("claude", 10, 1e308) + "," + dpStripe("codex", 10, 1e308)))),
                hidden: ["nobody"], today: dpToday, costStyle: .banded, components: dpAllComponents)),
        ]
        for (label, payload) in dpSilent {
            expect(payload == nil,
                "\(label) publishes nothing (mutation: dropping the zero guard publishes an idle "
                    + "beacon; dropping the isFinite guard publishes a band for a meaningless "
                    + "value)")
        }

        // The top client is the busiest CLIENT, not the biggest stripe:
        // `clients` holds per client×model×provider stripes, so claude's 30+30
        // must beat codex's single 50.
        let dpFoldGraph = dpGraph(dpPayload(dpDay(
            dpToday, 110, 1.1,
            dpStripe("claude", 30, 0.3, model: "m1") + ","
                + dpStripe("claude", 30, 0.3, model: "m2") + ","
                + dpStripe("codex", 50, 0.5, model: "m1"))))
        let dpFold = DiscordPresence.payload(
            graph: dpFoldGraph, hidden: [], today: dpToday, costStyle: .banded, components: dpAllComponents)
        expect(dpFold?.state.hasPrefix("Claude Code") == true,
            "the top client folds stripes per client first (mutation: max over raw stripes picks "
                + "Codex's single 50 over Claude Code's 30+30)")

        // Deterministic tie-break: tokens, then higher cost, then the smallest
        // id. The six-way tie is fed in both orders because an unsorted key walk
        // is only probabilistically wrong — Swift seeds Dictionary hashing per
        // process, so it must get lucky twice.
        let dpTieIds = ["zed", "warp", "goose", "droid", "codex", "amp"]
        let dpTies: [(String, String, String)] = [
            ("equal tokens break to the higher cost",
             dpStripe("amp", 100, 1.0) + "," + dpStripe("zed", 100, 2.0), "Zed · <$10"),
            ("a full tie breaks to the lexicographically smallest id",
             dpTieIds.map { dpStripe($0, 100, 1.0) }.joined(separator: ","), "Amp · <$10"),
            ("the tie-break ignores the order the stripes arrive in",
             dpTieIds.reversed().map { dpStripe($0, 100, 1.0) }.joined(separator: ","),
             "Amp · <$10"),
        ]
        for (label, stripes, expected) in dpTies {
            expect(
                DiscordPresence.payload(
                    graph: dpGraph(dpPayload(dpDay(dpToday, 600, 6.0, stripes))),
                    hidden: [], today: dpToday, costStyle: .banded, components: dpAllComponents)?.state == expected,
                "\(label) (mutation: `>=` in the fold comparison, or an unsorted key walk)")
        }

        // Composition. The hostile fixture runs with the client component
        // selected and NOTHING else, which is the whole point: every privacy
        // value-scan above runs against whichever shape its fixture picked, so
        // a selection of tokens + cost would satisfy "a `cc-mirror/SECRET` id
        // cannot escape" without ever executing the allowlist path that
        // assertion exists to guard. The client label is the only component
        // built from a user-controlled string, so this is the case that closes
        // it — not sixteen fixtures, one per subset.
        let dpClientOnly = DiscordPresence.payload(
            graph: dpSecretGraph, hidden: ["SECRET_HIDDEN"], today: dpToday,
            costStyle: .banded, components: [.client])
        expect(
            dpClientOnly?.details == "Claude Code"
                && dpClientOnly.map { Array($0.fields.values).joined().contains("SECRET_") } == false
                && dpClientOnly?.fields.keys.sorted() == ["details", "largeImageKey"],
            "one selected component becomes `details`, an unregistered id reaches no field, and "
                + "no empty `state` key reaches the wire "
                + "(mutation: composing without the allowlist gate leaks the id; publishing "
                + "`state` unconditionally adds a blank field)")
        // The composition is a user-controlled string flowing toward a public
        // profile — the same shape as the `cc-mirror/<name>` id. Unknown tokens
        // must produce nothing and never echo themselves, and the canonical
        // write-back is what keeps a reordering from reaching the value gate as
        // a change.
        let dpMixedComponents = DiscordPresence.parseComponents("tokens, SECRET_COMPONENT ,cost")
        expect(
            dpMixedComponents == [.tokens, .cost]
                && DiscordPresence.rawComponents([.cost, .tokens]) == "tokens,cost"
                && DiscordPresence.payload(
                    graph: dpSecretGraph, hidden: [], today: dpToday, costStyle: .banded,
                    components: dpMixedComponents)
                    .map { Array($0.fields.values).joined().contains("SECRET_COMPONENT") } == false,
            "an unknown component token is dropped rather than echoed, and the canonical form is "
                + "written in a fixed order (mutation: a fallback branch passing the raw token "
                + "through publishes it)")
        expect(
            DiscordPresence.payload(
                graph: dpGrainGraph, hidden: [], today: dpToday, costStyle: .banded,
                components: []) == nil
                && DiscordPresence.parseComponents("SECRET_COMPONENT").isEmpty,
            "an empty composition publishes nothing at all, and a preference of only unknown "
                + "tokens is empty (mutation: an activity with no components still carries the "
                + "app name, image and button, and still refreshes — a working-hours beacon "
                + "with no usage content to justify it)")
        // Unticking a component takes something off the profile, so it must not
        // wait out the publish floor. Same subset rule as the hidden set with
        // the arguments swapped, including the swap case a size test gets wrong.
        expect(
            AppDelegate.componentsChange(previous: [.tokens, .cost], current: [.tokens])
                == .reducing
                && AppDelegate.componentsChange(previous: [.tokens], current: [.tokens, .cost])
                    == .increasing
                && AppDelegate.componentsChange(previous: [.tokens], current: [.cost]) == .reducing
                && AppDelegate.componentsChange(previous: [.tokens], current: [.tokens]) == .none,
            "unticking a component is a reduction, ticking one is throttled, and swapping one for "
                + "another is a reduction (mutation: a size test calls the swap no change and "
                + "leaves the unticked component on the profile for the rest of the floor)")
        // A cost-style change cannot alter a byte when cost is not published,
        // and classifying it anyway is not just noise: `.reducing` carries a
        // stale, so calling it a change would retire work that is still valid.
        expect(
            AppDelegate.costStyleChange(
                previous: .wholeDollars, current: .banded, publishedInBoth: false) == .none
                && AppDelegate.costStyleChange(
                    previous: .banded, current: .wholeDollars, publishedInBoth: false) == .none
                && AppDelegate.costStyleChange(
                    previous: .wholeDollars, current: .banded, publishedInBoth: true) == .reducing,
            "a cost-style change is classified only when cost is published on both sides of it "
                + "(mutation: classifying it unconditionally retires work that is still valid)")
        // Absent and malformed are different answers. An absent key is an
        // upgrade and keeps every component; a present non-string is a
        // malformed write and gets what a string of only unknown tokens gets.
        let dpCompSuite = "TokenBar.SelfTest.DiscordComponents"
        if let dpCompDefaults = UserDefaults(suiteName: dpCompSuite) {
            defer { UserDefaults.standard.removePersistentDomain(forName: dpCompSuite) }
            let dpAbsent = DiscordPresence.components(defaults: dpCompDefaults)
            dpCompDefaults.set(1, forKey: DiscordPresence.componentsKey)
            let dpWrongType = DiscordPresence.components(defaults: dpCompDefaults)
            dpCompDefaults.set("client", forKey: DiscordPresence.componentsKey)
            let dpGoodString = DiscordPresence.components(defaults: dpCompDefaults)
            expect(
                dpAbsent == DiscordPresence.defaultComponents && dpWrongType.isEmpty
                    && dpGoodString == [.client],
                "an absent composition key keeps every component while a present non-string "
                    + "publishes nothing (mutation: one `as? String` cast for both makes a "
                    + "malformed `defaults write` publish all three the user never selected)")
        } else {
            expect(false, "the isolated composition suite could not be created")
        }
        // The cost validity check belongs to the cost component. `costBucket`
        // maps a non-finite value to the LOWEST band, so publishing one would
        // assert something false — but a tokens-only selection loses its whole
        // presence to an overflow that was never going to reach the wire.
        let dpOverflowGraph = dpGraph(dpPayload(dpDay(
            dpToday, 10, 1e308,
            dpStripe("claude", 10, 1e308) + "," + dpStripe("codex", 10, 1e308))))
        expect(
            DiscordPresence.payload(
                graph: dpOverflowGraph, hidden: ["nobody"], today: dpToday,
                costStyle: .banded, components: [.tokens])?.details == "<1K tokens today"
                && DiscordPresence.payload(
                    graph: dpOverflowGraph, hidden: ["nobody"], today: dpToday,
                    costStyle: .banded, components: [.tokens, .cost]) == nil,
            "an overflowed cost blocks only a composition that publishes cost "
                + "(mutation: guarding before the composition is read silently blanks the "
                + "presence of a tokens-only selection)")

        // Agent selection. Survival is `id ∈ only && id ∉ hidden`, and BOTH
        // conditions holding is what makes "a selection cannot defeat hiding"
        // structural rather than a guard someone has to remember.
        expect(
            DiscordPresence.payload(
                graph: dpSecretGraph, hidden: ["claude"], today: dpToday, costStyle: .banded,
                components: dpAllComponents, selection: .only("claude")) == nil,
            "selecting a client that is also hidden publishes nothing (mutation: applying the "
                + "selection instead of intersecting it lets a selection override a hide)")
        // The same hostile graph with a REGISTERED client selected. The secret
        // is larger than the selection, so a filter that lets it through would
        // be visible in the figures as well as the label.
        let dpSelected = DiscordPresence.payload(
            graph: dpSecretGraph, hidden: [], today: dpToday, costStyle: .banded,
            components: dpAllComponents, selection: .only("claude"))
        expect(
            dpSelected?.details == "200K tokens today"
                && dpSelected?.state.hasPrefix("Claude Code") == true
                && dpSelected.map { Array($0.fields.values).joined().contains("SECRET") } == false,
            "a selected client publishes only its own figures, with an unregistered stripe "
                + "excluded from the totals (mutation: a complement filter cannot subtract "
                + "cc-mirror/SECRET_VARIANT, so it is aggregated in and its 900K is published)")
        expect(
            DiscordPresence.payload(
                graph: dpSecretGraph, hidden: [], today: dpToday, costStyle: .banded,
                components: dpAllComponents, selection: .only("renamed-since-release")) == nil,
            "a selection the registry does not know publishes nothing (mutation: falling back to "
                + "most-used silently widens `one agent` to `all of them` on a rename)")
        // The re-summed slow path can go negative, and it is reachable here
        // because a positive filter never takes the fast path.
        expect(
            DiscordPresence.payload(
                graph: dpGraph(dpPayload(dpDay(
                    dpToday, 0, 1.0,
                    dpStripe("claude", -1_234_567, 0.0) + "," + dpStripe("codex", 1_000, 1.0)))),
                hidden: [], today: dpToday, costStyle: .banded,
                components: dpAllComponents, selection: .only("codex"))?.state
                .hasSuffix("<$10") == true,
            "a negative stripe elsewhere still leaves the selected client a finite band")
        // A selection change replaces what is published, so anything computed
        // for the previous selection is stale.
        expect(
            AppDelegate.selectionChange(
                previous: .mostUsed, current: .only("claude"), hidden: []) == .retiring
                && AppDelegate.selectionChange(
                    previous: .only("claude"), current: .only("codex"), hidden: []) == .retiring
                && AppDelegate.selectionChange(
                    previous: .only("claude"), current: .only("claude"), hidden: []) == .none
                && AppDelegate.selectionChange(
                    previous: .only("claude"), current: .only("codex"),
                    hidden: ["claude", "codex"]) == .none,
            "a selection change is `.retiring`, and switching between two clients that are both "
                + "hidden is no change at all (mutation: classifying it `.reducing` grants an "
                + "work computed for a selection that is still current; comparing raw "
                + "selections republishes when nothing published actually moved)")
        // A hidden-set change is judged against the clients published at EITHER
        // endpoint. With one agent named, hiding an unrelated client cannot
        // move a published byte; hiding the selected one is still a reduction;
        // and a turn that BOTH switches selection and hides the outgoing client
        // is a reduction too — that one is only visible if the previous
        // selection is consulted, and it is the case coalescing produces.
        func dpVis(
            _ previousHidden: String, _ hidden: String,
            _ previousSelection: DiscordPresence.ClientSelection = .mostUsed,
            _ selection: DiscordPresence.ClientSelection = .mostUsed
        ) -> DiscordIPC.VisibilityChange {
            AppDelegate.visibilityChange(
                previousHiddenRaw: previousHidden, hiddenRaw: hidden,
                previousSelection: previousSelection, selection: selection)
        }
        expect(
            dpVis("", "amp", .only("claude"), .only("claude")) == .none
                && dpVis("amp", "", .only("claude"), .only("claude")) == .none
                && dpVis("", "claude", .only("claude"), .only("claude")) == .reducing
                && dpVis("", "amp") == .reducing
                && dpVis("amp", "") == .increasing
                && dpVis("", "claude", .only("claude"), .only("codex")) == .reducing,
            "hiding a client the selection does not publish is no change, hiding the selected one "
                + "is a reduction, and switching selection while hiding the outgoing client is "
                + "still a reduction (mutation: judging the hidden delta under the CURRENT "
                + "selection alone reports no change and leaves the just-hidden client on the "
                + "profile for the rest of the floor)")

        // `.mostUsed` is not "every registered client" — it is whichever of
        // them actually has usage today. Hiding a registered client with no
        // stripe removes nothing from the profile, and while Discord is offline
        // that grant cannot be spent, so a later payload carrying genuinely new
        // activity would inherit it and go out inside the floor.
        expect(
            AppDelegate.visibilityChange(
                previousHiddenRaw: "", hiddenRaw: "amp",
                contributors: ["claude", "codex"]) == .none
                && AppDelegate.visibilityChange(
                    previousHiddenRaw: "", hiddenRaw: "claude",
                    contributors: ["claude", "codex"]) == .reducing
                && AppDelegate.effectivePublished(
                    selection: .mostUsed, hidden: [], contributors: ["claude"]) == ["claude"],
            "hiding a registered client with no usage today is no change, while hiding one that "
                + "contributed is a reduction (mutation: expanding `.mostUsed` to the whole "
                + "registry retires work for a hide that removed nothing published)")

        // Absent, malformed and named are three answers. One `as? String` cast
        // would send a key holding a number down the ABSENT branch and widen a
        // one-client selection to every registered client.
        let dpSelSuite = "TokenBar.SelfTest.DiscordSelection"
        if let dpSelDefaults = UserDefaults(suiteName: dpSelSuite) {
            defer { UserDefaults.standard.removePersistentDomain(forName: dpSelSuite) }
            let dpSelAbsent = DiscordPresence.selection(defaults: dpSelDefaults)
            dpSelDefaults.set(1, forKey: DiscordPresence.selectionKey)
            let dpSelWrong = DiscordPresence.selection(defaults: dpSelDefaults)
            dpSelDefaults.set("claude", forKey: DiscordPresence.selectionKey)
            let dpSelNamed = DiscordPresence.selection(defaults: dpSelDefaults)
            expect(
                dpSelAbsent == .mostUsed && dpSelWrong == .malformed && dpSelNamed == .only("claude")
                    && DiscordPresence.payload(
                        graph: dpSecretGraph, hidden: [], today: dpToday, costStyle: .banded,
                        components: dpAllComponents, selection: .malformed) == nil,
                "an absent selection key is most-used, a present non-string publishes nothing, and "
                    + "a named one selects (mutation: one `as? String` cast for both widens a "
                    + "malformed one-client selection to every registered client)")
        } else {
            expect(false, "the isolated selection suite could not be created")
        }
        // The picker's universe is derived from what `payload` will publish, not
        // from the registry. Every row it offers that the payload path rejects
        // is a choice the user makes and nothing happens — the same silent
        // nothing the zero-usage and empty-component guards exist to prevent,
        // arriving through Settings instead of through the wire.
        let dpPickVisible = DiscordPresence.selectableClients(
            present: ["claude", "codex", "cc-mirror/foo"], hiddenRaw: "codex", orderRaw: "",
            selection: .mostUsed)
        let dpPickUnloaded = DiscordPresence.selectableClients(
            present: nil, hiddenRaw: "claude", orderRaw: "", selection: .mostUsed)
        // A scan that finished and found nothing is a real answer, not a
        // not-loaded one: the honest picker offers only "whichever you used
        // most". Collapsing it into the unloaded branch hands a user with no
        // usage the whole registry back.
        let dpPickNoUsage = DiscordPresence.selectableClients(
            present: [], hiddenRaw: "", orderRaw: "", selection: .mostUsed)
        // An id the registry no longer knows is one `payload` rejects outright,
        // so listing it would tick a row that can never publish.
        let dpPickUnknown = DiscordPresence.selectableClients(
            present: ["claude"], hiddenRaw: "", orderRaw: "",
            selection: .only("not-a-registered-client"))
        let dpPickStale = DiscordPresence.selectableClients(
            present: ["claude"], hiddenRaw: "codex", orderRaw: "", selection: .only("codex"))
        // Every other fixture passes an empty order, which leaves "in the user's
        // saved tab order" unfalsifiable — the picker could ignore `orderRaw`
        // entirely and still pass them.
        let dpPickOrdered = DiscordPresence.selectableClients(
            present: ["claude", "codex"], hiddenRaw: "", orderRaw: "codex,claude",
            selection: .mostUsed)
        expect(
            dpPickVisible == ["claude"]
                && dpPickUnloaded.count > 1 && !dpPickUnloaded.contains("claude")
                && dpPickNoUsage.isEmpty
                && dpPickStale.contains("codex") && dpPickStale.contains("claude")
                && dpPickUnknown == ["claude"]
                && dpPickOrdered == ["codex", "claude"],
            "the agent picker offers only registered, unhidden clients with usage, falls back to "
                + "the registry before the first scan lands, and keeps a stored selection listed "
                + "after it stops qualifying (mutation: dropping the registry filter offers "
                + "`cc-mirror/foo`, which `payload` rejects; dropping the hidden filter offers a "
                + "client `trayTotals` subtracts; dropping the fallback empties the picker while "
                + "the dashboard is still loading; treating a finished empty scan as unloaded "
                + "hands the whole registry to a user with no usage; dropping the stale append "
                + "ticks nothing while the preference still names that agent; appending an "
                + "unregistered stale id ticks a row `payload` rejects; ignoring `orderRaw` lists "
                + "the agents in registry order instead of the one the user dragged)")
        // Combining is the union of the retire. Losing one would let a payload
        // built against a state that no longer holds reach the socket.
        expect(
            DiscordIPC.VisibilityChange.retiring.combined(with: .increasing).retires
                && DiscordIPC.VisibilityChange.reducing.combined(with: .increasing).retires
                && !DiscordIPC.VisibilityChange.increasing.combined(with: .none).retires,
            "a turn that both replaces content and adds some still retires the old payload, "
                + "while a turn that only adds does not (mutation: an AND instead of an OR lets "
                + "a payload built for the previous selection reach the socket)")
        // The intro card. One contract, behavioural: nothing it does turns the
        // feature on. A source scan counting writes to the key name is exactly
        // the shape #148 removed and #147 showed gets relocated around.
        let dpIntroSuite = "TokenBar.SelfTest.DiscordIntro"
        if let dpIntroDefaults = UserDefaults(suiteName: dpIntroSuite) {
            defer { UserDefaults.standard.removePersistentDomain(forName: dpIntroSuite) }
            // Deciding CONSUMES the flag: presentation is what marks it, not
            // the choice, so a card that returns until the user picks the
            // preferred action is impossible.
            let dpIntroFirst = DiscordIntro.consume(defaults: dpIntroDefaults)
            let dpIntroAgain = DiscordIntro.consume(defaults: dpIntroDefaults)
            var dpIntroOpened = 0
            // Read, never written: the process's own domain is where a card
            // that enabled the feature would actually write, and an assertion
            // confined to the isolated suite cannot see that. Measured — a
            // mutation adding `UserDefaults.standard.set(true, forKey:)` to the
            // openSettings branch passed the suite-only form of this check.
            //
            // Known limit, stated rather than papered over: this detects a
            // CHANGE, so it cannot see a write of `true` over an existing
            // `true`. Under `swift run` that domain starts empty, so the case
            // only arises from a previous mutation run leaving the key behind —
            // which happened while writing this, and silently disabled the
            // check. Asserting the key is absent beforehand would be the
            // stronger form, but it would fail on a bundled run for
            // any user who has the feature switched on.
            let dpIntroStandardBefore =
                UserDefaults.standard.object(forKey: DiscordPresence.enabledKey) as? Bool
            DiscordIntro.perform(.openSettings) { dpIntroOpened += 1 }
            DiscordIntro.perform(.notNow) { dpIntroOpened += 1 }
            let dpIntroStandardAfter =
                UserDefaults.standard.object(forKey: DiscordPresence.enabledKey) as? Bool
            expect(
                dpIntroFirst && !dpIntroAgain && dpIntroOpened == 1
                    && !DiscordPresence.enabled(defaults: dpIntroDefaults)
                    && dpIntroStandardBefore == dpIntroStandardAfter,
                "the intro card is shown once, marked by being presented rather than acted on, "
                    + "and NEITHER action turns the feature on (mutation: an enable button, or "
                    + "marking it shown only on the preferred choice, fails here)")
            // Already using it: nothing to introduce, and interrupting would be
            // noise. Asserted on a second suite so the flag above cannot be
            // what makes this pass.
            let dpIntroOnSuite = "TokenBar.SelfTest.DiscordIntroOn"
            if let dpIntroOn = UserDefaults(suiteName: dpIntroOnSuite) {
                defer { UserDefaults.standard.removePersistentDomain(forName: dpIntroOnSuite) }
                dpIntroOn.set(true, forKey: DiscordPresence.enabledKey)
                let dpIntroSkipped = DiscordIntro.consume(defaults: dpIntroOn)
                // The upgrade path: they had it on before this card existed, so
                // they never see it — and must not see it later if they switch
                // off. Skipping has to consume the flag, not defer it.
                dpIntroOn.set(false, forKey: DiscordPresence.enabledKey)
                expect(!dpIntroSkipped && !DiscordIntro.consume(defaults: dpIntroOn),
                    "someone already using the feature is not introduced to it, and switching it "
                        + "off later does not introduce them either (mutation: skipping without "
                        + "consuming the flag shows the card to a user who deliberately turned "
                        + "the feature off)")
            }
        } else {
            expect(false, "the isolated intro suite could not be created")
        }

        // MARK: - Discord Rich Presence transport (DISCORD-PRESENCE M2a)
        //
        // Nothing in the app calls this transport yet. These run against real
        // syscalls — a `socketpair(AF_UNIX, SOCK_STREAM)` end, not a mock — so
        // framing, fd lifetime and SIGPIPE behaviour are the production ones.
        // Contracts: C3 wire framing, C1 payload/privacy on the wire, C4
        // lifecycle, C5 privacy-sensitive ordering (throttle vs. consent).

        /// Frames built independently of `DiscordIPC.encode`, so the decoder is
        /// never checked against its own mirror image.
        func dpRaw(_ op: UInt32, _ length: UInt32, _ body: Data) -> Data {
            var out = Data()
            withUnsafeBytes(of: op.littleEndian) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: length.littleEndian) { out.append(contentsOf: $0) }
            out.append(body)
            return out
        }
        func dpFrameBytes(_ op: UInt32, _ text: String) -> Data {
            let body = Data(text.utf8)
            return dpRaw(op, UInt32(body.count), body)
        }
        /// Incomplete frame prefixes carried between `dpFrames` polls, per
        /// descriptor. Declared here because `dpSocketPair` clears it: see
        /// there for why clearing happens at birth rather than at close.
        var dpPartial: [Int32: Data] = [:]
        func dpSocketPair() -> (Int32, Int32) {
            var fds: [Int32] = [-1, -1]
            _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
            // Descriptor numbers are recycled the moment a fixture closes one,
            // and a one-shot `dpFrames` that lands between fragments of a frame
            // leaves a non-empty entry behind. Clearing at birth covers every
            // teardown path — `dpFinish`, `dpScenario`, and the scenarios that
            // call `close` directly — where clearing at close would have to be
            // remembered at each of them.
            dpPartial[fds[0]] = nil
            dpPartial[fds[1]] = nil
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(fds[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var on: Int32 = 1
            setsockopt(fds[1], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            return (fds[0], fds[1])
        }
        func dpRecv(_ fd: Int32) -> Data {
            var buf = [UInt8](repeating: 0, count: 4096)
            let count = recv(fd, &buf, buf.count, 0)
            return count > 0 ? Data(buf[0..<count]) : Data()
        }
        /// Non-blocking, unlike `dpRecv`: a poll loop built on the blocking read
        /// can spend up to the peer's 1s `SO_RCVTIMEO` per turn and outlast the
        /// very delay it is trying to detect.
        func dpRecvNow(_ fd: Int32) -> Data {
            var buf = [UInt8](repeating: 0, count: 4096)
            let count = recv(fd, &buf, buf.count, MSG_DONTWAIT)
            return count > 0 ? Data(buf[0..<count]) : Data()
        }
        func dpDrainToEOF(_ fd: Int32) -> Data {
            var out = Data()
            while true {
                let chunk = dpRecv(fd)
                if chunk.isEmpty { return out }
                out.append(chunk)
            }
        }
        func dpWaitUntil(_ ready: () -> Bool) -> Bool {
            for _ in 0..<400 {
                if ready() { return true }
                usleep(5_000)
            }
            return ready()
        }
        /// Decodes every complete frame currently sitting in `fd`'s buffer,
        /// non-blocking. Replaces the hand-rolled `while case .frame(...) =
        /// decode(...)` loop that most scenarios below used to repeat.
        ///
        /// The leftover is CARRIED between calls, per descriptor. `SOCK_STREAM`
        /// does not preserve write boundaries, so a frame can be split across
        /// `recv` calls; discarding the prefix would leave every later poll
        /// starting in the middle of a frame and reporting it missing —
        /// intermittently, and only under the timing that splits the write.
        /// Only a `needMore` remainder is carried, and only that. A first
        /// attempt kept whatever the `while case .frame` loop stopped on, which
        /// exhausted memory: `fatal` consumes nothing, so the loop halted on
        /// the same bytes every turn while each poll appended more, and
        /// `dpFrameArrives` polls in a tight loop. Retaining a decodable
        /// remainder is bounded by one frame; retaining an undecodable one is
        /// not bounded at all. The entry is dropped when empty so a recycled
        /// descriptor never inherits another socket's bytes — and `dpSocketPair`
        /// clears the entry at birth, which covers the case where a one-shot
        /// call leaves a real prefix behind on a descriptor about to be closed.
        func dpFrames(_ fd: Int32) -> [(DiscordIPC.Opcode, Data)] {
            var buf = (dpPartial[fd] ?? Data()) + dpRecvNow(fd)
            var out: [(DiscordIPC.Opcode, Data)] = []
            decoding: while !buf.isEmpty {
                switch DiscordIPC.decode(from: &buf) {
                case .frame(let op, let body): out.append((op, body))
                case .discard: continue
                case .needMore: break decoding
                // Unrecoverable by definition, so there is nothing to carry.
                case .fatal: buf.removeAll()
                }
            }
            dpPartial[fd] = buf.isEmpty ? nil : buf
            return out
        }
        /// Counts calls to an injected connect factory. Mutated on the client's
        /// serial queue and read after `drainForTesting()`/`dpWaitUntil`, which
        /// is what orders the two.
        final class DPCounter: @unchecked Sendable {
            var value = 0
        }
        /// The common shape roughly twenty scenarios below repeat: one socket
        /// pair, a plain connect factory, start, drain the handshake, run
        /// `body`, then stop and close. Scenarios that need two socket pairs, a
        /// mode-counting connect factory, or `holdQueueForTesting` keep their
        /// own setup instead — this shape does not fit them.
        ///
        /// `peerClosedByBody` hands descriptor ownership to the body. The
        /// SIGPIPE scenario closes the peer itself to provoke the write
        /// failure, and closing it again here would be a double close: in a
        /// harness with a live serial queue the number can already have been
        /// reused, so the second `close` can take an unrelated socket out from
        /// under `stop()` and make later scenarios fail unpredictably.
        @discardableResult
        func dpScenario<T>(
            peerClosedByBody: Bool = false, _ body: (Int32, DiscordIPCClient) -> T
        ) -> T {
            let (local, peer) = dpSocketPair()
            let client = DiscordIPCClient(connect: { local })
            client.start()
            client.drainForTesting()
            _ = dpRecv(peer) // the handshake
            let result = body(peer, client)
            client.stop()
            client.drainForTesting()
            if !peerClosedByBody { close(peer) }
            return result
        }
        /// The cases `dpScenario` excludes: several socket pairs handed out in
        /// order, so a scenario can break one connection and watch the client
        /// arrive on the next. Local funcs rather than a type, because a type
        /// declared in a function body cannot capture the helpers above it.
        func dpRig(peers count: Int) -> ([Int32], DiscordIPCClient, DPCounter) {
            let pairs = (0..<count).map { _ in dpSocketPair() }
            let handed = DPCounter()
            let client = DiscordIPCClient(connect: {
                let i = min(handed.value, pairs.count - 1)
                handed.value += 1
                return pairs[i].0
            })
            return (pairs.map { $0.1 }, client, handed)
        }
        /// The READY frame Discord actually sends, sentinels included: the
        /// account's username, id and avatar, none of which may be read, kept
        /// or echoed. Declared here rather than beside its first assertion
        /// because the helpers below capture it, and a local `let` cannot be
        /// captured before its declaration.
        let dpReadyBody = "{\"cmd\":\"DISPATCH\",\"evt\":\"READY\",\"data\":{\"v\":1,"
            + "\"user\":{\"username\":\"SECRET_USERNAME\",\"id\":\"SECRET_ID\","
            + "\"avatar\":\"SECRET_AVATAR\",\"discriminator\":\"0001\"}}}"
        /// Answers a handshake the client has already sent. The client only
        /// leaves `ready` on an inbound READY, so every scenario past the
        /// connect path needs this.
        func dpSendReady(_ peer: Int32) {
            dpFrameBytes(1, dpReadyBody).withUnsafeBytes { raw in
                _ = send(peer, raw.baseAddress!, raw.count, 0)
            }
        }
        /// Drains the handshake, answers READY, and waits for the client to
        /// record it. The Bool is the liveness half of every conjunction below:
        /// without it an absence assertion passes on a client that never
        /// connected.
        func dpReachReady(_ peer: Int32, _ client: DiscordIPCClient) -> Bool {
            _ = dpRecv(peer)
            dpSendReady(peer)
            return dpWaitUntil { client.inboundTokenForTesting == "ready" }
        }
        /// Parks the client's queue so several calls can be enqueued behind one
        /// another and released together. Signal the returned semaphore to let
        /// them run.
        func dpHold(_ client: DiscordIPCClient) -> DispatchSemaphore {
            let gate = DispatchSemaphore(value: 0)
            client.holdQueueForTesting(until: gate)
            return gate
        }
        func dpFinish(_ client: DiscordIPCClient, _ peers: [Int32]) {
            client.stop()
            client.drainForTesting()
            for peer in peers where peer >= 0 { close(peer) }
        }
        /// The payload shape every lifecycle scenario publishes. Only `details`
        /// varies, and it is what the assertions look for on the wire.
        func dpP(_ details: String, state: String = "Amp · $10-25") -> DiscordPresence.Payload {
            DiscordPresence.Payload(details: details, state: state, largeImageKey: "tokenbar")
        }

        // A6 — framing resilience, pinned against a frame built independently
        // of the encoder.
        expect(DiscordIPC.encode(.handshake, Data("{}".utf8)) == dpRaw(0, 2, Data("{}".utf8)),
            "the frame encoder emits LE opcode, LE length, then body")

        // A6a — an absurd length is refused before the completeness check, so
        // no allocation is ever sized from the wire; the cap is exactly 64 KiB.
        var dpOversize = dpRaw(1, 0xFFFF_FFFF, Data())
        expect(DiscordIPC.decode(from: &dpOversize) == .fatal && dpOversize.count == 8,
            "A6a: an oversized frame length is fatal and consumes nothing "
                + "(mutation: dropping the maxFrameLength check yields needMore forever)")
        var dpAtCap = dpRaw(1, 65_536, Data())
        var dpOverCap = dpRaw(1, 65_537, Data())
        expect(DiscordIPC.decode(from: &dpAtCap) == .needMore
                && DiscordIPC.decode(from: &dpOverCap) == .fatal,
            "a length exactly at the 64 KiB cap is allowed, one byte over is fatal")

        // A6b — opcode allowlist.
        var dpOpFive = dpFrameBytes(5, "{}")
        var dpOpMax = dpFrameBytes(0xFFFF_FFFF, "{}")
        expect(DiscordIPC.decode(from: &dpOpFive) == .discard && dpOpFive.isEmpty
                && DiscordIPC.decode(from: &dpOpMax) == .discard && dpOpMax.isEmpty,
            "A6b: an unknown opcode is discarded and consumed, whether small or "
                + "0xFFFFFFFF read as a negative int "
                + "(mutation: dropping the Opcode allowlist surfaces it as a frame)")

        // A6c — partial reads never block and never consume.
        var dpHeaderOnly = dpRaw(1, 2, Data())
        var dpHalfHeader = Data([1, 0, 0, 0])
        expect(DiscordIPC.decode(from: &dpHeaderOnly) == .needMore && dpHeaderOnly.count == 8
                && DiscordIPC.decode(from: &dpHalfHeader) == .needMore && dpHalfHeader.count == 4,
            "A6c: a header with no body, or fewer than 8 bytes, needs more and leaves the buffer "
                + "intact (mutation: consuming on an incomplete frame loses the header)")

        // A6d — malformed bodies are dropped silently. One check covers both:
        // JSONSerialization rejects invalid UTF-8 the same way it rejects
        // invalid JSON.
        var dpNonUTF8 = dpRaw(1, 3, Data([0xFF, 0xFE, 0xFD]))
        var dpBadJSON = dpFrameBytes(1, "{not json")
        expect(DiscordIPC.decode(from: &dpNonUTF8) == .discard && dpNonUTF8.isEmpty
                && DiscordIPC.decode(from: &dpBadJSON) == .discard && dpBadJSON.isEmpty,
            "A6d: a non-UTF-8 or unparseable-JSON body is discarded "
                + "(mutation: dropping the body validity check surfaces it as a frame)")

        // A6e — several frames in one read are taken one at a time, in order,
        // and the bad middle frame does not desync the buffer.
        var dpStream = dpFrameBytes(1, "{\"a\":1}")
            + dpFrameBytes(5, "{}")
            + dpFrameBytes(0, "{\"b\":2}")
        expect(DiscordIPC.decode(from: &dpStream) == .frame(.frame, Data("{\"a\":1}".utf8)),
            "A6e: the first of three concatenated frames comes out intact")
        expect(DiscordIPC.decode(from: &dpStream) == .discard
                && DiscordIPC.decode(from: &dpStream) == .frame(.handshake, Data("{\"b\":2}".utf8)),
            "A6e: the bad middle frame is skipped and the third follows intact "
                + "(mutation: advancing the buffer by the wrong amount fails here)")
        expect(DiscordIPC.decode(from: &dpStream) == .needMore && dpStream.isEmpty,
            "A6e: the buffer is fully drained afterwards")

        // A-wire — the published surface and the serialized bytes are the same
        // set. `leafStrings`/`leafKeys` walk the real JSON, nesting included,
        // so a field or key smuggled in anywhere is visible — including one
        // whose VALUE repeats an existing leaf, which a Set would erase.
        let dpWirePayload = DiscordPresence.Payload(
            details: "12K tokens today", state: "Amp · $1-5", largeImageKey: "tokenbar")
        let dpWire = DiscordIPC.activityJSON(dpWirePayload, pid: 4242, nonce: "NONCE-1")
        let dpWireObject = (try? JSONSerialization.jsonObject(with: dpWire)) as? [String: Any]
        let dpWireArgs = dpWireObject?["args"] as? [String: Any]
        let dpWireActivity = dpWireArgs?["activity"] as? [String: Any]
        let dpWireAssets = dpWireActivity?["assets"] as? [String: Any]
        expect(
            DiscordIPC.leafStrings(dpWire).sorted()
                == (Array(dpWirePayload.fields.values)
                    // Literals, not the constants: the button is carried by the
                    // transport, not the payload, so a value derived from
                    // anything — a `?ref=` parameter being the obvious one —
                    // fails right here instead of being admitted as just
                    // another field.
                    + ["View on GitHub", "https://github.com/Nanako0129/TokenBar"]
                    + ["SET_ACTIVITY", "NONCE-1", "4242"]).sorted()
                && DiscordIPC.leafKeys(dpWire).sorted() == [
                    "activity", "args", "assets", "buttons", "cmd", "details",
                    "label", "large_image", "nonce", "pid", "state", "url",
                ]
                && dpWireAssets?.count == 1
                // Per KEY, not only as a sorted multiset. Swapping `details`
                // and `state` in `activityJSON` preserves the sorted leaves,
                // the sorted keys and the object counts, so every clause above
                // still passes while Discord renders the token summary in the
                // cost field and the client name in the other.
                && dpWireActivity?["details"] as? String == dpWirePayload.details
                && dpWireActivity?["state"] as? String == dpWirePayload.state
                && dpWireAssets?["large_image"] as? String == dpWirePayload.largeImageKey,
            "A-wire: the activity's leaves are exactly Payload.fields plus Discord's structural "
                + "constants, counted; each field keeps its own key; its keys are exactly the "
                + "protocol's; and assets holds "
                + "exactly large_image (mutation: adding any field or key — even one whose value "
                + "or an empty-object value duplicates an existing leaf — fails one of these three)")
        expect(dpWireActivity?.count == 4 && dpWireAssets?["large_image"] as? String == "tokenbar",
            "A-wire: the activity holds exactly details, state, assets and buttons, and "
                + "largeImageKey is published as assets.large_image, renamed but unaltered")
        expect(dpWireObject?["cmd"] as? String == "SET_ACTIVITY"
            && dpWireArgs?["pid"] as? Int == 4242 && dpWireObject?["nonce"] as? String == "NONCE-1",
            "A-wire: the envelope is SET_ACTIVITY with the given pid and nonce")
        expect(String(decoding: DiscordIPC.activityJSON(nil, pid: 4242, nonce: "N"), as: UTF8.self)
            .contains("\"activity\":null"),
            "clearing the presence sends activity: null")

        // The handshake and the clear are serialized by the same helper and
        // deserve the same pin — the activity frame is not the only thing that
        // leaves this machine.
        let dpShake = DiscordIPC.handshakeJSON()
        expect(DiscordIPC.leafKeys(dpShake).sorted() == ["client_id", "v"]
                && DiscordIPC.leafStrings(dpShake).sorted() == [DiscordIPC.applicationID, "1"].sorted(),
            "A-wire: the handshake's keys are exactly v and client_id, and it carries the "
                + "application id and protocol version — nothing else")
        let dpClear = DiscordIPC.activityJSON(nil, pid: 4242, nonce: "NONCE-2")
        expect(DiscordIPC.leafKeys(dpClear).sorted() == ["activity", "args", "cmd", "nonce", "pid"]
                && DiscordIPC.leafStrings(dpClear).sorted()
                    == ["4242", "NONCE-2", "SET_ACTIVITY", "null"].sorted(),
            "A-wire: the clear frame's keys are exactly the protocol's, and it carries no payload "
                + "data at all")

        // A13 — nothing from an inbound frame may be read, kept or echoed.
        // `dpReadyBody` above is the frame Discord actually sends, sentinels
        // and all.
        let dpInboundToken = DiscordIPC.inbound(Data(dpReadyBody.utf8))
        // Literal "ready", not DiscordIPC.readyEvent: an expectation read out of
        // the constant it guards passes whatever that constant becomes.
        expect(dpInboundToken == "ready" && !dpInboundToken.contains("SECRET_")
                && DiscordIPC.inbound(Data("{\"evt\":\"ERROR\",\"data\":{}}".utf8)) == "other",
            "A13: a READY frame yields a fixed token and no frame content, and a non-READY event "
                + "is not mistaken for it "
                + "(mutation: returning the parsed user object, or the raw body, leaks SECRET_)")

        // A-path — sun_path is 104 bytes and truncation does not fail, it
        // connects somewhere else.
        func dpAddressFits(_ path: String) -> Bool {
            DiscordIPC.unixSocketAddress(path: path).map { _ in true } ?? false
        }
        var dpAddress = DiscordIPC.unixSocketAddress(path: "/tmp/discord-ipc-0")!
        let dpAddressPath = withUnsafeBytes(of: &dpAddress.sun_path) {
            String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
        }
        expect(
            !dpAddressFits(String(repeating: "a", count: 200))
                && !dpAddressFits(String(repeating: "a", count: 104))
                && dpAddressFits(String(repeating: "a", count: 103))
                && dpAddressPath == "/tmp/discord-ipc-0",
            "A-path: an over-long path or one filling sun_path exactly is refused, 103 bytes "
                + "fits, and the accepted path round-trips verbatim "
                + "(mutation: truncating to fit connects to a different path)")

        // A7a/A7c/A13 over a real socket pair, reused across the button and
        // privacy checks below — this fixture inspects the handshake bytes
        // itself, so it does not go through dpScenario.
        let (dpLocal, dpPeer) = dpSocketPair()
        let dpConnects = DPCounter()
        let dpClient = DiscordIPCClient(connect: {
            dpConnects.value += 1
            return dpLocal
        })
        dpClient.start()
        dpClient.start()
        dpClient.drainForTesting()
        expect(dpConnects.value == 1,
            "A7a: start() twice opens one connection "
                + "(mutation: dropping the `!running` guard in start() connects twice)")

        var dpHandshakeBuffer = dpRecv(dpPeer)
        var dpHandshakeOK = false
        if case .frame(.handshake, let body) = DiscordIPC.decode(from: &dpHandshakeBuffer) {
            let text = String(decoding: body, as: UTF8.self)
            dpHandshakeOK = text.contains("\"client_id\":\"1534085299163107348\"")
                && text.contains("\"v\":1")
        }
        expect(dpHandshakeOK, "the client opens with a v1 handshake carrying the application id")

        dpFrameBytes(1, dpReadyBody).withUnsafeBytes { raw in
            _ = send(dpPeer, raw.baseAddress!, raw.count, 0)
        }
        expect(dpWaitUntil { dpClient.inboundTokenForTesting == "ready" },
            "the client recognises READY off the wire")
        expect(!dpClient.inboundTokenForTesting.contains("SECRET_"),
            "A13: nothing from the READY frame survives in the client's state")

        dpClient.publish(dpWirePayload)
        dpClient.publish(dpP("999K tokens today", state: "Zed · $50-100"))
        dpClient.drainForTesting()
        var dpActivityBuffer = dpRecv(dpPeer)
        var dpActivityText = ""
        var dpActivityBody = Data()
        if case .frame(.frame, let body) = DiscordIPC.decode(from: &dpActivityBuffer) {
            dpActivityText = String(decoding: body, as: UTF8.self)
            dpActivityBody = body
        }
        // Every A-wire assertion above calls `activityJSON` with a fixed pid
        // and nonce, so the real `pid()`/`nonce()` that supply every actual
        // frame were exercised by none of them; this checks the bytes that
        // left the socket, not just the pure function.
        expect(dpActivityText.contains("12K tokens today")
                && DiscordIPC.leafKeys(dpActivityBody).sorted() == [
                    "activity", "args", "assets", "buttons", "cmd", "details",
                    "label", "large_image", "nonce", "pid", "state", "url",
                ],
            "the first publish reaches the socket immediately, carrying exactly the protocol's "
                + "keys")

        // A26 — the button's shape, against Discord's documented limits and
        // against the one way this constant could become a channel.
        if let dpWireButtons = (((try? JSONSerialization.jsonObject(with: dpActivityBody))
            as? [String: Any])?["args"] as? [String: Any])?["activity"] as? [String: Any],
            let dpButtons = dpWireButtons["buttons"] as? [[String: String]] {
            let dpLabel = dpButtons.first?["label"] ?? ""
            let dpURL = dpButtons.first?["url"] ?? ""
            expect(dpButtons.count == 1 && !dpLabel.isEmpty && dpLabel.count <= 32
                    && !dpURL.isEmpty && dpURL.count <= 512,
                "A26: exactly one button goes out, label and URL within Discord's 1-32/1-512 "
                    + "character limits (a longer value is silently dropped by Discord, so the "
                    + "button would simply not appear)")
            let dpURLParts = URLComponents(string: dpURL)
            expect(
                dpURLParts?.scheme == "https" && dpURLParts?.host == "github.com"
                    && dpURLParts?.query == nil && dpURLParts?.fragment == nil
                    && dpURLParts?.user == nil && dpURLParts?.password == nil,
                "A26-URL: the URL is a bare https://github.com link with no query, fragment or "
                    + "credentials (mutation: `buttonURL + \"?ref=\" + installID` — the shape a "
                    + "per-user tracking parameter takes — fails here, and it is the reason this "
                    + "constant lives in the transport rather than in the payload)")
        } else {
            // Not a formality. The cast above is what asserts the wire shape:
            // if `buttons` regressed from an array to an OBJECT carrying the
            // same `label` and `url`, this block would simply be skipped, and
            // every other check still passes — the leaf-key and leaf-value
            // assertions see identical leaves from both shapes. Discord renders
            // nothing for the object form, so the button would silently vanish.
            expect(false, "A26: the activity carries `buttons` as an ARRAY of objects")
        }

        // A26b — buttons ride with an activity, never with a clear. A cleared
        // presence is the user withdrawing; sending them a link at that moment
        // would be the one place this feature turns into advertising.
        let dpClearFrame = DiscordIPC.activityJSON(nil, pid: 4242, nonce: "NONCE-C")
        expect(!String(decoding: dpClearFrame, as: UTF8.self).contains("buttons")
            && DiscordIPC.leafStrings(dpClearFrame).allSatisfy {
                $0 != DiscordIPC.buttonURL && $0 != DiscordIPC.buttonLabel
            },
            "A26b: a clear carries no buttons (mutation: attaching them outside the `if let "
                + "payload` sends a link on the frame that withdraws the presence)")
        let dpLiveLeaves = DiscordIPC.leafStrings(dpActivityBody)
        // Literals, not the constants they pin, for the same reason the button
        // URL above is: a future non-constant value fails HERE rather than
        // riding along as one more payload field.
        let dpLivePayloadLeaves = [
            "12K tokens today", "Amp · $1-5", "tokenbar", "SET_ACTIVITY",
            "View on GitHub", "https://github.com/Nanako0129/TokenBar",
        ]
        let dpLiveExtra = dpLiveLeaves.filter { !dpLivePayloadLeaves.contains($0) }
        let dpLiveNonce = dpLiveExtra.first {
            $0 != String(ProcessInfo.processInfo.processIdentifier)
        }
        expect(
            dpLiveLeaves.count == dpLivePayloadLeaves.count + 2
                && dpLivePayloadLeaves.allSatisfy(dpLiveLeaves.contains)
                && dpLiveExtra.contains(String(ProcessInfo.processInfo.processIdentifier))
                && dpLiveNonce.map { UUID(uuidString: $0) != nil } == true,
            "the frame on the wire carries the payload, the envelope constant, and exactly two "
                + "more leaves — this process's own pid and a bare UUID nonce "
                + "(mutation: deriving either from NSUserName() or a hostname hash fails here)")
        expect(!dpActivityText.contains("999K") && dpActivityBuffer.isEmpty,
            "a second publish inside the 15s floor is coalesced rather than sent")

        dpClient.stop()
        dpClient.drainForTesting()
        var dpTail = dpDrainToEOF(dpPeer)
        var dpClearSeen = false
        while case .frame(_, let body) = DiscordIPC.decode(from: &dpTail) {
            if String(decoding: body, as: UTF8.self).contains("\"activity\":null") {
                dpClearSeen = true
            }
        }
        expect(dpClearSeen && !dpClient.isConnectedForTesting,
            "A7c: stop() sends the activity clear before closing the socket "
                + "(mutation: closing first loses the frame entirely)")
        close(dpPeer)

        // A9 — SIGPIPE. The connection is established first (SO_NOSIGPIPE only
        // applies to a live socket), then the peer is closed and a frame
        // written in the same queue item so the EOF handler cannot get there
        // first. With SO_NOSIGPIPE removed this does not fail, it kills the
        // selftest process: no FAIL line, no "selftest passed", exit 141.
        let dpSigOK = dpScenario(peerClosedByBody: true) { peer, client in
            client.probeWriteForTesting { close(peer) }
            return client.writeErrnoForTesting == EPIPE && !client.isConnectedForTesting
        }
        expect(dpSigOK,
            "A9: a write to a closed socket returns EPIPE, tearing the connection down, and the "
                + "process survives "
                + "(mutation: dropping SO_NOSIGPIPE terminates the selftest on signal 13)")

        // A7b, part 1 — retries are bounded. Every connection here is born
        // broken (peer closed immediately), so the retry path runs to its limit.
        let dpRetries = DPCounter()
        let dpRetryClient = DiscordIPCClient(connect: {
            dpRetries.value += 1
            var fds: [Int32] = [-1, -1]
            _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
            close(fds[1])
            return fds[0]
        })
        dpRetryClient.reconnectDelay = 0.02
        dpRetryClient.start()
        let dpRetriesBudgeted = dpWaitUntil { dpRetries.value >= 2 }
            && dpWaitUntil { dpRetries.value == 6 }
        usleep(300_000)
        expect(dpRetriesBudgeted && dpRetries.value == 6,
            "A7b: a broken connection retries, and the budget is exactly the initial attempt "
                + "plus five (mutation: dropping maxReconnectAttempts retries forever)")
        dpRetryClient.stop()

        // A7b, part 2 — stop() cancels the armed retry, and idempotence has to
        // hold while a retry is armed too, where `fd < 0` no longer covers it.
        let dpCancelCount = DPCounter()
        let dpCancelClient = DiscordIPCClient(connect: {
            dpCancelCount.value += 1
            var fds: [Int32] = [-1, -1]
            _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
            close(fds[1])
            return fds[0]
        })
        dpCancelClient.reconnectDelay = 0.5
        dpCancelClient.start()
        let dpArmed = dpWaitUntil { dpCancelClient.reconnectPendingForTesting }
        dpCancelClient.start()
        dpCancelClient.drainForTesting()
        expect(dpArmed && dpCancelCount.value == 1,
            "A7a: start() during an armed retry does not open a second connection "
                + "(mutation: dropping the `!running` guard in start() connects immediately)")
        dpCancelClient.stop()
        dpCancelClient.drainForTesting()
        let dpCancelled = !dpCancelClient.reconnectPendingForTesting
        usleep(700_000)
        expect(dpCancelled && dpCancelCount.value == 1,
            "A7b: stop() cancels the armed retry, and the cancelled retry never fires "
                + "(mutation: dropping reconnectWork?.cancel() leaves it armed)")

        // A7b, part 3 — after stop(), no path rebuilds the connection. Driven
        // directly, because once stop() has closed the socket there is no
        // disconnect left to provoke.
        let (dpStopLocal, dpStopPeer) = dpSocketPair()
        let dpStopConnects = DPCounter()
        let dpStopClient = DiscordIPCClient(connect: {
            dpStopConnects.value += 1
            return dpStopLocal
        })
        dpStopClient.reconnectDelay = 0.02
        dpStopClient.start()
        dpStopClient.drainForTesting()
        dpStopClient.stop()
        dpStopClient.drainForTesting()
        dpStopClient.scheduleReconnectForTesting()
        usleep(300_000)
        expect(dpStopConnects.value == 1,
            "A7b: no path rebuilds the connection after stop() "
                + "(mutation: dropping the running guard in openConnection reconnects here)")
        close(dpStopPeer)

        // A14b — consent withdrawn while a publish is queued behind its own
        // paired start(). This is the ONE ordering `applyDiscordPresence`
        // actually produces; A14's bare `stop()` with no paired start ahead
        // of the publish is not, and is subsumed by this fixture's mutation.
        let (dpPairedLocal, dpPairedPeer) = dpSocketPair()
        let dpPairedClient = DiscordIPCClient(connect: { dpPairedLocal })
        dpPairedClient.start()
        dpPairedClient.drainForTesting()
        let dpPairedReady = dpReachReady(dpPairedPeer, dpPairedClient)
        let dpPairedGate = dpHold(dpPairedClient)
        dpPairedClient.start()
        dpPairedClient.publish(dpP("99K tokens today"))
        dpPairedClient.stop()
        dpPairedGate.signal()
        dpPairedClient.drainForTesting()
        let dpPairedTail = String(decoding: dpDrainToEOF(dpPairedPeer), as: UTF8.self)
        expect(dpPairedReady && !dpPairedTail.contains("99K tokens today")
                && dpPairedTail.contains("\"activity\":null"),
            "A14b: a publish queued behind its paired start() never reaches the socket, though "
                + "the clear still does "
                + "(mutation: re-arming consent inside start()'s queued block publishes it anyway)")
        close(dpPairedPeer)

        // A14c — off then straight back on while a publish is still queued. A
        // single consent Bool cannot survive this: `start()` re-arms it and
        // the pre-withdrawal payload flushes. The epoch a later `start()`
        // cannot undo is what `stop()` retired.
        let (dpEpochPeers, dpEpochClient, dpEpochHanded) = dpRig(peers: 2)
        dpEpochClient.start()
        dpEpochClient.drainForTesting()
        let dpEpochReady = dpReachReady(dpEpochPeers[0], dpEpochClient)
        let dpEpochGate = dpHold(dpEpochClient)
        dpEpochClient.publish(dpP("41K tokens today"))
        dpEpochClient.stop()
        dpEpochClient.start()
        dpEpochClient.publish(dpP("42K tokens today"))
        dpEpochGate.signal()
        dpEpochClient.drainForTesting()
        let dpEpochOld = String(decoding: dpDrainToEOF(dpEpochPeers[0]), as: UTF8.self)
        let dpEpochOldOK = !dpEpochOld.contains("41K tokens today")
            && dpEpochOld.contains("\"activity\":null")
        close(dpEpochPeers[0])
        let dpEpochReconnected = dpWaitUntil { dpEpochHanded.value >= 2 }
        _ = dpReachReady(dpEpochPeers[1], dpEpochClient)
        let dpEpochNewArrived = dpFrameArrives(dpEpochPeers[1], "42K tokens today", within: 2)
        dpFinish(dpEpochClient, [dpEpochPeers[1]])
        expect(dpEpochReady && dpEpochOldOK && dpEpochReconnected && dpEpochNewArrived,
            "A14c: a publish made before the switch went off is not re-authorized by switching "
                + "it back on, though the off half still cleared the activity and the on half "
                + "kept working "
                + "(mutation: a single consent Bool is set again by start() and the stale "
                + "payload reaches Discord)")

        // A18 — after a withdrawal the only thing this process sends is the
        // clear, even for a ping whose read handler queued ahead of `stop()`.
        let (dpPingLocal, dpPingPeer) = dpSocketPair()
        let dpPingClient = DiscordIPCClient(connect: { dpPingLocal })
        dpPingClient.start()
        dpPingClient.drainForTesting()
        _ = dpRecv(dpPingPeer)
        let dpPingGate = dpHold(dpPingClient)
        dpFrameBytes(3, "{\"ping\":1}").withUnsafeBytes { raw in
            _ = send(dpPingPeer, raw.baseAddress!, raw.count, 0)
        }
        // Let the read source fire and enqueue its handler while the queue is
        // parked, so the handler really is ahead of the stop block below.
        usleep(50_000)
        dpPingClient.stop()
        dpPingGate.signal()
        dpPingClient.drainForTesting()
        let dpPingFrames = dpFrames(dpPingPeer)
        let dpPongSeen = dpPingFrames.contains { $0.0 == .pong }
        let dpPingClearSeen = dpPingFrames.contains {
            String(decoding: $0.1, as: UTF8.self).contains("\"activity\":null")
        }
        expect(!dpPongSeen && dpPingClearSeen,
            "A18: a ping whose handler was queued before the switch went off is not answered, "
                + "though the clear still goes out "
                + "(mutation: an ungated writeFrame(.pong,) replies to Discord after opt-out)")
        close(dpPingPeer)

        // A20 — a reduction retires what was computed before it. "Switch off,
        // hide a client, switch on" coalesces to one apply with no `stop()`,
        // so the hide itself has to retire the stale payload.
        let (dpStaleLocal, dpStalePeer) = dpSocketPair()
        let dpStaleClient = DiscordIPCClient(connect: { dpStaleLocal })
        dpStaleClient.start()
        dpStaleClient.drainForTesting()
        let dpStaleReady = dpReachReady(dpStalePeer, dpStaleClient)
        let dpStaleGate = dpHold(dpStaleClient)
        dpStaleClient.publish(dpP("70K tokens today"))
        dpStaleClient.publish(dpP("71K tokens today", state: "Zed · $10-25"), visibility: .reducing)
        dpStaleGate.signal()
        dpStaleClient.drainForTesting()
        let dpStaleSeen = dpFramesNow(dpStalePeer)
        expect(dpStaleReady && !dpStaleSeen.contains("70K tokens today")
                && dpStaleSeen.contains("71K tokens today"),
            "A20: a payload computed before the hide never reaches the socket, though the "
                + "reduction itself does "
                + "(mutation: without the reduction retiring earlier work it is written first, "
                + "putting the client the user just hid back on the profile)")
        dpFinish(dpStaleClient, [dpStalePeer])

        // A19 — a clear that lost its socket is retried on the next
        // connection. `nil` stands for both "nothing given yet" and "the
        // clear was given", so a fresh connection can wrongly claim it holds
        // one already and drop it.
        let (dpReclearPeers, dpReclearClient, dpReclearHanded) = dpRig(peers: 2)
        dpReclearClient.reconnectDelay = 0.02
        dpReclearClient.start()
        _ = dpWaitUntil { dpReclearClient.isConnectedForTesting }
        let dpReclearReady = dpReachReady(dpReclearPeers[0], dpReclearClient)
        dpReclearClient.publish(dpP("60K tokens today"))
        dpReclearClient.drainForTesting()
        let dpReclearPublished = dpFramesNow(dpReclearPeers[0]).contains("60K tokens today")
        // Park the queue, put the clear behind it, then break the socket. The
        // clear's write is attempted against a peer that is already gone, so
        // it fails and tears the connection down with the clear still pending.
        let dpReclearGate = dpHold(dpReclearClient)
        dpReclearClient.publish(nil, visibility: .reducing)
        close(dpReclearPeers[0])
        dpReclearGate.signal()
        dpReclearClient.drainForTesting()
        let dpReclearReconnected = dpWaitUntil { dpReclearHanded.value >= 2 }
        _ = dpReachReady(dpReclearPeers[1], dpReclearClient)
        let dpReclearArrived = dpFrameArrives(dpReclearPeers[1], "\"activity\":null", within: 2)
        dpFinish(dpReclearClient, [dpReclearPeers[1]])
        expect(dpReclearReady && dpReclearPublished && dpReclearReconnected && dpReclearArrived,
            "A19: a clear that lost its socket is retried on the next connection "
                + "(mutation: one `nil` for both \"nothing delivered yet\" and \"the clear was "
                + "delivered\" makes the fresh connection treat it as already held and drop it)")

        // A17 — on then off before the queue has run the start: the gate's
        // contract is that this process may not connect at all.
        let dpOptOutConnects = DPCounter()
        let dpOptOutClient = DiscordIPCClient(connect: {
            dpOptOutConnects.value += 1
            var fds: [Int32] = [-1, -1]
            _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
            close(fds[1])
            return fds[0]
        })
        let dpOptOutGate = dpHold(dpOptOutClient)
        dpOptOutClient.start()
        dpOptOutClient.publish(dpP("51K tokens today"))
        dpOptOutClient.stop()
        dpOptOutGate.signal()
        dpOptOutClient.drainForTesting()
        // A control fixture without the opt-out: without it, the assertion
        // below would pass on a client that simply never connects at all.
        let dpOptInConnects = DPCounter()
        let dpOptInClient = DiscordIPCClient(connect: {
            dpOptInConnects.value += 1
            var fds: [Int32] = [-1, -1]
            _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
            close(fds[1])
            return fds[0]
        })
        let dpOptInGate = dpHold(dpOptInClient)
        dpOptInClient.start()
        dpOptInClient.publish(dpP("51K tokens today"))
        dpOptInGate.signal()
        dpOptInClient.drainForTesting()
        dpOptInClient.stop()
        dpOptInClient.drainForTesting()
        expect(dpOptOutConnects.value == 0 && dpOptInConnects.value == 1,
            "A17: a start queued before the switch went off never opens a socket, though the "
                + "same fixture without the opt-out does connect "
                + "(mutation: guarding openConnection on the queue-local `running` alone hands "
                + "Discord a connection and a handshake after the user opted out)")

        // The floor applies to every NEW sample, including one caused by a
        // hide. That is the whole behavioural change of removing the bypass,
        // and it is what the consent copy now states. A clear is different and
        // still is not throttled: it carries no new information, and delaying
        // one would keep a stale presence public after the user switched off.
        let (dpNoBypassLocal, dpNoBypassPeer) = dpSocketPair()
        let dpNoBypassClient = DiscordIPCClient(connect: { dpNoBypassLocal })
        dpNoBypassClient.start()
        dpNoBypassClient.drainForTesting()
        let dpNoBypassReady = dpReachReady(dpNoBypassPeer, dpNoBypassClient)
        dpNoBypassClient.publish(dpP("10K tokens today", state: "Amp · $1-5"))
        dpNoBypassClient.drainForTesting()
        let dpNoBypassArmed = String(decoding: dpRecvNow(dpNoBypassPeer), as: UTF8.self)
            .contains("10K tokens today")
        dpNoBypassClient.publish(dpP("11K tokens today", state: "Amp · $1-5"), visibility: .reducing)
        dpNoBypassClient.drainForTesting()
        let dpNoBypassHeld = !String(decoding: dpRecvNow(dpNoBypassPeer), as: UTF8.self).contains("11K")
        dpNoBypassClient.publish(nil, visibility: .reducing)
        dpNoBypassClient.drainForTesting()
        let dpNoBypassCleared = String(decoding: dpRecvNow(dpNoBypassPeer), as: UTF8.self)
            .contains("\"activity\":null")
        dpFinish(dpNoBypassClient, [dpNoBypassPeer])
        expect(dpNoBypassReady && dpNoBypassArmed && dpNoBypassHeld && dpNoBypassCleared,
            "a hide waits out the publish floor like any other new sample, while a clear still "
                + "goes out immediately (mutation: re-adding a bypass republishes the hide "
                + "sub-interval; throttling the clear leaves a stale presence public)")
        // The superseded-grant fixture is gone with the grant: nothing is armed, so nothing can be inherited or destroyed.

        // A clear carries no new information, so it is not throttled — but it
        // must not re-arm the floor's CLOCK either, or the unhide behind it
        // goes out inside the interval. Windows below are wall-clock.
        func dpFramesNow(_ fd: Int32) -> String {
            dpFrames(fd).filter { $0.0 == .frame }
                .map { String(decoding: $0.1, as: UTF8.self) }.joined()
        }
        func dpFrameArrives(_ fd: Int32, _ needle: String, within seconds: Double) -> Bool {
            let deadline = DispatchTime.now() + seconds
            repeat {
                if dpFramesNow(fd).contains(needle) { return true }
                usleep(5_000)
            } while DispatchTime.now() < deadline
            return false
        }
        let (dpOneShotLocal, dpOneShotPeer) = dpSocketPair()
        let dpOneShotClient = DiscordIPCClient(connect: { dpOneShotLocal })
        dpOneShotClient.publishInterval = 1.0
        dpOneShotClient.start()
        dpOneShotClient.drainForTesting()
        let dpOneShotReady = dpReachReady(dpOneShotPeer, dpOneShotClient)
        dpOneShotClient.publish(dpP("20K tokens today", state: "Amp · $1-5"))
        dpOneShotClient.drainForTesting()
        let dpOneShotArmedAt = DispatchTime.now()
        let dpOneShotArmed = dpFramesNow(dpOneShotPeer).contains("20K tokens today")
        // Every client hidden: the payload is nil and what goes out is a clear.
        dpOneShotClient.publish(nil, visibility: .reducing)
        dpOneShotClient.drainForTesting()
        let dpOneShotCleared = dpFramesNow(dpOneShotPeer).contains("\"activity\":null")
        dpOneShotClient.publish(dpP("21K tokens today", state: "Amp · $1-5"))
        dpOneShotClient.drainForTesting()
        // The fixture has to still be inside the 1s floor here, or the
        // assertions below would be reporting payloads that were simply due.
        let dpOneShotSpent = Double(
            DispatchTime.now().uptimeNanoseconds - dpOneShotArmedAt.uptimeNanoseconds)
            / 1_000_000_000
        let dpOneShotFast = dpOneShotSpent < 0.5
        // 300ms: well inside the 1s floor, well over the time a due frame needs.
        let dpOneShotHeld = !dpFrameArrives(dpOneShotPeer, "21K tokens today", within: 0.3)
        let dpOneShotArrivedLater = dpFrameArrives(dpOneShotPeer, "21K tokens today", within: 3)
        dpFinish(dpOneShotClient, [dpOneShotPeer])
        expect(dpOneShotReady && dpOneShotArmed && dpOneShotCleared && dpOneShotFast
                && dpOneShotHeld && dpOneShotArrivedLater,
            "A15c: the unhide that follows a clear still waits out the floor, and does arrive "
                + "once it expires (fixture spent \(String(format: "%.3f", dpOneShotSpent))s "
                + "arming; mutation: letting the clear reset `lastSent` leaves the clock cleared "
                + "through it, and this payload goes out inside the interval)")

        // A15d is gone with the grant it tested — an armed-but-unspent state cannot occur.

        // A2 — the two behaviours a previous review found unguarded.

        // Superseding a live connection must close the old socket, checked
        // from the OLD PEER reaching EOF — an fd number can be reused, so "is
        // fd N still open" proves nothing.
        let (dpSupPeers, dpSupClient, dpSupIdx) = dpRig(peers: 2)
        dpSupClient.reconnectDelay = 0.02
        dpSupClient.start()
        _ = dpWaitUntil { dpSupClient.isConnectedForTesting }
        // Drain the handshake first, or the peer has bytes waiting and can
        // never report EOF.
        _ = dpRecv(dpSupPeers[0])
        dpSupClient.scheduleReconnectForTesting()
        _ = dpWaitUntil { dpSupIdx.value >= 2 }
        let dpSupClosed = dpWaitUntil {
            var byte: UInt8 = 0
            return recv(dpSupPeers[0], &byte, 1, MSG_DONTWAIT) == 0
        }
        expect(dpSupClosed,
            "reconnecting over a live connection closes the superseded socket (mutation: dropping "
                + "openConnection's `if fd >= 0 { teardown() }` leaks the descriptor and the old "
                + "peer never sees EOF)")
        dpSupClient.stop()
        close(dpSupPeers[0])
        close(dpSupPeers[1])

        // The retry budget resets on READY, so a long session survives more
        // than `maxReconnectAttempts` restarts — the peer must answer READY
        // before dropping, or a fixture that closes immediately would pass
        // even with the reset removed.
        let dpReadyFrame = dpFrameBytes(1, "{\"evt\":\"READY\"}")
        let dpReadyCount = DPCounter()
        let dpReadyClient = DiscordIPCClient(connect: {
            var fds: [Int32] = [-1, -1]
            _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
            var on: Int32 = 1
            setsockopt(fds[1], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            dpReadyCount.value += 1
            _ = dpReadyFrame.withUnsafeBytes { send(fds[1], $0.baseAddress, $0.count, 0) }
            let peer = fds[1]
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { close(peer) }
            return fds[0]
        })
        dpReadyClient.reconnectDelay = 0.01
        dpReadyClient.start()
        // Initial connect plus the cap is 6; anything beyond it can only come
        // from a budget that was reset.
        let dpReadyBeyondCap = dpWaitUntil {
            dpReadyCount.value > DiscordIPCClient.maxReconnectAttempts + 1
        }
        dpReadyClient.stop()

        // The mirror image: a peer that connects, says nothing, and drops
        // must still exhaust the budget — the reset has to be on READY, not
        // on socket-open, or this reconnects forever.
        let dpMuteCount = DPCounter()
        let dpMuteClient = DiscordIPCClient(connect: {
            var fds: [Int32] = [-1, -1]
            _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
            var on: Int32 = 1
            setsockopt(fds[1], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            dpMuteCount.value += 1
            let peer = fds[1]
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { close(peer) }
            return fds[0]
        })
        dpMuteClient.reconnectDelay = 0.01
        dpMuteClient.start()
        let dpMuteCap = DiscordIPCClient.maxReconnectAttempts + 1
        _ = dpWaitUntil { dpMuteCount.value >= dpMuteCap }
        // Long enough for ~30 more cycles at this delay, short enough not to
        // pad the suite.
        for _ in 0..<60 where dpMuteCount.value <= dpMuteCap { usleep(5_000) }
        dpMuteClient.stop()
        expect(dpReadyBeyondCap && dpMuteCount.value <= dpMuteCap,
            "reaching READY resets the retry budget, and a peer that never reaches READY still "
                + "exhausts it as normal "
                + "(mutation: dropping `attempts = 0` from the READY branch caps reconnects at "
                + "maxReconnectAttempts for the whole start() lifetime; resetting on socket-open "
                + "instead reconnects forever against a peer that accepts and immediately drops)")

        // Codex round 1 on the transport PR — four findings that were all the
        // same root: the lifecycle treated "connected, published, dropped" as
        // the end of the story instead of something that has to come back.

        // Reconnecting republishes the last activity, or the presence stays
        // missing until the producer happens to publish again.
        let dpRepubReady = dpFrameBytes(1, "{\"evt\":\"READY\"}")
        let (dpRepubPeers, dpRepubClient, dpRepubIdx) = dpRig(peers: 2)
        dpRepubClient.reconnectDelay = 0.02
        // Deliberately high: a restore re-sends bytes Discord already has, so
        // it must not queue behind the sampling floor. With the throttle
        // applied to it, this frame would arrive 30s late and the wait below
        // would time out.
        dpRepubClient.publishInterval = 30
        dpRepubClient.start()
        _ = dpWaitUntil { dpRepubClient.isConnectedForTesting }
        _ = dpRepubReady.withUnsafeBytes { send(dpRepubPeers[0], $0.baseAddress, $0.count, 0) }
        _ = dpWaitUntil { dpRepubClient.inboundTokenForTesting == DiscordIPC.readyEvent }
        dpRepubClient.publish(dpWirePayload)
        dpRepubClient.drainForTesting()
        _ = dpDrainToEOF(dpRepubPeers[0])
        // Break the first connection; the client retries onto the second pair.
        close(dpRepubPeers[0])
        _ = dpWaitUntil { dpRepubIdx.value >= 2 }
        _ = dpRepubReady.withUnsafeBytes { send(dpRepubPeers[1], $0.baseAddress, $0.count, 0) }
        dpRepubClient.drainForTesting()
        // No second `publish()` anywhere: whatever arrives here was resent by
        // the client itself.
        var dpRepubSeen = false
        _ = dpWaitUntil {
            if dpFrames(dpRepubPeers[1]).contains(where: {
                $0.0 == .frame && String(decoding: $0.1, as: UTF8.self).contains("12K tokens today")
            }) { dpRepubSeen = true }
            return dpRepubSeen
        }
        expect(dpRepubSeen,
            "a replacement connection republishes the last activity without a new publish() "
                + "(mutation: dropping the READY branch's `hasPending = true` leaves the presence "
                + "missing until the next producer update)")
        dpRepubClient.stop()
        close(dpRepubPeers[1])

        // Exhausting the retry budget returns the client to a state a later
        // start() can act on. Leaving `running` true made start() hit the
        // idempotence guard and do nothing, so a client started once at launch
        // could never recover once Discord had been away long enough.
        let dpDeadCount = DPCounter()
        let dpDeadClient = DiscordIPCClient(connect: {
            dpDeadCount.value += 1
            throw DiscordIPC.Failure.unavailable
        })
        dpDeadClient.reconnectDelay = 0.01
        dpDeadClient.start()
        let dpDeadCap = DiscordIPCClient.maxReconnectAttempts + 1
        _ = dpWaitUntil { dpDeadCount.value >= dpDeadCap }
        for _ in 0..<40 where dpDeadCount.value <= dpDeadCap { usleep(5_000) }
        let dpDeadBefore = dpDeadCount.value
        dpDeadClient.start()
        let dpDeadRestarted = dpWaitUntil { dpDeadCount.value > dpDeadBefore }
        dpDeadClient.stop()
        expect(dpDeadBefore == dpDeadCap && dpDeadRestarted,
            "a client whose retry budget ran out can be started again (mutation: returning from "
                + "scheduleReconnect without giveUp() leaves `running` true and the second start() "
                + "silently does nothing)")

        // A peer that accepts and then says nothing must not hold the client
        // forever. SO_RCVTIMEO cannot see this — the read source never fires on
        // an idle socket, so no recv() runs and its timeout is never observed.
        let dpMuteReadyCount = DPCounter()
        let dpMuteReadyClient = DiscordIPCClient(connect: {
            var fds: [Int32] = [-1, -1]
            _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
            var on: Int32 = 1
            setsockopt(fds[1], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            dpMuteReadyCount.value += 1
            // The peer end is deliberately never closed and never written to.
            return fds[0]
        })
        dpMuteReadyClient.reconnectDelay = 0.01
        dpMuteReadyClient.readyTimeout = 0.05
        dpMuteReadyClient.start()
        let dpMuteReadyRetried = dpWaitUntil { dpMuteReadyCount.value >= 2 }
        dpMuteReadyClient.stop()
        expect(dpMuteReadyRetried,
            "a silent endpoint trips the READY deadline and is retried (mutation: removing "
                + "armReadyDeadline leaves the client connected-but-never-ready forever, with "
                + "every publish parked behind `ready`)")

        // Codex round 2 — both findings are consequences of round 1's fixes.

        // The kill switch clears the queued payload even when the retry
        // budget already gave up (`giveUp()` keeps `pending` on purpose so a
        // later start() can restore).
        let dpAbandonReady = dpFrameBytes(1, "{\"evt\":\"READY\"}")
        let dpAbandonPairs = [dpSocketPair(), dpSocketPair()]
        // The counter doubles as the fixture's mode: 0 hands out the first
        // socket, anything below `dpAbandonRevive` fails so the budget is
        // genuinely exhausted, and the test raises it later for the second
        // start() to connect.
        let dpAbandonIdx = DPCounter()
        let dpAbandonRevive = DPCounter()
        dpAbandonRevive.value = 1_000_000
        let dpAbandonClient = DiscordIPCClient(connect: {
            let i = dpAbandonIdx.value
            dpAbandonIdx.value += 1
            if i == 0 { return dpAbandonPairs[0].0 }
            guard i >= dpAbandonRevive.value else { throw DiscordIPC.Failure.unavailable }
            return dpAbandonPairs[1].0
        })
        dpAbandonClient.reconnectDelay = 0.01
        dpAbandonClient.publishInterval = 0
        dpAbandonClient.start()
        _ = dpWaitUntil { dpAbandonClient.isConnectedForTesting }
        _ = dpAbandonReady.withUnsafeBytes { send(dpAbandonPairs[0].1, $0.baseAddress, $0.count, 0) }
        _ = dpWaitUntil { dpAbandonClient.inboundTokenForTesting == DiscordIPC.readyEvent }
        dpAbandonClient.publish(dpWirePayload)
        dpAbandonClient.drainForTesting()
        _ = dpDrainToEOF(dpAbandonPairs[0].1)
        // Drop the connection and let every remaining attempt fail, so the
        // client reaches the given-up state with `pending` still set.
        close(dpAbandonPairs[0].1)
        _ = dpWaitUntil { dpAbandonIdx.value > DiscordIPCClient.maxReconnectAttempts + 1 }
        // The user turns the feature off while it is in that state.
        dpAbandonClient.stop()
        dpAbandonClient.drainForTesting()
        // Now start again on the second socket and see whether the abandoned
        // payload comes back.
        dpAbandonRevive.value = dpAbandonIdx.value
        dpAbandonClient.start()
        _ = dpWaitUntil { dpAbandonClient.isConnectedForTesting }
        _ = dpAbandonReady.withUnsafeBytes { send(dpAbandonPairs[1].1, $0.baseAddress, $0.count, 0) }
        dpAbandonClient.drainForTesting()
        var dpAbandonRepublished = false
        for _ in 0..<60 where !dpAbandonRepublished {
            if dpFrames(dpAbandonPairs[1].1).contains(where: {
                $0.0 == .frame && String(decoding: $0.1, as: UTF8.self).contains("12K tokens today")
            }) { dpAbandonRepublished = true }
            usleep(5_000)
        }
        dpAbandonClient.stop()
        close(dpAbandonPairs[1].1)
        expect(!dpAbandonRepublished,
            "stop() clears the payload the retry give-up kept, so a later start() does not "
                + "resurrect it (mutation: restoring stop()'s `guard running else { return }` "
                + "republishes an activity the user already switched off)")

        // A clear is not a new sample, so it must not queue behind the
        // sampling floor: delaying one keeps a stale presence public for up to
        // the whole interval after the user hid the clients that produced it.
        let dpClearReady = dpFrameBytes(1, "{\"evt\":\"READY\"}")
        let dpClearSent = dpScenario { peer, client in
            client.publishInterval = 30
            _ = dpClearReady.withUnsafeBytes { send(peer, $0.baseAddress, $0.count, 0) }
            _ = dpWaitUntil { client.inboundTokenForTesting == DiscordIPC.readyEvent }
            client.publish(dpWirePayload)
            client.drainForTesting()
            _ = dpDrainToEOF(peer)
            client.publish(nil)
            client.drainForTesting()
            var sent = false
            for _ in 0..<60 where !sent {
                if dpFrames(peer).contains(where: {
                    $0.0 == .frame && String(decoding: $0.1, as: UTF8.self).contains("\"activity\":null")
                }) { sent = true }
                usleep(5_000)
            }
            return sent
        }
        expect(dpClearSent,
            "a clear goes out immediately rather than waiting for the publish floor (mutation: "
                + "throttling it unconditionally leaves a stale presence public for the whole "
                + "interval after the user hid everything)")

        // Codex round 3 — user intent vs connection state, descriptor
        // inheritance, and the duplicate the restore exemption let in.

        // A producer update while the retry budget is spent is still the
        // latest intent, and the client is what a later start() must restore.
        // `giveUp()` used to clear `running`, so `publish()` dropped it and the
        // reconnect resurrected the pre-give-up payload instead.
        let dpIntentReady = dpFrameBytes(1, "{\"evt\":\"READY\"}")
        let dpIntentPairs = [dpSocketPair(), dpSocketPair()]
        let dpIntentIdx = DPCounter()
        let dpIntentRevive = DPCounter()
        dpIntentRevive.value = 1_000_000
        let dpIntentClient = DiscordIPCClient(connect: {
            let i = dpIntentIdx.value
            dpIntentIdx.value += 1
            if i == 0 { return dpIntentPairs[0].0 }
            guard i >= dpIntentRevive.value else { throw DiscordIPC.Failure.unavailable }
            return dpIntentPairs[1].0
        })
        dpIntentClient.reconnectDelay = 0.01
        dpIntentClient.publishInterval = 0
        dpIntentClient.start()
        _ = dpWaitUntil { dpIntentClient.isConnectedForTesting }
        _ = dpIntentReady.withUnsafeBytes { send(dpIntentPairs[0].1, $0.baseAddress, $0.count, 0) }
        _ = dpWaitUntil { dpIntentClient.inboundTokenForTesting == DiscordIPC.readyEvent }
        dpIntentClient.publish(dpWirePayload)
        dpIntentClient.drainForTesting()
        _ = dpDrainToEOF(dpIntentPairs[0].1)
        close(dpIntentPairs[0].1)
        _ = dpWaitUntil { dpIntentIdx.value > DiscordIPCClient.maxReconnectAttempts + 1 }
        // The producer moves on while the client is abandoned.
        let dpIntentNewer = dpP("77K tokens today", state: "Zed · $1-5")
        dpIntentClient.publish(dpIntentNewer)
        dpIntentRevive.value = dpIntentIdx.value
        dpIntentClient.start()
        _ = dpWaitUntil { dpIntentClient.isConnectedForTesting }
        _ = dpIntentReady.withUnsafeBytes { send(dpIntentPairs[1].1, $0.baseAddress, $0.count, 0) }
        dpIntentClient.drainForTesting()
        var dpIntentGotNewer = false
        var dpIntentGotStale = false
        for _ in 0..<60 where !dpIntentGotNewer {
            for (op, body) in dpFrames(dpIntentPairs[1].1) where op == .frame {
                let text = String(decoding: body, as: UTF8.self)
                if text.contains("77K tokens today") { dpIntentGotNewer = true }
                if text.contains("12K tokens today") { dpIntentGotStale = true }
            }
            usleep(5_000)
        }
        dpIntentClient.stop()
        close(dpIntentPairs[1].1)
        expect(dpIntentGotNewer && !dpIntentGotStale,
            "a publish while the retries are spent is the intent a later start() restores "
                + "(mutation: having giveUp() clear `running` makes publish() drop it and the "
                + "reconnect republishes the pre-give-up payload)")

        // The socket must not survive into a child process the Rust core
        // spawns, checked both as adopted and from the moment it is created.
        let dpCloexecPair = dpSocketPair()
        let dpCloexecClient = DiscordIPCClient(connect: { dpCloexecPair.0 })
        dpCloexecClient.start()
        _ = dpWaitUntil { dpCloexecClient.isConnectedForTesting }
        let dpCloexecFlags = fcntl(dpCloexecPair.0, F_GETFD)
        dpCloexecClient.stop()
        close(dpCloexecPair.1)

        // Publishing the same payload twice on one connection sends it once.
        // The throttle exemption is for restores; without a per-connection
        // record it also let a duplicate through immediately, which resets the
        // floor's clock and delays the next real payload behind a no-op.
        let dpDupReady = dpFrameBytes(1, "{\"evt\":\"READY\"}")
        let dpDupResent = dpScenario { peer, client in
            client.publishInterval = 0
            _ = dpDupReady.withUnsafeBytes { send(peer, $0.baseAddress, $0.count, 0) }
            _ = dpWaitUntil { client.inboundTokenForTesting == DiscordIPC.readyEvent }
            client.publish(dpWirePayload)
            client.drainForTesting()
            _ = dpDrainToEOF(peer)
            client.publish(dpWirePayload)
            client.drainForTesting()
            var resent = false
            for _ in 0..<40 where !resent {
                if dpFrames(peer).contains(where: {
                    $0.0 == .frame && String(decoding: $0.1, as: UTF8.self).contains("12K tokens today")
                }) { resent = true }
                usleep(5_000)
            }
            return resent
        }
        expect(!dpDupResent,
            "an identical payload on the same connection is not sent twice (mutation: dropping "
                + "the deliveredOnThisConnection check resends it immediately, past the floor)")

        // Codex round 4 — the connect path itself, which every earlier round
        // had treated as a detail that either works or throws.
        let dpBornFD = DiscordIPC.makeSocket()
        let dpBornFlags = fcntl(dpBornFD, F_GETFD)
        close(dpBornFD)
        expect((dpCloexecFlags >= 0 && (dpCloexecFlags & FD_CLOEXEC) != 0)
                && (dpBornFD >= 0 && (dpBornFlags & FD_CLOEXEC) != 0),
            "the socket is close-on-exec both as adopted and from the moment makeSocket() "
                + "creates it (mutation: dropping either fcntl leaks the descriptor into helpers "
                + "the Rust core spawns, or leaves the connect() window inheritable)")

        // The restore skipped the floor but still moved its
        // clock, so a restore delayed the next real payload by a full
        // interval measured from the restore instead of from the last sample.
        let dpFloorReady = dpFrameBytes(1, "{\"evt\":\"READY\"}")
        let (dpFloorPeers, dpFloorClient, dpFloorIdx) = dpRig(peers: 2)
        dpFloorClient.reconnectDelay = 0.02
        dpFloorClient.publishInterval = 1.0
        dpFloorClient.start()
        _ = dpWaitUntil { dpFloorClient.isConnectedForTesting }
        _ = dpFloorReady.withUnsafeBytes { send(dpFloorPeers[0], $0.baseAddress, $0.count, 0) }
        _ = dpWaitUntil { dpFloorClient.inboundTokenForTesting == DiscordIPC.readyEvent }
        dpFloorClient.publish(dpWirePayload)
        dpFloorClient.drainForTesting()
        _ = dpDrainToEOF(dpFloorPeers[0])
        // Let the interval elapse against the real sample, so the payload that
        // follows the restore is due immediately if the clock was left alone.
        usleep(1_200_000)
        close(dpFloorPeers[0])
        _ = dpWaitUntil { dpFloorIdx.value >= 2 }
        _ = dpFloorReady.withUnsafeBytes { send(dpFloorPeers[1], $0.baseAddress, $0.count, 0) }
        // Wait for the restore to actually reach the socket before
        // publishing next, or both builds send it immediately and this
        // measures nothing.
        var dpFloorRestored = false
        for _ in 0..<200 where !dpFloorRestored {
            if dpFrames(dpFloorPeers[1]).contains(where: {
                $0.0 == .frame && String(decoding: $0.1, as: UTF8.self).contains("12K tokens today")
            }) { dpFloorRestored = true }
            usleep(5_000)
        }
        dpFloorClient.publish(dpP("55K tokens today", state: "Amp · $5-10"))
        dpFloorClient.drainForTesting()
        // 400ms: comfortably under the 1s the buggy path would defer by, and
        // comfortably over the time a due payload needs to reach the socket.
        var dpFloorPrompt = false
        for _ in 0..<80 where !dpFloorPrompt {
            if dpFrames(dpFloorPeers[1]).contains(where: {
                $0.0 == .frame && String(decoding: $0.1, as: UTF8.self).contains("55K tokens today")
            }) { dpFloorPrompt = true }
            usleep(5_000)
        }
        dpFloorClient.stop()
        close(dpFloorPeers[1])
        expect(dpFloorRestored && dpFloorPrompt,
            "a restore does not consume the publish interval (mutation: advancing lastSent on a "
                + "write that carries no new information throttles the next real payload from the "
                + "restore instead of from the last sample)")

        // MARK: - Discord Rich Presence wiring (DISCORD-PRESENCE M2b)
        //
        // M1 built the payload and M2a the transport, both with no caller. This
        // section covers the only question the wiring adds: can data actually
        // get out, and under what.

        // A1 (P0) — the demo/test gate, asserted through the production factory
        // `AppDelegate.applicationDidFinishLaunching` and `applyDiscordPresence`
        // both call. SelfTest cannot reach the app lifecycle (`run()` returns
        // `Never` before `NSApplication.shared`), so the gate is a static
        // function with injectable arguments rather than something buried in a
        // delegate method — that seam is what makes this assertion possible at
        // all.
        //
        // The flag SET is pinned separately from the behaviour: every assertion
        // below iterates `testArguments`, so all of them pass trivially on a
        // shortened array. `--icon-gallery` is in it because that debug window
        // enters the normal lifecycle and refreshes the live graph.
        let dpTestFlags = DiscordPresence.testArguments
        expect(dpTestFlags.sorted() == ["--demo", "--icon-gallery", "--selftest", "--smoke"],
            "A1: the refused arguments are exactly demo, smoke, selftest and the icon gallery")
        let dpLiveClient = DiscordIPCClient(connect: { throw DiscordIPC.Failure.unavailable })
        expect(
            dpTestFlags.allSatisfy {
                AppDelegate.makeDiscordClient(
                    arguments: ["TokenBar", $0, "--open-popover"], enabled: true) == nil
                    && AppDelegate.makeDiscordClient(
                        existing: dpLiveClient, arguments: ["TokenBar", $0], enabled: true) == nil
                    && !DiscordPresence.mayConnect(arguments: [$0], enabled: true)
            },
            "A1: no demo/smoke/selftest run builds a client or keeps an existing one, even with "
                + "the switch forced on, and the gate function itself puts the flags above the "
                + "preference (mutation: reading the preference before the flags publishes "
                + "fixture numbers onto the user's real Discord profile, which is the one "
                + "failure this feature cannot take back)")
        // The control half. Without it every assertion above passes on a
        // factory that refuses everything unconditionally.
        expect(
            AppDelegate.makeDiscordClient(arguments: ["TokenBar"], enabled: true) != nil
                && AppDelegate.makeDiscordClient(arguments: ["TokenBar"], enabled: false) == nil
                && AppDelegate.makeDiscordClient(
                    existing: dpLiveClient, arguments: ["TokenBar"], enabled: true) === dpLiveClient
                && DiscordPresence.mayConnect(arguments: [], enabled: true)
                && !DiscordPresence.mayConnect(arguments: [], enabled: false),
            "A1 control: an ordinary run builds a client, reuses the one it was given rather "
                + "than opening a second connection, and refuses when the switch is off")

        // A15b — which visibility change retires earlier work. Getting this
        // backwards is not cosmetic: it would retire work an unhide leaves
        // perfectly valid while letting a hide's stale payload through — the
        // exact inversion. The swap case is the one a subset or size test gets
        // wrong.
        func dpChange(_ previous: String, _ current: String) -> DiscordIPC.VisibilityChange {
            AppDelegate.visibilityChange(previousHiddenRaw: previous, hiddenRaw: current)
        }
        let dpChanges: [(String, String, DiscordIPC.VisibilityChange)] = [
            ("", "amp", .reducing), ("amp", "", .increasing),
            ("amp", "amp,zed", .reducing), ("amp,zed", "amp", .increasing),
            ("amp", "zed", .reducing),
            ("amp", "amp", DiscordIPC.VisibilityChange.none), ("", "", .none),
        ]
        for (previous, current, expected) in dpChanges {
            expect(dpChange(previous, current) == expected,
                "A15b: \"\(previous)\" -> \"\(current)\" is \(expected) (mutations: collapsing "
                    + "`.increasing` into `.none` lets an unhide inherit a pending reduction's "
                    + "bypass; a strict-subset or size test calls the swap no change and leaves "
                    + "the newly hidden client named for the rest of the floor; `.reducing` by "
                    + "default hands every ordinary sample a bypass)")
        }

        // A2 — the switch. Read through the authoritative accessor against an
        // isolated suite, never the process's own defaults.
        // Fixed, not per-run UUID. `UserDefaults(suiteName:)` creates a
        // persistent plist unconditionally and NONE of the cleanup calls
        // delete the file — measured: removing the domain on the instance, on
        // `.standard`, after clearing the keys, and after setting an empty
        // persistent domain all leave it behind. A fresh name per run
        // therefore deposits one more ~/Library/Preferences file every time
        // the suite runs. One reused name caps it at a single empty file.
        let dpSuiteName = "TokenBar.SelfTest.Discord"
        if let dpDefaults = UserDefaults(suiteName: dpSuiteName) {
            // On `UserDefaults.standard`, not on the suite's own instance:
            // calling it on the instance leaves the plist behind, so every run
            // deposited another ~/Library/Preferences file forever.
            defer { UserDefaults.standard.removePersistentDomain(forName: dpSuiteName) }
            // Every wrong type, by table. The string "true" is the one that
            // matters most: the Argument Domain, which the manual acceptance
            // flow in verification.md uses, stores `-tokenbar.<key> true` as
            // exactly that string, and `bool(forKey:)` coerces it. The integer
            // is 1 rather than 2 because `as? Bool` bridges NSNumber, so the
            // one that actually slips through is the one equal to true.
            let dpWrongTypes: [(String, Any?)] = [
                ("an absent key", nil), ("the string \"true\"", "true"),
                ("the integer 1", 1), ("the double 1.0", 1.0),
                ("a non-boolean number", 2), ("a wholly wrong type", ["on"]),
            ]
            for (label, value) in dpWrongTypes {
                if let value { dpDefaults.set(value, forKey: DiscordPresence.enabledKey) }
                expect(!DiscordPresence.enabled(defaults: dpDefaults),
                    "A2: \(label) is not the switch (mutation: `bool(forKey:)` coerces the "
                        + "string, and `as? Bool` alone bridges the integer — only a CFBoolean "
                        + "check rejects both)")
            }
            dpDefaults.set(true, forKey: DiscordPresence.enabledKey)
            let dpRealTrue = DiscordPresence.enabled(defaults: dpDefaults)
            dpDefaults.set(false, forKey: DiscordPresence.enabledKey)
            expect(dpRealTrue && !DiscordPresence.enabled(defaults: dpDefaults),
                "A2 control: a real Bool true is the switch and an explicit false is off — "
                    + "without this the table above passes on an accessor that always says false")
            // A25 — the cost switch reads through the SAME strict path. Sharing
            // one reader is what keeps the two from drifting, so this checks the
            // sharing rather than re-testing every wrong type.
            //
            // The key is removed rather than overwritten before the control, and
            // that is not tidiness: writing a real `true` over a stored integer
            // `1` DOES NOT CHANGE THE STORED TYPE — measured, it stays a
            // non-CFBoolean NSNumber, so the control would fail against a
            // perfectly correct accessor. A2 above only escapes this because it
            // writes an array in between, which is true by accident.
            let dpCostAbsent = DiscordPresence.costStyle(defaults: dpDefaults) == .banded
            dpDefaults.set("true", forKey: DiscordPresence.wholeDollarsKey)
            let dpCostString = DiscordPresence.costStyle(defaults: dpDefaults) == .banded
            dpDefaults.set(1, forKey: DiscordPresence.wholeDollarsKey)
            let dpCostInt = DiscordPresence.costStyle(defaults: dpDefaults) == .banded
            dpDefaults.removeObject(forKey: DiscordPresence.wholeDollarsKey)
            dpDefaults.set(true, forKey: DiscordPresence.wholeDollarsKey)
            expect(
                dpCostAbsent && dpCostString && dpCostInt
                    && DiscordPresence.costStyle(defaults: dpDefaults) == .wholeDollars,
                "A25: the cost switch refuses an absent key, the string and the integer — "
                    + "banded is the safe direction — and a real Bool true does turn it on "
                    + "(mutation: a second, looser reader for this key fails here)")
            dpDefaults.removeObject(forKey: DiscordPresence.wholeDollarsKey)
        } else {
            expect(false, "A2: the isolated defaults suite could not be created")
        }

        // A2b and the structural half of A1. Both are claims about the SHAPE of
        // the source — "declared in exactly one place", "constructed in exactly
        // one place" — which no runtime value can express: a second
        // `@AppStorage` default is invisible until the day it disagrees. So the
        // tree this binary was built from is read directly, via this file's own
        // compile-time path.
        func dpSourceFiles() -> [(name: String, text: String)] {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // Sources/TokenBar
                .deletingLastPathComponent()  // Sources
            guard let walk = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil) else { return [] }
            var out: [(name: String, text: String)] = []
            for case let url as URL in walk where url.pathExtension == "swift" {
                // This file is excluded: it quotes the very strings it counts.
                guard url.path != #filePath,
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                out.append((url.lastPathComponent, text))
            }
            return out
        }
        func dpOccurrences(_ needle: String, in files: [(name: String, text: String)]) -> Int {
            files.reduce(0) { $0 + $1.text.components(separatedBy: needle).count - 1 }
        }
        let dpSources = dpSourceFiles()
        // Whitespace-normalized copy, so `PresenceClient.init(connect : ...)`
        // cannot slip past a literal match. A source scan can always be evaded
        // by someone trying; what it has to survive is an ordinary refactor.
        let dpNormalized = dpSources.map {
            (name: $0.name, text: $0.text.filter { !$0.isWhitespace })
        }
        // The Settings binding. Nothing else observes it: the accessor
        // assertions above supply their own keys against an isolated suite, so
        // a `SettingsPanel` key that diverges from `enabledKey` leaves the whole
        // suite green while the toggle writes a key nobody reads — the feature
        // never enables, or a live presence cannot be switched off. Occurrences
        // rather than files, because a second declaration in the SAME file is
        // the easier mistake.
        expect(
            dpOccurrences("@AppStorage(DiscordPresence.enabledKey)", in: dpSources) == 1
                && dpSources.first(where: {
                    $0.text.contains("@AppStorage(DiscordPresence.enabledKey)")
                })?.name == "SettingsPanel.swift"
                && dpOccurrences("\"\(DiscordPresence.enabledKey)\"", in: dpSources) == 1
                && dpOccurrences("@AppStorage(DiscordPresence.wholeDollarsKey)", in: dpSources) == 1
                && dpOccurrences("\"\(DiscordPresence.wholeDollarsKey)\"", in: dpSources) == 1,
            "A2b: each switch is declared by exactly one view, in SettingsPanel, and each key "
                + "string is written exactly once (mutation: a second `@AppStorage` default, or "
                + "a hard-coded copy of the key — the trap `tokenbar.limits.enabled` already "
                + "fell into — fails here)")
        // The payload layer reads NO defaults domain, asserted at runtime rather
        // than by scanning for `.object(forKey:`. The scan's first draft matched
        // the receiver name and looked straight past
        // `UserDefaults.standard.object(forKey:)`, which is exactly the natural
        // way to violate this, and that mutation survived the whole suite.
        //
        // Structural, and it has to be. The M1 cost-mode conjunction catches an
        // UNCONDITIONAL replacement of the parameter, because a payload reading
        // a domain renders both `.banded` and `.wholeDollars` the same way. It
        // does not catch a CONDITIONAL read — consulting the domain only when
        // `style == .banded` renders both correctly on a default-off host and
        // still makes the payload machine-dependent the moment a saved or
        // command-line whole-dollar value exists.
        //
        // Not asserted by writing the process's own domain either, which an
        // earlier revision did: it read the prior value with `object(forKey:)`,
        // which searches volatile domains including `NSArgumentDomain`, while
        // `set` and `removeObject` write the persistent application domain.
        // Running the suite with `-tokenbar.discord.wholeDollars ...`, which
        // the manual acceptance flow does, would have copied a command-line
        // override into the user's saved preferences. A test must not be able
        // to change what it measures.
        //
        // Scoped to the BODY of `payload(...)`, brace-matched, rather than to
        // the file: the file legitimately declares the accessors, and every
        // wider form of this check has been evaded in turn. Counting
        // `.object(forKey:` matched on the receiver name and could only see
        // reads written against a `defaults` parameter, which `payload()` does
        // not have. Searching the file for `UserDefaults.standard` missed
        // `DiscordPresence.costStyle()` — the accessor spells `.standard` as
        // its own default argument, so calling it introduces no such substring.
        // Banning the accessor calls inside this one body closes both.
        let dpPayloadBody: String = {
            guard let text = dpSources.first(where: { $0.name == "DiscordPresence.swift" })?.text,
                  let start = text.range(of: "static func payload(") else { return "" }
            var depth = 0
            var opened = false
            var out = ""
            for character in text[start.lowerBound...] {
                out.append(character)
                if character == "{" { depth += 1; opened = true }
                if character == "}" {
                    depth -= 1
                    if opened && depth == 0 { break }
                }
            }
            return out
        }()
        expect(
            !dpPayloadBody.isEmpty
                && !dpPayloadBody.contains("UserDefaults")
                && !dpPayloadBody.contains("costStyle(")
                && !dpPayloadBody.contains("enabled("),
            "A2b: `payload(...)` reaches no defaults domain, directly or through an accessor, so "
                + "what it publishes depends on its arguments and not on the machine running it "
                + "(mutations: `UserDefaults.standard.bool(forKey:)`, or the subtler "
                + "`costStyle == .banded ? DiscordPresence.costStyle() : costStyle`, which reads "
                + "correctly on a default-off host and goes machine-dependent the moment a saved "
                + "whole-dollar value exists)")

        // The gate is the only path to a client. All three are shape claims —
        // "constructed in exactly one place", "not aliased", "not handed
        // curated arguments" — which no runtime value can express: a second
        // construction site is invisible until the day it runs, and SelfTest
        // cannot reach the app lifecycle.
        let dpCtorForms = ["DiscordIPCClient(connect:", "DiscordIPCClient.init(connect:"]
        expect(
            dpCtorForms.reduce(0) { $0 + dpOccurrences($1, in: dpNormalized) } == 1
                && dpOccurrences("typealias", in: dpNormalized.filter {
                    $0.text.contains("DiscordIPCClient")
                }) == 0
                && !dpNormalized.contains { $0.text.contains("makeDiscordClient(arguments:") },
            "A1: exactly one production site constructs a client and it is the gated factory, "
                + "the type is not aliased, and no call site substitutes its own arguments for "
                + "the process's (mutations: constructing one elsewhere including via `.init`, "
                + "renaming the type, or passing a curated array, each bypass the demo/test gate)")
        // A16 — the same class of claim, and kept for the same reason. The
        // disable path leaves the stopped client in `discord` on purpose:
        // `applicationWillTerminate` drains the queued clear inside
        // `if let discord`, so re-adding `discord = nil` after `stop()` lets an
        // immediate quit abandon it and leave the withdrawn activity public.
        // That needs a real app lifecycle to exercise and nothing else in the
        // suite detects it, so the shape is asserted instead.
        expect(dpOccurrences("discord=nil", in: dpNormalized) == 0,
            "A16: the disable path keeps the client reference until termination drains its clear "
                + "(mutation: re-adding `discord = nil` after `stop()` abandons the clear on an "
                + "off-then-quit, because the drain is guarded on the reference)")
        // A26c — the button constants, pinned as literal DECLARATIONS and as a
        // file compiled identically in every configuration. Neither half covers
        // the other's survivor, and both were measured to pass all 659
        // assertions before these existed:
        //
        //     #if DEBUG  …literal…  #else  …+ "?ref=" + NSUserName()  #endif
        //     static var buttonURL: String { Bundle.main.bundleIdentifier == nil
        //         ? literal : literal + "?ref=" + hash(NSUserName()) }
        //
        // What would reach every viewer's click, and GitHub's request logs, is
        // the account name of the person whose profile it is.
        //
        // This run is under `swift build` as a bare executable while shipping
        // runs release configuration inside an .app, so the wire assertions
        // ARE structurally blind to that difference here. They are not blind to
        // it in `make selftest-bundled`, which runs this same suite from the
        // bundled binary on every push to main and does catch all three of
        // these — including the use-site suffix, which the scan below cannot
        // see. What survives here is the PR-time proxy for a gate that runs at
        // merge; it is not the enforcement, and a fourth scan is not the answer
        // to whatever escapes it. Directives are counted as lines
        // starting with `#if`/`#else`/`#endif`, not as a substring: the only
        // `#if` in that file is inside the comment stating this policy.
        let dpTransportDirectives = dpSources
            .filter { $0.name == "DiscordIPC.swift" }
            .flatMap { $0.text.split(separator: "\n", omittingEmptySubsequences: false) }
            .filter {
                let trimmed = $0.drop { $0 == " " || $0 == "\t" }
                return trimmed.hasPrefix("#if") || trimmed.hasPrefix("#else")
                    || trimmed.hasPrefix("#endif")
            }
        expect(
            dpOccurrences(
                "static let buttonURL = \"https://github.com/Nanako0129/TokenBar\"",
                in: dpSources.filter { $0.name == "DiscordIPC.swift" }) == 1
                && dpOccurrences(
                    "static let buttonLabel = \"View on GitHub\"",
                    in: dpSources.filter { $0.name == "DiscordIPC.swift" }) == 1
                && dpTransportDirectives.isEmpty,
            "A26c: both button constants are literal `static let` declarations and the transport "
                + "compiles identically in every configuration, so what this suite observes is "
                + "what ships (mutations: a computed `var` reading Bundle.main, or a `#if DEBUG` "
                + "yielding the literal under test and a user-derived URL in release)")
        // M6's gap: the wiring layer's choice of hidden set had no assertion at
        // all, and the payload fixtures cannot see it — they are handed a set.
        // `quotaExcludedClients()` and `hiddenLimitsClients()` are different
        // sets with different meanings; only tab-hidden belongs here.
        let dpDelegate = dpNormalized.first { $0.name == "AppDelegate.swift" }
        expect(dpDelegate?.text.contains("hidden:ClientRegistry.hiddenClients()") == true
            && dpDelegate?.text.contains("hidden:ClientRegistry.quotaExcludedClients()") == false
            && dpDelegate?.text.contains("hidden:ClientRegistry.hiddenLimitsClients()") == false,
            "A1: the published payload excludes the tab-hidden clients and no other set "
                + "(mutation: swapping in quotaExcludedClients publishes a different total and "
                + "a different top client, and every payload fixture stays green)")

        // A8 — Discord absent. The common case, not an error: the connect
        // closure fails the way `connectToDiscord` does when there is no socket
        // to reach. Injected rather than real, because a selftest must not open
        // a connection to whatever Discord happens to be running on the
        // machine running it.
        let dpAbsentAttempts = DPCounter()
        let dpAbsentClient = DiscordIPCClient(connect: {
            dpAbsentAttempts.value += 1
            throw DiscordIPC.Failure.unavailable
        })
        dpAbsentClient.reconnectDelay = 0.01
        let dpAbsentBegan = DispatchTime.now()
        dpAbsentClient.start()
        dpAbsentClient.publish(dpP("12K tokens today", state: "Amp · $1-5"))
        let dpAbsentBlocked = Double(
            DispatchTime.now().uptimeNanoseconds - dpAbsentBegan.uptimeNanoseconds) / 1_000_000_000
        _ = dpWaitUntil { dpAbsentAttempts.value > DiscordIPCClient.maxReconnectAttempts }
        let dpAbsentConnected = dpAbsentClient.isConnectedForTesting
        dpAbsentClient.stop()
        dpAbsentClient.drainForTesting()
        expect(dpAbsentBlocked < 0.05 && !dpAbsentConnected && dpAbsentAttempts.value > 1,
            "A8: with Discord absent the caller is never blocked, nothing connects, and the app "
                + "keeps running (mutation: making start()/publish() synchronous parks the main "
                + "actor behind a socket that is not there)")

        // MARK: - LP3: restore the last-good dashboard on restart

        let lp3Identity = BuildIdentity(
            bundleIdentifier: "com.nyanako.tokenbar", shortVersion: "9.9.9", buildNumber: "999")
        let lp3OtherBuild = BuildIdentity(
            bundleIdentifier: "com.nyanako.tokenbar", shortVersion: "9.9.9", buildNumber: "1000")
        let lp3OtherBundle = BuildIdentity(
            bundleIdentifier: "com.example.other", shortVersion: "9.9.9", buildNumber: "999")

        func lp3TempDir(_ label: String) -> URL {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("tokenbar-lp3-\(label)-\(UUID().uuidString)", isDirectory: true)
        }

        func lp3Envelope(
            year: String?,
            identity: BuildIdentity = lp3Identity,
            schema: Int = SnapshotEnvelope.schemaVersion,
            savedAt: Date = Date(),
            payload: UsagePayload? = nil,
            knownYears: [String]? = nil,
            scanRoots: String = ClaudeExtraRoots.appliedPayloadJSON
        ) -> SnapshotEnvelope {
            let p = payload ?? DemoData.payload(for: year)
            return SnapshotEnvelope(
                snapshotSchemaVersion: schema, bundleIdentifier: identity.bundleIdentifier,
                shortVersion: identity.shortVersion, buildNumber: identity.buildNumber,
                savedAt: savedAt, selectedYear: year, payload: p,
                knownYears: knownYears ?? p.years.map(\.year), scanRoots: scanRoots)
        }

        let lp3Encoder: JSONEncoder = {
            let e = JSONEncoder()
            e.outputFormatting = [.sortedKeys]
            return e
        }()
        let lp3Decoder = JSONDecoder()
        func lp3Encode(_ envelope: SnapshotEnvelope) -> Data {
            (try? lp3Encoder.encode(envelope)) ?? Data()
        }
        func lp3PrepareDir(_ dir: URL, mode: Int16 = 0o700) {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: mode])
        }
        let lp3FileName = "dashboard-snapshot.json"

        // --- SnapshotStore: round trip + validate rejection matrix ---

        let lp3RTDir = lp3TempDir("roundtrip")
        let lp3RTEnvelope = lp3Envelope(year: "2033")
        let lp3RTWrote = SnapshotStore.write(lp3Encode(lp3RTEnvelope), in: lp3RTDir)
        let lp3RTBack = SnapshotStore.readBytes(in: lp3RTDir).flatMap {
            try? lp3Decoder.decode(SnapshotEnvelope.self, from: $0)
        }
        expect(
            lp3RTWrote
                && lp3RTBack.map {
                    SnapshotStore.validate($0, expectedYear: "2033", identity: lp3Identity)
                } == true
                && lp3RTBack?.payload.years.map(\.year) == ["2033"],
            "LP3: a written snapshot round-trips through write/readBytes/decode/validate with "
                + "a matching payload and year, and reaches .ready not .loading (see the "
                + "DashboardModel-level disk-restore check below)")

        func lp3ExpectRejected(
            _ label: String, _ envelope: SnapshotEnvelope,
            expectedYear: String? = "2033", identity: BuildIdentity = lp3Identity
        ) {
            expect(
                !SnapshotStore.validate(envelope, expectedYear: expectedYear, identity: identity),
                "LP3 validate rejects: \(label)")
        }

        lp3ExpectRejected("schema mismatch", lp3Envelope(year: "2033", schema: 999))
        lp3ExpectRejected(
            "build-number mismatch", lp3Envelope(year: "2033", identity: lp3OtherBuild))
        lp3ExpectRejected(
            "bundle-identifier mismatch", lp3Envelope(year: "2033", identity: lp3OtherBundle))
        lp3ExpectRejected(
            "requested-year gate (snapshot 2033, process wants 2034)",
            lp3Envelope(year: "2033"), expectedYear: "2034")
        lp3ExpectRejected(
            "requested-year gate (snapshot all-time, process wants a year)",
            lp3Envelope(year: nil), expectedYear: "2033")
        // LP3-ROOTS. Everything else here identifies the BUILD; nothing
        // identified the INPUTS. Editing the scan roots dropped the in-memory
        // caches and left this file passing every check, so the next open
        // restored totals from a removed root — or without an added one — and
        // published them as `.ready`.
        lp3ExpectRejected(
            "scan-root mismatch (snapshot built under a root this process does not have)",
            lp3Envelope(
                year: "2033",
                scanRoots: ClaudeExtraRoots.payloadJSON(["/tmp/tokenbar-selftest-root"])))
        // The other half, or the check above is satisfied by refusing any
        // snapshot that mentions a root at all.
        let lp3Roots = ClaudeExtraRoots.payloadJSON(["/tmp/tokenbar-selftest-root"])
        expect(
            SnapshotStore.validate(
                lp3Envelope(year: "2033", scanRoots: lp3Roots),
                expectedYear: "2033", identity: lp3Identity, scanRoots: lp3Roots),
            "LP3-ROOTS and a snapshot built under the SAME roots is still accepted, "
                + "so the gate is a comparison rather than a refusal")

        // LP3-BIND. The fingerprint has to describe the SCAN, not the moment
        // the snapshot is written. The FFI returns a scan that started before a
        // registry replace even after the replace lands, so a value read at
        // capture time labels pre-change data as post-change — and the check
        // above then accepts it on the next launch, which is the acceptance the
        // field exists to withhold.
        //
        // The roots move INSIDE the fetch rather than through a gate: the
        // property is only about which side of the request the read happens on,
        // and the source's own hook puts the move exactly between them.
        let bindRoots = awaitMainActorValue { () -> String in
            let previous = ClaudeExtraRoots.appliedProvider
            defer { ClaudeExtraRoots.appliedProvider = previous }
            let before = ClaudeExtraRoots.payloadJSON(["/tmp/tokenbar-bind-before"])
            let after = ClaudeExtraRoots.payloadJSON(["/tmp/tokenbar-bind-after"])
            nonisolated(unsafe) var installed = before
            ClaudeExtraRoots.appliedProvider = { installed }
            let source = AttributedSeriesTestSource(
                graphPayload: DemoData.payload(for: nil),
                refreshPayload: DemoData.payload(for: nil))
            source.onGraph = { installed = after }
            let model = DashboardModel(source: source, initialYear: nil)
            await model.load()
            // The envelope, not the stored property. An assertion on the
            // property alone passes while the stamp beside it reads the CURRENT
            // roots instead — which is the exact substitution being guarded,
            // and it survived a mutation until this line went through the
            // builder that actually writes to disk.
            return model.snapshotEnvelope(identity: lp3Identity)?.scanRoots ?? ""
        }
        expect(bindRoots == ClaudeExtraRoots.payloadJSON(["/tmp/tokenbar-bind-before"]),
               "LP3-BIND the snapshot records the roots the scan RAN under, not the "
                   + "ones installed by the time it was captured")
        lp3ExpectRejected(
            "knownYears entry not four-digit ASCII",
            lp3Envelope(year: "2033", knownYears: ["abcd"]))
        lp3ExpectRejected(
            "knownYears duplicated",
            lp3Envelope(year: "2033", knownYears: ["2033", "2033"]))
        lp3ExpectRejected(
            "knownYears oversized",
            lp3Envelope(
                year: "2033",
                knownYears: (0...SnapshotStore.maxKnownYears).map { String(1000 + $0) } + ["2033"]))
        lp3ExpectRejected(
            "knownYears does not cover the payload's own years",
            lp3Envelope(year: "2033", knownYears: []))
        lp3ExpectRejected(
            "savedAt in the future beyond the clock-skew allowance",
            lp3Envelope(
                year: "2033",
                savedAt: Date().addingTimeInterval(SnapshotStore.futureSkewAllowance + 30)))
        lp3ExpectRejected(
            "savedAt older than the retention bound",
            lp3Envelope(
                year: "2033", savedAt: Date().addingTimeInterval(-(SnapshotStore.maxAge + 30))))

        // A contribution date outside the selected year — DemoData always
        // confines a year-scoped payload's contributions to that year, so this
        // is hand-built rather than fixture-generated.
        func lp3PayloadWithForeignContribution() -> UsagePayload? {
            let json: [String: Any] = [
                "meta": [
                    "generatedAt": "2033-06-01T12:00:00Z", "version": "test",
                    "dateRange": ["start": "2033-01-01", "end": "2033-06-01"],
                ],
                "summary": [
                    "totalTokens": 10, "totalCost": 1.0, "totalDays": 1, "activeDays": 1,
                    "averagePerDay": 1.0, "maxCostInSingleDay": 1.0,
                    "clients": ["codex"], "models": ["demo-codex"],
                ],
                "years": [[
                    "year": "2033", "totalTokens": 10, "totalCost": 1.0,
                    "range": ["start": "2033-01-01", "end": "2033-06-01"],
                ]],
                "contributions": [[
                    // Wrong year on purpose.
                    "date": "2032-12-31", "totals": ["tokens": 10, "cost": 1.0, "messages": 1],
                    "intensity": 1,
                    "tokenBreakdown": [
                        "input": 5, "output": 5, "cacheRead": 0, "cacheWrite": 0, "reasoning": 0,
                    ],
                    "clients": [[
                        "client": "codex", "modelId": "demo-codex", "providerId": "demo",
                        "tokens": [
                            "input": 5, "output": 5, "cacheRead": 0, "cacheWrite": 0,
                            "reasoning": 0,
                        ],
                        "cost": 1.0, "messages": 1,
                    ]],
                ]],
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
            return try? JSONDecoder().decode(UsagePayload.self, from: data)
        }
        if let foreignPayload = lp3PayloadWithForeignContribution() {
            lp3ExpectRejected(
                "a contribution date falls outside the selected year",
                lp3Envelope(year: "2033", payload: foreignPayload, knownYears: ["2033"]))
        } else {
            expect(false, "LP3: the hand-built foreign-contribution fixture failed to decode")
        }

        // Malformed civil dates. `ISODay.init?` parses with `Int` and then
        // multiplies, so `era * 146097` on an enormous year OVERFLOWS AND TRAPS
        // — a file on disk could crash the dashboard at launch. An all-time
        // snapshot skipped date checking entirely before, which is exactly the
        // shape such a file would take, so these are all-time envelopes.
        func lp3PayloadWithDates(
            range: (String, String), yearRange: (String, String), contribution: String
        ) -> UsagePayload? {
            let json: [String: Any] = [
                "meta": [
                    "generatedAt": "2033-06-01T12:00:00Z", "version": "test",
                    "dateRange": ["start": range.0, "end": range.1],
                ],
                "summary": [
                    "totalTokens": 10, "totalCost": 1.0, "totalDays": 1, "activeDays": 1,
                    "averagePerDay": 1.0, "maxCostInSingleDay": 1.0,
                    "clients": ["codex"], "models": ["demo-codex"],
                ],
                "years": [[
                    "year": "2033", "totalTokens": 10, "totalCost": 1.0,
                    "range": ["start": yearRange.0, "end": yearRange.1],
                ]],
                "contributions": [[
                    "date": contribution, "totals": ["tokens": 10, "cost": 1.0, "messages": 1],
                    "intensity": 1,
                    "tokenBreakdown": [
                        "input": 5, "output": 5, "cacheRead": 0, "cacheWrite": 0, "reasoning": 0,
                    ],
                    "clients": [] as [Any],
                ]],
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
            return try? JSONDecoder().decode(UsagePayload.self, from: data)
        }
        let lp3Ok = ("2033-01-01", "2033-06-01")
        let lp3Trapping = "9223372036854775807-01-01"
        let lp3DateCases: [(String, UsagePayload?)] = [
            ("meta.dateRange start would trap ISODay",
             lp3PayloadWithDates(
                 range: (lp3Trapping, "2033-06-01"), yearRange: lp3Ok,
                 contribution: "2033-01-01")),
            ("years[].range end would trap ISODay",
             lp3PayloadWithDates(
                 range: lp3Ok, yearRange: ("2033-01-01", lp3Trapping),
                 contribution: "2033-01-01")),
            ("a contribution date would trap ISODay",
             lp3PayloadWithDates(
                 range: lp3Ok, yearRange: lp3Ok, contribution: lp3Trapping)),
            ("meta.dateRange runs backwards",
             lp3PayloadWithDates(
                 range: ("2033-06-01", "2033-01-01"), yearRange: lp3Ok,
                 contribution: "2033-01-01")),
            ("a date outside the computable era",
             lp3PayloadWithDates(
                 range: lp3Ok, yearRange: lp3Ok, contribution: "1899-01-01")),
        ]
        for (label, payload) in lp3DateCases {
            guard let payload else {
                expect(false, "LP3: the \(label) fixture failed to decode")
                continue
            }
            // `expectedYear: nil` matters: the helper defaults to "2033", and
            // an all-time envelope would then be rejected by the requested-year
            // gate before any date was looked at — which is exactly how the
            // first version of these passed while the date validation was
            // deleted.
            lp3ExpectRejected(
                label, lp3Envelope(year: nil, payload: payload, knownYears: ["2033"]),
                expectedYear: nil)
        }
        // Control: the same all-time shape with every date well-formed is
        // ACCEPTED, so the five rejections above cannot be passing on a
        // validator that rejects every hand-built payload.
        if let sane = lp3PayloadWithDates(
            range: lp3Ok, yearRange: lp3Ok, contribution: "2033-01-01")
        {
            expect(
                SnapshotStore.validate(
                    lp3Envelope(year: nil, payload: sane, knownYears: ["2033"]),
                    expectedYear: nil, identity: lp3Identity),
                "LP3 control: a hand-built all-time payload with well-formed dates is accepted "
                    + "— without this the malformed-date rejections would pass on a validator "
                    + "that rejects everything hand-built")
        } else {
            expect(false, "LP3: the well-formed control fixture failed to decode")
        }

        // --- SnapshotStore: raw-file hazards — none may hang, follow, chmod, ---
        // --- or mutate the external object.                                 ---

        let lp3CorruptDir = lp3TempDir("corrupt")
        lp3PrepareDir(lp3CorruptDir)
        try? Data("not json at all".utf8).write(
            to: lp3CorruptDir.appendingPathComponent(lp3FileName))
        let lp3CorruptBytes = SnapshotStore.readBytes(in: lp3CorruptDir)
        let lp3CorruptDecoded = lp3CorruptBytes.flatMap {
            try? lp3Decoder.decode(SnapshotEnvelope.self, from: $0)
        }
        expect(
            lp3CorruptBytes != nil && lp3CorruptDecoded == nil,
            "LP3: corrupt (non-JSON) bytes are read as bytes but fail to decode, so the cold "
                + "fallback triggers at the decode step rather than a crash")

        let lp3CapDir = lp3TempDir("cap")
        lp3PrepareDir(lp3CapDir)
        try? Data(repeating: 0x41, count: SnapshotStore.byteCap).write(
            to: lp3CapDir.appendingPathComponent(lp3FileName))
        expect(
            SnapshotStore.readBytes(in: lp3CapDir)?.count == SnapshotStore.byteCap,
            "LP3: a file at EXACTLY the byte cap is read in full")

        let lp3OverCapDir = lp3TempDir("overcap")
        lp3PrepareDir(lp3OverCapDir)
        try? Data(repeating: 0x41, count: SnapshotStore.byteCap + 1).write(
            to: lp3OverCapDir.appendingPathComponent(lp3FileName))
        expect(
            SnapshotStore.readBytes(in: lp3OverCapDir) == nil,
            "LP3: a file one byte over the cap is rejected rather than truncated")

        let lp3SymlinkFileDir = lp3TempDir("symlink-file")
        lp3PrepareDir(lp3SymlinkFileDir)
        let lp3SymlinkTarget = lp3TempDir("symlink-target")
        lp3PrepareDir(lp3SymlinkTarget)
        try? Data("target contents".utf8).write(
            to: lp3SymlinkTarget.appendingPathComponent("real.json"))
        _ = symlink(
            lp3SymlinkTarget.appendingPathComponent("real.json").path,
            lp3SymlinkFileDir.appendingPathComponent(lp3FileName).path)
        expect(
            SnapshotStore.readBytes(in: lp3SymlinkFileDir) == nil,
            "LP3: a symlink where the snapshot file should be is rejected, not followed")

        let lp3SymlinkDirParent = lp3TempDir("symlink-dir-parent")
        let lp3SymlinkDirTarget = lp3TempDir("symlink-dir-target")
        lp3PrepareDir(lp3SymlinkDirTarget)
        _ = symlink(lp3SymlinkDirTarget.path, lp3SymlinkDirParent.path)
        let lp3SymlinkDirRejectsRead = SnapshotStore.readBytes(in: lp3SymlinkDirParent) == nil
        let lp3SymlinkDirRejectsWrite =
            !SnapshotStore.write(Data("x".utf8), in: lp3SymlinkDirParent)
        expect(
            lp3SymlinkDirRejectsRead && lp3SymlinkDirRejectsWrite,
            "LP3: a symlinked app directory is rejected for both read and write, not followed "
                + "(O_NOFOLLOW constrains only the final path component, and the app directory "
                + "itself IS that final component)")

        let lp3FifoDir = lp3TempDir("fifo")
        lp3PrepareDir(lp3FifoDir)
        _ = mkfifo(lp3FifoDir.appendingPathComponent(lp3FileName).path, 0o600)
        expect(
            SnapshotStore.readBytes(in: lp3FifoDir) == nil,
            "LP3: a FIFO where the snapshot file should be is rejected without blocking on it "
                + "(O_NONBLOCK on the open makes this provable rather than assumed)")

        let lp3DirInPlaceDir = lp3TempDir("dir-in-place")
        lp3PrepareDir(lp3DirInPlaceDir)
        try? FileManager.default.createDirectory(
            at: lp3DirInPlaceDir.appendingPathComponent(lp3FileName),
            withIntermediateDirectories: true)
        expect(
            SnapshotStore.readBytes(in: lp3DirInPlaceDir) == nil,
            "LP3: a directory where the snapshot file should be is rejected")

        // "Wrong owner" cannot be reproduced without root in this environment
        // (chown to another uid requires privilege this sandbox does not have);
        // "wrong mode" IS reproducible and is the sibling half of the same
        // defense — a group/world-accessible app directory must be rejected
        // for both read and write, the same as a symlinked one.
        let lp3LooseModeDir = lp3TempDir("loose-mode")
        lp3PrepareDir(lp3LooseModeDir, mode: 0o755)
        expect(
            SnapshotStore.readBytes(in: lp3LooseModeDir) == nil
                && !SnapshotStore.write(Data("x".utf8), in: lp3LooseModeDir),
            "LP3: a group/world-accessible app directory (not owner-only 0700) is rejected for "
                + "both read and write")

        // --- Allowlist: the encoded recursive key set, exactly ---

        let lp3AllowlistEnvelope = lp3Envelope(year: "2035")
        let lp3AllowlistJSON =
            (try? JSONSerialization.jsonObject(with: lp3Encode(lp3AllowlistEnvelope)))
                as? [String: Any]
        func lp3CollectKeys(_ value: Any, parentKey: String?, into set: inout Set<String>) {
            if let dict = value as? [String: Any] {
                // `turnsByClient`'s own keys are client ids — DATA, not schema
                // field names — so only its field name (recorded by the
                // parent below) belongs in the allowlist, not its contents'
                // dynamic keys. Every other nested dict is a fixed-shape
                // struct and recurses normally.
                if parentKey == "turnsByClient" {
                    for v in dict.values { lp3CollectKeys(v, parentKey: nil, into: &set) }
                    return
                }
                for (key, v) in dict {
                    set.insert(key)
                    lp3CollectKeys(v, parentKey: key, into: &set)
                }
            } else if let array = value as? [Any] {
                for v in array { lp3CollectKeys(v, parentKey: parentKey, into: &set) }
            }
        }
        var lp3ActualKeys: Set<String> = []
        if let lp3AllowlistJSON { lp3CollectKeys(lp3AllowlistJSON, parentKey: nil, into: &lp3ActualKeys) }
        let lp3ExpectedKeys: Set<String> = [
            "snapshotSchemaVersion", "bundleIdentifier", "shortVersion", "buildNumber", "savedAt",
            "selectedYear", "payload", "knownYears", "scanRoots",
            "meta", "generatedAt", "version", "dateRange", "start", "end",
            "summary", "totalTokens", "totalCost", "totalDays", "activeDays", "averagePerDay",
            "maxCostInSingleDay", "clients", "models",
            "years", "year", "range",
            "contributions", "date", "totals", "tokens", "cost", "messages", "intensity",
            "tokenBreakdown", "input", "output", "cacheRead", "cacheWrite", "reasoning",
            "client", "modelId", "providerId", "turnsByClient",
        ]
        expect(
            !lp3ActualKeys.isEmpty && lp3ActualKeys == lp3ExpectedKeys,
            "LP3: the encoded snapshot's recursive key set is EXACTLY the allowlist — every "
                + "extra key means a persisted type stopped being explicit about its "
                + "CodingKeys, and every missing one means this list is stale (mutation: adding "
                + "a stored property to any persisted graph type without adding it here)")

        // --- SnapshotWriter: capture-sequence ordering and content dedup ---

        let lp3WriterDir = lp3TempDir("writer-order")
        let lp3WEnvelopeB = lp3Envelope(year: "2043", savedAt: Date(timeIntervalSince1970: 2_000))
        // A DIFFERENT year than B, on purpose: same-content-different-savedAt
        // would also be caught by the digest dedup, which would make this
        // assertion pass even without the sequence guard under test —
        // content that genuinely differs isolates the sequence check alone.
        let lp3WEnvelopeAOlder =
            lp3Envelope(year: "2098", savedAt: Date(timeIntervalSince1970: 1_000))
        let lp3WEnvelopeBAgain =
            lp3Envelope(year: "2043", savedAt: Date(timeIntervalSince1970: 3_000))
        let lp3WEnvelopeC = lp3Envelope(year: "2044", savedAt: Date(timeIntervalSince1970: 4_000))
        let lp3WEnvelopeStaleAfterSkip =
            lp3Envelope(year: "2045", savedAt: Date(timeIntervalSince1970: 5_000))
        let lp3WEnvelopeFailAttempt =
            lp3Envelope(year: "2046", savedAt: Date(timeIntervalSince1970: 6_000))
        let lp3WEnvelopeAfterFail =
            lp3Envelope(year: "2047", savedAt: Date(timeIntervalSince1970: 7_000))
        let lp3WriterChecks = awaitValue { () async -> [String: Bool] in
            var results: [String: Bool] = [:]
            func bytesNow() -> Data? { SnapshotStore.readBytes(in: lp3WriterDir) }

            await SnapshotWriter.shared.submit(
                sequence: 2, envelope: lp3WEnvelopeB, directory: lp3WriterDir)
            let afterB = bytesNow()
            results["newerWrote"] = afterB != nil

            // An older sequence, even with DIFFERENT content, is rejected —
            // the file must still hold B's content untouched.
            await SnapshotWriter.shared.submit(
                sequence: 1, envelope: lp3WEnvelopeAOlder, directory: lp3WriterDir)
            results["staleOlderRejected"] = bytesNow() == afterB

            // Identical canonical content (savedAt differs) at a NEWER
            // sequence must not write again.
            await SnapshotWriter.shared.submit(
                sequence: 3, envelope: lp3WEnvelopeBAgain, directory: lp3WriterDir)
            results["digestSkipDidNotWrite"] = bytesNow() == afterB

            // A real content change at a newer sequence DOES write.
            await SnapshotWriter.shared.submit(
                sequence: 4, envelope: lp3WEnvelopeC, directory: lp3WriterDir)
            let afterC = bytesNow()
            results["realChangeWrote"] = afterC != nil && afterC != afterB

            // The mark advanced to 3 on the digest-skip above; sequence 3
            // arriving again (older than the current mark of 4) is rejected.
            await SnapshotWriter.shared.submit(
                sequence: 3, envelope: lp3WEnvelopeStaleAfterSkip, directory: lp3WriterDir)
            results["staleAfterDigestSkipRejected"] = bytesNow() == afterC

            // The mark also advances on a FAILED write: deny write permission
            // on the directory (read/execute only) so the temp file cannot be
            // created, submit a real content change at sequence 5 (fails),
            // restore permission, then confirm an OLDER sequence is rejected
            // purely by the now-advanced mark rather than being let through
            // because the write at 5 never actually landed.
            _ = chmod(lp3WriterDir.path, 0o500)
            await SnapshotWriter.shared.submit(
                sequence: 5, envelope: lp3WEnvelopeFailAttempt, directory: lp3WriterDir)
            _ = chmod(lp3WriterDir.path, 0o700)
            results["failedWriteLeftPreviousContent"] = bytesNow() == afterC

            await SnapshotWriter.shared.submit(
                sequence: 4, envelope: lp3WEnvelopeAfterFail, directory: lp3WriterDir)
            results["staleAfterFailedWriteRejected"] = bytesNow() == afterC
            return results
        } ?? [:]
        try? FileManager.default.removeItem(at: lp3WriterDir)

        expect(
            lp3WriterChecks["newerWrote"] == true && lp3WriterChecks["realChangeWrote"] == true,
            "LP3 writer: real content changes at increasing sequences really do write — "
                + "without this the rejection assertions below could pass on writes that never "
                + "happened in the first place")
        expect(
            lp3WriterChecks["staleOlderRejected"] == true,
            "LP3 writer: a delayed OLDER capture cannot replace a newer one")
        expect(
            lp3WriterChecks["digestSkipDidNotWrite"] == true,
            "LP3 writer: identical complete content at a newer sequence is deduplicated, not "
                + "rewritten")
        expect(
            lp3WriterChecks["staleAfterDigestSkipRejected"] == true,
            "LP3 writer: the high-water mark advances on a digest-skip outcome, so a delayed "
                + "capture older than the SKIPPED sequence is still rejected")
        expect(
            lp3WriterChecks["failedWriteLeftPreviousContent"] == true,
            "LP3 writer: a write that fails (denied directory permission) leaves the previous "
                + "valid snapshot on disk untouched")
        expect(
            lp3WriterChecks["staleAfterFailedWriteRejected"] == true,
            "LP3 writer: the high-water mark advances on a FAILED write outcome too, so a "
                + "delayed capture older than the failed sequence is still rejected")

        // --- Isolation: the production directory must never be RESOLVED off ---
        // --- a shipping identity. Every `swift run` invocation — which is    ---
        // --- how --demo/--smoke/--selftest/--icon-gallery (and any combined  ---
        // --- flags) all run — carries a nil `BuildIdentity`, since           ---
        // --- `BuildIdentity.shipping()` requires the real bundle identifier. ---
        // --- So this exercises the actual gating mechanism directly: a nil   ---
        // --- identity, whatever produced it.                                ---

        final class LP3DirectorySpy: @unchecked Sendable {
            private(set) var resolvedCount = 0
            private let directory: URL
            init(directory: URL) { self.directory = directory }
            func resolve() -> URL? {
                resolvedCount += 1
                return directory
            }
        }
        let lp3SpyOff = LP3DirectorySpy(directory: lp3TempDir("spy-off"))
        _ = awaitMainActorValue { () -> Bool in
            _ = DashboardModel(
                cachesSnapshot: true, initialYear: "2099",
                buildIdentity: nil, snapshotDirectory: lp3SpyOff.resolve())
            return true
        }
        expect(
            lp3SpyOff.resolvedCount == 0,
            "LP3 isolation: with no shipping identity the production snapshot directory is "
                + "never even RESOLVED, not merely unwritten (mutation: hoisting the "
                + "`snapshotDirectory()` call ahead of the `buildIdentity != nil` check)")

        // The block above assumed in prose that every non-user mode yields a nil
        // identity. It did not: `shipping()` looked at the bundle identifier
        // alone, and `scripts/bundle.sh` stamps the production one by default,
        // so running `--selftest` on a release bundle — an ordinary way to check
        // one — left fixture-backed models resolving the real directory. The
        // assumption is a predicate now, and these assert it.
        expect(
            BuildIdentity.nonUserRuntimeFlags.sorted()
                == ["--demo", "--icon-gallery", "--selftest", "--smoke"],
            "LP3 isolation: the non-user runtime set is exactly the four modes the spy "
                + "above depends on")
        // Supply the production bundle triple explicitly. Under `swift run`
        // there is no bundle, so overriding only `arguments` would leave every
        // call nil for the bundle reason and the flag check untested — that
        // mutation survived before this was written.
        func lp3ShippingIdentity(_ args: [String]) -> BuildIdentity? {
            BuildIdentity.shipping(
                arguments: args,
                bundleIdentifier: "com.nyanako.tokenbar",
                shortVersion: "1.2.3", buildNumber: "456")
        }
        expect(
            lp3ShippingIdentity(["/Applications/TokenBar.app"]) != nil,
            "LP3 isolation control: the production bundle triple with no non-user flag DOES "
                + "yield an identity — without this every assertion below would pass on a "
                + "function that always returns nil")
        for flag in BuildIdentity.nonUserRuntimeFlags {
            expect(
                lp3ShippingIdentity(["/Applications/TokenBar.app", flag]) == nil,
                "LP3 isolation: \(flag) yields no shipping identity even on a production "
                    + "bundle, so no production snapshot path exists for a fixture model")
        }
        expect(
            lp3ShippingIdentity(["/Applications/TokenBar.app", "--demo", "--selftest"]) == nil,
            "LP3 isolation: combined non-user flags still yield no shipping identity")
        expect(
            !BuildIdentity.isNonUserRuntime(["/Applications/TokenBar.app"]),
            "LP3 isolation control: an ordinary launch is NOT classified as a non-user "
                + "runtime — without this the assertions above would pass on a predicate "
                + "that always returns true")

        let lp3SpyOn = LP3DirectorySpy(directory: lp3TempDir("spy-on"))
        _ = awaitMainActorValue { () -> Bool in
            _ = DashboardModel(
                cachesSnapshot: true, initialYear: "2099",
                buildIdentity: lp3Identity, snapshotDirectory: lp3SpyOn.resolve())
            return true
        }
        expect(
            lp3SpyOn.resolvedCount == 1,
            "LP3 isolation control: WITH a shipping identity the directory genuinely is "
                + "resolved exactly once — without this control the assertion above could pass "
                + "on an autoclosure that is never evaluated under any circumstance")

        // --- DashboardModel: disk restore, the requested-year gate, and ---
        // --- ApplyResult's ownership of the restored-age indicator.     ---

        let lp3DiskChecks = awaitMainActorValue { () async -> [String: Bool] in
            var results: [String: Bool] = [:]

            let diskDir = lp3TempDir("disk-restore")
            let diskYear = "2036"
            let diskEnvelope = lp3Envelope(year: diskYear)
            _ = SnapshotStore.write(lp3Encode(diskEnvelope), in: diskDir)
            let diskModel = DashboardModel(
                cachesSnapshot: true, source: ControlledTurnUsageDataSource(),
                initialYear: diskYear, buildIdentity: lp3Identity, snapshotDirectory: diskDir)
            if case .ready = diskModel.phase { results["diskRestoreReady"] = true }
            else { results["diskRestoreReady"] = false }
            results["diskRestorePayloadMatches"] =
                diskModel.payload?.meta.generatedAt == diskEnvelope.payload.meta.generatedAt
            results["diskRestoreYearMatches"] = diskModel.year == diskYear
            results["diskRestoreNoModel"] =
                diskModel.payload != nil && diskModel.modelReport == nil

            // The SAME disk snapshot must not surface for a different
            // requested year — the requested-year gate, exercised through the
            // full DashboardModel path rather than `validate()` alone.
            let mismatchModel = DashboardModel(
                cachesSnapshot: true, source: ControlledTurnUsageDataSource(),
                initialYear: "2037", buildIdentity: lp3Identity, snapshotDirectory: diskDir)
            if case .loading = mismatchModel.phase { results["yearGateRejectsMismatch"] = true }
            else { results["yearGateRejectsMismatch"] = false }

            // ApplyResult: a redirect (empty-year branch) must not clear the
            // restored age, and the spawned unfiltered reload it triggers
            // shows kind `.yearSwitch` on the header indicator while it runs
            // — this is also the "empty-year auto-clear reload" indicator case.
            let redirectDir = lp3TempDir("redirect")
            let redirectYear = "2038"
            let redirectEnvelope = lp3Envelope(year: redirectYear)
            _ = SnapshotStore.write(lp3Encode(redirectEnvelope), in: redirectDir)
            let redirectSource = ControlledTurnUsageDataSource()
            let redirectModel = DashboardModel(
                cachesSnapshot: true, source: redirectSource, initialYear: redirectYear,
                buildIdentity: lp3Identity, snapshotDirectory: redirectDir)
            results["redirectRestored"] = redirectModel.restoredSnapshot != nil
            await redirectSource.blockGraph(year: nil)
            // Force the requested-year fetch to return a payload for an
            // unrelated year, so `apply()` takes the empty-year branch
            // instead of committing — the real scenario is logs for the
            // selected year having been deleted or moved.
            await redirectSource.forceNextGraphPayload(DemoData.payload(for: "1999"))
            await redirectModel.load()
            results["redirectDidNotCommit"] = redirectModel.restoredSnapshot != nil
            results["redirectClearedYear"] = redirectModel.year == nil
            let redirectSpawnedYearSwitch = await waitUntil {
                await MainActor.run { redirectModel.backgroundRefresh?.kind == .yearSwitch }
            }
            results["redirectSpawnedYearSwitchKind"] = redirectSpawnedYearSwitch
            await redirectSource.releaseGraph(year: nil)
            let redirectApplied = await waitUntil {
                await MainActor.run { redirectModel.restoredSnapshot == nil }
            }
            results["redirectEventuallyApplied"] = redirectApplied

            return results
        } ?? [:]

        expect(
            lp3DiskChecks["diskRestoreReady"] == true
                && lp3DiskChecks["diskRestorePayloadMatches"] == true
                && lp3DiskChecks["diskRestoreYearMatches"] == true,
            "LP3: a valid disk snapshot restores to .ready with the matching payload and year")
        expect(
            lp3DiskChecks["diskRestoreNoModel"] == true,
            "LP3: a disk restore never carries a model report — the model report is not "
                + "persisted, so it is always re-requested")
        expect(
            lp3DiskChecks["yearGateRejectsMismatch"] == true,
            "LP3: the requested-year gate rejects a disk snapshot written for a different year "
                + "than the one this process wants, through the full DashboardModel path")
        expect(
            lp3DiskChecks["redirectRestored"] == true,
            "LP3: the redirect fixture really restores a snapshot with an age to clear — "
                + "without this the assertions below could pass on nothing being displayed")
        expect(
            lp3DiskChecks["redirectDidNotCommit"] == true
                && lp3DiskChecks["redirectClearedYear"] == true,
            "LP3: an empty-year redirect does not clear the restored age (only `.applied` "
                + "does), even though it does clear the year filter")
        expect(
            lp3DiskChecks["redirectSpawnedYearSwitchKind"] == true,
            "LP3: the reload apply() spawns for an emptied year filter shows as the "
                + "`.yearSwitch` kind on the header indicator")
        expect(
            lp3DiskChecks["redirectEventuallyApplied"] == true,
            "LP3: the spawned unfiltered reload eventually commits and THAT clears the "
                + "restored age — a redirect defers settling, it does not abandon it")

        // --- DashboardModel: the restore gate, both true task orderings ---
        // --- (model-task-first without `load()` ever having run first). ---

        let lp3GateChecks = awaitMainActorValue { () async -> [String: Bool] in
            var results: [String: Bool] = [:]

            let gateDir = lp3TempDir("gate-order")
            let gateYear = "2039"
            _ = SnapshotStore.write(lp3Encode(lp3Envelope(year: gateYear)), in: gateDir)
            let gateSource = ControlledTurnUsageDataSource()
            let gateModel = DashboardModel(
                cachesSnapshot: true, source: gateSource, initialYear: gateYear,
                buildIdentity: lp3Identity, snapshotDirectory: gateDir)
            results["gateRestoredWithoutModel"] =
                gateModel.payload != nil && gateModel.modelReport == nil
            await gateSource.blockGraph(year: gateYear)
            // `ensureModelData` is called BEFORE `load()` is ever invoked on
            // this model — true model-task-first ordering. Without the
            // restore gate, `modelSliceIsCommitted` is already true (restored
            // payload, year matches) and `graphLoadTask` is nil (nothing has
            // called `gatedGraph` yet), so the old code fell straight through
            // every guard and scanned immediately.
            let gateLens = Task { await gateModel.ensureModelData(for: .overview) }
            let gateRaced = await waitUntil { await gateSource.modelCallCount() > 0 }
            results["gateModelTaskFirstDidNotRace"] = !gateRaced
            // A DIFFERENT caller (not the one awaiting the gate) is what
            // finally calls load() — proving the gate is fulfilled by ANY
            // settling fetch, not only one the waiter itself started.
            let gateLoad = Task { await gateModel.load() }
            _ = await waitUntil { await gateSource.hasPendingGraph(year: gateYear) }
            await gateSource.releaseGraph(year: gateYear)
            await gateLoad.value
            await gateLens.value
            results["gateModelArrivedAfterLoad"] = gateModel.modelReport != nil

            // The failure side of the same ordering: the FIRST graph fetch a
            // restored-without-a-current-model dashboard ever runs fails, so
            // zero model calls should ever be issued for it.
            let gateFailDir = lp3TempDir("gate-order-fail")
            let gateFailYear = "2040"
            _ = SnapshotStore.write(lp3Encode(lp3Envelope(year: gateFailYear)), in: gateFailDir)
            let gateFailSource = ControlledTurnUsageDataSource()
            let gateFailModel = DashboardModel(
                cachesSnapshot: true, source: gateFailSource, initialYear: gateFailYear,
                buildIdentity: lp3Identity, snapshotDirectory: gateFailDir)
            let gateFailLens = Task { await gateFailModel.ensureModelData(for: .overview) }
            await gateFailSource.failNextGraph()
            await gateFailModel.load()
            await gateFailLens.value
            results["gateFailureIssuedNoScan"] = await gateFailSource.modelCallCount() == 0

            return results
        } ?? [:]

        expect(
            lp3GateChecks["gateRestoredWithoutModel"] == true,
            "LP3: the gate fixture really restores a payload without a current model — "
                + "without this the race assertions below could pass on a slice with nothing "
                + "to gate")
        expect(
            lp3GateChecks["gateModelTaskFirstDidNotRace"] == true,
            "LP3: calling ensureModelData BEFORE load() has ever run on a restored model does "
                + "not race the graph — the restore gate blocks it even with graphLoadTask nil")
        expect(
            lp3GateChecks["gateModelArrivedAfterLoad"] == true,
            "LP3: the gated model request still receives its report once ANY caller's load() "
                + "settles the slice")
        expect(
            lp3GateChecks["gateFailureIssuedNoScan"] == true,
            "LP3: a restored model whose first-ever graph fetch fails issues zero model calls")

        // --- Header indicator ownership: only the owning token clears ---
        // --- `backgroundRefresh`, so an overtaken fetch's completion  ---
        // --- (success or failure) can never clear a NEWER indicator.  ---

        let lp3IndicatorChecks = awaitMainActorValue { () async -> [String: Bool] in
            var results: [String: Bool] = [:]

            func settle() async { for _ in 0..<50 { await Task.yield() } }

            // initial → manual overtake.
            let indASource = ControlledTurnUsageDataSource()
            let indAYear = "2041"
            let indAModel = DashboardModel(source: indASource, initialYear: indAYear)
            await indASource.blockGraph(year: indAYear)
            let indALoad = Task { await indAModel.load() }
            _ = await waitUntil { await indASource.pendingGraphCount(year: indAYear) == 1 }
            results["indAInitialKind"] = indAModel.backgroundRefresh?.kind == .initial
            let indARefresh = Task { await indAModel.refresh() }
            _ = await waitUntil { await indASource.pendingGraphCount(year: indAYear) == 2 }
            results["indAManualKind"] = indAModel.backgroundRefresh?.kind == .manual
            // The OLDER (initial) fetch settles first — must not clear the
            // manual indicator that overtook it.
            await indASource.releaseGraph(year: indAYear, index: 0, day: 1)
            await settle()
            results["indAOlderSuccessDidNotClear"] = indAModel.backgroundRefresh?.kind == .manual
            await indASource.releaseGraph(year: indAYear, index: 0, day: 3)
            await indALoad.value
            await indARefresh.value
            results["indAClearedAfterSettle"] = indAModel.backgroundRefresh == nil

            // initial → year-switch overtake, same ownership shape.
            let indBSource = ControlledTurnUsageDataSource()
            let indBYear = "2049"
            let indBModel = DashboardModel(source: indBSource, initialYear: indBYear)
            await indBSource.blockGraph(year: indBYear)
            let indBLoad = Task { await indBModel.load() }
            _ = await waitUntil { await indBSource.pendingGraphCount(year: indBYear) == 1 }
            results["indBInitialKind"] = indBModel.backgroundRefresh?.kind == .initial
            await indBSource.blockGraph(year: "2050")
            let indBSwitch = Task { await indBModel.setYear("2050") }
            _ = await waitUntil { await indBSource.hasPendingGraph(year: "2050") }
            results["indBYearSwitchKind"] = indBModel.backgroundRefresh?.kind == .yearSwitch
            // The OLDER (initial, year 2049) fetch settles — must not clear
            // the year-switch indicator for the NEW year.
            await indBSource.releaseGraph(year: indBYear)
            await settle()
            results["indBOlderDidNotClear"] = indBModel.backgroundRefresh?.kind == .yearSwitch
            await indBSource.releaseGraph(year: "2050")
            await indBLoad.value
            await indBSwitch.value
            results["indBClearedAfterSettle"] = indBModel.backgroundRefresh == nil

            // A superseded FAILURE must not clear a newer indicator either.
            let indCSource = ControlledTurnUsageDataSource()
            let indCYear = "2042"
            let indCModel = DashboardModel(source: indCSource, initialYear: indCYear)
            await indCSource.blockGraph(year: indCYear)
            let indCLoad = Task { await indCModel.load() }
            _ = await waitUntil { await indCSource.pendingGraphCount(year: indCYear) == 1 }
            let indCRefresh = Task { await indCModel.refresh() }
            _ = await waitUntil { await indCSource.pendingGraphCount(year: indCYear) == 2 }
            results["indCManualKindBeforeFailure"] = indCModel.backgroundRefresh?.kind == .manual
            // Fail specifically the OLDER (index 0) parked fetch, leaving the
            // newer (manual) one still in flight.
            await indCSource.failGraph(year: indCYear, index: 0)
            await settle()
            results["indCFailureDidNotClearManual"] =
                indCModel.backgroundRefresh?.kind == .manual
            await indCSource.releaseGraph(year: indCYear, index: 0, day: 5)
            await indCLoad.value
            await indCRefresh.value
            results["indCClearedAfterSettle"] = indCModel.backgroundRefresh == nil

            return results
        } ?? [:]

        expect(
            lp3IndicatorChecks["indAInitialKind"] == true
                && lp3IndicatorChecks["indAManualKind"] == true,
            "LP3 indicator: the initial→manual fixture really tags each trigger's own kind "
                + "before either settles")
        expect(
            lp3IndicatorChecks["indAOlderSuccessDidNotClear"] == true,
            "LP3 indicator: an overtaken initial fetch's SUCCESS cannot clear a newer manual "
                + "request's indicator")
        expect(
            lp3IndicatorChecks["indAClearedAfterSettle"] == true,
            "LP3 indicator: the indicator clears once the OWNING (manual) fetch settles")
        expect(
            lp3IndicatorChecks["indBInitialKind"] == true
                && lp3IndicatorChecks["indBYearSwitchKind"] == true,
            "LP3 indicator: the initial→year-switch fixture really tags each trigger's own kind")
        expect(
            lp3IndicatorChecks["indBOlderDidNotClear"] == true
                && lp3IndicatorChecks["indBClearedAfterSettle"] == true,
            "LP3 indicator: an overtaken initial fetch cannot clear a newer year-switch "
                + "request's indicator, which clears on its own settling")
        expect(
            lp3IndicatorChecks["indCManualKindBeforeFailure"] == true,
            "LP3 indicator: the superseded-failure fixture really has a newer manual request "
                + "in flight when the older one is failed")
        expect(
            lp3IndicatorChecks["indCFailureDidNotClearManual"] == true
                && lp3IndicatorChecks["indCClearedAfterSettle"] == true,
            "LP3 indicator: an overtaken fetch's FAILURE cannot clear a newer request's "
                + "indicator either — ownership applies to both settlement routes")

        let windowMessages = try! JSONDecoder().decode(
            [WindowMessage].self,
            from: Data("""
            [
              {"timestamp":2000,"client":"test","providerId":"test","modelId":"test","input":0,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0,"cost":0,"isTurnStart":true},
              {"timestamp":3000,"client":"test","providerId":"test","modelId":"test","input":0,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0,"cost":0,"isTurnStart":false}
            ]
            """.utf8)
        )
        // CR1. `[from, to)`, matching the FFI's interval and the history fold.
        // It used to be `(from, to]`, and an inferred window's start IS the
        // timestamp of its first message, so that message — the one that
        // established the window — was the one it dropped.
        let crScan = UnionScan(
            fromMs: 0, untilMs: 10_000, capturedAt: Date(), messages: windowMessages)
        expect(
            crScan.slice(from: 2_000, to: 3_000).map(\.timestamp) == [2_000],
            "CR1 the message at the start of the interval is inside it")
        expect(
            crScan.slice(from: 2_000, to: 3_000).count == 1,
            "CR1 and the message at the end is not, so two adjacent windows cannot both claim it")

        // CR8. The inferred window is anchored by usage this subscription
        // owns. The card filters what it DISPLAYS by attribution and anchored
        // the window it infers to the earliest message in the whole union scan,
        // so another subscription's work could set this one's start — the chart
        // then begins before any usage it goes on to count as this client's.
        let cr8Mixed = try! JSONDecoder().decode(
            [WindowMessage].self,
            from: Data("""
            [{"timestamp":1000,"client":"other","providerId":"other","modelId":"m",
              "input":5,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0,
              "cost":0,"isTurnStart":true},
             {"timestamp":5000,"client":"mine","providerId":"mine","modelId":"m",
              "input":5,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0,
              "cost":0,"isTurnStart":true}]
            """.utf8))
        let cr8Records = [UsageAttribution.Record(
            client: "mine", provider: "mine", state: .assigned("mine"))]
        expect(
            WindowResolver.firstUsageAfterReset(messages: cr8Mixed, resetMs: 0) == 1_000,
            "CR8 unfiltered, the other subscription's message anchors the window")
        expect(
            WindowResolver.firstUsageAfterReset(
                messages: cr8Mixed.filter {
                    UsageAttribution.resolve(
                        client: $0.client, provider: $0.providerId, model: $0.modelId,
                        records: cr8Records) == .assigned("mine")
                }, resetMs: 0) == 5_000,
            "CR8 filtered, it is anchored by usage this subscription owns")

        // CR4. The first bar owns the window's own start. `UnionScan.slice`
        // admits a message landing exactly on `windowStartMs`, and for an
        // inferred window that message defines the start — so with every zone
        // exclusive at its lower bound it counted toward the card's total and
        // toward no bar, and the bars stopped summing to the number above them.
        let crBoundary = try! JSONDecoder().decode(
            [WindowMessage].self,
            from: Data("""
            [{"timestamp":1000,"client":"t","providerId":"t","modelId":"t","input":7,
              "output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0,"cost":0,
              "isTurnStart":true}]
            """.utf8))
        let crGeometry = WindowCardGeometry.usageGeometry(
            windowStartMs: 1_000, windowEndMs: 3_000, nowMs: 3_000,
            samples: [QuotaSample(atMs: 1_000, usedPercent: 1),
                      QuotaSample(atMs: 2_000, usedPercent: 4),
                      QuotaSample(atMs: 3_000, usedPercent: 9)],
            messages: crBoundary)
        expect(crGeometry.bars.contains { !$0.isEmpty },
               "CR4 a message at the window start is drawn in some bar at all")
        expect(crGeometry.bars.filter { !$0.isEmpty }.count == 1,
               "CR4 and in exactly one, so no zone double-counts it")

        // CR3. A model-specific declaration outranks the provider-wide one,
        // and the window folds must see it. They passed `model: nil`, which
        // makes the resolver skip every override — so a user who classified one
        // model separately got that usage charged to the provider-wide target
        // in the quota cards while the daily chart, which does pass the model,
        // showed it correctly. Two answers, same declarations.
        let crRecords = [
            UsageAttribution.Record(
                client: "test", provider: "test", state: .assigned("wide")),
            UsageAttribution.Record(
                client: "test", provider: "test", model: "test", state: .assigned("narrow")),
        ]
        let crTotals = WindowUsage(
            messages: windowMessages, undatedCount: 0, processingTimeMs: 0
        ).totals(confirmed: crRecords)
        expect(
            crTotals.assigned.map(\.target) == ["narrow"],
            "CR3 the model-specific declaration wins in a window fold, as it does in the daily series")
        expect(
            WindowUsage(
                messages: windowMessages, undatedCount: 0, processingTimeMs: 0
            ).totals(confirmed: [crRecords[0]]).assigned.map(\.target) == ["wide"],
            "CR3 and the provider-wide one still applies when no override exists")

        // CR7. The equivalence footer reads only the settled window. A sample
        // from the previous provider-anchored interval carries the earlier
        // cycle's movement, and including it made that line describe a window
        // the chart beside it said held no reading at all.
        let crSamples = [QuotaSample(atMs: 1_000, usedPercent: 4),
                         QuotaSample(atMs: 9_000, usedPercent: 30)]
        let crInside = crSamples.filter { $0.atMs >= 5_000 && $0.atMs <= 12_000 }
        expect(WindowEquivalence.row(samples: crInside, messages: []) == .unavailable,
               "CR7 one sample inside the settled window yields no delta at all")
        expect(WindowEquivalence.row(samples: crSamples, messages: []) != .unavailable,
               "CR7 and the unfiltered pair does yield one, which is the difference filtering makes")

        // CR5. The non-cache subtotal is summed from components, not
        // subtracted from the saturated total. With input and cacheRead both at
        // the ceiling, `tokens - cacheRead` reports zero non-cache work for a
        // row whose input alone was enormous — a wrong number rather than a
        // crash, which is the worse of the two.
        let crBoth = try! JSONDecoder().decode(
            WindowMessage.self,
            from: Data("""
            {"timestamp":1,"client":"t","providerId":"t","modelId":"t",
             "input":9223372036854775807,"output":0,
             "cacheRead":9223372036854775807,"cacheWrite":0,"reasoning":0,
             "cost":0,"isTurnStart":true}
            """.utf8))
        // The probe folds the same untrusted rows the production folds do, and
        // it exists to be pointed at data that looks wrong — so it must not
        // trap on the malformed input it is meant to inspect.
        let crSaturated = WindowUsage(
            messages: [crBoth, crBoth], undatedCount: 0, processingTimeMs: 0)
        expect(crSaturated.buckets(from: 0, bucketMs: 10, count: 2)
                .allSatisfy { $0 <= Int64.max },
               "CR5 two saturated rows fold into a bucket without trapping")
        expect(crSaturated.totals(confirmed: []).unassigned.tokens == Int64.max,
               "CR5 and into the attribution totals the same way")

        expect(crBoth.tokensExCacheRead == Int64.max,
               "CR5 the ex-cache subtotal keeps the input it is made of")
        expect(crBoth.tokens - crBoth.cacheRead == 0,
               "CR5 and the subtraction it replaces really does report zero, so this is not theoretical")

        // CR6. A ratio of a saturated token count over a small delta leaves
        // Int64's range entirely; the plain initializer traps on it.
        expect(WindowEquivalence.clamped(1e30) == Int64.max
                && WindowEquivalence.clamped(-1e30) == Int64.min
                && WindowEquivalence.clamped(.nan) == 0,
               "CR6 a Double outside Int64's range clamps instead of trapping")

        // CR2. Token components come from session files this app does not
        // write. A corrupt row must not be able to trap the process.
        let crHuge = try! JSONDecoder().decode(
            WindowMessage.self,
            from: Data("""
            {"timestamp":1,"client":"t","providerId":"t","modelId":"t",
             "input":9223372036854775807,"output":9223372036854775807,
             "cacheRead":0,"cacheWrite":0,"reasoning":0,"cost":0,"isTurnStart":true}
            """.utf8))
        expect(crHuge.tokens == Int64.max,
               "CR2 an overflowing token sum saturates instead of trapping")

        expect(
            WindowResolver.resolve(
                resetsAtMs: nil, durationMs: 5_000, now: 2_000,
                firstUsageAfterReset: nil
            ) == .unavailable,
            "window resolution is unavailable without a reset")
        expect(
            WindowResolver.resolve(
                resetsAtMs: 1_000, durationMs: nil, now: 2_000,
                firstUsageAfterReset: nil
            ) == .unavailable,
            "window resolution is unavailable without a duration")
        expect(
            WindowResolver.resolve(
                resetsAtMs: 1_000, durationMs: 5_000, now: 7_001,
                firstUsageAfterReset: nil
            ) == .unavailable,
            "a reset older than one duration is outside the probe bound")
        expect(
            WindowResolver.resolve(
                resetsAtMs: 2_000, durationMs: 5_000, now: 1_000,
                firstUsageAfterReset: nil
            ) == .active(start: -3_000, end: 2_000),
            "a future reset is an active provider-confirmed window")
        expect(
            WindowResolver.resolve(
                resetsAtMs: 6_000, durationMs: 5_000, now: 1_000,
                firstUsageAfterReset: nil
            ) == .active(start: 1_000, end: 6_000),
            "a reset exactly one duration ahead is still an active window")
        expect(
            WindowResolver.resolve(
                resetsAtMs: 6_001, durationMs: 5_000, now: 1_000,
                firstUsageAfterReset: nil
            ) == .unavailable,
            "a reset more than one duration ahead cannot place a window")
        expect(
            WindowResolver.resolve(
                resetsAtMs: 20_000, durationMs: 5_000, now: 1_000,
                firstUsageAfterReset: 1_000
            ) == .unavailable,
            "a wildly future reset stays unavailable even with usage on hand")
        expect(
            WindowResolver.resolve(
                resetsAtMs: 1_000, durationMs: 5_000, now: 3_000,
                firstUsageAfterReset: nil
            ) == .idle,
            "a bounded past reset with no usage is idle")
        expect(
            WindowResolver.resolve(
                resetsAtMs: 1_000, durationMs: 5_000, now: 6_000,
                firstUsageAfterReset: nil
            ) == .idle,
            "the now-minus-reset equals duration boundary remains idle")
        expect(
            WindowResolver.resolve(
                resetsAtMs: 6_000, durationMs: 5_000, now: 6_000,
                firstUsageAfterReset: nil
            ) == .idle,
            "a reset exactly at now is still idle without usage")
        expect(
            WindowResolver.firstUsageAfterReset(messages: windowMessages, resetMs: 1_000)
                == 2_000,
            "first usage helper selects the earliest usage after reset")
        // The `>= resetMs` filter is the sole source of the t0 >= R invariant that
        // lets `resolve` omit an end-in-past guard. It only does work when a message
        // predates the reset, so it needs a reset between the two fixture messages.
        expect(
            WindowResolver.firstUsageAfterReset(messages: windowMessages, resetMs: 2_500)
                == 3_000,
            "first usage helper discards usage that predates the reset")
        expect(
            WindowResolver.firstUsageAfterReset(messages: windowMessages, resetMs: 2_000)
                == 2_000,
            "first usage helper keeps usage exactly at the reset")
        expect(
            WindowResolver.resolve(
                resetsAtMs: 1_000, durationMs: 5_000, now: 3_000,
                firstUsageAfterReset: WindowResolver.firstUsageAfterReset(
                    messages: windowMessages, resetMs: 1_000
                )
            ) == .inferred(start: 2_000, end: 7_000),
            "inferred window starts at the first usage, not the most recent")
        expect(
            WindowResolver.resolve(
                resetsAtMs: 1_000, durationMs: 5_000, now: 3_000,
                firstUsageAfterReset: 2_000
            ) == .inferred(start: 2_000, end: 7_000),
            "the first usage literal opens the expected inferred window")
        expect(
            WindowResolver.resolve(
                resetsAtMs: 1_000, durationMs: 5_000, now: 3_000,
                firstUsageAfterReset: 3_000
            ) == .inferred(start: 3_000, end: 8_000)
                && WindowResolver.resolve(
                    resetsAtMs: 1_000, durationMs: 5_000, now: 3_000,
                    firstUsageAfterReset: 3_000
                ) != .inferred(start: 2_000, end: 7_000),
            "using the last usage instead would produce a different window")

        // MARK: card geometry (V12-V15)

        func windowMessage(at t: Int64, input: Int64, cacheRead: Int64,
                           cost: Double = 0) -> WindowMessage {
            try! JSONDecoder().decode(WindowMessage.self, from: Data("""
            {"timestamp":\(t),"client":"c","providerId":"p","modelId":"m",
             "input":\(input),"output":0,"cacheRead":\(cacheRead),
             "cacheWrite":0,"reasoning":0,"cost":\(cost),"isTurnStart":true}
            """.utf8))
        }

        // Deliberately not 50%: there the two metrics coincide and V12 could
        // pass with `metric` wired straight into the bar height.
        let geoSamples = [
            QuotaSample(atMs: 1_000, usedPercent: 12),
            QuotaSample(atMs: 5_000, usedPercent: 12),
            QuotaSample(atMs: 9_000, usedPercent: 30),
        ]
        let geoMessages = [
            windowMessage(at: 2_000, input: 400, cacheRead: 90_000),
            windowMessage(at: 6_000, input: 1_200, cacheRead: 90_000),
        ]
        let geoUsed = WindowCardGeometry.chartGeometry(
            windowStartMs: 0, windowEndMs: 20_000, nowMs: 10_000, samples: geoSamples,
            messages: geoMessages, metric: .used)
        let geoRemaining = WindowCardGeometry.chartGeometry(
            windowStartMs: 0, windowEndMs: 20_000, nowMs: 10_000, samples: geoSamples,
            messages: geoMessages, metric: .remaining)
        expect(
            geoUsed.bars == geoRemaining.bars && geoUsed.hits == geoRemaining.hits,
            "V12 flipping the quota metric leaves bar and hit geometry identical")
        expect(
            geoUsed.samplePoints.map(\.y) == [12, 12, 30]
                && geoRemaining.samplePoints.map(\.y) == [88, 88, 70],
            "V12 the metric does reach the line, so the previous check is not vacuous")
        // Four zones, not three: the region before the first sample and the one
        // after the last are real intervals that can hold usage, and both must
        // be hoverable. Their bars are empty here only because the fixture put
        // no messages there.
        expect(
            geoUsed.bars.map(\.isEmpty) == [true, false, false, true],
            "the pre-sample and trailing regions are zones of their own")
        expect(
            geoUsed.hits.map(\.loMs) == [0, 1_000, 5_000, 9_000]
                && geoUsed.hits.compactMap { $0.closingSample?.usedPercent } == [12, 12, 30],
            "only the zones that end on a sample carry one; the trailing zone does not")
        // The consumption figure flips sign with the metric — it must read the
        // way the line moves, or the tooltip and the chart disagree on screen.
        expect(
            geoUsed.hits.map { $0.consumed(.used) } == [nil, 0, 18, nil]
                && geoUsed.hits.map { $0.consumed(.remaining) } == [nil, 0, -18, nil],
            "an interval's consumption is signed by the metric and absent at either open end")

        // A one-millisecond bucket: far below any plausible minimum width.
        let narrow = WindowCardGeometry.zones(
            windowStartMs: 0, windowEndMs: 20_000, nowMs: 10_000,
            samples: [QuotaSample(atMs: 4_000, usedPercent: 1),
                      QuotaSample(atMs: 4_001, usedPercent: 2)])
        expect(
            narrow.first?.loMs == 0 && narrow.last?.hiMs == 10_000,
            "V13 hit zones start at the window start and end exactly at now")
        expect(
            zip(narrow, narrow.dropFirst()).allSatisfy { $0.hiMs == $1.loMs },
            "V13 hit zones tile without gap or overlap")
        expect(
            narrow.contains { $0.hiMs - $0.loMs == 1 },
            "V13 a one-millisecond bucket keeps its true width — no minimum")
        expect(
            narrow.allSatisfy { $0.hiMs <= 10_000 },
            "V13 no hit zone reaches past now into the future")
        // The millisecond edges above are not enough: the overhang this row
        // exists to catch was in the drawn fractions, where a minimum width
        // leaves the timestamps untouched and still pushes the last zone past
        // the right edge.
        expect(
            zip(narrow, narrow.dropFirst())
                .allSatisfy { abs(($0.x + $0.width) - $1.x) < 1e-12 },
            "V13 drawn zones meet exactly, with no minimum width wedged between")
        expect(
            narrow.first.map { abs($0.x) < 1e-12 } == true
                && narrow.last.map { abs(($0.x + $0.width) - 0.5) < 1e-12 } == true,
            "V13 the drawn zones span exactly 0...nowX, so none overhangs into the future")
        expect(
            geoUsed.nowX == 0.5 && geoUsed.firstSampleX == 0.05
                && geoUsed.nowX == geoRemaining.nowX,
            "V13 now and the first sample are placed against the whole window, not the elapsed part")
        expect(
            narrow.contains { $0.width < 1e-3 },
            "V13 the narrow zone stays narrow when drawn, not padded to a floor")

        // Flat, then a jump: the shape that makes Catmull-Rom bulge.
        let jump = [CurvePoint(x: 0, y: 2), CurvePoint(x: 1, y: 2),
                    CurvePoint(x: 2, y: 2), CurvePoint(x: 3, y: 7)]
        let curve = WindowCardGeometry.monotoneCurve(jump)
        var overshoot = false
        for (k, pt) in curve.enumerated() where k > 0 {
            let seg = (k - 1) / WindowCardGeometry.curveResolution
            let lo = min(jump[seg].y, jump[seg + 1].y)
            let hi = max(jump[seg].y, jump[seg + 1].y)
            if pt.y < lo - 1e-9 || pt.y > hi + 1e-9 { overshoot = true }
        }
        expect(!overshoot,
               "V14 interpolation never leaves the span of its two samples (flat then jump)")

        // Two different guards stop overshoot and one fixture cannot exercise
        // both. The flat run above is held by zeroing BOTH tangents around a
        // zero secant; a burst between two gentle segments is held by the
        // alpha^2+beta^2>9 clamp. Without the clamp this one dips to -0.70,
        // i.e. it draws a refill.
        let burst = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1),
                     CurvePoint(x: 2, y: 20), CurvePoint(x: 3, y: 21)]
        let burstCurve = WindowCardGeometry.monotoneCurve(burst)
        var burstOvershoot = false
        for (k, pt) in burstCurve.enumerated() where k > 0 {
            let seg = (k - 1) / WindowCardGeometry.curveResolution
            let lo = min(burst[seg].y, burst[seg + 1].y)
            let hi = max(burst[seg].y, burst[seg + 1].y)
            if pt.y < lo - 1e-9 || pt.y > hi + 1e-9 { burstOvershoot = true }
        }
        expect(!burstOvershoot,
               "V14 a burst between two gentle segments stays within its span too")
        expect(
            curve.count == 1 + 3 * WindowCardGeometry.curveResolution
                && curve.last?.y == 7,
            "V14 the curve is actually interpolated and lands on the last sample")

        // Same tokens, two different deltas: a hardcoded coefficient would
        // return the same ratio for both.
        //
        // The expected counts below are 5,060,000 — input PLUS cache read. They
        // used to be 60,000, and that number was not a decision: this fixture
        // exists to prove the ratio scales with delta, and its author wrote
        // down whatever the code returned for a message that happened to carry
        // 5M cache reads. It therefore pinned a basis nobody had chosen, and
        // pinned the wrong one (issue #237). An expectation copied from current
        // behaviour asserts that the code does what it does.
        let eqMessages = [windowMessage(at: 1_500, input: 60_000, cacheRead: 5_000_000,
                                        cost: 30)]
        let wide = WindowEquivalence.row(
            samples: [QuotaSample(atMs: 1_000, usedPercent: 0),
                      QuotaSample(atMs: 2_000, usedPercent: 10)],
            messages: eqMessages)
        let narrower = WindowEquivalence.row(
            samples: [QuotaSample(atMs: 1_000, usedPercent: 0),
                      QuotaSample(atMs: 2_000, usedPercent: 20)],
            messages: eqMessages)
        expect(
            wide == .ratio(tokensPerTenth: 5_060_000, costPerTenth: 30, errorPercent: 5),
            "V15 the ratio is the measured quotient, not a coefficient")
        expect(
            narrower == .ratio(tokensPerTenth: 2_530_000, costPerTenth: 15, errorPercent: 3),
            "V15 doubling the quota delta halves the ratio")
        expect(
            WindowEquivalence.row(
                samples: [QuotaSample(atMs: 1_000, usedPercent: 0),
                          QuotaSample(atMs: 2_000, usedPercent: 1)],
                messages: eqMessages) == .insufficient(deltaPercent: 1, errorPercent: 50),
            "V15 a one-point move is muted, and says so with its error")
        expect(
            WindowEquivalence.row(
                samples: [QuotaSample(atMs: 1_000, usedPercent: 0),
                          QuotaSample(atMs: 2_000, usedPercent: 56)],
                messages: []) == .unaccounted(deltaPercent: 56),
            "V15 quota moving with no local usage is reported, never shown as zero")
        // MARK: window card loading (W-3: L1a, L2a, L3a, L6a)

        func windowPayload(
            _ agents: [(client: String, windows: [(card: String, key: String,
                                                   resetsAt: String, durationSecs: Int64)])],
            generation: UInt64 = 7,
            modelScope: String? = nil
        ) -> AgentUsagePayload {
            let scopeField = modelScope.map { #","modelScope":"\#($0)""# } ?? ""
            let body = agents.map { agent in
                let windows = agent.windows.map { w in
                    """
                    {"cardId":"\(w.card)","label":"\(w.card)","usedPercent":10,
                     "remainingPercent":90,"resetsAt":"\(w.resetsAt)",
                     "durationSeconds":\(w.durationSecs),
                     "windowMinutes":\(w.durationSecs / 60)\(scopeField),
                     "paceStatus":{"state":"learningHistory","windowKey":"\(w.key)",
                                   "durationSeconds":\(w.durationSecs),
                                   "durationSource":"provider","completeCycles":1}}
                    """
                }.joined(separator: ",")
                return """
                {"clientId":"\(agent.client)","source":"oauth","updatedAt":"t",
                 "windows":[\(windows)]}
                """
            }.joined(separator: ",")
            let json = """
            {"generatedAt":"t","publicationGeneration":\(generation),"agents":[\(body)]}
            """
            return try! JSONDecoder().decode(AgentUsagePayload.self, from: Data(json.utf8))
        }

        // `isActive` says whether the curve's reset group is the one still
        // running. Cycles that are still open are not history, so a fixture
        // that wants a COMPLETED cycle has to say so.
        func windowCurve(resetAtSecs: Int64, durationSecs: Int64,
                         at: [(Int64, Double)], isActive: Bool = true) -> QuotaCurve {
            let points = at.map { t, pct in
                """
                {"sampledAt":\(t),"usedPercent":\(pct),"resetAt":\(resetAtSecs),
                 "durationSeconds":\(durationSecs),"durationSource":"provider",
                 "origin":"liveV3","isActiveGroup":\(isActive)}
                """
            }.joined(separator: ",")
            let json = """
            {"points":[\(points)],
             "coverage":{"oldestSampledAt":\(at.first?.0 ?? 0),
                         "newestSampledAt":\(at.last?.0 ?? 0),"sampleCount":\(at.count)},
             "activeResetAt":\(isActive ? String(resetAtSecs) : "null"),"generation":7}
            """
            return try! JSONDecoder().decode(QuotaCurve.self, from: Data(json.utf8))
        }

        // A window whose reset is 1h away with a 5h duration: started 4h ago.
        let wNow = Int64(Date().timeIntervalSince1970)
        let wReset = wNow + 3_600
        let wIso = ISO8601DateFormatter().string(
            from: Date(timeIntervalSince1970: Double(wReset)))
        let wPayload = windowPayload([
            (client: "codex", windows: [(card: "session.v1", key: "session.v1",
                                         resetsAt: wIso, durationSecs: 18_000)]),
        ])
        let wCurve = windowCurve(
            resetAtSecs: wReset, durationSecs: 18_000,
            at: [(wNow - 3_000, 4), (wNow - 600, 9)])

        // L1a. `quotaHalf` takes no UsageDataSource at all, so the network is
        // unreachable by signature rather than by discipline — the assertion
        // below is that it produces a placed window from memory alone.
        let stage1 = WindowCardLoader.quotaHalf(
            payload: wPayload, clientId: "codex", attempted: true,
            curve: { _, _, _, _ in wCurve }, nowMs: wNow * 1000)
        var stage1Placed = false
        var stage1Live = false
        if case let .quotaOnly(q, _) = stage1 {
            if case .active = q.resolution {
                // Two persisted, plus the reading the payload is carrying now.
                stage1Placed = q.samples.count == 3
                stage1Live = q.samples.last?.atMs == wNow * 1000
            }
        }
        expect(stage1Placed,
               "L1a stage one places the window and carries its samples without a source")
        expect(stage1Live,
               "L1a and the newest sample is the payload's own reading, stamped now — "
                   + "the store keeps one sample per 48th of a cycle, which on a weekly "
                   + "window is one per 3.5 hours, so the persisted set alone shows a "
                   + "single point while the headline above it moves")

        // L6a (i). No payload yet — loading, never absent, never unavailable.
        var isLoading = false
        if case .loading = WindowCardLoader.quotaHalf(
            payload: nil, clientId: "codex", attempted: false,
            curve: { _, _, _, _ in wCurve }, nowMs: wNow * 1000) { isLoading = true }
        expect(isLoading, "L6a a payload that has not arrived yet is loading")

        // L6a (ii). Payload in, but this window has no recorded history: a
        // terminal answer. Mapping it to loading spins forever — copilot's
        // chat.v1 is exactly this case on real data.
        var noHistory = false
        if case .noQuotaHistory = WindowCardLoader.quotaHalf(
            payload: wPayload, clientId: "codex", attempted: true,
            curve: { _, _, _, _ in nil }, nowMs: wNow * 1000) { noHistory = true }
        expect(noHistory,
               "L6a a window with no quota history is terminal, not perpetually loading")

        // L6b. The other direction, and the one that shipped wrong: the engine
        // fails the curve read CLOSED on a generation mismatch, and replaces its
        // bindings on every publication — including the tray poller's, which the
        // dashboard does not drive. A read issued against the generation this
        // payload carries can therefore expire mid-flight. Reporting that as
        // "this window has no recorded quota history" states a fact about the
        // subscription on the strength of a failed read.
        struct CurveReadFailed: Error {}
        var transientIsLoading = false
        if case .loading = WindowCardLoader.quotaHalf(
            payload: wPayload, clientId: "codex", attempted: true,
            curve: { _, _, _, _ in throw CurveReadFailed() }, nowMs: wNow * 1000)
        { transientIsLoading = true }
        expect(transientIsLoading,
               "L6b a failed curve read is transient, never a claim of no history")

        // L6d. `attempted` has to change the answer, or it is not a parameter.
        // Both no-payload guards returned `.loading` regardless — one through a
        // ternary whose two branches were identical — so a quota fetch that
        // kept failing left this card spinning for ever.
        func stateIsLoading(_ state: WindowCardState) -> Bool {
            if case .loading = state { return true }
            return false
        }
        func stateIsBlocked(_ state: WindowCardState) -> Bool {
            if case .blocked = state { return true }
            return false
        }
        expect(
            stateIsLoading(WindowCardLoader.quotaHalf(
                payload: nil, clientId: "codex", attempted: false,
                curve: { _, _, _, _ in nil }, nowMs: wNow * 1000)),
            "L6d no payload and no attempt yet is still waiting")
        expect(
            stateIsBlocked(WindowCardLoader.quotaHalf(
                payload: nil, clientId: "codex", attempted: true,
                curve: { _, _, _, _ in nil }, nowMs: wNow * 1000)),
            "L6d no payload after the attempt settled is a terminal answer")
        expect(
            stateIsBlocked(WindowCardLoader.quotaHalf(
                payload: wPayload, clientId: "not-in-payload", attempted: true,
                curve: { _, _, _, _ in nil }, nowMs: wNow * 1000)),
            "L6d a client the settled payload does not carry is answered, not awaited")
        // The third guard, and the one the "no quota windows" wording was
        // written for: present, no error, and offering nothing to settle on.
        // The wire format allows an empty `windows` array, so this is an
        // answer. It returned `.loading` unconditionally — the same defect as
        // the two above, in the copy neither review round reached.
        let emptyWindows = try! JSONDecoder().decode(
            AgentUsagePayload.self,
            from: Data(#"{"generatedAt":"now","agents":[{"clientId":"codex","source":"fixture","updatedAt":"now","windows":[]}]}"#.utf8))
        expect(
            stateIsBlocked(WindowCardLoader.quotaHalf(
                payload: emptyWindows, clientId: "codex", attempted: true,
                curve: { _, _, _, _ in nil }, nowMs: wNow * 1000)),
            "L6d an agent present with no windows is answered once the attempt has settled")
        expect(
            stateIsLoading(WindowCardLoader.quotaHalf(
                payload: emptyWindows, clientId: "codex", attempted: false,
                curve: { _, _, _, _ in nil }, nowMs: wNow * 1000)),
            "L6d and is still a wait before it has")
        expect(
            stateIsLoading(WindowCardLoader.quotaHalf(
                payload: wPayload, clientId: "not-in-payload", attempted: false,
                curve: { _, _, _, _ in nil }, nowMs: wNow * 1000)),
            "L6d a client missing from an unsettled payload is still a wait")

        // L6g. The picker's selection must be one of its own options. The
        // stored value is a single preference shared by every client, so it
        // routinely names another client's window; the loader already falls
        // back, and the picker echoing the stored value left it selecting
        // nothing it offered. Pure form of the rule the binding applies.
        func pickerSelection(stored: String, cardId: String,
                             candidates: [String]) -> String {
            candidates.contains(stored) ? stored : cardId
        }
        expect(
            pickerSelection(stored: "claude|weekly.v1", cardId: "codex|session.v1",
                            candidates: ["codex|session.v1", "codex|main.weekly.v1"])
                == "codex|session.v1",
            "L6g a stored selection from another client falls back to the shown window")
        expect(
            pickerSelection(stored: "codex|main.weekly.v1", cardId: "codex|session.v1",
                            candidates: ["codex|session.v1", "codex|main.weekly.v1"])
                == "codex|main.weekly.v1",
            "L6g while one this client does offer is honoured, so the fallback is not blanket")

        // L6f. Retention has to be keyed on the identity the CARD shows. Two
        // window selections share a client, so "keep what we had for this
        // client" could leave the chart on the window the user navigated away
        // from while the picker highlighted the new one.
        let wSelected = WindowCardLoader.selectedCardId(
            payload: wPayload, clientId: "codex")
        expect(wSelected == "codex|session.v1",
               "L6f the selected card id names the client AND the window")
        expect(
            WindowCardLoader.selectedCardId(payload: wPayload, clientId: "absent") == nil,
            "L6f and is nil when nothing can be selected, so a retained card cannot match it")
        expect(
            WindowCardLoader.quotaHalf(
                payload: wPayload, clientId: "codex", attempted: true,
                curve: { _, _, _, _ in wCurve }, nowMs: wNow * 1000).cardId == wSelected,
            "L6f a resolved card reports the same identity the selection does")
        expect(
            WindowCardLoader.quotaHalf(
                payload: nil, clientId: "codex", attempted: false,
                curve: { _, _, _, _ in nil }, nowMs: wNow * 1000).cardId == nil,
            "L6f while a card about no window reports none, so it is never retained")

        // L6e. Teaching `quotaHalf` to answer is not the same as the answer
        // reaching the card. `refreshWindowQuotaHalves` is the only writer of
        // `windowCards`, and it was called from the poll's success branch
        // alone, so a run of failures left the card holding the `.loading` it
        // was built with. Driven through the real poll rather than reasoned
        // about, because the pure function was already green while this was
        // broken.
        let blockedOnFailure: Bool? = awaitMainActorValue {
            let src = WindowScanCountingSource(payload: wPayload)
            src.failAgentUsage = true
            let m = DashboardModel(source: src, initialYear: nil)
            // Set before the poll settles: this is what the lens task supplies
            // in the app, and the recompute writes one entry per client.
            m.windowCardClients = ["codex"]
            let poll = Task { await m.pollAgentUsage() }
            var spins = 0
            while !m.agentUsageAttempted, spins < 2_000 {
                try? await Task.sleep(nanoseconds: 1_000_000)
                spins += 1
            }
            poll.cancel()
            _ = await poll.value
            guard let state = m.windowCards["codex"] else { return false }
            return stateIsBlocked(state)
        }
        expect(blockedOnFailure == true,
               "L6e a settled quota failure reaches the card, not just the function")

        // And the two must stay distinguishable at the layer below, or the
        // check above is one `try?` away from silently reverting.
        expect(
            WindowCardLoader.curveSamples(
                payload: wPayload, clientId: "codex", accountKey: nil,
                window: wPayload.agents[0].uniqueCardWindows[0],
                curve: { _, _, _, _ in throw CurveReadFailed() }, nowMs: wNow * 1000) == nil,
            "L6b a throwing read yields nil, meaning unknown")
        expect(
            WindowCardLoader.curveSamples(
                payload: wPayload, clientId: "codex", accountKey: nil,
                window: wPayload.agents[0].uniqueCardWindows[0],
                curve: { _, _, _, _ in nil }, nowMs: wNow * 1000) == [],
            "L6b a read that succeeds with no curve yields empty, meaning none")

        // Same contract, same reason, one layer over: the history card reads
        // `cycles`, and folding "no payload yet" into `[]` is what let it state
        // "no earlier windows recorded" during the very first fetch. The quota
        // payload is never persisted, so that is every cold start.
        expect(
            WindowCardLoader.cycles(
                payload: nil, clientId: "codex",
                curve: { _, _, _, _ in nil }) == nil,
            "L6c no payload yet is unknown, not an empty history")
        expect(
            WindowCardLoader.cycles(
                payload: wPayload, clientId: "codex",
                curve: { _, _, _, _ in nil }) == [],
            "L6c a payload whose curve holds nothing is an empty history")

        // L3a. The union starts at the earliest R - D across every client, so
        // one scan covers them all. Second client's window started earlier.
        let wIso2 = ISO8601DateFormatter().string(
            from: Date(timeIntervalSince1970: Double(wNow + 600)))
        let twoClients = windowPayload([
            (client: "codex", windows: [(card: "session.v1", key: "session.v1",
                                         resetsAt: wIso, durationSecs: 18_000)]),
            (client: "claude", windows: [(card: "weekly.v1", key: "weekly.v1",
                                          resetsAt: wIso2, durationSecs: 604_800)]),
        ])
        let union = WindowCardLoader.unionStart(
            payload: twoClients, clients: ["codex", "claude"], nowMs: wNow * 1000)
        expect(union == (wNow + 600 - 604_800) * 1000,
               "L3a the union starts at the earliest window start, not the selected one")
        expect(
            WindowCardLoader.unionStart(
                payload: twoClients, clients: ["codex"], nowMs: wNow * 1000)
                == (wReset - 18_000) * 1000,
            "L3a a narrower client set gives a narrower union, so the bound is real")

        // L3b. The union must apply the SAME anchor-validity rule the card
        // does. A reset 60 days old resolves `.unavailable` — the card draws
        // nothing for it — but `R - D` still put the scan 67 days back, so
        // opening that tab paid for months of local history to render a window
        // that displays no usage at all.
        let wStale = ISO8601DateFormatter().string(
            from: Date(timeIntervalSince1970: Double(wNow - 60 * 86_400)))
        let withStale = windowPayload([
            (client: "codex", windows: [(card: "session.v1", key: "session.v1",
                                         resetsAt: wIso, durationSecs: 18_000)]),
            (client: "claude", windows: [(card: "weekly.v1", key: "weekly.v1",
                                          resetsAt: wStale, durationSecs: 604_800)]),
        ])
        expect(
            WindowCardLoader.unionStart(
                payload: withStale, clients: ["codex", "claude"], nowMs: wNow * 1000)
                == (wReset - 18_000) * 1000,
            "L3b a stale anchor the card cannot use does not widen the scan")

        // The other direction, or the filter above is one `!=` away from
        // excluding every past-reset window: a reset INSIDE one duration is
        // `.idle`, which the card does display once usage places it, and its
        // start must still bound the scan.
        let wRecent = ISO8601DateFormatter().string(
            from: Date(timeIntervalSince1970: Double(wNow - 3_600)))
        let withRecent = windowPayload([
            (client: "codex", windows: [(card: "session.v1", key: "session.v1",
                                         resetsAt: wIso, durationSecs: 18_000)]),
            (client: "claude", windows: [(card: "weekly.v1", key: "weekly.v1",
                                          resetsAt: wRecent, durationSecs: 604_800)]),
        ])
        expect(
            WindowCardLoader.unionStart(
                payload: withRecent, clients: ["codex", "claude"], nowMs: wNow * 1000)
                == (wNow - 3_600 - 604_800) * 1000,
            "L3b a past reset still within one duration keeps bounding the scan")

        // MS. A model-scoped window ("Fable only") must show only that model's
        // usage. It showed the whole subscription's, so the bars underneath the
        // curve were explaining a different quota than the one drawn.
        //
        // The join is between two naming systems and nothing guarantees they
        // agree — the provider sends `scope.model.id: null`, so the scope is
        // its DISPLAY-NAME slug while the rows carry the transcript's canonical
        // id. These fixtures use the real strings from both sides.
        expect(ModelScope.covers("fable", modelId: "claude-fable-5"),
               "MS the provider's display slug matches the transcript's canonical id")
        expect(!ModelScope.covers("fable", modelId: "claude-sonnet-4-5"),
               "MS and does not match a different model, or the filter is a no-op")
        expect(ModelScope.covers("claude-fable-5", modelId: "claude-fable-5-20260101"),
               "MS a multi-token scope matches when every token is present, so a "
                   + "display name spelled out in full still lands")
        expect(!ModelScope.covers("fable-max", modelId: "claude-fable-5"),
               "MS but a token the id lacks does NOT match — the rule is a subset "
                   + "test, and this is the under-match the scope note exists for")
        expect(!ModelScope.covers("", modelId: "claude-fable-5"),
               "MS an empty scope selects nothing rather than everything")

        let msIso = ISO8601DateFormatter().string(
            from: Date(timeIntervalSince1970: Double(wNow + 3_600)))
        let msPayload = windowPayload([
            (client: "codex", windows: [(card: "weekly_scoped.fable.v1",
                                         key: "weekly_scoped.fable.v1",
                                         resetsAt: msIso, durationSecs: 604_800)]),
        ], modelScope: "fable")
        let msMessages = try! JSONDecoder().decode(
            [WindowMessage].self,
            from: Data("""
            [{"timestamp":\((wNow - 1_000) * 1000),"client":"codex","providerId":"anthropic",
              "modelId":"claude-fable-5","input":700,"output":0,"cacheRead":0,"cacheWrite":0,
              "reasoning":0,"cost":1.0,"isTurnStart":true},
             {"timestamp":\((wNow - 900) * 1000),"client":"codex","providerId":"anthropic",
              "modelId":"claude-sonnet-4-5","input":300,"output":0,"cacheRead":0,"cacheWrite":0,
              "reasoning":0,"cost":0.5,"isTurnStart":true}]
            """.utf8))
        // Declared, or `isMine` rejects every row and all three cases below
        // pass on an empty set rather than on the filter.
        let msConfirmed = [UsageAttribution.Record(
            client: "codex", provider: "anthropic", state: .assigned("codex"))]
        let msScan = UnionScan(
            fromMs: (wNow - 604_800) * 1000, untilMs: wNow * 1000,
            capturedAt: Date(), messages: msMessages)
        let msStage1 = WindowCardLoader.quotaHalf(
            payload: msPayload, clientId: "codex", attempted: true,
            curve: { _, _, _, _ in
                windowCurve(resetAtSecs: wNow + 3_600, durationSecs: 604_800,
                            at: [(wNow - 2_000, 4), (wNow - 500, 9)])
            },
            nowMs: wNow * 1000)
        if case let .quotaOnly(msQuota, _) = msStage1 {
            expect(msQuota.modelScope == "fable",
                   "MS the scope reaches stage 1 from the payload, so stage 2 does "
                       + "not re-derive it from the window key")
            let msHalf = WindowCardLoader.usageHalf(
                quota: msQuota, scan: msScan, confirmed: msConfirmed)
            expect(msHalf?.1.mine.map(\.modelId) == ["claude-fable-5"],
                   "MS a scoped window counts only the model its allowance is about")
            expect(msHalf?.1.scopeMatchedNothing == false,
                   "MS and does not claim the scope missed when it matched")
        } else {
            expect(false, "MS the scoped fixture reaches stage 1")
        }

        // The other direction, or the filter is satisfied by dropping
        // everything: the same scan against an UNSCOPED window keeps both rows.
        let msUnscoped = windowPayload([
            (client: "codex", windows: [(card: "weekly.v1", key: "weekly.v1",
                                         resetsAt: msIso, durationSecs: 604_800)]),
        ])
        let msUnscopedStage1 = WindowCardLoader.quotaHalf(
            payload: msUnscoped, clientId: "codex", attempted: true,
            curve: { _, _, _, _ in
                windowCurve(resetAtSecs: wNow + 3_600, durationSecs: 604_800,
                            at: [(wNow - 2_000, 4), (wNow - 500, 9)])
            },
            nowMs: wNow * 1000)
        if case let .quotaOnly(msQuota, _) = msUnscopedStage1 {
            expect(msQuota.modelScope == nil,
                   "MS a window the provider did not narrow carries no scope")
            let msHalf = WindowCardLoader.usageHalf(
                quota: msQuota, scan: msScan, confirmed: msConfirmed)
            expect(msHalf?.1.mine.count == 2,
                   "MS and an unscoped window still counts the whole subscription")
        } else {
            expect(false, "MS the unscoped fixture reaches stage 1")
        }

        // MS-KEY. The history rows and the equivalence estimate hold a
        // `"<clientId>|<cardId>"` and no `UsageWindow`, so they ask for the
        // scope by that key. Without one lookup they would each parse it out of
        // the window-key string — three parsers for one fact.
        expect(WindowCardLoader.modelScope(
                   payload: msPayload, cardId: "codex|weekly_scoped.fable.v1") == "fable",
               "MS-KEY a window's scope is addressable by the same key every other "
                   + "surface uses to name it")
        expect(WindowCardLoader.modelScope(
                   payload: msUnscoped, cardId: "codex|weekly.v1") == nil,
               "MS-KEY and an unscoped window answers nil, so the lookup is not "
                   + "simply returning whatever it finds first")
        expect(WindowCardLoader.modelScope(
                   payload: msPayload, cardId: "codex|no.such.window.v1") == nil
                   && WindowCardLoader.modelScope(
                       payload: msPayload, cardId: "ghost|weekly_scoped.fable.v1") == nil
                   && WindowCardLoader.modelScope(payload: msPayload, cardId: nil) == nil,
               "MS-KEY an unknown card, an unknown client and a missing key all "
                   + "answer nil rather than the wrong window's scope")

        // MS-MISS. The join finding nothing is reported, not drawn as an idle
        // week. Empty bars under a moving curve state that the user did no
        // work, which is a claim this card has no evidence for.
        let msMissPayload = windowPayload([
            (client: "codex", windows: [(card: "weekly_scoped.ghost.v1",
                                         key: "weekly_scoped.ghost.v1",
                                         resetsAt: msIso, durationSecs: 604_800)]),
        ], modelScope: "ghost")
        let msMissStage1 = WindowCardLoader.quotaHalf(
            payload: msMissPayload, clientId: "codex", attempted: true,
            curve: { _, _, _, _ in
                windowCurve(resetAtSecs: wNow + 3_600, durationSecs: 604_800,
                            at: [(wNow - 2_000, 4), (wNow - 500, 9)])
            },
            nowMs: wNow * 1000)
        if case let .quotaOnly(msQuota, _) = msMissStage1 {
            let msHalf = WindowCardLoader.usageHalf(
                quota: msQuota, scan: msScan, confirmed: msConfirmed)
            expect(msHalf?.1.mine.isEmpty == true
                       && msHalf?.1.scopeMatchedNothing == true,
                   "MS-MISS a scope that matches nothing says so, rather than "
                       + "presenting an empty window as a quiet week")
        } else {
            expect(false, "MS-MISS the unmatched fixture reaches stage 1")
        }

        // L2a. `usageHalf` consumes a scan rather than issuing one: the single
        // scan is structural. It must also refuse a scan that starts too late,
        // because filtering from it would silently under-count.
        let late = UnionScan(fromMs: wNow * 1000, untilMs: wNow * 1000,
                             capturedAt: Date(), messages: [])
        if case let .quotaOnly(q, _) = stage1 {
            expect(WindowCardLoader.usageHalf(quota: q, scan: late, confirmed: []) == nil,
                   "L2a a scan that begins after the window did cannot answer for it")
            let covering = UnionScan(
                fromMs: (wReset - 18_000) * 1000, untilMs: wNow * 1000,
                capturedAt: Date(), messages: [])
            expect(
                WindowCardLoader.usageHalf(quota: q, scan: covering, confirmed: []) != nil,
                "L2a a covering scan answers, so the previous check is not vacuous")
        }

        // MARK: Agent-limits sparkline eligibility
        //
        // The one place that decides whether a row draws a line or the bar.
        // Getting it wrong is not a cosmetic slip: a series that misses the
        // window entirely still interpolates, so the row would show a confident
        // flat line for a window nobody has sampled.
        let sparkWindow = wPayload.agents[0].uniqueCardWindows[0]
        let sparkNow = wNow * 1000
        let sparkStart = (wReset - 18_000) * 1000

        expect(
            AgentLimitsCard.sparklineInterval(
                window: sparkWindow,
                samples: [QuotaSample(atMs: sparkNow - 3_000_000, usedPercent: 4),
                          QuotaSample(atMs: sparkNow - 600_000, usedPercent: 9)],
                nowMs: sparkNow).map { $0.start } == sparkStart,
            "SP1 two readings inside the window draw a line spanning R - D to R")

        // The load-bearing one. Both readings predate this window's start, so
        // the count alone is satisfied and only the interval filter rejects it.
        expect(
            AgentLimitsCard.sparklineInterval(
                window: sparkWindow,
                samples: [QuotaSample(atMs: sparkStart - 90_000_000, usedPercent: 40),
                          QuotaSample(atMs: sparkStart - 80_000_000, usedPercent: 55)],
                nowMs: sparkNow) == nil,
            "SP2 readings from before this window cannot draw its line")

        expect(
            AgentLimitsCard.sparklineInterval(
                window: sparkWindow,
                samples: [QuotaSample(atMs: sparkNow - 600_000, usedPercent: 9)],
                nowMs: sparkNow) == nil,
            "SP3 one reading is a dot, not a line, so the bar stays")

        expect(
            AgentLimitsCard.sparklineInterval(
                window: sparkWindow, samples: [], nowMs: sparkNow) == nil,
            "SP4 no readings at all keeps the bar")

        // MARK: scan scope (SC)
        //
        // The message scan follows what is on screen. Measured 2026-08-16:
        // unioning every displayed client stretched the range to 14.93 days and
        // 109,278 messages because `copilot chat.v1` is a 31-day window, and it
        // ran on the all-agent overview, which renders no window card at all —
        // 67 seconds of scanning for output nothing displayed.
        let scanCounts: (idle: Int, open: Int)? = awaitMainActorValue {
            let src = WindowScanCountingSource(payload: wPayload)
            let m = DashboardModel(source: src, initialYear: nil)
            // `agentUsage` is private(set), so the poll is the only way in.
            // One turn is enough; cancel and drain before counting anything.
            let poll = Task { await m.pollAgentUsage() }
            var spins = 0
            while m.agentUsage == nil, spins < 2_000 {
                try? await Task.sleep(nanoseconds: 1_000_000)
                spins += 1
            }
            poll.cancel()
            _ = await poll.value
            m.windowCardClients = ["codex"]
            src.scans = 0

            // Overview: curves still wanted for the sparklines, no card on screen.
            m.windowUsageClient = nil
            await m.refreshWindowUsage()
            let idle = src.scans

            // Agent tab open: the same call must reach a scan, or the check
            // above is satisfied by a method that never scans under any
            // condition — which is exactly how this regression hid.
            m.windowUsageClient = "codex"
            await m.refreshWindowUsage()
            return (idle: idle, open: src.scans)
        }
        expect(scanCounts?.idle == 0,
               "SC1 no agent tab open issues no message scan")
        expect((scanCounts?.open ?? 0) >= 1,
               "SC1 an open agent tab does scan, so the bound above is not vacuous")

        // SC2. The scan range used to be anchored on the live window, so a
        // provider that reports a reset without a window length took the whole
        // history down with it: `unionStart` returned nil, `refreshWindowUsage`
        // returned before scanning, and no scan covering this client's cycles
        // was ever cached — leaving every row of the history card on "Reading
        // local usage…" permanently rather than for the length of a scan.
        // Measured on live Codex data 2026-09-08: all three of its windows
        // carried `resetsAt` with `durationSeconds` nil.
        //
        // The cycles are their own range, so both numbers are asserted: a scan
        // that runs but produces no joined row would satisfy the count alone.
        let hsReset = wNow - 7_200
        let hsPayload: AgentUsagePayload = {
            let json = """
            {"generatedAt":"t","publicationGeneration":7,"agents":[
              {"clientId":"codex","source":"oauth","updatedAt":"t","windows":[
                {"cardId":"main.weekly.v1","label":"Weekly","usedPercent":0,
                 "remainingPercent":100,"resetsAt":"\(wIso)",
                 "paceStatus":{"state":"unavailable","windowKey":"main.weekly.v1",
                               "completeCycles":0,"reason":"invalidEvidence"}}
              ]}
            ]}
            """
            return try! JSONDecoder().decode(AgentUsagePayload.self, from: Data(json.utf8))
        }()
        let durationlessScan: (scans: Int, rows: Int)? = awaitMainActorValue {
            let src = WindowScanCountingSource(payload: hsPayload)
            src.curve = windowCurve(
                resetAtSecs: hsReset, durationSecs: 18_000,
                at: [(hsReset - 15_000, 4), (hsReset - 600, 40)], isActive: false)
            let m = DashboardModel(source: src, initialYear: nil)
            let poll = Task { await m.pollAgentUsage() }
            var spins = 0
            while m.agentUsage == nil, spins < 2_000 {
                try? await Task.sleep(nanoseconds: 1_000_000)
                spins += 1
            }
            poll.cancel()
            _ = await poll.value
            m.windowCardClients = ["codex"]
            m.windowUsageClient = "codex"
            m.refreshWindowQuotaHalves()
            src.scans = 0
            await m.refreshWindowUsage()
            return (scans: src.scans, rows: m.quotaHistory.count)
        }
        expect(durationlessScan?.scans == 1,
               "SC2 a window with no provider duration still scans for its history")
        expect(durationlessScan?.rows == 1,
               "SC2 and the scan reaches the history rows rather than only running")

        // SS1. `windowCardClients` is assigned from `displayClients`, which
        // arrives with graph data, so it is briefly empty on every top-level
        // view change. Recomputing the strip summaries from an empty client set
        // and publishing the empty result made the card announce "no completed
        // windows recorded yet" mid-switch and then come back.
        let stripSummaries: (present: Int, afterEmpty: Int)? = awaitMainActorValue {
            let src = WindowScanCountingSource(payload: wPayload)
            // Completed, not running: the strip summarises past windows, and a
            // fixture whose only cycle is the open one now yields none.
            src.curve = windowCurve(
                resetAtSecs: wReset, durationSecs: 18_000,
                at: [(wNow - 3_000, 4), (wNow - 600, 9)], isActive: false)
            let m = DashboardModel(source: src, initialYear: nil)
            let poll = Task { await m.pollAgentUsage() }
            var spins = 0
            while m.agentUsage == nil, spins < 2_000 {
                try? await Task.sleep(nanoseconds: 1_000_000)
                spins += 1
            }
            poll.cancel()
            _ = await poll.value
            m.windowCardClients = ["codex"]
            m.refreshWindowQuotaHalves()
            let present = m.quotaWindowSummaries.count
            m.windowCardClients = []
            m.refreshWindowQuotaHalves()
            return (present: present, afterEmpty: m.quotaWindowSummaries.count)
        }
        // SS2. A window whose only movement is in the cycle now running has a
        // grid and no summary — the strip excludes active cycles deliberately.
        // Keying the heatmap picker on summaries made that grid unreachable and
        // the card said nothing had been recorded, for as long as the cycle
        // takes to finish. Same fixture as SS1 but left ACTIVE.
        let activeOnly: (summaries: Int, heatmaps: Int)? = awaitMainActorValue {
            let src = WindowScanCountingSource(payload: wPayload)
            src.curve = windowCurve(
                resetAtSecs: wReset, durationSecs: 18_000,
                at: [(wNow - 3_000, 4), (wNow - 600, 9)], isActive: true)
            let m = DashboardModel(source: src, initialYear: nil)
            let poll = Task { await m.pollAgentUsage() }
            var spins = 0
            while m.agentUsage == nil, spins < 2_000 {
                try? await Task.sleep(nanoseconds: 1_000_000)
                spins += 1
            }
            poll.cancel()
            _ = await poll.value
            m.windowCardClients = ["codex"]
            m.refreshWindowQuotaHalves()
            return (summaries: m.quotaWindowSummaries.count,
                    heatmaps: m.quotaHeatmapWindows.count)
        }
        // SS3. A curve read that THROWS on the very first refresh is not an
        // absence. Nothing had been published yet, so `quotaCyclesCardId` was
        // nil — and the retention branch read nil as "what we hold is about a
        // different window" and answered by publishing empty. The quota fetch
        // has settled by then, so the card stated "No earlier windows recorded
        // yet" about a curve it could not read, and kept saying it until some
        // later refresh happened to retry.
        let firstReadThrows: (cycles: Int, unreadable: Int)? = awaitMainActorValue {
            let src = WindowScanCountingSource(payload: wPayload)
            src.failCurveRead = true
            let m = DashboardModel(source: src, initialYear: nil)
            let poll = Task { await m.pollAgentUsage() }
            var spins = 0
            while m.agentUsage == nil, spins < 2_000 {
                try? await Task.sleep(nanoseconds: 1_000_000)
                spins += 1
            }
            poll.cancel()
            _ = await poll.value
            m.windowCardClients = ["codex"]
            m.windowUsageClient = "codex"
            m.refreshWindowQuotaHalves()
            return (cycles: m.quotaCycles.count,
                    unreadable: m.quotaCurveUnreadable ? 1 : 0)
        }
        expect(firstReadThrows?.cycles == 0 && firstReadThrows?.unreadable == 1,
               "SS3 a curve read that THROWS leaves no cycles AND says it was "
                   + "unreadable — the card decides on emptiness plus settled, so "
                   + "without the second fact it reports an absence it never checked")

        expect(activeOnly?.summaries == 0,
               "SS2 a window with only a running cycle has no completed history")
        expect((activeOnly?.heatmaps ?? 0) >= 1,
               "SS2 but it does have a grid, and the picker can still reach it")

        // SS3. The other half of the empty-client rule. Skipping publication
        // stops a top-level view change from blanking the strip, but the user
        // hiding their LAST visible client is also an empty set — a permanent
        // one — and skipping there left the strip and the grid drawing a client
        // no longer on screen. `stats` is the graph's arrival signal, so it is
        // what separates the transient empty from the settled one.
        let clearedWhenHidden: (before: Int, after: Int, settled: Bool)? =
            awaitMainActorValue {
                let src = WindowScanCountingSource(payload: wPayload)
                src.curve = windowCurve(
                    resetAtSecs: wReset, durationSecs: 18_000,
                    at: [(wNow - 3_000, 4), (wNow - 600, 9)], isActive: false)
                let m = DashboardModel(source: src, initialYear: nil)
                let poll = Task { await m.pollAgentUsage() }
                var spins = 0
                while m.agentUsage == nil, spins < 2_000 {
                    try? await Task.sleep(nanoseconds: 1_000_000)
                    spins += 1
                }
                poll.cancel()
                _ = await poll.value
                // The graph has to have landed, or an empty set is still the
                // transient kind and must NOT clear.
                await m.load()
                m.windowCardClients = ["codex"]
                m.refreshWindowQuotaHalves()
                let before = m.quotaWindowSummaries.count
                m.windowCardClients = []
                m.refreshWindowQuotaHalves()
                return (before: before, after: m.quotaWindowSummaries.count,
                        settled: m.stats != nil)
            }
        expect(clearedWhenHidden?.settled == true,
               "SS3 the fixture does reach a settled graph, so the case below is reachable")
        expect((clearedWhenHidden?.before ?? 0) >= 1,
               "SS3 and it populates first, so the clearing is observable")
        expect(clearedWhenHidden?.after == 0,
               "SS3 hiding the last client clears the derived quota state")

        expect((stripSummaries?.present ?? 0) >= 1,
               "SS1 the fixture does produce a summary, so the check below is not vacuous")
        expect(stripSummaries != nil && stripSummaries?.afterEmpty == stripSummaries?.present,
               "SS1 an empty client set leaves the strip summaries alone")

        // MARK: quota heatmap (QM)
        //
        // Fixed to UTC and to a known Monday (2026-01-05) so the expected slots
        // are arithmetic rather than whatever the runner's calendar says.
        func heatPoint(
            _ at: Int64, _ used: Double, reset: Int64, active: Bool = false
        ) -> QuotaCurvePoint {
            try! JSONDecoder().decode(QuotaCurvePoint.self, from: Data("""
            {"sampledAt":\(at),"usedPercent":\(used),"resetAt":\(reset),
             "durationSeconds":604800,"durationSource":"provider","origin":"liveV3",
             "isActiveGroup":\(active)}
            """.utf8))
        }
        let utc = TimeZone(identifier: "UTC")!
        // Each reset must bracket its own points: the decoder refuses a sample
        // outside `[reset - duration, reset]`, which is the store's own rule.
        let monReset: Int64 = 1_767_700_000
        let otherReset: Int64 = 1_767_800_000
        let sunReset: Int64 = 1_768_200_000

        // QM1. A delta is spread across the hours its interval covers, weighted
        // by time in each. 09:30 -> 11:30 carrying 4 points lands 1 / 2 / 1 on
        // hours 9, 10, 11 — not 4 on the hour that observed it.
        let spread = QuotaHeatmapFold.build(
            points: [heatPoint(1_767_605_400, 10, reset: monReset),
                     heatPoint(1_767_612_600, 14, reset: monReset)],
            timeZone: utc)
        expect(abs(spread.cells[0][9] - 1) < 1e-9
                && abs(spread.cells[0][10] - 2) < 1e-9
                && abs(spread.cells[0][11] - 1) < 1e-9,
               "QM1 a two-hour delta is spread 1/2/1 across the hours it covers")
        expect(abs(spread.total - 4) < 1e-9 && abs(spread.peak - 2) < 1e-9,
               "QM1 the grid accounts for the whole delta, and the peak is the fullest hour")

        // QM2. Deltas never cross a reset. The third reading is a NEW cycle
        // sitting HIGHER than the old one's last, so a fold that sorted by time
        // and ignored `resetAt` would add 26 points of imaginary consumption.
        let crossing = QuotaHeatmapFold.build(
            points: [heatPoint(1_767_605_400, 10, reset: monReset),
                     heatPoint(1_767_612_600, 14, reset: monReset),
                     heatPoint(1_767_616_200, 40, reset: otherReset)],
            timeZone: utc)
        expect(abs(crossing.total - 4) < 1e-9,
               "QM2 a higher reading in the next cycle is not consumption")

        // QM3. Readings too far apart to place are reported, not folded in and
        // not dropped: 7h exceeds the 6h bound.
        let sparse = QuotaHeatmapFold.build(
            points: [heatPoint(1_767_661_200, 20, reset: monReset),
                     heatPoint(1_767_686_400, 29, reset: monReset)],
            timeZone: utc)
        expect(sparse.total == 0 && abs(sparse.unplacedPercent - 9) < 1e-9,
               "QM3 consumption between readings 7h apart is unplaced, not spread")

        // QM4. That same grid still counts as a window where the allowance
        // moved. `isEmpty` reads `total`, which counts only what could be
        // placed, so an unplaced-only window was dropped from the picker and
        // the card then reported "no allowance movement recorded yet" — the
        // opposite of what QM3 just measured, with the line that explains it
        // unreachable behind the same condition.
        expect(sparse.isEmpty && sparse.hasMovement,
               "QM4 a window whose movement is entirely unplaced is empty as a GRID "
                   + "but is not a window without movement")
        expect(!QuotaHeatmap.empty.hasMovement,
               "QM4 and a window with nothing recorded at all still has no movement, "
                   + "so the honest empty state is still reachable")
        // QM5. Any positive unplaced movement, not a full point. Curve readings
        // are arbitrary finite percentages, so a pair seven hours apart moving
        // half a point is movement this fold recorded — and a `>= 1` test threw
        // it away, dropping the window from the picker exactly as QM4 describes.
        let qm5 = QuotaHeatmapFold.build(
            points: [heatPoint(1_767_661_200, 20, reset: monReset),
                     heatPoint(1_767_686_400, 20.5, reset: monReset)],
            timeZone: utc)
        expect(qm5.total == 0 && qm5.unplacedPercent > 0 && qm5.unplacedPercent < 1
                   && qm5.hasMovement,
               "QM5 half a point of unplaced movement is still movement")

        // QH-A. The running cycle is not history. It appears in a strip
        // captioned "past windows", stands beside completed spans as though
        // comparable, and counts toward the three-cycle threshold the
        // equivalence needs — an estimate that would then move under the reader
        // as the cycle filled.
        let qhaPoints = [
            heatPoint(1_767_605_400, 10, reset: monReset),
            heatPoint(1_767_612_600, 14, reset: monReset),
            heatPoint(1_767_616_200, 40, reset: otherReset),
        ]
        expect(QuotaHistoryFold.cycles(points: qhaPoints).count == 2,
               "QH-A both groups are cycles when no point is marked active")
        let qhaActive = [
            heatPoint(1_767_605_400, 10, reset: monReset),
            heatPoint(1_767_612_600, 14, reset: monReset),
            heatPoint(1_767_616_200, 40, reset: otherReset, active: true),
        ]
        expect(
            QuotaHistoryFold.cycles(points: qhaActive).map(\.resetAtMs)
                == [monReset * 1000],
            "QH-A the running cycle's own points exclude it, leaving only the "
                + "completed one")
        // QH-A2. The exclusion must not depend on `resetAt` matching anything.
        // It used to compare each point's NORMALIZED `resetAt` against the
        // curve's RAW `activeResetAt`, so it silently did nothing whenever the
        // provider's reset was off the quantum — most of the time. Here the
        // active point's reset matches no other value on the curve and is not
        // passed in anywhere: only the flag can exclude it.
        let qhaOffQuantum = [
            heatPoint(1_767_605_400, 10, reset: monReset),
            heatPoint(1_767_616_200, 40, reset: otherReset + 137, active: true),
        ]
        expect(
            QuotaHistoryFold.cycles(points: qhaOffQuantum).map(\.resetAtMs)
                == [monReset * 1000],
            "QH-A2 an active point whose reset matches no quantised value is "
                + "still excluded, because the producer said so rather than the "
                + "consumer inferring it")

        // QH-CAP. The fold used to return everything the engine retained (128
        // cycles per series). Nothing draws that many — the history card shows
        // 12 rows and the overview strip 16 — but the OLDEST cycle is what
        // bounds the message scan, so a 5-hour window at 128 cycles asked for a
        // 26-day scan to render twelve rows, and a weekly window walked that
        // bound backwards for ever.
        func qhcPoint(_ at: Int64, _ used: Double, reset: Int64, duration: Int64) -> QuotaCurvePoint {
            try! JSONDecoder().decode(QuotaCurvePoint.self, from: Data("""
            {"sampledAt":\(at),"usedPercent":\(used),"resetAt":\(reset),
             "durationSeconds":\(duration),"durationSource":"provider","origin":"liveV3",
             "isActiveGroup":false}
            """.utf8))
        }
        let qhcWeek: Int64 = 604_800
        // The oldest cycle is the only one that ran the allowance out, so it is
        // also the fixture for what the cap must NOT hide.
        let qhcPoints: [QuotaCurvePoint] = (0..<40).flatMap { index -> [QuotaCurvePoint] in
            let reset = monReset + Int64(index) * qhcWeek
            return [qhcPoint(reset - qhcWeek + 60, 10, reset: reset, duration: qhcWeek),
                    qhcPoint(reset - 60, index == 0 ? 100 : 30,
                             reset: reset, duration: qhcWeek)]
        }
        let qhcAll = QuotaHistoryFold.cycles(points: qhcPoints)
        let qhcCycles = QuotaHistoryFold.considered(qhcAll)
        expect(qhcAll.count == 40,
               "QH-CAP the fold itself returns every recorded cycle")
        expect(qhcCycles.count == QuotaHistoryFold.consideredCycles,
               "QH-CAP forty recorded cycles reduce to the considered cap")
        expect(
            qhcCycles.first?.resetAtMs == (monReset + 39 * qhcWeek) * 1000
                && qhcCycles.last?.resetAtMs == (monReset + 8 * qhcWeek) * 1000,
            "QH-CAP the cap keeps the NEWEST cycles — dropping those instead would "
                + "bound the scan at the same place while showing stale rows")
        // QH-MONEY. `$%.2f` cannot tell "nothing" from "nothing we could price"
        // from "less than half a cent"; all three render "$0.00" and only the
        // first is true. A single list-priced call at $0.003 is ordinary, so
        // "2.1M · $0.00" — the string the other-subscription line was rewritten
        // to stop printing — survived inside the rewrite itself.
        expect(Format.usdOrBelowCent(0.003) == "<$0.01"
                   && Format.usdOrBelowCent(0) == "$0.00"
                   && Format.usdOrBelowCent(1.5) == "$1.50",
               "QH-MONEY a real amount below the format's resolution is said to be "
                   + "small, while an exact zero and an ordinary amount are unchanged")
        expect(Format.money(tokens: 2_100_000, cost: 0) == "—"
                   && Format.money(tokens: 0, cost: 0) == "$0.00"
                   && Format.money(tokens: 2_100_000, cost: 0.003) == "<$0.01",
               "QH-MONEY tokens with no price get a dash rather than a false total, "
                   + "while a window that genuinely spent nothing still reads $0.00")
        // FMT-TIER. `compactTokens` picked its unit from the raw value and only
        // then rounded the mantissa, so a `%.0f` carry out of 999.5 published a
        // mantissa that had left its own tier: "1000M", "1000K".
        expect(Format.compactTokens(999_500_000) == "1B"
                   && Format.compactTokens(999_999_999) == "1B"
                   && Format.compactTokens(999_500) == "1M"
                   && Format.compactTokens(999_999) == "1M",
               "FMT-TIER a mantissa that rounds up to 1000 is promoted to the next "
                   + "unit rather than printed as \"1000M\" / \"1000K\"")
        expect(Format.compactTokens(999_499_999) == "999M"
                   && Format.compactTokens(999_499) == "999K"
                   && Format.compactTokens(1_000_000_000) == "1B"
                   && Format.compactTokens(1_234_567) == "1.2M"
                   && Format.compactTokens(12_345) == "12.3K"
                   && Format.compactTokens(999) == "999",
               "FMT-TIER every value outside the two half-unit bands renders exactly "
                   + "as it did before the promotion was added")
        // QH-REASON. "Not enough history" is a false sentence for three of the
        // states that reach the heatmap tooltip's fallback: their history is
        // sufficient and each fails for its own reason.
        expect(
            QuotaHeatmapCard.noFigureReason(.notMoved)
                != QuotaHeatmapCard.noFigureReason(.unavailable)
                && QuotaHeatmapCard.noFigureReason(.insufficient(
                        deltaPercent: 2, errorPercent: 25))
                    != QuotaHeatmapCard.noFigureReason(.unavailable)
                && QuotaHeatmapCard.noFigureReason(.unaccounted(deltaPercent: 9))
                    != QuotaHeatmapCard.noFigureReason(.unavailable),
            "QH-REASON a window with sufficient history is not told its history is "
                + "insufficient")
        expect(
            QuotaHeatmapCard.noFigureReason(.unavailable)
                == "Not enough history to convert this window to a figure"
                && QuotaHeatmapCard.noFigureReason(.undeclared)
                    == "Classify your usage in Settings to see what this window is worth",
            "QH-REASON and the two states that genuinely lack history or a "
                + "declaration keep the sentences they had")
        // QH-FAIL. A success for one client must not erase another's recorded
        // failure. The version this replaced assigned nil unconditionally, so
        // opening tab B after tab A's scan failed made A's card forget — while
        // the doc comment two lines up claimed the flag was cleared "for that
        // client, and by nothing else". The rule is pure and static precisely
        // so this can be asserted; nothing in the async method could catch it.
        expect(
            DashboardModel.scanFailures(["claude", "codex"], resolvedBy: "codex")
                == ["claude"],
            "QH-FAIL a successful scan for one client leaves every OTHER client's "
                + "recorded failure alone")
        expect(
            DashboardModel.scanFailures(["claude"], resolvedBy: "claude").isEmpty
                && DashboardModel.scanFailures([], resolvedBy: "claude").isEmpty,
            "QH-FAIL and a success for the client that failed does clear it, so the "
                + "check above is not simply refusing to clear anything")
        // FMT-DURATION. The window countdown interpolated its units instead of
        // using the four localized templates that already existed and were
        // already translated, so a Traditional Chinese build rendered
        // "3h 5m 後重置" — units in one language, sentence in another.
        // Asserted on the KEY, not the rendered string: under English every one
        // of these templates is an identity, so comparing output passes whether
        // the code looks the key up or interpolates it — verified by mutation,
        // the interpolated version leaves the English run green.
        expect(Format.durationTemplate(ms: 54 * 60_000) == ("%lldm", [54]),
               "FMT-DURATION minutes use the localized minute template")
        expect(Format.durationTemplate(ms: (3 * 60 + 5) * 60_000)
                   == ("%lldh %lldm", [3, 5]),
               "FMT-DURATION and hours with a remainder use the two-unit one")
        expect(Format.durationTemplate(ms: 3 * 3_600_000) == ("%lldh", [3])
                   && Format.durationTemplate(ms: 2 * 86_400_000) == ("%lldd", [2]),
               "FMT-DURATION a whole number of hours or days uses the one-unit "
                   + "template rather than printing an empty second unit")
        expect(Format.durationTemplate(ms: (5 * 24 + 14) * 3_600_000)
                   == ("%lldd %lldh", [5, 14]),
               "FMT-DURATION and days with a remainder keep both")
        expect(Format.duration(ms: (3 * 60 + 5) * 60_000) == "3h 5m",
               "FMT-DURATION the rendered English string is unchanged")

        // QH-MONEY-UNPRICED. `usdOrBelowCent` covers only the sub-cent half:
        // an exact zero still renders "$0.00", which is right for a total and
        // wrong for a price nobody could compute. Two comments were written
        // claiming the unpriced case was handled by it; neither was.
        expect(Format.usdOrBelowCent(0) == "$0.00"
                   && Format.money(tokens: 5_200_000, cost: 0) == "—",
               "QH-MONEY the sub-cent helper still reports an exact zero as zero, "
                   + "so a token count beside it needs the tokens-aware rule instead")
        // QH-MONEY-ZERO. `usd` renders -0.0 as "$-0.00".
        expect(Format.usdOrBelowCent(-0.0) == "$0.00",
               "QH-MONEY a negative zero is still zero dollars")
        expect(QuotaHistoryCard.visibleRows <= QuotaHistoryFold.consideredCycles,
               "QH-CAP the history card's row list still fits inside the cap, which "
                + "would otherwise silently draw fewer rows than the card intends")
        // QH-CAP-LIFETIME. The cap belongs to the surfaces that pay for a scan.
        // Lifetime summaries pay nothing and answer about ALL of history, so a
        // cap applied at the fold made a window that ran out forty cycles ago
        // report that it never had.
        let qhcSummary = QuotaOverviewFold.summaries(windows: [
            (clientId: "c", accountKey: nil, cardId: "w", label: "W", cycles: qhcAll)
        ]).first
        expect(qhcSummary?.neverExhausted == false && qhcSummary?.cycleCount == 40,
               "QH-CAP-LIFETIME exhaustion older than the cap is still visible to the "
                   + "overview, and the recorded count is not truncated by it")

        // QH-SHRINK. `startMs` comes from the NEWEST point's duration, so a
        // provider that shortens its reported window moves the cycle's start
        // forward, past readings already taken. Bounding the join there dropped
        // usage from before it while `usedPercent` still counted the movement
        // those readings showed: numerator short, denominator whole.
        let qhsReset: Int64 = 1_768_900_000
        let qhsCycles = QuotaHistoryFold.cycles(points: [
            qhcPoint(qhsReset - qhcWeek, 10, reset: qhsReset, duration: qhcWeek),
            qhcPoint(qhsReset - 86_400, 30, reset: qhsReset, duration: 172_800),
        ])
        expect(
            qhsCycles.first.map { $0.evidenceStartMs < $0.startMs } == true,
            "QH-SHRINK the shortened duration puts the computed start after the first "
                + "reading, which is the condition the rest of this case needs")
        // A message inside the observed span but before the recomputed start.
        let qhsMessages = try! JSONDecoder().decode(
            [WindowMessage].self,
            from: Data("""
            [{"timestamp":\((qhsReset - 500_000) * 1000),"client":"c","providerId":"p",
              "modelId":"m","input":100,"output":0,"cacheRead":0,"cacheWrite":0,
              "reasoning":0,"cost":0.25,"isTurnStart":true}]
            """.utf8))
        let qhsRecords = [UsageAttribution.Record(
            client: "c", provider: "p", state: .assigned("c"))]
        let qhsSpans = QuotaHistoryFold.spans(
            cycles: qhsCycles, messages: qhsMessages, subscription: "c",
            modelScope: nil,
            confirmed: qhsRecords)
        expect(qhsSpans.first?.tokens == 100 && qhsSpans.first.map { abs($0.cost - 0.25) < 1e-9 } == true,
               "QH-SHRINK usage taken before the recomputed start still counts toward the "
                + "span its own readings bracket")

        // QH-SPAN. The cycle column and the span are different questions, and
        // the equivalence must use the second: a message inside the window but
        // outside the interval the two readings bracket has no quota movement
        // to be divided by.
        let qhspMessages = try! JSONDecoder().decode(
            [WindowMessage].self,
            from: Data("""
            [{"timestamp":\((qhsReset - 500_000) * 1000),"client":"c","providerId":"p",
              "modelId":"m","input":100,"output":0,"cacheRead":0,"cacheWrite":0,
              "reasoning":0,"cost":0.25,"isTurnStart":true},
             {"timestamp":\((qhsReset - 3_600) * 1000),"client":"c","providerId":"p",
              "modelId":"m","input":700,"output":0,"cacheRead":0,"cacheWrite":0,
              "reasoning":0,"cost":1.75,"isTurnStart":true}]
            """.utf8))
        let qhspRows = QuotaHistoryFold.rows(
            cycles: qhsCycles, messages: qhspMessages, subscription: "c",
            modelScope: nil,
            confirmed: qhsRecords)
        expect(qhspRows.first?.mineTokensExCacheRead == 800,
               "QH-SPAN the cycle column counts everything charged to the window")
        // AL-HIDDEN. Every exit from `baseClients` goes through one filter.
        // The rule was got wrong three times — inside `reorderable`, then above
        // only the restricted return, then above both while the opencode branch
        // exited before either — and each fix moved a line without making "no
        // hidden client leaves this function" checkable. Now it is.
        expect(AgentLimitsCard.visible(["codex", "claude"], hiddenRaw: "claude") { $0 }
                   == ["codex"],
               "AL-HIDDEN a hidden client is removed from a candidate list")
        expect(AgentLimitsCard.visible(["codex", "claude"], hiddenRaw: "") { $0 } ==
                   ["codex", "claude"],
               "AL-HIDDEN and an empty hide set removes nothing, so the check "
                   + "above is not simply emptying the list")

        // GEO-TURN. Averaging adjacent secants leaves a nonzero tangent at a
        // local extremum, and the `α²+β²>9` clamp bounds a tangent's magnitude
        // without touching its sign — so a provider correction that reverses
        // direction interpolated ABOVE the peak and drew quota levels nobody
        // observed. The sign half of the monotone condition was missing.
        let turn = WindowCardGeometry.monotoneCurve([
            .init(x: 0.0, y: 80), .init(x: 0.5, y: 90), .init(x: 1.0, y: 89),
        ])
        expect((turn.map(\.y).max() ?? 0) <= 90 + 1e-9,
               "GEO-TURN a reversal never interpolates past the peak it turns at")
        // Control: a rising run still curves, so the fix is not a straight line
        // through every series.
        let rising = WindowCardGeometry.monotoneCurve([
            .init(x: 0.0, y: 0), .init(x: 0.5, y: 40), .init(x: 1.0, y: 100),
        ])
        expect((rising.map(\.y).max() ?? 0) <= 100 + 1e-9 && rising.count > 3,
               "GEO-TURN and a monotone run is still interpolated, not flattened")

        // EQ-BOTH. The error bar was measured on the cost estimate and printed
        // beside two numbers. Cycles with stable cost per point but differently
        // priced models have unstable tokens per point, so a 1% bar could sit
        // beside a token figure the cycles disagreed about wildly.
        let eqSplit = WindowEquivalence.aggregate(cycles: [
            aeCycle(50, 1_000, 10), aeCycle(50, 20_000, 10), aeCycle(50, 100_000, 10),
        ])
        expect({ if case .spread = eqSplit { return true }; return false }(),
               "EQ-BOTH stable cost with wildly disagreeing tokens is a spread, not "
                   + "a ratio wearing the cost's error bar")

        // QH-OTHER. The other bucket mixes three attribution states, and the
        // card called all of it "other subscriptions". On a setup with no
        // declarations that is a claim about every message on the machine.
        let qhoMessages = try! JSONDecoder().decode(
            [WindowMessage].self,
            from: Data("""
            [{"timestamp":\((qhsReset - 500_000) * 1000),"client":"z","providerId":"p",
              "modelId":"m","input":700,"output":0,"cacheRead":0,"cacheWrite":0,
              "reasoning":0,"cost":1.0,"isTurnStart":true},
             {"timestamp":\((qhsReset - 400_000) * 1000),"client":"unknown","providerId":"q",
              "modelId":"m","input":300,"output":0,"cacheRead":0,"cacheWrite":0,
              "reasoning":0,"cost":0.5,"isTurnStart":true}]
            """.utf8))
        let qhoRows = QuotaHistoryFold.rows(
            cycles: qhsCycles, messages: qhoMessages, subscription: "c",
            modelScope: nil,
            confirmed: [UsageAttribution.Record(
                client: "z", provider: "p", state: .assigned("other"))])
        expect(qhoRows.first?.otherTokens == 1000,
               "QH-OTHER everything not mine still lands in one total")
        expect(qhoRows.first?.otherHasAssigned == true
                   && qhoRows.first?.otherHasUnattributed == true,
               "QH-OTHER and both states are recorded as present, so the copy can "
                   + "avoid calling unclassified usage a subscription the user "
                   + "never named")
        // Presence, not a total: a count compares one dimension over data that
        // has two. An unclassified row carrying cost and no tokens made the
        // token totals equal, and the whole bucket read as "other
        // subscriptions" while some of the spend was unclassified.
        let qhoCostOnly = try! JSONDecoder().decode(
            [WindowMessage].self,
            from: Data("""
            [{"timestamp":\((qhsReset - 500_000) * 1000),"client":"z","providerId":"p",
              "modelId":"m","input":700,"output":0,"cacheRead":0,"cacheWrite":0,
              "reasoning":0,"cost":1.0,"isTurnStart":true},
             {"timestamp":\((qhsReset - 400_000) * 1000),"client":"unknown","providerId":"q",
              "modelId":"m","input":0,"output":0,"cacheRead":0,"cacheWrite":0,
              "reasoning":0,"cost":0.5,"isTurnStart":true}]
            """.utf8))
        let qhoCostRows = QuotaHistoryFold.rows(
            cycles: qhsCycles, messages: qhoCostOnly, subscription: "c",
            modelScope: nil,
            confirmed: [UsageAttribution.Record(
                client: "z", provider: "p", state: .assigned("other"))])
        // QH-SCOPE. The chart, these history rows and the equivalence spans are
        // three surfaces of ONE quota. Narrowing only the chart made them
        // disagree about the same window — corrected bars above, uncorrected
        // "past windows" underneath, counting Sonnet against a Fable
        // allowance. The rule lives in the fold so it cannot be applied at two
        // of the three.
        let qhsScopeMessages = try! JSONDecoder().decode(
            [WindowMessage].self,
            from: Data("""
            [{"timestamp":\((qhsReset - 500_000) * 1000),"client":"c","providerId":"anthropic",
              "modelId":"claude-fable-5","input":700,"output":0,"cacheRead":0,"cacheWrite":0,
              "reasoning":0,"cost":1.0,"isTurnStart":true},
             {"timestamp":\((qhsReset - 400_000) * 1000),"client":"c","providerId":"anthropic",
              "modelId":"claude-sonnet-4-5","input":300,"output":0,"cacheRead":0,"cacheWrite":0,
              "reasoning":0,"cost":0.5,"isTurnStart":true}]
            """.utf8))
        let qhsDeclared = [UsageAttribution.Record(
            client: "c", provider: "anthropic", state: .assigned("c"))]
        let qhsUnscopedRows = QuotaHistoryFold.rows(
            cycles: qhsCycles, messages: qhsScopeMessages, subscription: "c",
            modelScope: nil,
            confirmed: qhsDeclared)
        let qhsScopedRows = QuotaHistoryFold.rows(
            cycles: qhsCycles, messages: qhsScopeMessages, subscription: "c",
            modelScope: "fable", confirmed: qhsDeclared)
        expect(qhsUnscopedRows.first?.mineTokens == 1000,
               "QH-SCOPE without a scope the history counts every model, so the "
                   + "scoped case below is a narrowing rather than an empty fixture")
        expect(qhsScopedRows.first?.mineTokens == 700,
               "QH-SCOPE a scoped window's history counts only the model its "
                   + "allowance charges")
        let qhsUnscopedSpans = QuotaHistoryFold.spans(
            cycles: qhsCycles, messages: qhsScopeMessages, subscription: "c",
            modelScope: nil,
            confirmed: qhsDeclared)
        let qhsScopedSpans = QuotaHistoryFold.spans(
            cycles: qhsCycles, messages: qhsScopeMessages, subscription: "c",
            modelScope: "fable", confirmed: qhsDeclared)
        expect(qhsUnscopedSpans.first?.tokens == 1000
                   && qhsScopedSpans.first?.tokens == 700,
               "QH-SCOPE and the equivalence denominator narrows with it — counting "
                   + "a model the allowance does not charge understates what the "
                   + "quota costs")

        expect(qhoCostRows.first?.otherHasUnattributed == true,
               "QH-OTHER an unclassified contribution that arrives as cost with no "
                   + "tokens is still unclassified — the label cannot be decided by "
                   + "comparing token totals")

        // QH-EXCL. `.excluded` is a decision the user made, `.unassigned` is one
        // they have not. Folding both into one flag made the card report the
        // user's own exclusion back to them as "Unclassified usage" — an
        // outstanding question they had already answered.
        let qhxRows = QuotaHistoryFold.rows(
            cycles: qhsCycles, messages: qhoMessages, subscription: "c",
            modelScope: nil,
            confirmed: [
                UsageAttribution.Record(
                    client: "z", provider: "p", state: .assigned("other")),
                UsageAttribution.Record(
                    client: "unknown", provider: "q", state: .excluded),
            ])
        expect(qhxRows.first?.otherHasExcluded == true
                   && qhxRows.first?.otherHasUnattributed == false,
               "QH-EXCL an excluded source is recorded as excluded and NOT as "
                   + "unclassified, so the card does not call a decision an "
                   + "open question")
        // Both halves, or the flag is satisfied by never setting the other one.
        expect(qhoRows.first?.otherHasExcluded == false
                   && qhoRows.first?.otherHasUnattributed == true,
               "QH-EXCL and an undeclared source is still unclassified, so the "
                   + "split is a split rather than a rename")
        // Excluded spend stays IN the bucket: the line answers what else was
        // happening in these hours, and an excluded source was happening.
        expect(qhxRows.first?.otherTokens == qhoRows.first?.otherTokens,
               "QH-EXCL excluding a source changes what it is called, not "
                   + "whether it counts")

        // FMT-TOKENS. The mirror of the money rule. A supported cost-only
        // source reports a price with no token counts, so the count column
        // printed "0" for usage that certainly happened — beside an amount
        // that had already learned to say "—" in the opposite case.
        expect(Format.tokens(tokens: 0, cost: 4.10) == "—"
                   && Format.tokens(tokens: 0, cost: 0) == "0"
                   && Format.tokens(tokens: 2_100_000, cost: 0) == "2.1M",
               "FMT-TOKENS an unmeasured count is a dash, a real zero is a zero, "
                   + "and a measured count is itself")

        expect(qhspRows.first?.spanTokens == 100,
               "QH-SPAN the span counts only what the two readings bracket — the later "
                + "message sits after the last sample, so no observed movement measures it")

        // QH-CACHE. The span is the equivalence's DENOMINATOR and `spanCost` is
        // its numerator, and the numerator is `message.cost` — the message's
        // whole priced cost, cache reads included, which cannot be decomposed
        // here because `WindowMessage` carries one cost and not one per token
        // class. A denominator that excluded cache reads therefore priced one
        // set of tokens and counted another, inflating the implied per-token
        // rate by the cache-read share. On a Claude Code workload that share is
        // most of the volume, which is how "10% of quota ~ 4.8M · $172" reached
        // $36 per million (issue #237).
        //
        // Only V15 above carried a non-zero cache read before this, and it
        // asserted the OLD basis — an expectation copied from behaviour rather
        // than chosen, which is how a defect gets pinned by its own suite. The
        // rest of this file sets `cacheRead: 0` and could not tell the two
        // bases apart at all.
        let qhCacheMessages = try! JSONDecoder().decode(
            [WindowMessage].self,
            from: Data("""
            [{"timestamp":\((qhsReset - 500_000) * 1000),"client":"c","providerId":"p",
              "modelId":"m","input":100,"output":0,"cacheRead":900,"cacheWrite":0,
              "reasoning":0,"cost":0.25,"isTurnStart":true}]
            """.utf8))
        let qhCacheSpans = QuotaHistoryFold.spans(
            cycles: qhsCycles, messages: qhCacheMessages, subscription: "c",
            modelScope: nil, confirmed: qhsRecords)
        expect(qhCacheSpans.first?.tokens == 1000,
               "QH-CACHE the equivalence denominator counts cache reads, because the "
                   + "cost beside it does and the two are printed as one ratio")
        expect(qhCacheSpans.first?.cost == 0.25,
               "QH-CACHE and the cost is the message's whole cost, unchanged — the "
                   + "fix moves the denominator to meet it, not the other way round")
        // The bars keep the OTHER basis, deliberately, and this is the pair that
        // says so: same message, two figures, cache reads in one and not the
        // other. Folding them onto one basis would either decouple the bars from
        // the quota line or break the ratio again.
        let qhCacheRows = QuotaHistoryFold.rows(
            cycles: qhsCycles, messages: qhCacheMessages, subscription: "c",
            modelScope: nil, confirmed: qhsRecords)
        expect(qhCacheRows.first?.mineTokensExCacheRead == 100
                   && qhCacheRows.first?.mineTokens == 1000,
               "QH-CACHE the bars' basis still excludes cache reads while the total "
                   + "includes them, so the two questions keep their two answers")

        // QH-CACHE-LIVE. The SECOND path that computes this ratio, and the one
        // the first fix missed. `WindowUsageCard.equivalenceRow` calls
        // `WindowEquivalence.row` directly instead of going through the fold,
        // and `QuotaView` renders that card immediately above the history —
        // so a basis fixed in one place and not the other put the inflated
        // price and the corrected price on screen together.
        //
        // Both now read `WindowEquivalence.ratioTokens`, and this asserts the
        // live path specifically rather than trusting that they share a helper.
        let qhLiveSamples = [
            QuotaSample(atMs: 1_000_000, usedPercent: 10),
            QuotaSample(atMs: 2_000_000, usedPercent: 20),
        ]
        let qhLiveMessages = try! JSONDecoder().decode(
            [WindowMessage].self,
            from: Data("""
            [{"timestamp":1500000,"client":"c","providerId":"p",
              "modelId":"m","input":100,"output":0,"cacheRead":900,"cacheWrite":0,
              "reasoning":0,"cost":2.0,"isTurnStart":true}]
            """.utf8))
        // delta = 10 points, so per-tenth = tokens / 10 * 10 = the raw total.
        if case let .ratio(tokensPerTenth, costPerTenth, _) =
            WindowEquivalence.row(samples: qhLiveSamples, messages: qhLiveMessages)
        {
            expect(tokensPerTenth == 1000,
                   "QH-CACHE-LIVE the live window's denominator counts cache reads too, "
                       + "so the card above the history no longer contradicts it")
            expect(costPerTenth == 2.0,
                   "QH-CACHE-LIVE and its numerator is the whole message cost, "
                       + "unchanged — the same pairing as the pooled path")
        } else {
            expect(false, "QH-CACHE-LIVE the live fixture produces a ratio row")
        }

        // QH-DIST. A reset inside a group makes the two old denominators
        // disagree with each other and with the truth: the readings return to
        // zero, so the displacement collapses while the range saturates at the
        // highest reading. Both call sites now measure the distance travelled.
        //
        // Worked from the group behind a card that read 4.2B per 10% where the
        // volume implied 0.35B: first 0%, last 8%, peak 85%, 93 points actually
        // consumed. Dividing by 8 rather than 93 is the whole 11.6x.
        let distResetReadings: [Double] = [0, 40, 85, 0, 3, 8]
        expect(abs(QuotaHistoryFold.consumed(distResetReadings) - 93) < 1e-9,
               "QH-DIST a run crossing one reset consumed 93, not the 8 it ended on "
                   + "nor the 85 it reached")
        let distSamples = distResetReadings.enumerated().map {
            QuotaSample(atMs: Int64($0.offset + 1) * 1_000_000, usedPercent: $0.element)
        }
        let distMessages = try! JSONDecoder().decode(
            [WindowMessage].self,
            from: Data("""
            [{"timestamp":1500000,"client":"c","providerId":"p",
              "modelId":"m","input":930,"output":0,"cacheRead":0,"cacheWrite":0,
              "reasoning":0,"cost":9.3,"isTurnStart":true}]
            """.utf8))
        // 930 tokens over 93 points is 10 per point, so per-tenth is 100. The
        // same fixture under the old displacement of 8 divides by 11.6x less
        // and reports 11.6x more, which is the defect's whole size.
        if case let .ratio(distTokens, _, distError) =
            WindowEquivalence.row(samples: distSamples, messages: distMessages)
        {
            expect(distTokens == 100,
                   "QH-DIST the live path divides by the distance travelled, so the "
                       + "numerator's two windows meet a denominator that counted both")
            expect(distError == 1,
                   "QH-DIST and the quoted error follows the same denominator — "
                       + "two rises at 0.5 each over 93, not the 6% that 0.5/8 printed")
        } else {
            expect(false, "QH-DIST the crossing fixture still produces a ratio row")
        }

        // QH-RUNS. Each rise `consumed` sums was quantised on its own, so a
        // group that crossed a reset carries the uncertainty of every rise, not
        // of one. [0,3,0,3] is two 3-point rises: 6 consumed, but neither rise
        // clears the single-rise bar and their summed error is ±1 on 6, about
        // 17% — over tolerance. It must come back insufficient, not as a ratio
        // quoted at ±8%.
        expect(QuotaHistoryFold.risingRuns([0, 3, 0, 3]) == 2,
               "QH-RUNS one decline separates two rises")
        expect(QuotaHistoryFold.risingRuns([1, 12, 30]) == 1
                   && QuotaHistoryFold.risingRuns([7]) == 0
                   && QuotaHistoryFold.risingRuns([]) == 0,
               "QH-RUNS a monotonic run is one rise; a lone reading has none; nothing is none")
        let runsSamples = [0.0, 3, 0, 3].enumerated().map {
            QuotaSample(atMs: Int64($0.offset + 1) * 1_000_000, usedPercent: $0.element)
        }
        let runsMessages = try! JSONDecoder().decode(
            [WindowMessage].self,
            from: Data("""
            [{"timestamp":1500000,"client":"c","providerId":"p",
              "modelId":"m","input":60,"output":0,"cacheRead":0,"cacheWrite":0,
              "reasoning":0,"cost":0.6,"isTurnStart":true}]
            """.utf8))
        if case let .insufficient(runsDelta, runsError) =
            WindowEquivalence.row(samples: runsSamples, messages: runsMessages)
        {
            expect(abs(runsDelta - 6) < 1e-9,
                   "QH-RUNS the consumption is still the full 6 — the gate scales, the sum does not")
            expect(runsError == 17,
                   "QH-RUNS and the error is 0.5 × 2 rises over 6, not 0.5 over 6")
        } else {
            expect(false, "QH-RUNS two sub-threshold rises must not be admitted as one measurement")
        }

        // QH-RUNS-A1. The run count under one rule: a positive delta starts a
        // run iff no earlier delta was positive or the most recent non-zero
        // delta was negative; zero deltas are transparent. The first cut
        // counted declines and charged [0,9,0]'s trailing decline as a rise.
        for (readings, want) in [([0.0, 9, 0], 1), ([0, 3, 0, 3], 2), ([0, 5, 5, 9], 1),
                                 ([0, 9, 8, 9], 2), ([1, 12, 30, 55], 1), ([7], 0),
                                 ([], 0), ([5, 5, 5], 0)] as [([Double], Int)] {
            expect(QuotaHistoryFold.risingRuns(readings) == want,
                   "QH-RUNS-A1 risingRuns(\(readings)) == \(want)")
        }
        // QH-RUNS-A2. The one statement of the admission rule. `delta > 0`
        // is what keeps `runs == 0` from turning the threshold into zero.
        expect(!WindowEquivalence.deltaQualifies(6, runs: 2)
                   && WindowEquivalence.deltaQualifies(9, runs: 1)
                   && !WindowEquivalence.deltaQualifies(0, runs: 0)
                   && WindowEquivalence.deltaQualifies(93, runs: 2)
                   && !WindowEquivalence.deltaQualifies(4.9, runs: 1),
               "QH-RUNS-A2 deltaQualifies clears the bar once per rise and never at zero")
        // QH-RUNS-A3. A trailing decline is not a rise: [0,9,0] is one
        // 9-point measurement, admitted at threshold 5 with error 0.5/9.
        let trailSamples = [0.0, 9, 0].enumerated().map {
            QuotaSample(atMs: Int64($0.offset + 1) * 1_000_000, usedPercent: $0.element)
        }
        let trailMessages = try! JSONDecoder().decode(
            [WindowMessage].self,
            from: Data("""
            [{"timestamp":1500000,"client":"c","providerId":"p",
              "modelId":"m","input":90,"output":0,"cacheRead":0,"cacheWrite":0,
              "reasoning":0,"cost":0.9,"isTurnStart":true}]
            """.utf8))
        if case let .ratio(trailTokens, _, trailError) =
            WindowEquivalence.row(samples: trailSamples, messages: trailMessages)
        {
            expect(trailTokens == 100, "QH-RUNS-A3 90 tokens over one 9-point rise is 100 per tenth")
            expect(trailError == 6, "QH-RUNS-A3 and its error is 0.5 over 9, one rise not two")
        } else {
            expect(false, "QH-RUNS-A3 a single rise followed by a decline is still admitted")
        }
        // QH-RUNS-A4. The same rule at the pooled site. A merged [0,3,0,3]
        // cycle carries delta 6 over 2 rises; beside two clean qualifying
        // cycles it must NOT be admitted, so the pool sees two, not three.
        let mergedCycle = QuotaHistoryFold.cycles(points: [0.0, 3, 0, 3].enumerated().map {
            heatPoint(1_767_600_000 + Int64($0.offset) * 3_600, $0.element, reset: monReset)
        }).first!
        expect(abs(mergedCycle.usedPercent - 6) < 1e-9 && mergedCycle.risingRuns == 2,
               "QH-RUNS-A4 the merged cycle carries both its consumption and its run count")
        let poolRow = WindowEquivalence.aggregate(cycles: [
            WindowEquivalence.Cycle(deltaPercent: 50, spanTokens: 5_000, spanCost: 5,
                                    observedFraction: 1, risingRuns: 1),
            WindowEquivalence.Cycle(deltaPercent: 40, spanTokens: 4_000, spanCost: 4,
                                    observedFraction: 1, risingRuns: 1),
            WindowEquivalence.Cycle(deltaPercent: mergedCycle.usedPercent, spanTokens: 600,
                                    spanCost: 0.6, observedFraction: 1,
                                    risingRuns: mergedCycle.risingRuns),
        ])
        if case let .tooFewCycles(poolCount, poolNeeded) = poolRow {
            expect(poolCount == 2 && poolNeeded == 3,
                   "QH-RUNS-A4 the pool admits the two clean cycles and rejects the merged one")
        } else {
            expect(false, "QH-RUNS-A4 the merged cycle must not make a third admitted cycle")
        }
        // QH-RUNS-A9. The insufficient row's error sums half-steps over every
        // rise in every cycle offered — not over admitted cycles, which are
        // empty by construction in that branch, and not per cycle.
        if case let .insufficient(insDelta, insError) = WindowEquivalence.aggregate(cycles: [
            WindowEquivalence.Cycle(deltaPercent: 2, spanTokens: 100, spanCost: 0.1,
                                    observedFraction: 1, risingRuns: 1),
            WindowEquivalence.Cycle(deltaPercent: 3, spanTokens: 100, spanCost: 0.1,
                                    observedFraction: 1, risingRuns: 2),
        ]) {
            expect(abs(insDelta - 5) < 1e-9 && insError == 30,
                   "QH-RUNS-A9 three rises at 0.5 over 5 points is 30%, not 20% per-cycle nor 0% over admitted")
        } else {
            expect(false, "QH-RUNS-A9 two sub-threshold cycles produce the insufficient row")
        }
        // The pooled site, same readings, same answer.
        let distCycles = QuotaHistoryFold.cycles(points: distResetReadings.enumerated().map {
            heatPoint(1_767_600_000 + Int64($0.offset) * 3_600, $0.element, reset: monReset)
        })
        expect(distCycles.first.map { abs($0.usedPercent - 93) < 1e-9 } == true,
               "QH-DIST the pooled site agrees with the live one, which is the point "
                   + "of stating the rule once")
        expect(distCycles.first.map { abs($0.peakUsedPercent - 85) < 1e-9 } == true,
               "QH-DIST and the peak is untouched — still the highest reading")
        // Two resets accumulate rather than saturating. Asserting past 100 is
        // the deliberate outcome: a group holding three windows consumed three
        // windows' worth of one allowance.
        expect(abs(QuotaHistoryFold.consumed([0, 60, 99, 0, 50, 99, 0, 20]) - 218) < 1e-9,
               "QH-DIST consumption accumulates across every reset in the group and "
                   + "may exceed 100, where the range would have saturated at 99")
        // The no-op that guards the regression. Compared against the old
        // expressions computed here rather than against literals, so what is
        // asserted is the equality itself.
        let distRising: [Double] = [1, 12, 30, 55, 88, 99]
        expect(abs(QuotaHistoryFold.consumed(distRising)
                   - ((distRising.max() ?? 0) - (distRising.min() ?? 0))) < 1e-9,
               "QH-DIST on readings that only rise the distance equals the old range")
        expect(abs(QuotaHistoryFold.consumed(distRising)
                   - ((distRising.last ?? 0) - (distRising.first ?? 0))) < 1e-9,
               "QH-DIST and equals the old displacement, so every clean cycle is "
                   + "left exactly where it was")

        // QH-B. Exhaustion is an absolute reading, not the observed span. A
        // cycle first seen at 40% and last at 100% consumed 60 points as far as
        // this machine can tell, and reached the ceiling; deriving the ceiling
        // from the span called it a quiet window.
        let qhbCycles = QuotaHistoryFold.cycles(points: [
            heatPoint(1_767_605_400, 40, reset: monReset),
            heatPoint(1_767_612_600, 100, reset: monReset),
        ])
        expect(qhbCycles.first.map { abs($0.usedPercent - 60) < 1e-9 } == true,
               "QH-B consumption is still the span this machine witnessed")
        expect(qhbCycles.first.map { abs($0.peakUsedPercent - 100) < 1e-9 } == true,
               "QH-B and the peak is the absolute reading, so the ceiling is knowable")
        expect(
            QuotaOverviewFold.summaries(windows: [
                (clientId: "c", accountKey: nil, cardId: "w", label: "W", cycles: qhbCycles)
            ]).first?.neverExhausted == false,
            "QH-B a cycle that reached 100% is not reported as never having run out")

        // QM6. "Days observed" counts LOCAL days, like the cells it describes.
        // Two readings four hours apart on one Taipei morning straddle UTC
        // midnight, so counting UTC dates reports two days of evidence where
        // the grid drew one.
        let taipei = TimeZone(identifier: "Asia/Taipei")!
        let straddling = QuotaHeatmapFold.build(
            points: [heatPoint(1_767_564_000, 2, reset: monReset),
                     heatPoint(1_767_578_400, 5, reset: monReset)],
            timeZone: taipei)
        expect(straddling.observedDays == 1,
               "QM6 one local morning is one observed day, whichever side of UTC midnight it falls")
        expect(straddling.total > 0,
               "QM6 and the fixture does place its consumption, so the count above is not of nothing")

        // QM4. Sunday is the last row, not the first: weekday 0 is Monday.
        let sunday = QuotaHeatmapFold.build(
            points: [heatPoint(1_768_140_000, 5, reset: sunReset),
                     heatPoint(1_768_143_600, 8, reset: sunReset)],
            timeZone: utc)
        expect(abs(sunday.cells[6][14] - 3) < 1e-9,
               "QM4 a Sunday reading lands on the last row, so the weekend stays a block")

        // QM5. A reading that goes backwards inside one cycle is a refill or a
        // provider correction, not negative consumption.
        let refill = QuotaHeatmapFold.build(
            points: [heatPoint(1_767_605_400, 30, reset: monReset),
                     heatPoint(1_767_612_600, 12, reset: monReset)],
            timeZone: utc)
        expect(refill.total == 0 && refill.unplacedPercent == 0,
               "QM5 a backwards reading contributes nothing rather than a negative slot")

        // MARK: quota history (QH)

        func curvePoint(_ sampledAt: Int64, _ used: Double, resetAt: Int64,
                        duration: Int64 = 18_000) -> QuotaCurvePoint {
            try! JSONDecoder().decode(QuotaCurvePoint.self, from: Data("""
            {"sampledAt":\(sampledAt),"usedPercent":\(used),"resetAt":\(resetAt),
             "durationSeconds":\(duration),"durationSource":"provider","origin":"liveV3",
             "isActiveGroup":false}
            """.utf8))
        }
        func attributedMessage(at t: Int64, client: String, provider: String,
                               model: String, tokens: Int64, cost: Double) -> WindowMessage {
            try! JSONDecoder().decode(WindowMessage.self, from: Data("""
            {"timestamp":\(t),"client":"\(client)","providerId":"\(provider)",
             "modelId":"\(model)","input":\(tokens),"output":0,"cacheRead":0,
             "cacheWrite":0,"reasoning":0,"cost":\(cost),"isTurnStart":true}
            """.utf8))
        }

        // Two cycles. The older one is first observed at 40% used, which is the
        // case the span rule exists for: the app was not running when it began.
        let qhCycles = QuotaHistoryFold.cycles(points: [
            curvePoint(100_000, 40, resetAt: 118_000),
            curvePoint(110_000, 55, resetAt: 118_000),
            curvePoint(120_000, 1, resetAt: 136_000),
            curvePoint(130_000, 12, resetAt: 136_000),
        ])
        expect(qhCycles.count == 2, "QH1 points group into one cycle per reset instant")
        expect(qhCycles[0].resetAtMs == 136_000_000,
               "QH1 cycles come back newest first, so the list reads like history")
        expect(qhCycles[1].usedPercent == 15,
               "QH2 a cycle consumed the SPAN of its readings, not its highest reading")
        expect(qhCycles[1].startMs == (118_000 - 18_000) * 1000,
               "QH2 the window starts one duration before its reset")
        expect(
            abs(qhCycles[1].observedFraction - (10_000.0 / 18_000.0)) < 0.001,
            "QH3 observed fraction is sample span over window length, not sample count")

        // Attribution: `codex` is declared to the codex subscription, `claude`
        // to claude. A message the user has not classified must not silently
        // become this subscription's.
        let qhConfirmed = [
            UsageAttribution.Record(client: "claude", provider: "anthropic",
                                    state: .assigned("claude")),
            UsageAttribution.Record(client: "codex", provider: "openai",
                                    state: .assigned("codex")),
        ]
        // Boundaries: 100_000_000 is the older cycle's start, 118_000_000 its
        // reset and simultaneously nothing else's start. One message sits on
        // each, and neither may be counted twice.
        let qhRows = QuotaHistoryFold.rows(
            cycles: qhCycles,
            messages: [
                attributedMessage(at: 100_000_000, client: "claude", provider: "anthropic",
                                  model: "opus", tokens: 10, cost: 1),
                attributedMessage(at: 110_000_000, client: "codex", provider: "openai",
                                  model: "sol", tokens: 500, cost: 90),
                attributedMessage(at: 118_000_000, client: "claude", provider: "anthropic",
                                  model: "opus", tokens: 7, cost: 2),
                attributedMessage(at: 125_000_000, client: "unknown", provider: "nowhere",
                                  model: "x", tokens: 3, cost: 5),
            ],
            subscription: "claude", modelScope: nil, confirmed: qhConfirmed)

        let older = qhRows[1]
        expect(older.mineTokens == 10 && older.mineCost == 1,
               "QH4 a message exactly on the window start belongs to that window")
        expect(older.otherTokens == 500 && older.otherCost == 90,
               "QH4 usage charged elsewhere is kept, because it explains a flat quota bar")
        expect(qhRows[0].otherTokens == 3,
               "QH5 unclassified usage counts as other, never as this subscription's")
        expect(qhRows[0].mineTokens == 7,
               "QH5 a message exactly on a reset joins the cycle that reset OPENS")
        expect(qhRows.reduce(0) { $0 + $1.mineTokens + $1.otherTokens } == 520,
               "QH6 every message lands in exactly one cycle, so nothing double counts")
        expect(older.models.map(\.modelId) == ["opus"]
                   && older.models.map(\.providerId) == ["anthropic"],
               "QH7 the model breakdown covers this subscription only, provider included")

        expect(QuotaHistoryFold.lowerBound([10, 20, 20, 30], 20) == 1,
               "QH8 lower bound finds the FIRST equal element, not any of them")
        expect(QuotaHistoryFold.lowerBound([10, 20], 99) == 2,
               "QH8 a value past the end returns the count rather than trapping")

        // MARK: cross-subscription summary (QS)

        func summaryPayload(
            _ agents: [(client: String, windows: [(card: String, label: String, left: Double)])],
            errorOn: String? = nil
        ) -> AgentUsagePayload {
            let body = agents.map { agent in
                let windows = agent.windows.map { w in
                    """
                    {"cardId":"\(w.card)","label":"\(w.label)",
                     "usedPercent":\(100 - w.left),"remainingPercent":\(w.left),
                     "paceStatus":{"state":"learningDuration","windowKey":"\(w.card)","completeCycles":0}}
                    """
                }.joined(separator: ",")
                let err = agent.client == errorOn ? #""error":"boom","# : ""
                return """
                {"clientId":"\(agent.client)","source":"oauth","updatedAt":"t",
                 \(err)"windows":[\(windows)]}
                """
            }.joined(separator: ",")
            return try! JSONDecoder().decode(
                AgentUsagePayload.self,
                from: Data("""
                {"generatedAt":"t","publicationGeneration":1,"agents":[\(body)]}
                """.utf8))
        }

        let qsPayload = summaryPayload([
            (client: "claude", windows: [(card: "session.v1", label: "Session", left: 18),
                                         (card: "weekly.v1", label: "Weekly", left: 61)]),
            // Same LABEL as claude's second window, different client. Counting
            // by label instead of by (client, cardId) would lose one of them.
            (client: "codex", windows: [(card: "main.weekly.v1", label: "Weekly", left: 74)]),
            (client: "grok", windows: [(card: "billing.v1", label: "Weekly", left: 88)]),
        ])
        let qs = QuotaSummaryFold.build(payload: qsPayload)
        expect(qs?.tightestClient == "claude" && qs?.remainingPercent == 18,
               "QS1 the tightest window is the lowest remaining across every subscription")
        expect(qs?.otherWindows == 3,
               "QS2 the tightest is not also counted among the others")
        expect(qs?.othersComfortable == 3 && qs?.allOthersComfortable == true,
               "QS2 three windows at 61, 74 and 88 all clear the comfortable line")

        // Hiding the tightest client must move the headline, not merely drop a
        // row: a summary that keeps naming a hidden subscription is reporting
        // something the user asked not to see.
        let qsHidden = QuotaSummaryFold.build(payload: qsPayload, excluding: ["claude"])
        expect(qsHidden?.tightestClient == "codex" && qsHidden?.otherWindows == 1,
               "QS3 excluding a client removes both its headline and its windows")

        // An agent that reported an error is not evidence about anything.
        let qsErrored = QuotaSummaryFold.build(
            payload: summaryPayload([
                (client: "claude", windows: [(card: "s", label: "Session", left: 5)]),
                (client: "codex", windows: [(card: "w", label: "Weekly", left: 70)]),
            ], errorOn: "claude"))
        expect(qsErrored?.tightestClient == "codex",
               "QS4 a client that failed to report is skipped, not treated as tightest")
        // `QuotaResolver` already skips errored agents when picking the
        // tightest, so the line above passes with or without this fold's own
        // filter. Only the tally reaches it: codex's window is the headline, so
        // a correct fold has NO others, while counting the errored client's 5%
        // window would report one — and would put a number on screen sourced
        // from a subscription that just told us it could not answer.
        expect(qsErrored?.otherWindows == 0,
               "QS4 an errored client's windows are absent from the tally too")

        expect(QuotaSummaryFold.build(payload: nil) == nil,
               "QS5 no payload yields no summary, so the view can say it is still asking")

        // A rate-limited endpoint sets `error` on an agent that still carries
        // its last-good windows. `select` must refuse it — showing a stale
        // window as the one running now is uncorrectable — while the history
        // must not, because those cycles are on disk and a failed fetch does
        // not unwrite them. Reported once as "no earlier windows recorded" for
        // a subscription holding weeks of them.
        let ratedLimited = summaryPayload([
            (client: "claude", windows: [(card: "session.v1", label: "Session", left: 71)]),
        ], errorOn: "claude")
        expect(
            WindowCardLoader.select(payload: ratedLimited, clientId: "claude") == nil,
            "QS8 a client whose fetch failed cannot supply the CURRENT window")
        expect(
            WindowCardLoader.pickForHistory(
                payload: ratedLimited, clientId: "claude")?.window.cardId == "session.v1",
            "QS8 but it can still identify which window the recorded history belongs to")

        // Burn warning. Linear mode so the expectation is arithmetic rather
        // than a fitted history: a window exactly half elapsed expects 50% used.
        let burnNow = Date()
        func burnPayload(
            _ agents: [(client: String, used: Double, elapsedFraction: Double)]
        ) -> AgentUsagePayload {
            let duration: Int64 = 18_000
            let body = agents.map { agent in
                let reset = burnNow.addingTimeInterval(
                    Double(duration) * (1 - agent.elapsedFraction))
                let iso = ISO8601DateFormatter().string(from: reset)
                return """
                {"clientId":"\(agent.client)","source":"oauth","updatedAt":"t","windows":[
                 {"cardId":"w","label":"Session","usedPercent":\(agent.used),
                  "remainingPercent":\(100 - agent.used),"resetsAt":"\(iso)",
                  "durationSeconds":\(duration),"windowMinutes":\(duration / 60),
                  "paceStatus":{"state":"learningHistory","windowKey":"session.v1",
                                "durationSeconds":\(duration),"durationSource":"provider",
                                "completeCycles":1}}]}
                """
            }.joined(separator: ",")
            return try! JSONDecoder().decode(
                AgentUsagePayload.self,
                from: Data("""
                {"generatedAt":"t","publicationGeneration":1,"agents":[\(body)]}
                """.utf8))
        }

        // codex is 30 points past its line, claude only 10. The larger deficit
        // wins even though claude has less left in absolute terms — which is
        // the whole reason this line exists next to "tightest".
        let burn = QuotaSummaryFold.build(
            payload: burnPayload([
                (client: "claude", used: 60, elapsedFraction: 0.5),
                (client: "codex", used: 80, elapsedFraction: 0.5),
            ]),
            paceMode: .linear, now: burnNow)
        expect(burn?.tightestClient == "codex",
               "QS6 control: codex has less remaining, so it is also the tightest here")
        expect(burn?.burning?.clientId == "codex",
               "QS6 the largest deficit wins, and the tightest window is not skipped")
        expect((burn?.burning?.aheadPercent).map { abs($0 - 30) < 0.5 } == true,
               "QS6 ahead-of-pace is actual minus expected, not actual alone")

        // Under the line is not a warning.
        expect(
            QuotaSummaryFold.build(
                payload: burnPayload([(client: "claude", used: 20, elapsedFraction: 0.5)]),
                paceMode: .linear, now: burnNow)?.burning == nil,
            "QS7 a window running under its schedule produces no burn warning")

        // Pace off means the card hides its marker, so the summary must not
        // keep naming a fastest burner beside it. Shipped wrong once: the call
        // site omitted `paceMode` and took the fold's default, projecting
        // Historically whatever the user had chosen.
        expect(
            QuotaSummaryFold.build(
                payload: burnPayload([(client: "codex", used: 80, elapsedFraction: 0.5)]),
                paceMode: .off, now: burnNow)?.burning == nil,
            "QS9 pace turned off suppresses the burn line, matching the card")
        expect(
            QuotaSummaryFold.build(
                payload: burnPayload([(client: "codex", used: 80, elapsedFraction: 0.5)]),
                paceMode: .off, now: burnNow)?.tightestClient == "codex",
            "QS9 and the tightest line survives, because it is not a projection")
        // QS10. `burning == nil` alone cannot carry the reassurance the view
        // prints beside it. With pace off nothing was measured, so "every
        // window is running under its expected pace" would be a guarantee
        // nobody evaluated; the count is what lets the view tell the two apart.
        expect(
            QuotaSummaryFold.build(
                payload: burnPayload([(client: "codex", used: 80, elapsedFraction: 0.5)]),
                paceMode: .off, now: burnNow)?.paceCheckedWindows == 0,
            "QS10 pace off checks no window, so the reassurance has nothing behind it")
        expect(
            (QuotaSummaryFold.build(
                payload: burnPayload([(client: "codex", used: 80, elapsedFraction: 0.5)]),
                paceMode: .linear, now: burnNow)?.paceCheckedWindows ?? 0) > 0,
            "QS10 and a live mode does check, so the count is not always zero")

        // The burn line correctly never fires on this machine's live data —
        // measured, every window runs under its expected line. That makes
        // "works" and "broken" the same picture for anyone looking at the app,
        // so it has to be observable somewhere. `--demo` is that somewhere:
        // the shipped fixture carries a session window at 72% used against a
        // historical expectation of 35%. If this check ever fails, demo mode
        // has stopped being able to show the feature at all.
        let demoBurn = QuotaSummaryFold.build(
            payload: DemoData.agentUsage, paceMode: .historical)
        expect(demoBurn?.burning != nil,
               "QS10 the demo payload fires the burn line, so the feature is observable")
        expect((demoBurn?.burning?.aheadPercent).map { abs($0 - 37) < 0.5 } == true,
               "QS10 and it reports +37 ahead, the fixture's actual 72 minus 35")

        // MARK: recorded-cycle strips (QO)

        func qoCycle(_ resetAt: Int64, _ used: Double) -> QuotaCycle {
            QuotaCycle(
                resetAtMs: resetAt * 1000, startMs: (resetAt - 18_000) * 1000,
                usedPercent: used, sampleCount: 40, observedFraction: 0.9)
        }
        // `QuotaHistoryFold.cycles` hands back newest first; a strip is read in
        // time order, so the fold has to reverse it. 30 is the newest here.
        let qoSummaries = QuotaOverviewFold.summaries(windows: [
            (clientId: "claude", accountKey: nil, cardId: "session.v1", label: "Session",
             cycles: [qoCycle(500, 30), qoCycle(400, 58), qoCycle(300, 10)]),
            (clientId: "grok", accountKey: nil, cardId: "billing.v1", label: "Weekly",
             cycles: [qoCycle(500, 99)]),
            (clientId: "copilot", accountKey: nil, cardId: "chat.v1", label: "Chat", cycles: []),
        ])

        expect(qoSummaries.map(\.clientId) == ["grok", "claude"],
               "QO1 windows with no recorded cycle are omitted, and the heaviest leads")
        expect(qoSummaries.last?.recent == [10, 58, 30],
               "QO2 the strip runs oldest to newest, reversing the fold's order")
        expect(qoSummaries.last?.peakPercent == 58 && qoSummaries.last?.neverExhausted == true,
               "QO3 a peak below the ceiling is reported as never having run out")
        expect(qoSummaries.first?.neverExhausted == false,
               "QO3 and 99 counts as exhausted, because providers stop updating once spent")
        expect(qoSummaries.last?.cycleCount == 3,
               "QO4 the count is every recorded cycle, not just the ones on the strip")

        // The strip is capped, the peak is not. With more cycles than the strip
        // holds and the heaviest one falling off its old end, a peak taken from
        // the drawn bars alone would understate — and "never ran out" is
        // derived from that peak, so understating it turns into a false
        // reassurance. The fixture above cannot reach this: three cycles all
        // fit, so the two readings coincide.
        let qoLong = QuotaOverviewFold.summaries(windows: [(
            clientId: "claude", accountKey: nil, cardId: "session.v1", label: "Session",
            // Newest first, so the 99 is the OLDEST of twenty and falls off a
            // sixteen-bar strip.
            cycles: (0..<19).map { qoCycle(Int64(1000 - $0 * 10), 5) }
                + [qoCycle(500, 99)])])
        expect(qoLong.first?.recent.count == QuotaOverviewFold.stripLength,
               "QO5 the strip is capped at its length")
        expect(qoLong.first?.peakPercent == 99 && qoLong.first?.neverExhausted == false,
               "QO5 but the peak sees every cycle, including one older than the strip")

        // MARK: aggregate quota equivalence (AE)
        //
        // The estimate is pooled — sum the deltas, sum the spend, divide once —
        // because quantisation is an absolute half-point on each delta, so a
        // cycle's relative noise runs as 1/delta and pooling weights each cycle
        // by the evidence it carries. Averaging per-cycle ratios gives a
        // 5-point cycle the same say as a 98-point one.
        //
        // Measured 2026-08-17 on 14 live cycles: per-cycle ratios spread 2.7x
        // (38% half-range) while the pooled estimate agreed to 1% between
        // independent halves and carries a 5% jackknife error. An earlier
        // version reported the per-cycle spread as the estimate's error and so
        // rejected its own usable answer.

        func aeCycle(_ delta: Double, _ tokens: Int64, _ cost: Double,
                     observed: Double = 1) -> WindowEquivalence.Cycle {
            WindowEquivalence.Cycle(
                deltaPercent: delta, spanTokens: tokens, spanCost: cost,
                observedFraction: observed)
        }

        // Four identical cycles: 80 points of movement carrying $40 and 800
        // tokens. A tenth of the allowance is therefore $5.00 and 100 tokens.
        // Identical cycles leave the jackknife with nothing to disagree about,
        // so the error floors at 1% rather than claiming zero.
        if case let .ratio(tokens, cost, error) = WindowEquivalence.aggregate(
            cycles: Array(repeating: aeCycle(20, 200, 10), count: 4))
        {
            expect(tokens == 100, "AE1 a tenth is the POOLED token sum over the pooled delta")
            expect(abs(cost - 5.0) < 0.001, "AE1 and the pooled spend over the same delta")
            expect(error == 1, "AE1 cycles that agree perfectly still state a floor, not 0%")
        } else {
            expect(false, "AE1 four agreeing cycles produce an estimate")
        }

        // Unequal deltas — the case that separates pooling from averaging, and
        // the only one that can. Three cycles of 50 points carrying $50 each
        // and one of 5 points carrying $10: pooled is 160/155 = 1.032 per
        // point, so $10.32 a tenth. Averaging the four per-cycle ratios
        // (1, 1, 1, 2) would give 1.25 and hence $12.50, letting the smallest
        // cycle drag the answer 21% by carrying a thirtieth of the evidence.
        //
        // Every other fixture here uses equal deltas, where the two agree.
        // Without this one the distinction is unreachable and a mutation
        // swapping pooling for averaging survives the whole suite.
        if case let .ratio(_, cost, _) = WindowEquivalence.aggregate(cycles: [
            aeCycle(50, 500, 50), aeCycle(50, 500, 50),
            aeCycle(50, 500, 50), aeCycle(5, 100, 10),
        ]) {
            expect(abs(cost - 10.3226) < 0.001,
                   "AE1 unequal cycles are weighted by their delta, not counted equally")
        } else {
            expect(false, "AE1 unequal cycles that agree closely still produce an estimate")
        }

        // Same deltas, spend rising 5/10/15/20. Hand-computed jackknife: the
        // four leave-one-out ratios are 0.750, 0.667, 0.583 and 0.500 per
        // point, mean 0.625, standard error 0.161 — 25.8% relative, past the
        // 10% tolerance, so no single figure is claimed.
        let aeDivergent = WindowEquivalence.aggregate(cycles: [
            aeCycle(20, 200, 5), aeCycle(20, 200, 10),
            aeCycle(20, 200, 15), aeCycle(20, 200, 20),
        ])
        expect(!aeDivergent.isRatio,
               "AE2 cycles whose leave-one-out estimates disagree give no single figure")
        if case let .spread(_, _, lowCost, highCost) = aeDivergent {
            expect(abs(lowCost - 2.5) < 0.001 && abs(highCost - 10.0) < 0.001,
                   "AE2 the span reported is the per-cycle extremes per tenth")
        } else {
            expect(false, "AE2 divergent cycles report a span")
        }

        // Admission. Each gate excludes on its own, and falling under the cycle
        // floor is reported as insufficient rather than as a wrong number.
        expect(
            !WindowEquivalence.aggregate(
                cycles: Array(repeating: aeCycle(4.9, 200, 10), count: 6)).isRatio,
            "AE3 cycles under the minimum delta are not evidence, however many there are")
        expect(
            !WindowEquivalence.aggregate(
                cycles: Array(repeating: aeCycle(20, 200, 10, observed: 0.4), count: 6)).isRatio,
            "AE3 a window the app mostly missed is excluded, whatever its delta says")
        expect(
            WindowEquivalence.aggregate(
                cycles: Array(repeating: aeCycle(20, 200, 10, observed: 0.6), count: 6)).isRatio,
            "AE3 control: the same cycles above the observation floor ARE admitted")
        expect(
            !WindowEquivalence.aggregate(
                cycles: Array(repeating: aeCycle(20, 200, 10), count: 2)).isRatio,
            "AE3 two cycles cannot support a leave-one-out spread, so no figure is given")

        expect(
            WindowEquivalence.aggregate(cycles: [aeCycle(0, 0, 0)]) == .notMoved,
            "AE4 quota that never moved is its own answer, not a division by zero")
        expect(
            WindowEquivalence.aggregate(cycles: [aeCycle(60, 0, 0)])
                == .unaccounted(deltaPercent: 60),
            "AE4 quota moved with nothing recorded locally is not `1% is free`")
        expect(
            // The live case that exposed the old copy: two cycles, 35% and
            // 97%, both individually admissible. Reporting that as "moved only
            // 132%" with a +/-1% error was three false claims in one line.
            WindowEquivalence.aggregate(cycles: [
                aeCycle(35, 1_000, 10), aeCycle(97, 3_000, 30),
            ]) == .tooFewCycles(count: 2, needed: WindowEquivalence.minimumCycles),
            "V15 two large cycles are too FEW, not too small")
        expect(
            WindowEquivalence.text(
                .tooFewCycles(count: 2, needed: 3),
                tokens: Format.compactTokens, money: Format.usd)
                == "2 of 3 windows recorded — the estimate needs that many",
            "V15 and it says so, without quoting a movement figure that contradicts it")
        expect(
            WindowEquivalence.aggregate(declared: false, cycles: [aeCycle(60, 0, 0)])
                == .undeclared,
            "V15 with nothing declared the fold says so, rather than reporting the "
                + "same cycles as unrecorded usage")
        expect(
            WindowEquivalence.aggregate(declared: true, cycles: [aeCycle(60, 0, 0)])
                != .undeclared,
            "V15 and the flag is what decides it, not the empty spend those cycles carry")
        // V16. Pricing that is unavailable is not usage that is absent. Three
        // cycles with real tokens and no price used to fail the cost-only
        // admission gate and be reported as "none of it recorded on this
        // machine" — false about the one thing the machine could see.
        let aeUnpriced = [aeCycle(50, 1_000, 0), aeCycle(50, 1_000, 0),
                          aeCycle(50, 1_000, 0)]
        if case let .tokensOnly(tokens, _) = WindowEquivalence.aggregate(cycles: aeUnpriced) {
            expect(tokens == 200,
                   "V16 unpriced cycles still yield a token estimate: 3000 tokens over 150 points")
        } else {
            expect(false, "V16 unpriced cycles still yield a token estimate")
        }
        expect(
            WindowEquivalence.aggregate(cycles: aeUnpriced) != .unaccounted(deltaPercent: 150),
            "V16 and are not reported as usage nobody recorded")
        // The money figure must not be pooled over cycles that carry no price:
        // one priced cycle among three would otherwise be divided by all three
        // deltas and read a third of its true rate.
        let aeMixed = [aeCycle(50, 1_000, 10), aeCycle(50, 1_000, 0),
                       aeCycle(50, 1_000, 0)]
        expect(
            WindowEquivalence.aggregate(cycles: aeMixed) ==
                WindowEquivalence.aggregate(cycles: aeUnpriced),
            "V16 a single priced cycle is not enough for a money figure, so the row is the same")
        // With enough priced cycles the money figure appears — and it must be
        // pooled over THOSE, not over every admitted cycle. Three priced cycles
        // at $10 per 50 points is $2 per tenth; dividing the same $30 by all
        // four deltas would read $1.50 and understate in proportion to how much
        // unpriced work happened.
        let aeEnoughPriced = [aeCycle(50, 1_000, 10), aeCycle(50, 1_000, 10),
                              aeCycle(50, 1_000, 10), aeCycle(50, 1_000, 0)]
        if case let .ratio(tokens, cost, _) =
            WindowEquivalence.aggregate(cycles: aeEnoughPriced)
        {
            expect(abs(cost - 2.0) < 1e-9,
                   "V16 the money figure is pooled over priced cycles only")
            expect(tokens == 200,
                   "V16 while the token figure still pools over every admitted cycle")
        } else {
            expect(false, "V16 enough priced cycles do produce a ratio")
        }

        // V17. A provider row can carry a cost and no token components. The
        // pooled path admits one; the single-window footer required tokens and
        // reported "none of it recorded on this machine" about usage sitting in
        // the same scan.
        let v17CostOnly = try! JSONDecoder().decode(
            [WindowMessage].self,
            from: Data("""
            [{"timestamp":1500,"client":"t","providerId":"t","modelId":"t","input":0,
              "output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0,"cost":4.5,
              "isTurnStart":true}]
            """.utf8))
        expect(
            WindowEquivalence.row(
                samples: [QuotaSample(atMs: 1_000, usedPercent: 1),
                          QuotaSample(atMs: 2_000, usedPercent: 20)],
                messages: v17CostOnly) != .unaccounted(deltaPercent: 19),
            "V17 a cost-only row counts as usage this machine recorded")
        expect(
            WindowEquivalence.row(
                samples: [QuotaSample(atMs: 1_000, usedPercent: 1),
                          QuotaSample(atMs: 2_000, usedPercent: 20)],
                messages: []) == .unaccounted(deltaPercent: 19),
            "V17 and an empty span still is not, so the check above is not vacuous")
        // V21. Admitting either kind of evidence and then always answering
        // `.ratio` presented the MISSING metric as a measured zero: the
        // cost-only window above as `0` tokens, and its mirror as a $0 API
        // equivalent. Unavailable and zero are different claims, and the pooled
        // path already distinguished them.
        let v21TokensOnly = try! JSONDecoder().decode(
            [WindowMessage].self,
            from: Data("""
            [{"timestamp":1500,"client":"t","providerId":"t","modelId":"t","input":900,
              "output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0,"cost":0,
              "isTurnStart":true}]
            """.utf8))
        let v21Samples = [QuotaSample(atMs: 1_000, usedPercent: 1),
                          QuotaSample(atMs: 2_000, usedPercent: 20)]
        func v21Kind(_ messages: [WindowMessage]) -> String {
            switch WindowEquivalence.row(samples: v21Samples, messages: messages) {
            case .ratio: return "ratio"
            case .costOnly: return "costOnly"
            case .tokensOnly: return "tokensOnly"
            default: return "other"
            }
        }
        expect(v21Kind(v17CostOnly) == "costOnly",
               "V21 a window with cost but no tokens reports cost only, rather than a "
                   + "ratio claiming zero tokens")
        expect(v21Kind(v21TokensOnly) == "tokensOnly",
               "V21 and a window with tokens but no price reports tokens only, rather "
                   + "than a ratio claiming a $0 equivalent")
        expect(v21Kind(v17CostOnly + v21TokensOnly) == "ratio",
               "V21 and a window carrying both still reports a full ratio, so the two "
                   + "checks above are not simply refusing everything")
        // V20. The three-cycle threshold guards BOTH estimates or neither.
        // Splitting the pooling without splitting the guard let a token figure
        // built from one cycle sit beside a properly supported money figure, on
        // one line, under an error bar that described only the money.
        let aeCostHeavy = [aeCycle(50, 0, 10), aeCycle(50, 0, 10),
                           aeCycle(50, 0, 10), aeCycle(50, 1_000, 10)]
        if case let .costOnly(cost, _) = WindowEquivalence.aggregate(cycles: aeCostHeavy) {
            expect(abs(cost - 2.0) < 1e-9,
                   "V20 the money figure stands on its four priced cycles")
        } else {
            expect(false, "V20 enough priced and too few token-bearing yields a cost-only row")
        }
        expect(
            WindowEquivalence.aggregate(cycles: aeCostHeavy).isRatio == false,
            "V20 and never a ratio, which would publish tokens from a single cycle")
        // The mirror still works: enough of both is still a ratio.
        expect(
            WindowEquivalence.aggregate(cycles: [
                aeCycle(50, 1_000, 10), aeCycle(50, 1_000, 10), aeCycle(50, 1_000, 10),
            ]).isRatio,
            "V20 while enough of both kinds still produces one, so the guard is not blanket")

        // V19. The token estimate pools over token-bearing cycles, mirroring
        // what the money estimate already did. A cost-only cycle carries quota
        // delta and no tokens, so leaving it in the denominator understated the
        // token figure by exactly the share of history it represents — the same
        // defect as the money one, on the other side, fixed only on one side.
        let aeCostOnly = [aeCycle(50, 1_000, 10), aeCycle(50, 1_000, 10),
                          aeCycle(50, 1_000, 10), aeCycle(50, 0, 10)]
        if case let .ratio(tokens, _, _) = WindowEquivalence.aggregate(cycles: aeCostOnly) {
            expect(tokens == 200,
                   "V19 3000 tokens over the 150 points that produced them, not over 200")
        } else {
            expect(false, "V19 a mixed history still produces a ratio")
        }
        // Neither estimate has enough behind it. Two admitted cycles fail the
        // count gate before the split even matters, and the count the user sees
        // is of recorded windows — which is what the sentence says.
        expect(
            WindowEquivalence.aggregate(cycles: [aeCycle(50, 1_000, 0), aeCycle(50, 0, 10)])
                == .tooFewCycles(count: 2, needed: WindowEquivalence.minimumCycles),
            "V19 two admitted cycles are too few whichever evidence they carry")
        // Three admitted, but split one-and-two across the two kinds: neither
        // estimate has three behind it, and inventing one from the majority
        // kind would be a figure with less history than the row claims.
        expect(
            WindowEquivalence.aggregate(cycles: [
                aeCycle(50, 1_000, 0), aeCycle(50, 1_000, 0), aeCycle(50, 0, 10),
            ]) == .tooFewCycles(count: 2, needed: WindowEquivalence.minimumCycles),
            "V19 and a history split across both kinds is counted per kind, not in total")

        // V18. The fallback classifier had to learn the same rule. Small
        // unpriced cycles are not admitted, and calling them unrecorded is the
        // third copy of the sentence this branch keeps deleting.
        let aeSmallUnpriced = [aeCycle(2, 500, 0), aeCycle(2, 500, 0)]
        expect(
            WindowEquivalence.aggregate(cycles: aeSmallUnpriced)
                != .unaccounted(deltaPercent: 4),
            "V18 small unpriced cycles are too little to estimate, not usage nobody recorded")
        expect(
            WindowEquivalence.aggregate(cycles: [aeCycle(2, 0, 0), aeCycle(2, 0, 0)])
                == .unaccounted(deltaPercent: 4),
            "V18 and cycles with neither tokens nor cost still are, so the check is not vacuous")

        // The tokens-only error bar must be computed, not decorative: cycles
        // that disagree produce a non-zero jackknife. A homogeneous fixture
        // makes that path unreachable, which is how it was covered in
        // appearance only.
        if case let .tokensOnly(_, error) = WindowEquivalence.aggregate(cycles: [
            aeCycle(50, 1_000, 0), aeCycle(50, 4_000, 0), aeCycle(50, 9_000, 0),
        ]) {
            expect(error > 1, "V18 disagreeing unpriced cycles carry a real error bar")
        } else {
            expect(false, "V18 disagreeing unpriced cycles still produce a tokens-only row")
        }

        expect(
            WindowEquivalence.aggregate(cycles: []) == .unavailable,
            "AE4 no cycles means no estimate at all")

        // MARK: daily trend by subscription (ST)

        func seriesPoint(_ date: String, _ state: UsageAttribution.State,
                         _ model: String, _ tokens: Int64, _ cost: Double)
            -> AttributedDailySeries.Point
        {
            AttributedDailySeries.Point(
                date: date, state: state, model: model, tokens: tokens, cost: cost)
        }

        let stTrend = SubscriptionTrendFold.build(
            points: [
                seriesPoint("2026-08-14", .assigned("codex"), "sol", 900, 90),
                seriesPoint("2026-08-14", .assigned("claude"), "opus", 100, 10),
                // 08-15 is deliberately absent: an idle day.
                seriesPoint("2026-08-16", .assigned("claude"), "opus", 300, 30),
                seriesPoint("2026-08-16", .unassigned, "mystery", 50, 5),
                seriesPoint("2026-08-16", .excluded, "bench", 999, 999),
                seriesPoint("2026-08-01", .assigned("codex"), "sol", 700, 70),
            ],
            today: "2026-08-16", days: 3)

        expect(stTrend.days.map(\.date) == ["2026-08-14", "2026-08-15", "2026-08-16"],
               "ST1 idle days are present as empty columns, so the axis does not compress time")
        expect(stTrend.days[1].isEmpty,
               "ST1 and the day with no rows is empty rather than absent")
        expect(stTrend.days[0].byTarget["codex"]?.cost == 90,
               "ST2 each day keeps its own per-subscription split")
        expect(stTrend.days[2].byTarget[SubscriptionTrendFold.unassignedTarget]?.tokens == 50,
               "ST3 unclassified usage is its own band, never dropped or merged")
        expect(stTrend.days[2].byTarget["bench"] == nil && stTrend.days[2].totalCost == 35,
               "ST3 declared-excluded usage IS dropped, which is what declaring it meant")
        expect(stTrend.days.allSatisfy { $0.date >= "2026-08-14" },
               "ST4 a point older than the range is outside it, so 08-01 is not counted")
        expect(stTrend.targets == ["codex", "claude", SubscriptionTrendFold.unassignedTarget],
               "ST5 stacking order is by total cost, so the biggest payer is the base")
        expect(stTrend.peakCost == 100,
               "ST6 the peak is a DAY total, not the range total")

        // ST5b. Cost and tokens do not rank subscriptions the same way, and the
        // cost order was applied to both views. The legend draws only
        // `prefix(4)`, so under Tokens the largest token consumer could sit
        // behind smaller bands and fall outside the legend entirely — beneath a
        // tooltip that says largest-first.
        //
        // `bulk` is the biggest by tokens and the smallest by cost; `boutique`
        // is the reverse. One fixture, two orders, opposite ends.
        let stRank = SubscriptionTrendFold.build(
            points: [
                seriesPoint("2026-08-16", .assigned("bulk"), "unpriced", 9_000, 1),
                seriesPoint("2026-08-16", .assigned("middle"), "m", 500, 50),
                seriesPoint("2026-08-16", .assigned("boutique"), "opus", 10, 900),
            ],
            today: "2026-08-16", days: 1)
        expect(stRank.targets == ["boutique", "middle", "bulk"],
               "ST5b the cost order still ranks by cost")
        expect(stRank.targetsByTokens == ["bulk", "middle", "boutique"],
               "ST5b and the token order ranks by tokens, which is the opposite "
                   + "order on this data — so reusing one for the other cannot be "
                   + "hidden by a fixture where they agree")
        expect(stRank.targets(byTokens: true) == stRank.targetsByTokens
                   && stRank.targets(byTokens: false) == stRank.targets,
               "ST5b and the accessor the card resolves once returns each of them, "
                   + "so the stacking order and the legend cannot disagree")
        expect(Set(stRank.targets) == Set(stRank.targetsByTokens),
               "ST5b both orders cover the same subscriptions — an order, not a filter")

        // ST8. Which of the four things the card shows. The empty state is a
        // claim about the RANGE; only the copy is a claim about the toggle.
        // Deriving it from the metric-specific peak reported recorded usage as
        // absent whenever the other metric held all of it — the default Price
        // view over unpriced models, and its mirror in Tokens.
        // Through the fold, not a hand-built value: the initialisers are
        // internal to Core, and a fixture that cannot be produced by the
        // pipeline is a fixture the pipeline need not respect.
        let stTokensOnly = SubscriptionTrendFold.build(
            points: [seriesPoint("2026-08-16", .assigned("claude"), "unpriced", 900, 0)],
            today: "2026-08-16", days: 1)
        let stCostOnly = SubscriptionTrendFold.build(
            points: [seriesPoint("2026-08-16", .assigned("claude"), "opaque", 0, 12)],
            today: "2026-08-16", days: 1)
        expect(
            SubscriptionTrendCard.state(trend: stTokensOnly, metric: .cost)
                == .metricUnavailable
                && SubscriptionTrendCard.state(trend: stTokensOnly, metric: .tokens) == .chart,
            "ST8 unpriced usage draws in Tokens and says so in Price, rather than "
                + "reporting the range as empty")
        expect(
            SubscriptionTrendCard.state(trend: stCostOnly, metric: .tokens)
                == .metricUnavailable
                && SubscriptionTrendCard.state(trend: stCostOnly, metric: .cost) == .chart,
            "ST8 and the mirror holds for usage that carries a cost but no token counts")
        expect(
            SubscriptionTrendCard.state(trend: .empty, metric: .cost) == .noUsage
                && SubscriptionTrendCard.state(trend: nil, metric: .cost) == .loading,
            "ST8 a genuinely empty range is still reported as empty, and a range not "
                + "yet read is still reported as loading")

        // A DST-safe walk, checked against a transition the arithmetic version
        // gets wrong: 2026-11-01 is the US fall-back day.
        expect(SubscriptionTrendFold.calendarRange(endingAt: "2026-11-02", count: 3)
                == ["2026-10-31", "2026-11-01", "2026-11-02"],
               "ST7 the range walks calendar days, so a 25-hour day is still one day")

        // MARK: day keys (SU5)

        // Calendar days, not 86_400-second multiples — the arithmetic version
        // lands on the wrong date across a DST transition. The zone is pinned
        // because "07:33 local" names a different date in each of them, and an
        // assertion that reads the runner's own zone passes wherever it was
        // written and fails everywhere else. It did: on a UTC runner this epoch
        // is still 2026-03-31, so the expectation below was a day out for a
        // day, on every run, while the local suite stayed green.
        let su5Zone = TimeZone(identifier: "Asia/Taipei")!
        let su5Instant = Date(timeIntervalSince1970: 1_775_000_000)
        expect(
            Format.todayKey(now: su5Instant, timeZone: su5Zone) == "2026-04-01",
            "SU5 the fixture instant is 2026-04-01 in the zone it is stated in")
        expect(
            Format.dayKey(daysAgo: 1, now: su5Instant, timeZone: su5Zone) == "2026-03-31",
            "SU5 one day back from it is the previous calendar day")
        // Not `dayKey(daysAgo: 0) == todayKey()`, which cannot fail: `dayKey`
        // is defined as `todayKey` of a shifted date, so at zero it IS that
        // call.
        //
        // 2026-03-08 is the US spring-forward day, 23 hours long. From 00:30 on
        // the 9th, subtracting 86_400 seconds lands at 23:30 on the SEVENTH —
        // two calendar days back — while walking one calendar day lands on the
        // eighth. A fall-back fixture would not discriminate: on a 25-hour day
        // both answers stay inside the same date.
        expect(
            Format.dayKey(
                daysAgo: 1,
                now: Date(timeIntervalSince1970: 1_773_030_600),
                timeZone: TimeZone(identifier: "America/New_York")!) == "2026-03-08",
            "SU5 one day back across a 23-hour day is a calendar day, not 86,400 seconds")

        // MARK: Overview composition (OC)
        //
        // The Agent-limits card was moved off Overview and back, which is the
        // behaviour these pin: what a fresh install sees must not change
        // because someone reorganised a lens, and the anchor must survive a
        // hand-edited preference for the same reason `AppView`'s does.
        expect(OverviewCard.allCases.map(\.rawValue)
                == ["quotaSummary", "chart", "limits", "trace", "models", "streaks"],
               "OC1 the usage chart precedes the limits card, as it did before the move")
        expect(OverviewCard.visible(hiddenRaw: "") == OverviewCard.allCases,
               "OC2 the default shows every card, so an upgrade changes nothing")
        expect(OverviewCard.visible(hiddenRaw: "limits,trace")
                == OverviewCard.allCases.filter { $0 != .limits && $0 != .trace },
               "OC2 hiding two removes exactly those two, order otherwise unchanged")
        expect(!OverviewCard.toggleable.contains(.chart),
               "OC3 the usage chart is an anchor, matching AppView's rule for Overview")
        expect(OverviewCard.visible(hiddenRaw: "chart").contains(.chart),
               "OC3 and a tampered preference cannot empty the lens everything falls back to")
        expect(OverviewCard.visible(
                hiddenRaw: OverviewCard.allCases.map(\.rawValue).joined(separator: ",")
               ) == [.chart],
               "OC3 hiding literally everything still leaves the anchor")
        expect(OverviewCard.hiddenKey == "tokenbar.overview.hidden",
               "OC4 the key is declared once, on the type that owns it")

        // MARK: limits layout (LL)
        //
        // The sparkline shipped inside `full` first, which changed the card for
        // everyone who had not asked for it. It is a choice now, and the
        // default is the one users already had — a silent default change here
        // would redraw every existing install's most-looked-at card.
        expect(LimitsLayout(rawValue: "full") == .full && LimitsLayout.full.rawValue == "full",
               "LL1 the stored default id is `full`, the bar layout")
        expect(LimitsLayout(rawValue: "nonsense") == nil,
               "LL1 an unknown stored value does not decode, so callers fall back explicitly")
        expect(Set(LimitsLayout.allCases.map(\.rawValue)) == ["full", "classic", "chart"],
               "LL2 three layouts are offered, and Settings enumerates allCases")

        // Stated in behaviour rather than by reading the constant, because the
        // constant is no longer reachable from this target: `minimumDelta` is
        // internal to `TokenBarCore` so the admission comparison cannot be
        // written outside `deltaQualifies`. Bracketing the boundary is also a
        // stronger claim than the equality it replaces — it says where the bar
        // is AND that it admits at it, which an `== 5` on the constant did not.
        expect(
            !WindowEquivalence.deltaQualifies(4.999, runs: 1)
                && WindowEquivalence.deltaQualifies(5, runs: 1),
            "V15 the threshold follows from the tolerance, not from a chosen number")

        // Every row string is rendered, not just constructed. A literal `%` in
        // one of these was read as a `% o` octal conversion, consumed the first
        // argument, and segfaulted the app on the next `%@` — and nothing in the
        // suite could have caught it, because the strings lived in a SwiftUI
        // body. Rendering each one is the whole point of this block.
        let rowText: (WindowEquivalence.Row) -> String = {
            WindowEquivalence.text($0, tokens: { "\($0)" }, money: { "$\($0)" })
        }
        expect(
            rowText(.ratio(tokensPerTenth: 7, costPerTenth: 3, errorPercent: 8))
                == "10% of quota ~ 7 · $3.0 API-equivalent, ±8%",
            "V15 the ratio row renders its literal percent signs, not an octal conversion")
        expect(
            rowText(.insufficient(deltaPercent: 1, errorPercent: 50))
                == "Quota moved only 1% — too little to estimate (±50%)",
            "V15 the insufficient row renders both percent signs")
        expect(
            rowText(.unaccounted(deltaPercent: 56))
                == "Quota moved 56%, none of it recorded on this machine",
            "V15 the unaccounted row renders its percent sign")
        // The two must stay distinguishable in copy as well as in the type:
        // most users have declared nothing, and telling them their machine
        // recorded no usage is both false and alarming.
        expect(
            rowText(.undeclared)
                == "Classify your usage in Settings to see what this window is worth",
            "V15 an undeclared window says so instead of claiming nothing was recorded")
        expect(
            rowText(.undeclared) != rowText(.unaccounted(deltaPercent: 56)),
            "V15 undeclared and unaccounted are two different statements")
        expect(
            rowText(.notMoved) == "Quota has not moved yet"
                && rowText(.unavailable) == "Not enough quota readings yet",
            "V15 the argument-free rows survive being run through the formatter")
        // The error term is 0.5/delta. Folding a zero delta into `insufficient`
        // would divide by zero, so it gets its own case with no error to state.
        expect(
            WindowEquivalence.row(
                samples: [QuotaSample(atMs: 1_000, usedPercent: 2),
                          QuotaSample(atMs: 2_000, usedPercent: 2)],
                messages: eqMessages) == .notMoved,
            "V15 a quota reading that never moved is its own case, not a zero error")
        expect(
            WindowEquivalence.row(
                samples: [QuotaSample(atMs: 1_000, usedPercent: 5),
                          QuotaSample(atMs: 2_000, usedPercent: 3)],
                messages: eqMessages) == .notMoved,
            "V15 a backwards reading is muted too rather than yielding a negative ratio")
        expect(
            WindowEquivalence.row(
                samples: [QuotaSample(atMs: 1_000, usedPercent: 2)],
                messages: eqMessages) == .unavailable
                && WindowEquivalence.row(samples: [], messages: eqMessages) == .unavailable,
            "V15 fewer than two samples yields no delta at all")

        // MARK: quota window recent-trend indicator

        // Window 0...100_000ms (100s), now at 80_000 (80% elapsed). Trailing
        // 25% span = last 25_000ms back from the newest sample. Two samples
        // at 60_000 and 80_000 (both inside that span): Δused=10 over
        // Δt=20_000ms -> elapsedFraction = 0.2 -> recentSlope = 10/(0.2*100)
        // = 0.5. remainingElapsedFraction = 1-0.8 = 0.2, so
        // projected = 50 + 0.5*0.2*100 = 60.
        let trendHand = QuotaTrendFold.trend(
            usedPercent: 50, windowStartMs: 0, windowEndMs: 100_000, nowMs: 80_000,
            samples: [QuotaSample(atMs: 60_000, usedPercent: 40),
                      QuotaSample(atMs: 80_000, usedPercent: 50)])
        expect(
            trendHand.map { abs($0.projectedUsedPercent - 60) < 1e-9 } == true,
                "quota trend: hand-computed projection 50 + 0.5*0.2*100 = 60")
        expect(trendHand?.direction == .rising, "quota trend: a positive recent slope is rising")
        // The live shape that produced an impossible row: 13 points gone in the
        // first 35 minutes of a five-hour window, four hours still to run. The
        // projection is arithmetically fine and the delta it implies (88 points)
        // is larger than the 87 that remain, so the row must not print it.
        let trendSaturating = QuotaTrendFold.trend(
            usedPercent: 13, windowStartMs: 0, windowEndMs: 18_000_000,
            nowMs: 3_600_000,
            samples: [QuotaSample(atMs: 1_500_000, usedPercent: 0),
                      QuotaSample(atMs: 3_600_000, usedPercent: 13)])
        expect(trendSaturating?.runsOutEarly == true
                && (trendSaturating?.projectedDeltaPercent ?? 0) > 87,
               "quota trend: a rate that spends more than remains is flagged, not printed")
        expect(trendHand?.runsOutEarly == false,
               "quota trend: an ordinary projection is not flagged, so the flag is not always on")
        // The row prints this, not the projection: what the current slope still
        // costs between now and reset. It must be the projection minus the
        // reading it was projected from, or the number on screen and the number
        // in the tooltip describe different windows.
        expect(
            trendHand.map { abs($0.projectedDeltaPercent - 10) < 1e-9 } == true,
            "quota trend: the printed delta is the projection minus the current reading")

        // The grok case that motivates the whole design: lifetime-average
        // ratio is the highest of the measured windows, but the recent slope
        // is flat because usage stopped days ago. A flat recent slope must
        // read as "not moving", never as a burn — regardless of the average.
        let dayMs: Int64 = 7 * 24 * 3_600_000
        let grokNow = Int64(Double(dayMs) * 0.88)
        let grokTrend = QuotaTrendFold.trend(
            usedPercent: 63, windowStartMs: 0, windowEndMs: dayMs, nowMs: grokNow,
            samples: [QuotaSample(atMs: grokNow - Int64(Double(dayMs) * 0.20), usedPercent: 63),
                      QuotaSample(atMs: grokNow, usedPercent: 63)])
        expect(
            grokTrend?.direction == .flat
                && grokTrend.map { abs($0.projectedUsedPercent - 63) < 1e-9 } == true,
            "quota trend: a flat recent slope reads as not-moving and projects flat, even at a high lifetime average (grok)")

        expect(
            QuotaTrendFold.trend(
                usedPercent: 50, windowStartMs: 0, windowEndMs: 100_000, nowMs: 80_000,
                samples: [QuotaSample(atMs: 80_000, usedPercent: 50)]) == nil,
            "quota trend: a single sample in the window yields no indicator, not a fabricated zero")
        expect(
            QuotaTrendFold.trend(
                usedPercent: 50, windowStartMs: 0, windowEndMs: 100_000, nowMs: 80_000,
                samples: [QuotaSample(atMs: 1_000, usedPercent: 5),
                          QuotaSample(atMs: 80_000, usedPercent: 50)]) == nil,
            "quota trend: only one of two on-file samples falls inside the trailing 25% span, so still no indicator")

        // slope = (90-70)/(0.2*100) = 1.0; projected = 90 + 1.0*0.2*100 = 110.
        let overTrend = QuotaTrendFold.trend(
            usedPercent: 90, windowStartMs: 0, windowEndMs: 100_000, nowMs: 80_000,
            samples: [QuotaSample(atMs: 60_000, usedPercent: 70),
                      QuotaSample(atMs: 80_000, usedPercent: 90)])
        expect(
            overTrend.map { $0.projectedUsedPercent > 100 } == true,
            "quota trend: a fast recent burn projects past 100% used at reset — reachable, not clamped")

        expect(
            QuotaTrendFold.trend(
                usedPercent: 50, windowStartMs: 0, windowEndMs: 0, nowMs: 80_000,
                samples: [QuotaSample(atMs: 60_000, usedPercent: 40),
                          QuotaSample(atMs: 80_000, usedPercent: 50)]) == nil,
            "quota trend: a window with no duration yields no indicator")
        // MARK: - Claude extra scan roots (CLAUDE-EXTRA-ROOT-E1; append-only)
        //
        // This module never calls the FFI (see the module comment atop this
        // file); the hermetic scan-adds-up assertions (A1-A6, A8) live in the
        // Rust `crates/tb_core_ffi/src/extra_scan_paths.rs` tests instead,
        // where a real `LocalSourceContext` can point at a temp root. What's
        // testable here is the pure Swift side: expanding a config dir into
        // the two sub-roots the engine actually scans, and encoding that into
        // the exact JSON `tb_set_extra_scan_paths` expects.
        expect(
            ClaudeExtraRoots.expand("/Users/x/.claude-work")
                == ["/Users/x/.claude-work/projects", "/Users/x/.claude-work/transcripts"],
            "D2: a config dir expands to BOTH projects and transcripts sub-roots "
                + "(mutation: expanding to only one silently drops whichever "
                + "sub-root a real isolated CLAUDE_CONFIG_DIR produces)")

        let payloadOne = ClaudeExtraRoots.payloadJSON(["/Users/x/.claude-work"])
        let decodedOne = try! JSONDecoder().decode(
            [String: [String]].self, from: Data(payloadOne.utf8))
        expect(
            decodedOne["claude"] == [
                "/Users/x/.claude-work/projects", "/Users/x/.claude-work/transcripts",
            ],
            "payloadJSON encodes one config dir as {\"claude\":[projects,transcripts]}")

        // Two dirs whose expansions don't overlap: both fully present, in order.
        let payloadTwo = ClaudeExtraRoots.payloadJSON(["/Users/a", "/Users/b"])
        let decodedTwo = try! JSONDecoder().decode(
            [String: [String]].self, from: Data(payloadTwo.utf8))
        expect(
            decodedTwo["claude"] == [
                "/Users/a/projects", "/Users/a/transcripts",
                "/Users/b/projects", "/Users/b/transcripts",
            ],
            "payloadJSON carries every configured dir's expansion, not just the first")

        // Empty list -> empty array, not an absent key or {} — the setter's
        // full-replace semantics need an explicit empty list to clear the
        // registry (the Settings rollback path), not a missing "claude" key
        // that leaves whatever was there before untouched.
        let payloadEmpty = ClaudeExtraRoots.payloadJSON([])
        let decodedEmpty = try! JSONDecoder().decode(
            [String: [String]].self, from: Data(payloadEmpty.utf8))
        expect(
            decodedEmpty["claude"] == [],
            "payloadJSON([]) encodes an explicit empty array (mutation: an absent key "
                + "would leave the core registry unchanged instead of clearing it)")

        // Duplicate config dirs (e.g. the same folder added twice, or two
        // dirs whose expansions collide) collapse to one entry per path in
        // the wire payload — dedup happens before the JSON leaves Swift, not
        // relied on solely by the Rust-side canonical-path dedup.
        let payloadDup = ClaudeExtraRoots.payloadJSON(["/Users/x/.claude-work", "/Users/x/.claude-work"])
        let decodedDup = try! JSONDecoder().decode(
            [String: [String]].self, from: Data(payloadDup.utf8))
        expect(
            decodedDup["claude"] == [
                "/Users/x/.claude-work/projects", "/Users/x/.claude-work/transcripts",
            ],
            "payloadJSON deduplicates repeated config dirs instead of doubling the path list")

        // The OTHER payload built from the same list: the config dirs
        // themselves, for `tb_set_claude_config_dirs`. It answers "whose
        // credential is this quota card fetched with", where payloadJSON above
        // answers "which directories does the scanner walk", so it must carry
        // the dirs and not their sub-roots.
        let configDirsPayload = ClaudeExtraRoots.configDirsPayloadJSON([
            "/Users/x/.claude-work/", "/Users/x/.claude-work", "/Users/y/.claude-other",
        ])
        let decodedConfigDirs = try! JSONDecoder().decode(
            [String].self, from: Data(configDirsPayload.utf8))
        expect(
            decodedConfigDirs == ["/Users/x/.claude-work", "/Users/y/.claude-other"],
            "configDirsPayloadJSON standardizes and deduplicates the config dirs themselves "
                + "(mutation: keeping the trailing slash derives a different Keychain service "
                + "name, so the account's card would read no credential at all; emitting the "
                + "expanded sub-roots would derive it from a directory that holds no item)")
        expect(
            ClaudeExtraRoots.configDirsPayloadJSON([]) == "[]",
            "configDirsPayloadJSON([]) clears the registry rather than leaving it untouched")

        // CE-APPLIED. What produced a scan is the registry the engine ACCEPTED,
        // not the list the user configured. `apply` deliberately keeps the
        // setter off the calling actor — the core probes each path with
        // `read_dir`, which an unmounted volume can stall, and tolerating that
        // is the whole feature — so there is a real interval in which `load()`
        // already names the new roots while the engine still scans the old
        // registry. Anything recording "which roots produced this data" that
        // reads the persisted list labels a pre-change scan as post-change,
        // and the snapshot check then accepts it on the next launch.
        ClaudeExtraRoots.resetAppliedForTesting()
        let ceEmpty = ClaudeExtraRoots.payloadJSON([])
        expect(ClaudeExtraRoots.appliedPayloadJSON == ceEmpty,
               "CE-APPLIED before any apply lands the engine holds no extra roots, "
                   + "and that is what is reported — not the configured list")
        let ceWanted = ClaudeExtraRoots.payloadJSON(["/tmp/tokenbar-applied"])
        ClaudeExtraRoots.recordApplied(ceWanted, result: nil)
        expect(ClaudeExtraRoots.appliedPayloadJSON == ceEmpty,
               "CE-APPLIED a setter that failed leaves the registry holding what it "
                   + "held, so the recorded value does not move either")
        // Decoded rather than constructed: `ExtraScanPathsResult` has no public
        // memberwise init, and going through the wire shape is what the real
        // caller does anyway.
        let ceResult = try! JSONDecoder().decode(
            ExtraScanPathsResult.self,
            from: Data(#"{"registeredCount":1,"unreadable":[],"rejected":[]}"#.utf8))
        ClaudeExtraRoots.recordApplied(ceWanted, result: ceResult)
        expect(ClaudeExtraRoots.appliedPayloadJSON == ceWanted,
               "CE-APPLIED and a setter that succeeded does move it, so the rule is "
                   + "a condition rather than a refusal to ever record")
        expect(UserDefaults.standard.string(forKey: ClaudeExtraRoots.appliedKey) == ceWanted,
               "CE-APPLIED and it is persisted, because the snapshot a RESTORE has "
                   + "to judge was written by a previous run")

        // CE-REJECTED. A successful call is not a fully accepted one.
        // `rejected` names paths Rust deliberately left out of the registry, so
        // recording the whole request claims roots the scan does not include —
        // and a rejected path that becomes a real directory while the app is
        // stopped would then let the next launch accept a snapshot whose scan
        // excluded it. `unreadable` is the opposite case: those ARE registered
        // and retried on the next scan, so they must stay.
        // Paths through `expand` and membership through the DECODED payload.
        // `JSONEncoder` escapes "/" as "\\/", so a `contains` on the raw JSON
        // string never matches a plain path — and the case would then pass on a
        // filter that removed nothing.
        func cePaths(_ json: String) -> [String] {
            (try? JSONDecoder().decode(
                [String: [String]].self, from: Data(json.utf8)))?["claude"] ?? []
        }
        let ceKept = ClaudeExtraRoots.expand("/tmp/tokenbar-a")[0]
        let ceRefused = ClaudeExtraRoots.expand("/tmp/tokenbar-b")[0]
        let cePartialJSON = "{\"registeredCount\":1,"
            + "\"unreadable\":[{\"client\":\"claude\",\"path\":\"\(ceKept)\","
            + "\"reason\":\"unmounted\"}],"
            + "\"rejected\":[{\"client\":\"claude\",\"path\":\"\(ceRefused)\","
            + "\"reason\":\"not a directory\"}]}"
        let cePartial = try! JSONDecoder().decode(
            ExtraScanPathsResult.self, from: Data(cePartialJSON.utf8))
        let ceTwo = ClaudeExtraRoots.payloadJSON(["/tmp/tokenbar-a", "/tmp/tokenbar-b"])
        // The premise: both paths really are in the request, or "the refused
        // one is absent" is true of a payload that never had it.
        expect(cePaths(ceTwo).contains(ceKept) && cePaths(ceTwo).contains(ceRefused),
               "CE-REJECTED the request really carries both roots")
        let ceRegistered = ClaudeExtraRoots.registeredJSON(
            ceTwo, rejected: cePartial.rejected)
        expect(cePaths(ceRegistered).contains(ceKept)
                   && !cePaths(ceRegistered).contains(ceRefused),
               "CE-REJECTED a refused path leaves the recorded registry, and an "
                   + "unreadable one — which IS registered and retried — stays in it")
        expect(ClaudeExtraRoots.registeredJSON(ceTwo, rejected: []) == ceTwo,
               "CE-REJECTED and with nothing refused the payload is returned "
                   + "byte-identical, so the common case cannot drift on re-encoding")
        // Through `recordApplied`, not just the helper beside it. Asserting the
        // helper alone passes while the recorder stores the whole request —
        // the same one-layer-short shape LP3-BIND'''s first version had, and it
        // survived this exact mutation until this case was added.
        ClaudeExtraRoots.resetAppliedForTesting()
        ClaudeExtraRoots.recordApplied(ceTwo, result: cePartial)
        expect(!cePaths(ClaudeExtraRoots.appliedPayloadJSON).contains(ceRefused)
                   && cePaths(ClaudeExtraRoots.appliedPayloadJSON).contains(ceKept),
               "CE-REJECTED the RECORDER stores the registered subset, so a "
                   + "snapshot is stamped with the roots the scan included")
        expect(!cePaths(
                   UserDefaults.standard.string(forKey: ClaudeExtraRoots.appliedKey) ?? ""
               ).contains(ceRefused),
               "CE-REJECTED and the persisted copy a restore judges against "
                   + "excludes it too")
        ClaudeExtraRoots.resetAppliedForTesting()
        expect(ClaudeExtraRoots.appliedPayloadJSON == ceEmpty,
               "CE-APPLIED a process that has never applied compares against the "
                   + "empty registry, which is what the engine holds then")

        // CE-MOVED. `apply` runs at launch and on every Settings save, not only
        // when the list changes, so "an apply ran" never implied "something
        // changed". Both consequences of an apply — dropping every Swift-side
        // scan cache and advancing the generation views key their reloads on —
        // were unconditional, so every launch paid for both. A popover already
        // open when that landed took a forced, cache-bypassing rescan for a
        // registry identical to the one already installed.
        ClaudeExtraRoots.resetAppliedForTesting()
        let ceFirst = ClaudeExtraRoots.payloadJSON(["/tmp/tokenbar-moved"])
        expect(ClaudeExtraRoots.recordAppliedAndReportChange(ceFirst, result: ceResult),
               "CE-MOVED installing a registry that differs reports a change")
        expect(!ClaudeExtraRoots.recordAppliedAndReportChange(ceFirst, result: ceResult),
               "CE-MOVED and installing the SAME registry again reports none — which "
                   + "is the launch case, and the one that was paying for a rescan")
        expect(ClaudeExtraRoots.recordAppliedAndReportChange(
                   ClaudeExtraRoots.payloadJSON(["/tmp/tokenbar-moved-2"]), result: ceResult),
               "CE-MOVED a genuinely different registry still reports a change, so the "
                   + "gate is a comparison rather than a one-shot latch")
        expect(!ClaudeExtraRoots.recordAppliedAndReportChange(
                   ClaudeExtraRoots.payloadJSON(["/tmp/tokenbar-moved-3"]), result: nil),
               "CE-MOVED a failed setter reports no change, because the registry still "
                   + "holds what it held")
        ClaudeExtraRoots.resetAppliedForTesting()

        // CE-CONFIG-MOVED. The account registry's own twin of CE-MOVED. `install`
        // wakes the quota throttle and every sleeping poller between its two
        // setters, and that wake was unconditional in exactly the way the scan
        // side's cache-drop and generation-bump were — `install` runs at launch
        // and on every Settings save, and `lastApplied` cannot catch the launch
        // case because it is in-memory and starts nil every process, so a
        // comparison against it always reports a change on the first apply of
        // a run. `appliedConfigDirsJSON` is persisted, which is what makes the
        // comparison mean something across a relaunch.
        ClaudeExtraRoots.resetAppliedConfigDirsForTesting()
        let ceCfgFirst = ClaudeExtraRoots.configDirsPayloadJSON(["/tmp/tokenbar-cfg-moved"])
        expect(ClaudeExtraRoots.recordAppliedConfigDirsAndReportChange(ceCfgFirst),
               "CE-CONFIG-MOVED installing an account list that differs reports a change")
        expect(!ClaudeExtraRoots.recordAppliedConfigDirsAndReportChange(ceCfgFirst),
               "CE-CONFIG-MOVED and installing the SAME list again reports none — the "
                   + "launch case, and the one that was paying for an unnecessary wake")
        expect(ClaudeExtraRoots.recordAppliedConfigDirsAndReportChange(
                   ClaudeExtraRoots.configDirsPayloadJSON(["/tmp/tokenbar-cfg-moved-2"])),
               "CE-CONFIG-MOVED a genuinely different list still reports a change, so "
                   + "the gate is a comparison rather than a one-shot latch")
        ClaudeExtraRoots.resetAppliedConfigDirsForTesting()

        // isRejectedRoot: home and root are refused; an ordinary subfolder is not.
        let ceHome = FileManager.default.homeDirectoryForCurrentUser.path
        expect(
            ClaudeExtraRoots.isRejectedRoot(ceHome) && ClaudeExtraRoots.isRejectedRoot("/")
                && !ClaudeExtraRoots.isRejectedRoot("\(ceHome)/.claude-work"),
            "isRejectedRoot refuses the home directory and filesystem root but not an "
                + "ordinary subfolder (mutation: refusing everything would make Settings' "
                + "add button always a no-op; refusing nothing would let a scan-everything "
                + "root through unwarned)")

        // isMissing: a real directory is present; a path that doesn't exist is missing.
        let ceTempDir = FileManager.default.temporaryDirectory.path
        expect(
            !ClaudeExtraRoots.isMissing(ceTempDir)
                && ClaudeExtraRoots.isMissing("\(ceTempDir)/tokenbar-selftest-does-not-exist"),
            "isMissing distinguishes a present directory from an absent path "
                + "(this is display-only — a missing path stays in the persisted list, "
                + "matching how vendor's own scan silently skips nonexistent roots "
                + "instead of dropping the user's configuration)")

        // MARK: - M3: a Claude card is addressed by (clientId, accountKey)

        // Two Claude accounts sharing `clientId == "claude"`, listed EXTRA
        // account first — deliberately not primary-first, so a mutation that
        // resolves "the first agent whose clientId matches" instead of "the
        // agent whose (clientId, accountKey) pair matches" changes the
        // answer rather than accidentally still passing by array order.
        // Distinct remaining percentages (primary 90, extra 20) so the
        // tighter one — the extra account — is never the one a naive
        // first-match would already happen to return.
        let m3ExtraKey = "/Users/x/.claude-extra"
        let m3PayloadJSON = """
        {"generatedAt":"now","publicationGeneration":9,"agents":[
          {"clientId":"claude","accountKey":"\(m3ExtraKey)","source":"oauth","updatedAt":"now",
           "windows":[{"cardId":"session.v1","label":"Session","usedPercent":80,"remainingPercent":20}]},
          {"clientId":"claude","source":"oauth","updatedAt":"now",
           "windows":[{"cardId":"session.v1","label":"Session","usedPercent":10,"remainingPercent":90}]}
        ]}
        """
        let m3Payload = try! JSONDecoder().decode(
            AgentUsagePayload.self, from: Data(m3PayloadJSON.utf8))

        // M3-a. Restore the historical `Dictionary(agents.map { ($0.clientId, $0) },
        // uniquingKeysWith: { first, _ in first })` — keying by clientId alone — to
        // watch this go red: the second account collapses into the first and the
        // count drops from 2 to 1.
        expect(
            AgentLimitsCard.snapshotsByRow(m3Payload.agents).count == 2,
            "M3-a two Claude agents with different accountKey both survive to the "
                + "rendered list, rather than one collapsing onto the other under a "
                + "clientId-only dictionary key")

        // M3-b. Change `expandedWithExtraAccounts` to test `visiblePrimaries.contains`
        // membership before deciding whether to emit the EXTRA row too (instead of
        // unconditionally appending every known id's extras) to watch this go red.
        let m3KnownIds = ["codex", "claude"]
        let m3VisiblePrimaries = Set(
            AgentLimitsCard.visible(
                m3KnownIds.map { AccountIdentity(clientId: $0, accountKey: nil) },
                hiddenRaw: "claude"
            ) { $0.clientId }.map(\.clientId))
        let m3Expanded = AgentLimitsCard.expandedWithExtraAccounts(
            known: m3KnownIds, visiblePrimaries: m3VisiblePrimaries, agents: m3Payload.agents)
        expect(
            m3Expanded.contains(AccountIdentity(clientId: "claude", accountKey: m3ExtraKey))
                && !m3Expanded.contains(AccountIdentity(clientId: "claude", accountKey: nil))
                && m3Expanded.contains(AccountIdentity(clientId: "codex", accountKey: nil)),
            "M3-b hiding the primary Claude account by clientId (\"claude\" in "
                + "limitsHiddenRaw) removes only the primary row, leaving the extra "
                + "account's row visible and codex untouched")

        // M3-c. Change `agent.clientId == parsed.clientId && agent.accountKey ==
        // accountKey` back to `agent.clientId == parsed.clientId` in both
        // `canonicalSelection` and `resolve` to watch this go red.
        let m3Auto = QuotaResolver.resolve(payload: m3Payload, selection: QuotaResolver.auto)
        expect(
            m3Auto?.clientId == "claude" && m3Auto?.accountKey == m3ExtraKey
                && m3Auto?.window.remainingPercent == 20,
            "M3-c auto mode can select the EXTRA account when it is the tighter of "
                + "the two, not only ever the first snapshot in the payload")
        let m3StoredSelection = QuotaResolver.selection(clientId: "claude", cardId: "session.v1")
        let m3ResolvedPrimary = QuotaResolver.resolve(
            payload: m3Payload, selection: m3StoredSelection, accountKey: nil)
        let m3ResolvedExtra = QuotaResolver.resolve(
            payload: m3Payload, selection: m3StoredSelection, accountKey: m3ExtraKey)
        expect(
            m3ResolvedPrimary?.accountKey == nil && m3ResolvedPrimary?.window.remainingPercent == 90
                && m3ResolvedExtra?.accountKey == m3ExtraKey
                && m3ResolvedExtra?.window.remainingPercent == 20,
            "M3-c resolving the identical stored \"claude|session.v1\" selection for "
                + "two different accountKey contexts returns the account each names, "
                + "not the same arbitrary snapshot both times")

        // M3-d. Drop the `agent.accountKey == tightest.accountKey` conjunct from the
        // fold's identity check (back to `(clientId, cardId)` alone) to watch this
        // go red: the primary's identically-carded window then matches the
        // tightest's `(clientId, cardId)` and is skipped as if it were the same
        // window, instead of being counted as an "other".
        let m3Summary = QuotaSummaryFold.build(payload: m3Payload)
        expect(
            m3Summary?.tightestAccountKey == m3ExtraKey && m3Summary?.otherWindows == 1,
            "M3-d QuotaSummary counts the primary account's identically-carded "
                + "window as an OTHER window rather than folding it into the tightest")

        // M3-e. Change `payload.agents.first(where: { $0.clientId == clientId &&
        // $0.accountKey == nil })` back to `payload.agents.first(where: { $0.clientId
        // == clientId })` in `WindowCardLoader.select` to watch this go red — the
        // extra account is listed FIRST in `m3Payload`, so an accountKey-blind match
        // resolves to its 20%-remaining window instead of the primary's 90%.
        let m3Selected = WindowCardLoader.select(
            payload: m3Payload, clientId: "claude", chosen: m3StoredSelection)
        expect(
            m3Selected?.window.remainingPercent == 90,
            "M3-e an existing \"tokenbar.window.card.selection\" value written before "
                + "a second account existed still resolves to the SAME primary window, "
                + "not whichever account the payload happens to list first")

        // M3-k. Two accounts' rows must be distinguishable.
        //
        // Both rows render `style.displayName` and nothing else, so two Claude
        // accounts on the same plan — or two whose profile lookup failed —
        // showed identical headings and identical detail text. The reader could
        // not tell which quota, or which error, belonged to which directory.
        //
        // Basename rather than path: this heading is the part of the app that
        // ends up in screenshots and the value is a directory under the user's
        // home.
        let m3kWork = AccountIdentity(clientId: "claude", accountKey: "/Users/someone/.claude-work").accountLabel
        let m3kOther = AccountIdentity(clientId: "claude", accountKey: "/Users/someone/.claude-other").accountLabel
        expect(
            AccountIdentity(clientId: "claude", accountKey: nil).accountLabel == nil
                && m3kWork == ".claude-work" && m3kWork != m3kOther
                && !(m3kWork?.contains("/Users") ?? true),
            "M3-k the primary row stays unqualified, an extra row is labelled by its basename, "
                + "two accounts differ, and no home path reaches the heading")

        // M3-l. And the Overview's one-line answer has to carry it too.
        //
        // `M3-k` covers the derivation; it cannot see a caller that has the
        // label available and renders the bare client name anyway, which is
        // what `QuotaSummaryLine.tightestRow` did. Auto picks the extra account
        // in `m3Payload` (that is what M3-c asserts), so this is the exact
        // sentence a user with two Claude subscriptions reads on the landing
        // tab, and with the qualifier dropped it names neither of them.
        //
        // Delete the `account` term from `tightestName`'s join to watch it go
        // red. The primary case is asserted beside it because a "fix" that
        // always appends something would satisfy the first assertion alone.
        let m3TightestName = m3Summary.map { QuotaSummaryLine.tightestName($0) }
        expect(
            m3TightestName?.contains(".claude-extra") == true,
            "M3-l the Overview's tightest line names the client but not which of "
                + "its two accounts the window belongs to")
        let m3PrimaryOnly = try! JSONDecoder().decode(
            AgentUsagePayload.self,
            from: Data("""
            {"generatedAt":"now","publicationGeneration":9,"agents":[
              {"clientId":"claude","source":"oauth","updatedAt":"now",
               "windows":[{"cardId":"session.v1","label":"Session","usedPercent":10,
                           "remainingPercent":90}]}
            ]}
            """.utf8))
        expect(
            QuotaSummaryFold.build(payload: m3PrimaryOnly)
                .map { QuotaSummaryLine.tightestName($0) }
                == ClientRegistry.style("claude").displayName,
            "M3-l a single-account install gained a qualifier on the tightest line")

        // M3-m. One Settings save must invalidate once, not twice.
        //
        // `commitClaudeExtraRoots` calls `apply` and its `UserDefaults` write
        // trips `AppDelegate`'s observer, which calls it again — the observer's
        // gate compares against a value only the observer updates, so it cannot
        // see the direct call. That was harmless while an apply merely
        // re-registered an identical list. It stopped being harmless once apply
        // began dropping the throttled payload and waking every poller: two of
        // those means one edit can issue two full provider rounds, each able to
        // spend 30 seconds on one account, against a provider that rate-limits.
        //
        // Asserted on the claim rather than through `apply`, which needs the
        // FFI and a real registry. Three properties, and the third is the one a
        // plausible wrong implementation gets wrong: a membership test over
        // everything ever applied would swallow the re-add below, leaving the
        // core scanning what the removal installed while Settings showed the
        // directory present.
        let m3mClaims: [Bool]? = awaitMainActorValue {
            ClaudeExtraRoots.resetApplyClaimForTesting()
            let claim = ClaudeExtraRoots.claimApplyForTesting
            let claims = [
                claim("A", "a"), // first
                claim("A", "a"), // the duplicate one save produces
                claim("B", "b"), // a genuinely different list
                claim("A", "a"), // removed, then added back
                claim("A", "different"), // only the account registry changed
            ]
            ClaudeExtraRoots.resetApplyClaimForTesting()
            return claims
        }
        expect(
            m3mClaims?[0] == true && m3mClaims?[1] == false,
            "M3-m the second apply for one save was not coalesced, so an edit "
                + "issues two provider rounds")
        expect(
            m3mClaims?[2] == true,
            "M3-m a genuinely different list was coalesced away, so the change "
                + "never reached the core")
        expect(
            m3mClaims?[3] == true,
            "M3-m removing a directory and adding it back was treated as a "
                + "duplicate, so the re-add never reached the core")
        // Either payload differing on its own is still a change: the scan roots
        // and the account registry are separate registries.
        expect(
            m3mClaims?[4] == true,
            "M3-m only one of the two payloads is compared, so a change to the "
                + "other is coalesced away")

        // M3-n. Two more Overview surfaces render only the client name, so two
        // accounts of one client read identically there too.
        //
        // Task A: `QuotaHistoryStripCard.row`/`tooltipLayer` and
        // `QuotaHeatmapCard.label`/picker compose the row text inline in a
        // `some View` body, which cannot be asserted directly — pulled out
        // into `QuotaHistoryStripCard.rowLabel` and the now-`static`
        // `QuotaHeatmapCard.label`, the same move `tightestName`'s doc
        // comment already explains for this exact reason.
        let m3nSummary = QuotaOverviewFold.summaries(windows: [
            (clientId: "claude", accountKey: m3ExtraKey, cardId: "session.v1",
             label: "Session", cycles: [
                QuotaCycle(
                    resetAtMs: 500_000, startMs: 400_000, usedPercent: 30,
                    sampleCount: 40, observedFraction: 0.9)]),
        ])[0]
        expect(
            QuotaHistoryStripCard.rowLabel(m3nSummary).contains(".claude-extra")
                && QuotaHistoryStripCard.rowLabel(m3nSummary).contains("Session"),
            "M3-n the history strip's row names the client and window but not "
                + "which of its two accounts the history belongs to")
        let m3nHeatmapWindow = QuotaHeatmapWindow(
            clientId: "claude", accountKey: m3ExtraKey, cardId: "session.v1",
            windowLabel: "Session", total: 30)
        expect(
            QuotaHeatmapCard.label(m3nHeatmapWindow).contains(".claude-extra")
                && QuotaHeatmapCard.label(m3nHeatmapWindow).contains("Session"),
            "M3-n the heatmap's picker names the client and window but not "
                + "which of its two accounts the grid belongs to")

        // Task B: `BurnWarning` carried only `clientId`, so `burnRow` rendered
        // the same text for either account. Two Claude agents, linear pace so
        // the expectation is arithmetic: both half elapsed, the EXTRA
        // account far ahead of its line (90 used against 50 expected) and the
        // primary only slightly ahead (55 against 50) — the extra account's
        // deficit must win, and the rendered label must name it.
        //
        // Delete the `account` term from `burnName`'s join (or drop
        // `accountKey` from the `BurnWarning` the fold builds) to watch this
        // go red.
        let m3nDuration: Int64 = 18_000
        let m3nResetIso = ISO8601DateFormatter().string(
            from: burnNow.addingTimeInterval(Double(m3nDuration) * 0.5))
        func m3nWindowJSON(accountKey: String?, used: Double, resetIso iso: String) -> String {
            let account = accountKey.map { "\"accountKey\":\"\($0)\"," } ?? ""
            return """
            {"clientId":"claude",\(account)"source":"oauth","updatedAt":"t","windows":[
             {"cardId":"session.v1","label":"Session","usedPercent":\(used),
              "remainingPercent":\(100 - used),"resetsAt":"\(iso)",
              "durationSeconds":\(m3nDuration),"windowMinutes":\(m3nDuration / 60),
              "paceStatus":{"state":"learningHistory","windowKey":"session.v1",
                            "durationSeconds":\(m3nDuration),"durationSource":"provider",
                            "completeCycles":1}}]}
            """
        }
        let m3nBurnPayload = try! JSONDecoder().decode(
            AgentUsagePayload.self,
            from: Data("""
            {"generatedAt":"t","publicationGeneration":1,"agents":[
              \(m3nWindowJSON(accountKey: m3ExtraKey, used: 90, resetIso: m3nResetIso)),
              \(m3nWindowJSON(accountKey: nil, used: 55, resetIso: m3nResetIso))
            ]}
            """.utf8))
        let m3nBurn = QuotaSummaryFold.build(
            payload: m3nBurnPayload, paceMode: .linear, now: burnNow)
        expect(
            m3nBurn?.burning?.accountKey == m3ExtraKey,
            "M3-n the fastest-burning window belongs to the EXTRA account, but "
                + "the warning does not record which account it came from")
        let m3nBurnLabel = m3nBurn?.burning.map { QuotaSummaryLine.burnName($0) }
        expect(
            m3nBurnLabel?.contains(".claude-extra") == true,
            "M3-n the burn-fastest line names the client but not which of its "
                + "two accounts is burning")
        // Single-account case, asserted separately: a "fix" that always
        // appends a qualifier would satisfy the assertion above alone.
        let m3nPrimaryBurn = QuotaSummaryFold.build(
            payload: burnPayload([(client: "claude", used: 80, elapsedFraction: 0.5)]),
            paceMode: .linear, now: burnNow)
        expect(
            m3nPrimaryBurn?.burning.map { QuotaSummaryLine.burnName($0) }
                == ClientRegistry.style("claude").displayName,
            "M3-n a single-account install gained a qualifier on the burn-fastest line")

        // M3-o. The quota side must be woken between the two setters, not after
        // both of them.
        //
        // `apply` installs two registries. `setClaudeConfigDirs` hands over a
        // list of strings; `setExtraScanPaths` probes every path with
        // `read_dir`, and a stalled network or external mount holds that for
        // the whole mount timeout — the case this feature exists to tolerate.
        // With the throttle drop and the wake behind BOTH setters, the quota
        // cards kept describing the previous account set for that entire
        // timeout, waiting on a probe whose answer they never consume.
        //
        // Observing an order means holding one side still, which is why
        // `install` takes its two setters as parameters: the scan setter here
        // blocks on a semaphore and never returns until the assertion is made.
        // It blocks `applyQueue`, never the main actor, or the wake it is
        // waiting for could not run and this would deadlock rather than fail.
        //
        // `configDirsJSON` here must genuinely differ from what
        // `resetAppliedConfigDirsForTesting` leaves as the baseline, or the
        // CE-CONFIG-MOVED gate this exercise now runs through would report no
        // change and the wake would never fire — this test would then be
        // asserting a deadlock timeout rather than the order it names.
        ClaudeExtraRoots.resetAppliedConfigDirsForTesting()
        let m3oConfigDirs = ClaudeExtraRoots.configDirsPayloadJSON(["/tmp/tokenbar-m3o"])
        let m3oWokeBeforeScan: Bool? = awaitMainActorValue {
            let gate = DispatchSemaphore(value: 0)
            let before = ClaudeExtraRoots.RegistryChange.epoch
            ClaudeExtraRoots.installForTesting(
                json: "{}", configDirsJSON: m3oConfigDirs,
                setConfigDirs: { _ in },
                setScanPaths: { _ in
                    gate.wait()
                    return nil
                },
                then: nil)
            var woke = false
            for _ in 0..<200 where !woke {
                try? await Task.sleep(nanoseconds: 10_000_000)
                woke = ClaudeExtraRoots.RegistryChange.epoch != before
            }
            gate.signal()
            ClaudeExtraRoots.resetApplyClaimForTesting()
            return woke
        }
        expect(
            m3oWokeBeforeScan == true,
            "M3-o the quota pollers were not woken until the scan-root probe "
                + "returned, so a stalled mount leaves the cards on the previous "
                + "account set for the whole filesystem timeout")

        // M3-o2. The mirror of M3-o, and the half that proves the gate GATES
        // rather than merely not breaking the case above. Re-installing the
        // SAME account list `install` just recorded as applied must not wake
        // anything: that is the launch call and every no-op Settings save,
        // and before this fix it woke every poller and dropped the quota
        // throttle for a registry identical to the one already installed.
        let m3oNotWoken: Bool? = awaitMainActorValue {
            let before = ClaudeExtraRoots.RegistryChange.epoch
            let done = ThrottleGate()
            ClaudeExtraRoots.installForTesting(
                json: "{}", configDirsJSON: m3oConfigDirs,
                setConfigDirs: { _ in },
                setScanPaths: { _ in nil },
                then: { _ in Task { await done.open() } })
            await done.wait()
            ClaudeExtraRoots.resetApplyClaimForTesting()
            return ClaudeExtraRoots.RegistryChange.epoch == before
        }
        expect(
            m3oNotWoken == true,
            "M3-o2 re-applying the SAME account list wakes no poller, so an "
                + "unchanged registry — the launch case above all — costs "
                + "nothing on the quota side")
        ClaudeExtraRoots.resetAppliedConfigDirsForTesting()

        // M3-o3. The relaunch case `appliedConfigDirsJSON` alone cannot see.
        //
        // A user with a persisted extra account quits and reopens the app.
        // `apply()` reads the SAME account list this new process's persisted
        // marker already recorded from the PREVIOUS process — so the
        // persisted comparison reports no change — while the Rust registry in
        // THIS process starts genuinely empty. `TrayAnimator` starts polling
        // immediately at launch and can race that first install, reading only
        // the primary account; without a wake, nothing corrects that reading
        // for up to five minutes. Set up exactly that: the persisted marker
        // already agrees with what is about to install, and this process has
        // installed nothing yet.
        let m3oRelaunch = ClaudeExtraRoots.configDirsPayloadJSON(["/tmp/tokenbar-m3o-relaunch"])
        let m3oRelaunchWoke: Bool? = awaitMainActorValue {
            ClaudeExtraRoots.resetAppliedConfigDirsForTesting()
            _ = ClaudeExtraRoots.recordAppliedConfigDirsAndReportChange(m3oRelaunch)
            ClaudeExtraRoots.resetInstalledConfigDirsThisProcessForTesting()
            let before = ClaudeExtraRoots.RegistryChange.epoch
            let done = ThrottleGate()
            ClaudeExtraRoots.installForTesting(
                json: "{}", configDirsJSON: m3oRelaunch,
                setConfigDirs: { _ in },
                setScanPaths: { _ in nil },
                then: { _ in Task { await done.open() } })
            await done.wait()
            ClaudeExtraRoots.resetApplyClaimForTesting()
            return ClaudeExtraRoots.RegistryChange.epoch != before
        }
        expect(
            m3oRelaunchWoke == true,
            "M3-o3 the first install of a process wakes pollers even when the "
                + "persisted marker already matches, because the Rust registry "
                + "does not persist across a relaunch the way the marker does")

        // M3-o4. The same first-install case, but with nothing configured.
        // Waking pollers for an empty registry that stays empty corrects
        // nothing and reintroduces exactly the cost this fix removes, so the
        // "first install" exemption applies only to a non-empty list.
        let m3oEmptyRelaunchWoke: Bool? = awaitMainActorValue {
            ClaudeExtraRoots.resetAppliedConfigDirsForTesting()
            ClaudeExtraRoots.resetInstalledConfigDirsThisProcessForTesting()
            let before = ClaudeExtraRoots.RegistryChange.epoch
            let done = ThrottleGate()
            ClaudeExtraRoots.installForTesting(
                json: "{}", configDirsJSON: ClaudeExtraRoots.configDirsPayloadJSON([]),
                setConfigDirs: { _ in },
                setScanPaths: { _ in nil },
                then: { _ in Task { await done.open() } })
            await done.wait()
            ClaudeExtraRoots.resetApplyClaimForTesting()
            let woke = ClaudeExtraRoots.RegistryChange.epoch != before
            ClaudeExtraRoots.resetInstalledConfigDirsThisProcessForTesting()
            return woke
        }
        expect(
            m3oEmptyRelaunchWoke == false,
            "M3-o4 a first install with no accounts configured does not wake "
                + "pollers — there is nothing for the extra wake to correct")
        ClaudeExtraRoots.resetAppliedConfigDirsForTesting()

        // M3-p. A payload fetched under the previous registry must not be
        // applied, only dropped.
        //
        // `AgentUsageThrottle.invalidate()` deliberately hands an in-flight
        // result to the waiter that asked for it — the caller asked a question
        // and gets an answer — so the poll receives a payload built for the
        // account set that has since changed. Applying it publishes the old set
        // to the cards, the Auto gauge and a persisted scalar, and the
        // correction is a whole network round away.
        //
        // Driven through the real `pollAgentUsage` rather than asserting the
        // comparison, because the comparison is `==` and the defect was never
        // in the comparison — it was in applying before making it.
        //
        // The generations are deliberately far above every other fixture's.
        // `AgentUsagePublicationState.resolve` returns the PREVIOUSLY published
        // payload for any candidate whose generation is lower than the highest
        // this process has seen, and other cases publish generation 9 — so a
        // low-numbered fixture here is silently replaced and the assertion
        // measures another case's payload rather than this one's. The first
        // version of this check did exactly that and failed against correct
        // code.
        let m3pApplied: String? = awaitMainActorValue {
            let staleJSON = """
            {"generatedAt":"stale","publicationGeneration":90001,"agents":[
              {"clientId":"claude","source":"oauth","updatedAt":"stale","windows":[]}
            ]}
            """
            let freshJSON = """
            {"generatedAt":"fresh","publicationGeneration":90002,"agents":[
              {"clientId":"claude","source":"oauth","updatedAt":"fresh","windows":[]}
            ]}
            """
            let decoder = JSONDecoder()
            let source = RegistryRaceSource(
                stale: try! decoder.decode(
                    AgentUsagePayload.self, from: Data(staleJSON.utf8)),
                fresh: try! decoder.decode(
                    AgentUsagePayload.self, from: Data(freshJSON.utf8)))
            let model = DashboardModel(source: source, initialYear: nil)
            let poll = Task { await model.pollAgentUsage() }
            // Wait for the SECOND fetch to start and then look, while it is
            // still held. Looking after it finishes measures nothing: the fresh
            // payload lands either way, and the question is whether the stale
            // one was published before it.
            for _ in 0..<200 {
                if source.fetches >= 2 { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
            let published = model.agentUsage?.generatedAt
            let fetches = source.fetches
            source.release()
            poll.cancel()
            // Put the process-wide publication floor back where it was, or
            // these generations reject every later case's payload and hand it
            // this one instead — see `resetForTesting`.
            AgentUsagePublicationCoordinator.resetForTesting()
            // Two values in one, so neither can pass vacuously: `nil` published
            // is only meaningful if the loop actually got as far as a second
            // fetch, and a second fetch is only meaningful if nothing was
            // published before it.
            guard fetches >= 2 else { return "never-refetched" }
            return published ?? "dropped"
        } ?? nil
        expect(
            m3pApplied == "dropped",
            "M3-p the poll published a payload built for the previous account "
                + "set instead of dropping it and refetching")

        // M3-j. An account change must invalidate the throttled payload.
        //
        // This is the layer the three previous attempts at "the card outlives
        // its account" all missed. Waking the poll immediately achieves nothing
        // while `AgentUsageThrottle` answers the woken fetch from a payload it
        // cached before the change: the floor is 50 seconds, which is exactly
        // the delay the user reported as "it does update, but only after a
        // while".
        //
        // The floor is right and stays — it protects an endpoint that
        // rate-limits from repeated identical questions. An account being added
        // or removed is a DIFFERENT question, and the cached answer describes a
        // set of accounts that no longer exists.
        let m3jRefetched: Bool? = awaitMainActorValue { () async throws -> Bool in
            let throttle = AgentUsageThrottle()
            let clock = ThrottleClock(Date(timeIntervalSince1970: 2_000_000))
            let counter = ThrottleCallCounter()
            let empty = try JSONDecoder().decode(
                AgentUsagePayload.self,
                from: Data(#"{"generatedAt":"2026-08-23T00:00:00Z","agents":[]}"#.utf8))
            let fetch: @Sendable () async throws -> AgentUsagePayload = {
                await counter.bump()
                return empty
            }
            _ = try await throttle.payload(now: { clock.value }, fetch: fetch)
            // Well inside the floor: without an invalidation this is served
            // from cache and the counter does not move.
            _ = try await throttle.payload(now: { clock.value }, fetch: fetch)
            let cachedCalls = await counter.count
            await throttle.invalidate()
            _ = try await throttle.payload(now: { clock.value }, fetch: fetch)
            let afterInvalidate = await counter.count
            return cachedCalls == 1 && afterInvalidate == 2
        }
        expect(
            m3jRefetched == true,
            "M3-j an account change did not force a fresh fetch, so the cards keep the old set "
                + "for the rest of the throttle floor")

        // M3-h. A registry change must wake the quota poll, not wait it out.
        //
        // The mirror of every other M3 gate: those assert that state is
        // ESTABLISHED — two accounts appear, both survive, each resolves to its
        // own series. None asserted what happens when an account goes away, and
        // that is exactly the case that shipped broken: the card stayed for up
        // to a minute describing an account the engine no longer fetched.
        //
        // Keying a view's `.task` on the generation was not enough, because it
        // only holds while that view is alive — popover closed, or the separate
        // Settings window in use, and nobody was observing. This asserts the
        // mechanism that does not depend on a view: the sleep itself returns
        // early when the registry moves.
        let m3hWoken: Bool? = awaitMainActorValue {
            let epoch = ClaudeExtraRoots.RegistryChange.epoch
            let start = Date()
            let slept = Task { @MainActor in
                await ClaudeExtraRoots.RegistryChange.sleep(upTo: 60, since: epoch)
                return Date().timeIntervalSince(start)
            }
            // Let the sleeper register before signalling, or the signal lands
            // with no waiter and this measures nothing.
            try? await Task.sleep(nanoseconds: 50_000_000)
            ClaudeExtraRoots.RegistryChange.signal()
            return await slept.value < 5
        }
        expect(
            m3hWoken == true,
            "M3-h a registry change did not wake the quota poll before its 60s timeout")

        // M3-i. The signal must be STICKY. The quota poll spends most of each
        // cycle inside a network fetch, so a removal signals while the loop is
        // busy far more often than while it sleeps. A fire-and-forget wake-up
        // drops that one, and the card stays for the full sixty seconds — which
        // is exactly what shipped and what the user saw: "it does go away, but
        // only after a while".
        let m3iSticky: Bool? = awaitMainActorValue {
            // Observed BEFORE the change, the way the poll reads it before its
            // fetch.
            let epoch = ClaudeExtraRoots.RegistryChange.epoch
            ClaudeExtraRoots.RegistryChange.signal()
            let start = Date()
            await ClaudeExtraRoots.RegistryChange.sleep(upTo: 60, since: epoch)
            return Date().timeIntervalSince(start) < 1
        }
        expect(
            m3iSticky == true,
            "M3-i a change that landed before the sleep was dropped, so the poll waited it out")

        // And the timeout still applies when nothing signals, so a missed
        // signal degrades to the old cadence rather than hanging the loop.
        let m3hTimedOut: Bool? = awaitMainActorValue {
            let start = Date()
            await ClaudeExtraRoots.RegistryChange.sleep(
                upTo: 0.2, since: ClaudeExtraRoots.RegistryChange.epoch)
            return Date().timeIntervalSince(start) >= 0.15
        }
        expect(
            m3hTimedOut == true,
            "M3-h the sleep returned before its timeout with nothing signalling")

        // M3-g. The quota lens's row ids must use the same key as the grids
        // they select into. `QuotaHeatmapCard` looks up `heatmaps[$0.id]`, so a
        // two-part id against a three-part grid key finds nothing: the extra
        // account's heatmap would be blank, and both accounts' picker entries
        // would carry the same id in an `Identifiable` list.
        //
        // The primary's id must stay byte-identical to the two-part form every
        // stored and in-memory key has always used, or the same lookup breaks
        // for users who have no second account at all.
        let m3gPrimary = AccountIdentity(clientId: "claude", accountKey: nil)
        let m3gExtra = AccountIdentity(
            clientId: "claude", accountKey: "/Users/someone/.claude-work")
        expect(
            m3gPrimary.windowKey(cardId: "session.v1") == "claude|session.v1",
            "M3-g the primary's window key keeps the two-part shape everything already stores")
        expect(
            m3gExtra.windowKey(cardId: "session.v1") != m3gPrimary.windowKey(cardId: "session.v1"),
            "M3-g two accounts offering the same window collapse onto one key")

        let m3gSummaries = QuotaOverviewFold.summaries(windows: [
            (clientId: "claude", accountKey: nil, cardId: "session.v1", label: "Session",
             cycles: [qoCycle(1_000, 40)]),
            (clientId: "claude", accountKey: "/Users/someone/.claude-work",
             cardId: "session.v1", label: "Session", cycles: [qoCycle(1_000, 70)]),
        ])
        expect(
            Set(m3gSummaries.map(\.id)).count == 2,
            "M3-g two accounts' summaries share one id, so a list keyed on it renders one")
        expect(
            m3gSummaries.first(where: { $0.accountKey == nil })?.id == "claude|session.v1",
            "M3-g the primary's summary id drifted from the shape the grids are stored under")

        let m3gHeatmapIds = Set([
            QuotaHeatmapWindow(
                clientId: "claude", cardId: "session.v1", windowLabel: "Session", total: 1
            ).id,
            QuotaHeatmapWindow(
                clientId: "claude", accountKey: "/Users/someone/.claude-work",
                cardId: "session.v1", windowLabel: "Session", total: 1
            ).id,
        ])
        expect(
            m3gHeatmapIds.count == 2,
            "M3-g two accounts' heatmap picker entries share one id")

        // M3-f. Change `windowCurves`/`quotaHeatmaps` back to a bare
        // "clientId|cardId" key (dropping `accountKey`) to watch this go red: the
        // second write silently overwrites the first, so both dictionaries end up
        // with one entry instead of two.
        let m3fNow = Int64(Date().timeIntervalSince1970)
        let m3fReset = m3fNow + 3_600
        let m3fResetIso = ISO8601DateFormatter().string(
            from: Date(timeIntervalSince1970: Double(m3fReset)))
        let m3fPayload = try! JSONDecoder().decode(
            AgentUsagePayload.self,
            from: Data("""
                {"generatedAt":"now","publicationGeneration":11,"agents":[
                  \(m3nWindowJSON(accountKey: m3ExtraKey, used: 80, resetIso: m3fResetIso)),
                  \(m3nWindowJSON(accountKey: nil, used: 10, resetIso: m3fResetIso))
                ]}
                """.utf8))
        let m3fPrimaryCurve = windowCurve(
            resetAtSecs: m3fReset, durationSecs: 18_000, at: [(m3fNow - 3_000, 4)])
        let m3fExtraCurve = windowCurve(
            resetAtSecs: m3fReset, durationSecs: 18_000, at: [(m3fNow - 3_000, 77)])
        let m3fResult: (curveKeys: Int, curvesDiffer: Bool, heatmapKeys: Int)? = awaitMainActorValue {
            let src = WindowScanCountingSource(payload: m3fPayload)
            src.curveByAccount = [nil: m3fPrimaryCurve, m3ExtraKey: m3fExtraCurve]
            let m = DashboardModel(source: src, initialYear: nil)
            m.windowCardClients = ["claude"]
            let poll = Task { await m.pollAgentUsage() }
            var spins = 0
            while !m.agentUsageAttempted, spins < 2_000 {
                try? await Task.sleep(nanoseconds: 1_000_000)
                spins += 1
            }
            poll.cancel()
            _ = await poll.value
            let curveValues = Set(m.windowCurves.values.map { $0.map(\.usedPercent) })
            return (m.windowCurves.count, curveValues.count == 2, m.quotaHeatmaps.count)
        }
        expect(
            m3fResult?.curveKeys == 2 && m3fResult?.curvesDiffer == true
                && m3fResult?.heatmapKeys == 2,
            "M3-f two accounts' window curves and heatmaps land under two distinct "
                + "keys with two distinct sets of readings, rather than one account's "
                + "data silently overwriting the other's under a shared "
                + "\"clientId|cardId\" key")


        // QH-RUNS-A5. The dashboard's qualifying-window filter applies the same
        // rule as the pooled aggregate and the live row. Three completed
        // cycles, the third a merged [0,3,0,3]: it carries 6 points over two
        // rises, which clears a single-rise bar and fails a two-rise one. With
        // it rejected the window has two admitted cycles, not three, and
        // `rebuildQuotaEquivalences` builds no row for it at all — not a
        // `.tooFewCycles` row, no key. Drop the run factor from
        // `deltaQualifies` and the key appears.
        func runsCurve(cycles: [[Double]]) -> QuotaCurve {
            var points: [String] = []
            var oldest = Int64.max, newest = Int64.min
            for (index, readings) in cycles.enumerated() {
                let reset = m3fNow - Int64(cycles.count - index) * 18_000
                // Spread from 17,000s before reset towards 1,000s before, so
                // every cycle's observed fraction is about 16,000 / 18,000.
                // Integer division means a 4-reading cycle ends a second or two
                // short of -1,000, so coverage is derived from the points
                // actually emitted — the decoder rejects a coverage block that
                // does not match them.
                let step = readings.count > 1 ? 16_000 / (readings.count - 1) : 0
                for (slot, pct) in readings.enumerated() {
                    let at = reset - 17_000 + Int64(slot * step)
                    oldest = min(oldest, at); newest = max(newest, at)
                    points.append("""
                        {"sampledAt":\(at),"usedPercent":\(pct),
                         "resetAt":\(reset),"durationSeconds":18000,
                         "durationSource":"provider","origin":"liveV3",
                         "isActiveGroup":false}
                        """)
                }
            }
            let json = """
                {"points":[\(points.joined(separator: ","))],
                 "coverage":{"oldestSampledAt":\(oldest),
                             "newestSampledAt":\(newest),
                             "sampleCount":\(points.count)},
                 "activeResetAt":null,"generation":11}
                """
            return try! JSONDecoder().decode(QuotaCurve.self, from: Data(json.utf8))
        }
        let runsA5Keys: [String]? = awaitMainActorValue {
            let src = WindowScanCountingSource(payload: m3fPayload)
            src.curveByAccount = [
                nil: runsCurve(cycles: [[0, 40], [0, 45], [0, 3, 0, 3]]),
                m3ExtraKey: runsCurve(cycles: [[0, 20], [0, 25], [0, 30]]),
            ]
            let m = DashboardModel(source: src, initialYear: nil)
            m.windowCardClients = ["claude"]
            let poll = Task { await m.pollAgentUsage() }
            var spins = 0
            while !m.agentUsageAttempted, spins < 2_000 {
                try? await Task.sleep(nanoseconds: 1_000_000)
                spins += 1
            }
            poll.cancel()
            _ = await poll.value
            m.windowUsageClient = nil
            m.quotaLensAllAgents = true
            await m.refreshWindowUsage()
            return Array(m.quotaEquivalences.keys).sorted()
        }
        expect(runsA5Keys?.contains("claude|session.v1") == false,
               "QH-RUNS-A5 a window whose third cycle is a merged two-rise 6 does not "
                   + "qualify at the dashboard filter, so no equivalence row is built for it")
        expect(runsA5Keys?.contains("claude|\(m3ExtraKey)|session.v1") == true,
               "QH-RUNS-A5 and the control window with three clean cycles does qualify, "
                   + "so the absence above is the filter and not a broken fixture")

        // M3-q. The defect issue #258 reports, at the layer this side owns:
        // every account's equivalence row folding one shared scan.
        //
        // Asserted on WHICH accounts were scanned, not on how many. A count
        // alone passes when the model issues two scans for the primary and none
        // for the extra account, which is the shape a wrong selector produces.
        // Point `unionScan(for:)` at `Self.cardAccountKey` and this goes red.
        // Two readings per cycle: the window opens at 0 and ends at the
        // account's figure, which is the `runsCurve` shape with the first
        // reading fixed.
        func m3qCurve(accountUsed: [Double]) -> QuotaCurve {
            runsCurve(cycles: accountUsed.map { [0, $0] })
        }
        let m3qAccounts: [String?]? = awaitMainActorValue {
            let src = WindowScanCountingSource(payload: m3fPayload)
            src.curveByAccount = [
                nil: m3qCurve(accountUsed: [40, 45, 50]),
                m3ExtraKey: m3qCurve(accountUsed: [20, 25, 30]),
            ]
            let m = DashboardModel(source: src, initialYear: nil)
            m.windowCardClients = ["claude"]
            let poll = Task { await m.pollAgentUsage() }
            var spins = 0
            while !m.agentUsageAttempted, spins < 2_000 {
                try? await Task.sleep(nanoseconds: 1_000_000)
                spins += 1
            }
            poll.cancel()
            _ = await poll.value
            // The all-agent lens: no card on screen, only the estimates.
            m.windowUsageClient = nil
            m.quotaLensAllAgents = true
            src.scans = 0
            src.scannedAccounts = []
            await m.refreshWindowUsage()
            return src.scannedAccounts
        }
        // The same run again, this time serving each account a DIFFERENT set of
        // rows, so the estimate itself has to differ. `m3qAccounts` above
        // observes which scans were issued; only this observes which one each
        // row read, and a selector that issued two scans and then folded the
        // primary's into both rows would pass the first and fail here.
        func m3qMessage(atSecs: Int64, cost: Double) -> WindowMessage {
            try! JSONDecoder().decode(WindowMessage.self, from: Data("""
            {"timestamp":\(atSecs * 1000),"client":"claude",
             "providerId":"anthropic","modelId":"claude-opus-5",
             "input":\(Int(cost * 1_000_000)),"output":0,"cacheRead":0,
             "cacheWrite":0,"reasoning":0,"cost":\(cost),"isTurnStart":true}
            """.utf8))
        }
        // The fold attributes through the user's declarations, and an
        // undeclared row is `.unassigned` — which would leave both accounts
        // reporting "none of it recorded here" and make the comparison below
        // vacuous. Installed and restored around the block, the same way the
        // attribution card's case above does it.
        let m3qSavedAttribution = UserDefaults.standard.object(
            forKey: UsageAttribution.confirmedKey)
        UserDefaults.standard.set(
            UsageAttribution.confirmedRaw(
                updating: nil,
                record: UsageAttribution.Record(
                    client: "claude", provider: "anthropic", model: nil,
                    state: .assigned("claude"))),
            forKey: UsageAttribution.confirmedKey)
        defer {
            UserDefaults.standard.set(
                m3qSavedAttribution, forKey: UsageAttribution.confirmedKey)
        }
        func m3qRowsFor(cost: Double) -> [WindowMessage] {
            [63_000, 45_000, 27_000].map { m3qMessage(atSecs: m3fNow - $0, cost: cost) }
        }
        let m3qPrimaryRows = m3qRowsFor(cost: 100)
        let m3qExtraRows = m3qRowsFor(cost: 1)
        let m3qRows: [String: WindowEquivalence.Row]? = awaitMainActorValue {
            let src = WindowScanCountingSource(payload: m3fPayload)
            // The SAME quota movement for both accounts, deliberately. The
            // denominators being equal leaves the rows differing only by which
            // scan each one folded, which is the property under test; two
            // different curves would also produce two different rows and prove
            // nothing about the scan.
            src.curveByAccount = [
                nil: m3qCurve(accountUsed: [40, 45, 50]),
                m3ExtraKey: m3qCurve(accountUsed: [40, 45, 50]),
            ]
            // One row inside EVERY admitted cycle's observed span, because an
            // estimate is a fold across all of them and a cycle with no usage
            // reports as unaccounted rather than as a number.
            //
            // Two orders of magnitude apart between the accounts, so no
            // rounding can make the two rows agree by accident.
            src.messagesByAccount = [
                "": m3qPrimaryRows,
                m3ExtraKey: m3qExtraRows,
            ]
            let m = DashboardModel(source: src, initialYear: nil)
            m.windowCardClients = ["claude"]
            let poll = Task { await m.pollAgentUsage() }
            var spins = 0
            while !m.agentUsageAttempted, spins < 2_000 {
                try? await Task.sleep(nanoseconds: 1_000_000)
                spins += 1
            }
            poll.cancel()
            _ = await poll.value
            m.windowUsageClient = nil
            m.quotaLensAllAgents = true
            await m.refreshWindowUsage()
            return m.quotaEquivalences
        }
        func m3qCost(_ row: WindowEquivalence.Row?) -> Double? {
            switch row {
            case let .ratio(_, cost, _): return cost
            case let .costOnly(cost, _): return cost
            default: return nil
            }
        }
        let m3qPrimaryRow = m3qRows?["claude|session.v1"]
        let m3qExtraRow = m3qRows?["claude|\(m3ExtraKey)|session.v1"]
        expect(
            m3qCost(m3qPrimaryRow) != nil && m3qCost(m3qExtraRow) != nil,
            "M3-q both accounts produce a priced estimate, so the comparison "
                + "below is between two real numbers rather than a nil and a "
                + "number, which would pass while measuring nothing")
        // The RATIO, not two pinned floats. The fixture serves the primary
        // rows costing 100x the extra account's, so a hundredfold gap is the
        // property; the absolute figures are an artefact of the delta values
        // and would have to be re-pinned every time the fixture moved.
        let m3qRatio = zip([m3qCost(m3qPrimaryRow)], [m3qCost(m3qExtraRow)])
            .compactMap { primary, extra -> Double? in
                guard let primary, let extra, extra > 0 else { return nil }
                return primary / extra
            }
            .first
        expect(
            (m3qRatio.map { abs($0 - 100) < 0.001 }) == true,
            "M3-q each account's estimate is built from its OWN account's rows; "
                + "reading one shared scan gives both accounts the same "
                + "numerator, which is what issue #258 reports")
        expect(
            Set((m3qAccounts ?? []).map { $0 ?? "" }) == Set(["", m3ExtraKey]),
            "M3-q each account's equivalence reads a scan of its OWN transcripts; "
                + "one shared scan divides every account's usage by each account's "
                + "own quota movement")
        expect(
            (m3qAccounts ?? []).count == 2,
            "M3-q the two accounts are scanned once each, not once per window")

        if failures > 0 {
            print("\(failures) selftest check(s) failed")
            exit(1)
        }
        print("selftest passed")
        exit(0)
    }
}
