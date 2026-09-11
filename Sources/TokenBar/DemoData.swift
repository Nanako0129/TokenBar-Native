import Foundation
import TokenBarCore

/// Deterministic synthetic usage for the hidden `--demo` mode. The fixture is
/// rebuilt on each source read so its rolling current-year window follows the
/// local day, while every surface still derives from one set of client rows.
enum DemoData {
    static var payload: UsagePayload { payload(for: nil) }
    static var modelReport: ModelReport { modelReport(for: nil) }
    static var hourlyReport: HourlyReport { hourlyReport(for: nil, clients: nil) }
    static var agentsReport: AgentsReport { agentsReport(for: nil, clients: nil) }
    static var agentUsage: AgentUsagePayload { makeAgentUsage() }
    static var trace: [TraceBucket] { trace(windowSecs: 600) }
    static var tokensPerMin: Double {
        trace(windowSecs: 600).reduce(0) { $0 + $1.tokensPerMin }
    }

    static func payload(
        for year: String?, today: String = Format.todayKey()
    ) -> UsagePayload {
        let fixture = makeFixture(year: year, today: today)
        let json: [String: Any] = [
            "meta": [
                "generatedAt": "\(fixture.end)T12:00:00Z",
                "version": "demo",
                "dateRange": ["start": fixture.start, "end": fixture.end],
            ],
            "summary": [
                "totalTokens": fixture.allTotals.total,
                "totalCost": fixture.allTotals.cost,
                "totalDays": fixture.dates.count,
                "activeDays": fixture.dates.count,
                "averagePerDay": fixture.allTotals.cost / Double(fixture.dates.count),
                "maxCostInSingleDay": fixture.maxDayCost,
                "clients": ClientRegistry.allIds,
                "models": ClientRegistry.allIds.map { "demo-\($0)" },
            ],
            "years": fixture.yearMetadata,
            "contributions": fixture.contributionJSON,
        ]
        return decode(json, as: UsagePayload.self)
    }

    static func modelReport(
        for year: String?, today: String = Format.todayKey()
    ) -> ModelReport {
        let fixture = makeFixture(year: year, today: today)
        let entries = ClientRegistry.allIds.map { id in
            let totals = fixture.clientTotals[id]!
            return [
                "client": id,
                "model": "demo-\(id)",
                "provider": "demo",
                "input": totals.input,
                "output": totals.output,
                "cacheRead": totals.cacheRead,
                "cacheWrite": totals.cacheWrite,
                "reasoning": totals.reasoning,
                "total": totals.total,
                "messageCount": totals.messages,
                "cost": totals.cost,
                "msPer1kTokens": 1.25,
            ] as [String: Any]
        }
        let json: [String: Any] = [
            "entries": entries,
            "totalInput": fixture.allTotals.input,
            "totalOutput": fixture.allTotals.output,
            "totalCacheRead": fixture.allTotals.cacheRead,
            "totalCacheWrite": fixture.allTotals.cacheWrite,
            "totalMessages": fixture.allTotals.messages,
            "totalCost": fixture.allTotals.cost,
        ]
        return decode(json, as: ModelReport.self)
    }

    static func hourlyReport(
        for year: String?, clients: [String]?, today: String = Format.todayKey()
    ) -> HourlyReport {
        let fixture = makeFixture(year: year, today: today)
        let allowed = clientFilter(clients)
        var buckets: [String: HourlyTotals] = [:]
        for (dayIndex, rows) in fixture.rowsByDay.enumerated() {
            for (clientIndex, row) in rows.enumerated() where allowed.contains(row.client) {
                let hour = 8 + ((clientIndex + dayIndex) % 10)
                let key = "\(row.date) \(String(format: "%02d:00", hour))"
                var bucket = buckets[key] ?? HourlyTotals()
                bucket.add(row)
                buckets[key] = bucket
            }
        }

        let entries = buckets.keys.sorted().map { hour in
            let bucket = buckets[hour]!
            return [
                "hour": hour,
                "clients": bucket.clients.sorted(),
                "models": bucket.models.sorted(),
                "input": bucket.input,
                "output": bucket.output,
                "cacheRead": bucket.cacheRead,
                "cacheWrite": bucket.cacheWrite,
                "reasoning": bucket.reasoning,
                "total": bucket.total,
                "messageCount": bucket.messages,
                "turnCount": bucket.turns,
                "cost": bucket.cost,
            ] as [String: Any]
        }
        let totalCost = buckets.values.reduce(0.0) { $0 + $1.cost }
        return decode(
            ["entries": entries, "totalCost": totalCost],
            as: HourlyReport.self)
    }

    static func agentsReport(
        for year: String?, clients: [String]?, today: String = Format.todayKey()
    ) -> AgentsReport {
        let fixture = makeFixture(year: year, today: today)
        let allowed = clientFilter(clients)
        let entries = ClientRegistry.allIds.compactMap { id -> [String: Any]? in
            guard allowed.contains(id), let totals = fixture.clientTotals[id] else { return nil }
            return [
                "agent": "Demo Main · \(id)",
                "clients": [id],
                "input": totals.input,
                "output": totals.output,
                "cacheRead": totals.cacheRead,
                "cacheWrite": totals.cacheWrite,
                "reasoning": totals.reasoning,
                "total": totals.total,
                "cost": totals.cost,
                "messages": totals.messages,
            ] as [String: Any]
        }
        let totalCost = entries.reduce(0.0) { partial, entry in
            partial + (entry["cost"] as? Double ?? 0)
        }
        let totalMessages = entries.reduce(0) { partial, entry in
            partial + (entry["messages"] as? Int ?? 0)
        }
        return decode(
            [
                "entries": entries,
                "totalCost": totalCost,
                "totalMessages": totalMessages,
            ],
            as: AgentsReport.self)
    }

    static func trace(windowSecs: Int64) -> [TraceBucket] {
        _ = windowSecs
        let fixture = makeFixture(year: nil, today: Format.todayKey())
        let buckets = ClientRegistry.allIds.map { id in
            let total = fixture.clientTotals[id]?.total ?? 1
            let tokens = max(1, total / 10)
            return [
                "client": id,
                "agent": "Demo Main",
                "model": "demo-\(id)",
                "tokens": tokens,
                "messages": 1,
                "tokens_per_min": Double(tokens) / 10.0,
            ] as [String: Any]
        }
        return decode(buckets, as: [TraceBucket].self)
    }

    private struct ClientRow {
        let date: String
        let client: String
        let model: String
        let input: Int64
        let output: Int64
        let cacheRead: Int64
        let cacheWrite: Int64
        let reasoning: Int64
        let cost: Double
        let messages: Int

        var total: Int64 {
            input
                .saturatingAdding(output)
                .saturatingAdding(cacheRead)
                .saturatingAdding(cacheWrite)
                .saturatingAdding(reasoning)
        }

        var json: [String: Any] {
            [
                "client": client,
                "modelId": model,
                "providerId": "demo",
                "tokens": [
                    "input": input,
                    "output": output,
                    "cacheRead": cacheRead,
                    "cacheWrite": cacheWrite,
                    "reasoning": reasoning,
                ],
                "cost": cost,
                "messages": messages,
            ]
        }
    }

    private struct Totals {
        var input: Int64 = 0
        var output: Int64 = 0
        var cacheRead: Int64 = 0
        var cacheWrite: Int64 = 0
        var reasoning: Int64 = 0
        var cost = 0.0
        var messages = 0

        var total: Int64 {
            input
                .saturatingAdding(output)
                .saturatingAdding(cacheRead)
                .saturatingAdding(cacheWrite)
                .saturatingAdding(reasoning)
        }

        mutating func add(_ row: ClientRow) {
            input = input.saturatingAdding(row.input)
            output = output.saturatingAdding(row.output)
            cacheRead = cacheRead.saturatingAdding(row.cacheRead)
            cacheWrite = cacheWrite.saturatingAdding(row.cacheWrite)
            reasoning = reasoning.saturatingAdding(row.reasoning)
            cost += row.cost
            messages += row.messages
        }
    }

    private struct HourlyTotals {
        var clients = Set<String>()
        var models = Set<String>()
        var input: Int64 = 0
        var output: Int64 = 0
        var cacheRead: Int64 = 0
        var cacheWrite: Int64 = 0
        var reasoning: Int64 = 0
        var messages = 0
        var turns = 0
        var cost = 0.0

        var total: Int64 {
            input
                .saturatingAdding(output)
                .saturatingAdding(cacheRead)
                .saturatingAdding(cacheWrite)
                .saturatingAdding(reasoning)
        }

        mutating func add(_ row: ClientRow) {
            clients.insert(row.client)
            models.insert(row.model)
            input = input.saturatingAdding(row.input)
            output = output.saturatingAdding(row.output)
            cacheRead = cacheRead.saturatingAdding(row.cacheRead)
            cacheWrite = cacheWrite.saturatingAdding(row.cacheWrite)
            reasoning = reasoning.saturatingAdding(row.reasoning)
            messages += row.messages
            turns += row.messages
            cost += row.cost
        }
    }

    private struct YearTotals {
        var totals = Totals()
        var start: String
        var end: String
    }

    private struct Fixture {
        let dates: [String]
        let start: String
        let end: String
        let rowsByDay: [[ClientRow]]
        let contributionJSON: [[String: Any]]
        let clientTotals: [String: Totals]
        let allTotals: Totals
        let maxDayCost: Double
        let yearMetadata: [[String: Any]]
    }

    private static func makeFixture(year: String?, today: String) -> Fixture {
        let dates = dates(for: year, today: today)
        let ids = ClientRegistry.allIds
        var rowsByDay: [[ClientRow]] = []
        var clientTotals = Dictionary(uniqueKeysWithValues: ids.map { ($0, Totals()) })
        var allTotals = Totals()
        var maxDayCost = 0.0
        var yearTotals: [String: YearTotals] = [:]
        var contributionJSON: [[String: Any]] = []

        for (dayIndex, date) in dates.enumerated() {
            var rows: [ClientRow] = []
            var dayTotals = Totals()
            for (clientIndex, id) in ids.enumerated() {
                let input = Int64(900 + clientIndex * 73 + dayIndex * 31)
                let output = Int64(420 + clientIndex * 29 + dayIndex * 17)
                let cacheRead = Int64(90 + (clientIndex + dayIndex) * 11)
                let cacheWrite = Int64(18 + (clientIndex * 3 + dayIndex) % 19)
                let reasoning = Int64(35 + (clientIndex * 5 + dayIndex) % 23)
                let messages = 2 + (clientIndex + dayIndex) % 3
                let total = input + output + cacheRead + cacheWrite + reasoning
                let cost = Double(total) * 0.000_003
                let row = ClientRow(
                    date: date, client: id, model: "demo-\(id)", input: input,
                    output: output, cacheRead: cacheRead, cacheWrite: cacheWrite,
                    reasoning: reasoning, cost: cost, messages: messages)
                rows.append(row)
                dayTotals.add(row)
                clientTotals[id]!.add(row)
                allTotals.add(row)
            }
            rowsByDay.append(rows)
            maxDayCost = max(maxDayCost, dayTotals.cost)
            let dateYear = String(date.prefix(4))
            if var yearTotal = yearTotals[dateYear] {
                yearTotal.totals.add(rows[0])
                for row in rows.dropFirst() { yearTotal.totals.add(row) }
                yearTotal.end = date
                yearTotals[dateYear] = yearTotal
            } else {
                var yearTotal = YearTotals(totals: Totals(), start: date, end: date)
                for row in rows { yearTotal.totals.add(row) }
                yearTotals[dateYear] = yearTotal
            }
            // Mirror the engine's per-day turn map so the demo dashboard shows
            // the same Daily/Monthly turn column the live one does. The fixture
            // treats every message as a turn, matching how it fills the hourly
            // report's `turnCount`.
            var demoTurns: [String: Int] = [:]
            for row in rows {
                demoTurns[row.client, default: 0] += row.messages
            }
            contributionJSON.append([
                "date": date,
                "turnsByClient": demoTurns,
                "totals": [
                    "tokens": dayTotals.total,
                    "cost": dayTotals.cost,
                    "messages": dayTotals.messages,
                ],
                "intensity": (dayIndex % 4) + 1,
                "tokenBreakdown": [
                    "input": dayTotals.input,
                    "output": dayTotals.output,
                    "cacheRead": dayTotals.cacheRead,
                    "cacheWrite": dayTotals.cacheWrite,
                    "reasoning": dayTotals.reasoning,
                ],
                "clients": rows.map(\.json),
            ])
        }

        let yearMetadata = yearTotals.keys.sorted().map { key in
            let value = yearTotals[key]!
            return [
                "year": key,
                "totalTokens": value.totals.total,
                "totalCost": value.totals.cost,
                "range": ["start": value.start, "end": value.end],
            ] as [String: Any]
        }
        return Fixture(
            dates: dates, start: dates[0], end: dates[dates.count - 1],
            rowsByDay: rowsByDay, contributionJSON: contributionJSON,
            clientTotals: clientTotals, allTotals: allTotals,
            maxDayCost: maxDayCost, yearMetadata: yearMetadata)
    }

    private static func makeAgentUsage() -> AgentUsagePayload {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let updated = formatter.string(from: now)
        let sessionDuration: Int64 = 18_000
        let weeklyDuration: Int64 = 604_800

        func learningHistoryWindow(
            cardId: String, label: String, used: Double, duration: Int64
        ) -> [String: Any] {
            [
                "cardId": cardId,
                "label": label,
                "usedPercent": used,
                "remainingPercent": 100 - used,
                "resetsAt": formatter.string(
                    from: now.addingTimeInterval(TimeInterval(duration / 2))),
                "resetText": duration == sessionDuration ? "in 2h 30m" : "in 3d 12h",
                "windowMinutes": duration / 60,
                "paceStatus": [
                    "state": "learningHistory",
                    "windowKey": cardId,
                    "durationSeconds": duration,
                    "durationSource": "contract",
                    "completeCycles": 0,
                ],
            ]
        }

        let monthlyDuration: Int64 = 2_592_000
        let agents = ClientRegistry.allIds.enumerated().map { index, id in
            let sessionUsed = Double(12 + (index * 7) % 76)
            let weeklyUsed = max(5, sessionUsed * 0.58)
            let windows: [[String: Any]]
            // The `opencode` client carries the OpenCode Go subscription quota:
            // rolling/weekly/monthly percent windows (ported from mana.bar).
            // Give it those three so the demo card matches the real provider
            // shape instead of the generic session/weekly fixture.
            if id == "opencode" {
                // The real OpenCode Go adapter attaches NO duration evidence (the
                // endpoint reports only a percent and a reset), so pace is in the
                // learning-duration state. Model the demo the same way rather than
                // claiming a `contract` duration the provider never supplies.
                func goWindow(
                    cardId: String, label: String, used: Double, duration: Int64,
                    resetText: String
                ) -> [String: Any] {
                    [
                        "cardId": cardId,
                        "label": label,
                        "usedPercent": used,
                        "remainingPercent": 100 - used,
                        "resetsAt": formatter.string(
                            from: now.addingTimeInterval(TimeInterval(duration / 2))),
                        "resetText": resetText,
                        "paceStatus": [
                            "state": "learningDuration",
                            "windowKey": cardId,
                            "durationSource": "observed",
                            "completeCycles": 0,
                        ],
                    ]
                }
                windows = [
                    goWindow(
                        cardId: "rolling.v1", label: "Rolling", used: 47,
                        duration: sessionDuration, resetText: "in 2h 30m"),
                    goWindow(
                        cardId: "weekly.v1", label: "Weekly", used: 63,
                        duration: weeklyDuration, resetText: "in 3d 12h"),
                    goWindow(
                        cardId: "monthly.v1", label: "Monthly", used: 28,
                        duration: monthlyDuration, resetText: "in 14d 6h"),
                ]
                return [
                    "clientId": id,
                    "source": "fixture",
                    "updatedAt": updated,
                    "identity": ["email": "demo@\(id).local", "plan": "Go"],
                    "windows": windows,
                ] as [String: Any]
            }
            switch index {
            case 0:
                windows = [
                    [
                        "cardId": "session.v1",
                        "label": "Session · Learning duration",
                        "usedPercent": 18.0,
                        "remainingPercent": 82.0,
                        "resetsAt": formatter.string(
                            from: now.addingTimeInterval(TimeInterval(sessionDuration / 2))),
                        "resetText": "in 2h 30m",
                        "paceStatus": [
                            "state": "learningDuration",
                            "windowKey": "session.v1",
                            "durationSource": "observed",
                            "completeCycles": 0,
                        ],
                    ],
                    learningHistoryWindow(
                        cardId: "weekly.v1", label: "Weekly · Learning history",
                        used: 35, duration: weeklyDuration),
                ]
            case 1:
                windows = [
                    [
                        "cardId": "session.v1",
                        "label": "Session · Historical ahead",
                        "usedPercent": 72.0,
                        "remainingPercent": 28.0,
                        "resetsAt": formatter.string(
                            from: now.addingTimeInterval(TimeInterval(sessionDuration / 2))),
                        "resetText": "in 2h 30m",
                        "windowMinutes": sessionDuration / 60,
                        "paceStatus": [
                            "state": "available",
                            "windowKey": "session.v1",
                            "durationSeconds": sessionDuration,
                            "durationSource": "contract",
                            "completeCycles": 6,
                        ],
                        "historicalPace": [
                            "expectedUsedPercent": 35.0,
                            "etaSeconds": 1_800.0,
                            "willLastToReset": false,
                            "runOutProbability": 0.42,
                        ],
                    ],
                    [
                        "cardId": "weekly.v1",
                        "label": "Weekly · Typed unavailable",
                        "usedPercent": 20.0,
                        "remainingPercent": 80.0,
                        "resetText": "reset unavailable",
                        "paceStatus": [
                            "state": "unavailable",
                            "windowKey": "weekly.v1",
                            "completeCycles": 0,
                            "reason": "missingReset",
                        ],
                    ],
                ]
            default:
                windows = [
                    learningHistoryWindow(
                        cardId: "session.v1", label: "Session",
                        used: sessionUsed, duration: sessionDuration),
                    learningHistoryWindow(
                        cardId: "weekly.v1", label: "Weekly",
                        used: weeklyUsed, duration: weeklyDuration),
                ]
            }
            return [
                "clientId": id,
                "source": "fixture",
                "updatedAt": updated,
                "identity": ["email": "demo@\(id).local", "plan": "Demo pace fixture"],
                "windows": windows,
            ] as [String: Any]
        }
        return decode(
            [
                "generatedAt": updated,
                "agents": agents,
                "opencodeSubscriptions": ["Codex", "Claude"],
            ],
            as: AgentUsagePayload.self)
    }

    /// Returns the synthetic contribution dates for an injectable local today.
    /// All-years keeps the rolling 14-day window, current-year clamps its start
    /// to January 1, and every other valid year stays within that year.
    static func dates(for year: String?, today: String) -> [String] {
        guard let todayDay = ISODay(today) else {
            return dates(for: nil, today: Format.todayKey())
        }
        let currentYear = String(today.prefix(4))
        let end: ISODay
        let validYear = year.flatMap(Self.parseYear)
        if year == nil {
            end = todayDay
        } else if let validYear, String(format: "%04d", validYear) == currentYear {
            end = todayDay
        } else if let validYear, let yearEnd = ISODay("\(validYear)-12-31") {
            end = yearEnd
        } else {
            // Invalid year input falls back to the all-years rolling fixture;
            // DashboardModel still rejects the invalid filter via payload.years.
            end = todayDay
        }

        let start: Int
        if year == nil {
            start = end.number - 13
        } else if let validYear, String(format: "%04d", validYear) == currentYear,
                  let yearStart = ISODay("\(currentYear)-01-01")
        {
            start = max(yearStart.number, end.number - 13)
        } else if let validYear, let yearStart = ISODay("\(validYear)-01-01") {
            start = max(yearStart.number, end.number - 13)
        } else {
            start = end.number - 13
        }
        return (start...end.number).map { ISODay(number: $0).iso }
    }

    private static func parseYear(_ raw: String) -> Int? {
        guard raw.count == 4, let value = Int(raw), (1...9999).contains(value) else {
            return nil
        }
        return value
    }

    private static func clientFilter(_ clients: [String]?) -> Set<String> {
        guard let clients, !clients.isEmpty else { return Set(ClientRegistry.allIds) }
        return Set(clients)
    }

    private static func decode<T: Decodable>(_ json: Any, as type: T.Type) -> T {
        do {
            let data = try JSONSerialization.data(withJSONObject: json)
            return try JSONDecoder().decode(type, from: data)
        } catch {
            preconditionFailure("demo fixture failed to decode \(type): \(error)")
        }
    }
}
