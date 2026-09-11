import Foundation

/// Pure derivation for the provider-level Usage Attribution settings page.
public enum UsageAttributionSettings {
    public enum Copy {
        public static let section = "Usage attribution"
        public static let classifyHint = "Classify each observed client/provider source against the subscription it should count toward. Nothing here is inferred as a billing event."
        /// Two facts about provider identity, deliberately in one hint, and
        /// both hedged for a reason.
        ///
        /// The first is about this page: it compares whatever string arrived
        /// and never canonicalizes. The second is about what arrives.
        /// `canonical_provider` folds `vertex` into `anthropic` and
        /// `openai_codex` into `openai`, but it is applied per parser, not
        /// globally — of the engine's session parsers, fourteen never call it,
        /// so an OpenClaw row really does keep `openai-codex` as its own
        /// classifiable source. Neither half can be stated flatly: "nothing is
        /// merged" is false for Claude Code, and "Codex is reported as OpenAI"
        /// is false for OpenClaw. Hence "some clients".
        public static let canonicalizationHint = "Provider IDs are compared exactly as the source emitted them, so related-looking routes may appear as separate rows and be classified independently. Some clients merge them before reporting — Vertex AI arriving as Anthropic, Codex as OpenAI — and a row that arrived merged cannot be split here."
        public static let declarationHint = "A declaration is your classification, not a billing fact."
        public static let noRows = "No provider-split usage in this range."
        /// The report request finished without one. Distinct from `noRows`,
        /// which is an answer about a report that did arrive.
        public static let unavailable = "Usage could not be loaded, so there is nothing to classify yet."
        public static let acceptSuggestions = "Accept all suggestions (%lld)"
        public static let suggestionsHint = "Suggestions are proposals; they do not change your classification until accepted."
        public static let source = "%@ · %@"
        public static let observed = "Observed %@ tokens · %@"
        public static let classification = "Classification"
        public static let unassigned = "Unassigned"
        public static let excluded = "Not a subscription"
        public static let assigned = "Counts toward %@"
        public static let suggested = "Suggested: counts toward %@"
        public static let suggestedExcluded = "Suggested: not a subscription"
        public static let unspecifiedProvider = "Unspecified provider"
        public static let classificationFor = "Classification for %@"

        public static var all: [String] {
            [
                section, classifyHint, canonicalizationHint, declarationHint, noRows, unavailable,
                acceptSuggestions, suggestionsHint, source, observed, classification,
                unassigned, excluded, assigned, suggested, suggestedExcluded, unspecifiedProvider,
                classificationFor,
                WriteFailure.invalidExistingValue.message,
                WriteFailure.entryLimit.message,
                WriteFailure.sizeOrInvalidRecord.message,
            ]
        }
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public let client: String
        public let provider: String
        public let tokens: Int64
        public let cost: Double
        public let state: UsageAttribution.State
        public let suggestedState: UsageAttribution.State?

        public var id: String { "\(client)\u{0}\(provider)" }

        /// Empty provider is valid wire data. Keep it as its own source key and
        /// give it a readable label instead of hiding or merging the row.
        public var providerLabel: String {
            provider.isEmpty ? Copy.unspecifiedProvider : provider
        }
    }

    public enum WriteFailure: Equatable, Sendable {
        case invalidExistingValue
        case entryLimit
        case sizeOrInvalidRecord

        public var message: String {
            switch self {
            case .invalidExistingValue:
                return "Could not save this classification: existing attribution data is invalid or foreign."
            case .entryLimit:
                return "Could not save this classification: the attribution entry limit was reached."
            case .sizeOrInvalidRecord:
                return "Could not save this classification: the new value is too large or unsupported."
            }
        }
    }

    /// This is auditable product knowledge, not an inference from local usage
    /// or quota payloads. Cross-client suggestions remain proposals and are only
    /// offered where the provider's subscription terms permit that route.
    /// Providers whose subscription terms allow it to be reached through some
    /// other agent. Only these can carry a cross-client assignment suggestion.
    ///
    /// An allowlist rather than a denylist, because being wrong in the
    /// permissive direction proposes that the user did something their provider
    /// forbids. Extend it per provider, with the terms checked.
    ///
    /// xAI ships OAuth sign-in for SuperGrok / X Premium+ into third-party
    /// agents (Pi, OpenCode) and its own ACP protocol for them, and that usage
    /// draws on the same shared weekly pool as grok.com — so a row of theirs
    /// logged elsewhere really did consume the subscription.
    public static let crossAgentSubscriptionProviders: Set<String> = [
        "openai", "xai",
        // Vendors whose coding plans are sold to be reached from other agents —
        // that is the product. Reselling them is likewise routine.
        "deepseek", "moonshot", "minimax", "zhipu", "alibaba",
        // Not a vendor relationship at all. `open-weights` is a model the
        // product hosts itself and `own` is a model it trained; either way the
        // subscription that served it is the one that paid, and no third party's
        // terms are involved.
        "open-weights", "own",
        // Sold only inside a bundle (Copilot's MAI, Junie's Amazon models), so a
        // row of theirs is that bundle's spend by construction.
        "microsoft", "amazon",
    ]

    /// Providers whose subscription may only be used by its own client. A row
    /// of theirs logged by a different client is API spend under any compliant
    /// reading, so that is what gets suggested — never their subscription.
    public static let subscriptionBoundProviders: Set<String> = ["anthropic", "google"]

    /// The client whose *own* subscription a provider is. This is what
    /// `subscriptionBoundProviders` actually restricts: driving Anthropic's or
    /// Google's own subscription from a third-party agent is what their terms
    /// forbid. A different subscription that resells the same models — Copilot
    /// serving Anthropic — is that subscription's own matter and is not covered
    /// by the restriction, so it stays assignable.
    /// The registered client that *is* a vendor's own product, where one exists.
    ///
    /// Two callers, two reasons. The bound-provider rule uses it to name the
    /// subscription whose terms forbid being driven from elsewhere. Opencode
    /// label resolution uses it because an `auth.json` oauth entry for a vendor
    /// means the user authed to that vendor directly — so the subscription is
    /// the vendor's own, never a reseller that also happens to carry it.
    ///
    /// A vendor with no first-party client here (`microsoft`, `amazon`,
    /// `open-weights`, `own`) is sold only inside someone else's bundle.
    public static let providerOwnClient: [String: String] = [
        "anthropic": "claude",
        "openai": "codex",
        "google": "antigravity",
        "xai": "grok",
        "moonshot": "kimi",
        "minimax": "micode",
        "alibaba": "qwen",
    ]

    /// Which model vendors each subscription's own plan pays for.
    ///
    /// **This is a perishable external fact, not something derivable from the
    /// code.** Vendors are added and dropped from these plans continuously. The
    /// verification date, per-product notes and sources live in
    /// `docs/knowledge/architecture.md` under Usage attribution — when a
    /// suggestion looks obviously wrong, suspect this table before suspecting
    /// the logic that reads it. Last verified 2026-08-07.
    ///
    /// Two rules decide what belongs here, and both were got wrong before:
    ///
    /// - **BYO-key does not count.** A product that merely *supports* a vendor
    ///   when you supply your own API key did not pay for those tokens; you paid
    ///   the vendor. Cursor's BYOK path and Warp's own-key mode are excluded on
    ///   this basis.
    /// - **A vendor's open weights hosted by someone else are not that vendor's
    ///   subscription.** Antigravity serves `gpt-oss-120b`, but it is Apache-2.0
    ///   weights running on Google's capacity — the money goes to Google. It is
    ///   `open-weights`, never `openai`.
    ///
    /// Only clients in `ClientRegistry` appear here; the survey covered more
    /// products than TokenBar recognises.
    public static let subscriptionProviderMap: [String: Set<String>] = [
        // Single-vendor plans: the vendor's own product.
        "claude": ["anthropic"],
        "codex": ["openai"],
        "grok": ["xai"],
        "kimi": ["moonshot"],
        "micode": ["minimax"],

        // Multi-vendor plans. A row of theirs is the subscription's spend, not
        // the underlying vendor's.
        "copilot": ["openai", "anthropic", "google", "xai", "microsoft", "moonshot"],
        "antigravity": ["google", "anthropic", "open-weights"],
        "cursor": ["anthropic", "openai", "google", "xai", "own", "moonshot", "zhipu"],
        "zed": ["anthropic", "openai", "google"],
        "junie": ["openai", "anthropic", "google", "xai", "amazon"],
        "trae": ["openai", "anthropic", "minimax"],
        "amp": ["openai", "anthropic", "zhipu", "open-weights"],
        "droid": ["anthropic", "openai", "google", "moonshot", "zhipu", "open-weights"],
        "kiro": ["anthropic", "open-weights", "alibaba", "deepseek", "minimax"],
        "warp": [
            "openai", "anthropic", "google", "xai", "open-weights",
            "zhipu", "moonshot", "minimax", "alibaba", "deepseek",
        ],
        "kilo": [
            "anthropic", "openai", "google", "xai", "deepseek",
            "moonshot", "minimax", "zhipu", "alibaba", "open-weights",
        ],
        "kilocode": [
            "anthropic", "openai", "google", "xai", "deepseek",
            "moonshot", "minimax", "zhipu", "alibaba", "open-weights",
        ],
        "cline": ["zhipu", "moonshot", "deepseek", "minimax", "alibaba", "open-weights"],
        "qwen": ["alibaba", "zhipu", "moonshot", "minimax"],
    ]

    /// `agentUsage` is the capability source for assignment targets. A transient
    /// last-good snapshot keeps its display-ready identity, windows, or credits,
    /// while the Rust producer's required placeholder for an absent provider has
    /// none of them. Exclude only that terminal empty shape so it cannot invent a
    /// subscription the user never configured.
    ///
    /// `opencodeSubscriptions` is a second, independent statement of ownership:
    /// opencode reports the providers its `auth.json` holds an oauth entry for,
    /// and a user who reaches a subscription only that way has no snapshot of
    /// their own — just the empty placeholder the filter above removes. Dropping
    /// them would leave exactly those rows unable to name the subscription they
    /// are known to consume, so the labels are folded back in as targets.
    public static func subscriptionClients(from payload: AgentUsagePayload?) -> [String] {
        var seen = Set<String>()
        let configured = (payload?.agents ?? []).compactMap { snapshot -> String? in
            guard snapshot.identity != nil || !snapshot.windows.isEmpty || snapshot.credits != nil
            else { return nil }
            // A declared router is never a direct attribution target — its usage
            // is attributed through the subscriptions it routes into, not to
            // itself (architecture.md, "Router 不進表"). opencode now carries its
            // own OpenCode Go quota snapshot, so without this it would be admitted
            // here as a target and a usage row could be "assigned" to opencode.
            guard snapshot.clientId != "opencode" else { return nil }
            return snapshot.clientId
        }
        let viaOpencode = (payload?.opencodeSubscriptions ?? [])
            .compactMap(subscriptionClient(forLabel:))
        return (configured + viaOpencode).filter {
            ClientRegistry.allIds.contains($0) && seen.insert($0).inserted
        }
    }

    /// The subscription client an opencode label names, or nil when none is.
    ///
    /// Two rules, because the producer's labels are not uniformly invertible.
    /// `subscription_label` renames four providers outright (`openai` to `Codex`
    /// and so on) and otherwise just capitalizes the provider key, so the renames
    /// need an explicit inverse while everything else *is* a provider and can be
    /// resolved through the map that already says which client serves it. Writing
    /// the second rule as a lookup rather than a second hand-kept table is what
    /// stops a provider added to `subscriptionProviderMap` from being invisible
    /// here — `xai` was, which is how a Grok subscription reached only through
    /// opencode could not be named as a target.
    public static func subscriptionClient(forLabel label: String) -> String? {
        if let alias = ClientRegistry.subscriptionLabelAliases[label] { return alias }
        // opencode's provider keys carry the plan, not just the vendor:
        // `minimax-coding-plan` becomes the label `Minimax-coding-plan`, and
        // `kimi-for-coding` and the `zai` coding plan are the same shape. The
        // vendor is the leading segment, so the qualifier is trimmed before the
        // lookup rather than each plan being enumerated — these vendors sell
        // per-plan keys and the list would never stay complete.
        let vendor = label.lowercased()
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? label.lowercased()
        // The remaining labels are capitalized provider keys, and an oauth entry
        // for a provider means the user authed to that provider directly — so
        // the subscription is that vendor's own client, not whichever reseller
        // also carries it. Resolving by "the unique subscription covering this
        // provider" stopped working once the survey showed most providers are
        // carried by several: `Xai` would become ambiguous between Grok, Cursor,
        // Copilot, Warp and others, when the answer is plainly Grok.
        //
        // A label naming no first-party client names no subscription. `Kiro`
        // lowercases to a registered client, so returning it would put
        // "Counts toward Kiro" in the picker for something the policy can never
        // resolve.
        if let own = providerOwnClient[vendor] { return own }
        // The key can name the product rather than the model vendor: Moonshot
        // sells `kimi-for-coding`, and `kimi` is the registered client while
        // `moonshot` is the vendor `providerOwnClient` is keyed by. Accept the
        // segment as a client only when that client actually sells a plan —
        // otherwise a registered id that owns no subscription (`crush`) would
        // become a target the policy can never resolve.
        return subscriptionProviderMap[vendor] != nil ? vendor : nil
    }

    /// What the attribution page shows. A nil report is two states: the request
    /// is still running, or it finished without one — `DashboardModel.load()`
    /// takes the report with `try?` and reaches `.ready` on the graph alone.
    /// Collapsing the second into "no provider-split usage" tells the user there
    /// is nothing to classify at exactly the moment the data needed to classify
    /// could not be loaded.
    public enum PageState: Equatable {
        case loading
        case unavailable
        case empty
        case rows
    }

    public static func pageState(
        hasReport: Bool, rowCount: Int, isLoading: Bool
    ) -> PageState {
        guard hasReport else { return isLoading ? .loading : .unavailable }
        return rowCount == 0 ? .empty : .rows
    }

    /// Consume raw provider-split rows. `modelLevelEntries` folds providers
    /// back together, which would erase the exact dimension this page classifies.
    public static func rows(
        entries: [ModelReportEntry],
        confirmed: [UsageAttribution.Record],
        suggestions: [UsageAttribution.Record]
    ) -> [Row] {
        var aggregate: [String: (client: String, provider: String, tokens: Int64, cost: Double)] = [:]
        var order: [String] = []
        for entry in entries {
            // Per entry and before folding, which is where
            // `UsageAttributionBreakdown.rows` applies the same test. Applying
            // it to the aggregate instead would agree on every ordinary input
            // and part on one that cancels: two rows of +5 and -5 sum to an
            // empty source here while the card, having resolved each row first,
            // can still place them in different buckets and report both. Same
            // test at the same stage is one invariant; same test at two stages
            // is an invariant plus a standing obligation to remember it.
            guard entry.total != 0 || entry.cost != 0 else { continue }
            let key = sourceKey(client: entry.client, provider: entry.provider)
            if let current = aggregate[key] {
                aggregate[key] = (
                    current.client,
                    current.provider,
                    current.tokens.saturatingAdding(entry.total),
                    current.cost + entry.cost)
            } else {
                aggregate[key] = (entry.client, entry.provider, entry.total, entry.cost)
                order.append(key)
            }
        }

        return order.compactMap { key in
            guard let value = aggregate[key] else { return nil }
            let state = UsageAttribution.resolve(
                client: value.client, provider: value.provider, model: nil, records: confirmed)
            // A stored suggestion carries its own state now: `excluded` is a
            // proposal in its own right, not the absence of one.
            let suggestion: UsageAttribution.State?
            if case .unassigned = state {
                suggestion = suggestions.first {
                    $0.client == value.client && $0.provider == value.provider && $0.model == nil
                }?.state
            } else {
                suggestion = nil
            }
            return Row(
                client: value.client,
                provider: value.provider,
                tokens: value.tokens,
                cost: value.cost,
                state: state,
                suggestedState: suggestion)
        }
    }

    /// Which subscription a source row could plausibly belong to, or nil when
    /// nothing can be said.
    ///
    /// The question is asked provider-first, not source-first: a row records
    /// which provider served the tokens, and the answer is which of the user's
    /// subscriptions covers that provider — usually *not* the client that
    /// happened to log it. Routing a Claude Code session through a gateway to
    /// an OpenAI model produces `("claude", "openai")`, and the subscription it
    /// consumed is Codex.
    ///
    /// Still only a suggestion. The same row on another machine is an OpenAI
    /// API key, whose right answer is `excluded`, and no field in the data tells
    /// the two apart. This turns N clicks into one confirmation; it never
    /// decides.
    /// Clients that route through subscriptions they do not own, keyed to the
    /// subscription clients they are authed against.
    ///
    /// opencode is the only one TokenBar can know this for, because its
    /// `auth.json` oauth entries are reported as `opencodeSubscriptions`. That
    /// declaration is what separates it from every other multi-provider source:
    /// a Cursor row is Cursor's own plan, but an opencode row was paid for by
    /// whichever subscription opencode is signed into. Without this the router's
    /// rows get no suggestion at all, and on real data opencode is the single
    /// most provider-diverse source there is.
    public typealias RoutedSubscriptions = [String: [String]]

    public static func routedSubscriptions(
        from payload: AgentUsagePayload?
    ) -> RoutedSubscriptions {
        let authed = (payload?.opencodeSubscriptions ?? [])
            .compactMap(subscriptionClient(forLabel:))
            .filter { ClientRegistry.allIds.contains($0) }
        return authed.isEmpty ? [:] : ["opencode": authed]
    }

    public static func suggestionTarget(
        sourceClient: String, provider: String, subscriptionClients: [String],
        routedSubscriptions: RoutedSubscriptions = [:]
    ) -> UsageAttribution.State? {
        let owners = subscriptionClients.filter {
            subscriptionProviderMap[$0]?.contains(provider) == true
        }
        // A client talking to its own provider is the plainest reading, and
        // stays unambiguous even when another subscription also accepts it.
        //
        // "Its own" is asked of the subscription the source draws on, not of its
        // process identity: `antigravity-cli` is a client in its own right but
        // spends the `antigravity` subscription, so comparing the raw id would
        // find no owner and fall through to the subscription-bound branch —
        // declaring the CLI's own subscription usage to be API spend.
        let sourceOwner = ClientRegistry.quotaOwner(sourceClient)

        // Own subscription wins, and asking the table directly rather than
        // `owners` is the point: `owners` is filtered by `subscriptionClients`,
        // which lists only clients TokenBar has a quota snapshot for. Attribution
        // answers who paid, not who has a gauge — Cursor's own plan covers the
        // Anthropic models it serves whether or not TokenBar can draw its meter.
        // Requiring a snapshot here is what made a Cursor row fall through and
        // get proposed against someone else's subscription entirely.
        if subscriptionProviderMap[sourceOwner]?.contains(provider) == true {
            return .assigned(sourceOwner)
        }

        // A declared router spends the subscription it is signed into, so that
        // is the answer before any policy about the provider applies — the
        // question of who may reach a vendor from elsewhere does not arise when
        // the user authed to it here on purpose.
        if let routed = routedSubscriptions[sourceOwner] {
            let covering = routed.filter {
                subscriptionProviderMap[$0]?.contains(provider) == true
            }
            guard covering.count == 1 else { return nil }
            return .assigned(covering[0])
        }

        // A source the table says nothing about is not evidence of anything.
        // Absence here means "nobody has established what this product's plan
        // covers", which is a different claim from "this product's plan does not
        // cover it" — and only the second one justifies calling the usage API
        // spend. Refusing to suggest leaves the row unassigned for the user.
        guard subscriptionProviderMap[sourceOwner] != nil else { return nil }

        // Which of the covering subscriptions could legitimately have been
        // reached from somewhere else. For a bound provider that is every owner
        // except the provider's own client, whose terms forbid exactly that
        // route; a reseller like Copilot is unaffected. For a permitted
        // provider every owner qualifies.
        let bound = subscriptionBoundProviders.contains(provider)
        let eligible: [String]
        if bound {
            eligible = owners.filter { $0 != providerOwnClient[provider] }
        } else if crossAgentSubscriptionProviders.contains(provider) {
            eligible = owners
        } else {
            // Neither policy covers this provider. The self-test pins that this
            // cannot happen for a provider a subscription serves; it remains the
            // runtime backstop if that stops holding.
            eligible = []
        }

        // Nothing eligible and the provider is bound: assume the user is
        // complying, so the tokens were bought rather than drawn from the
        // subscription. Nothing eligible otherwise says nothing at all.
        guard let only = eligible.count == 1 ? eligible[0] : nil else {
            return eligible.isEmpty && bound ? .excluded : nil
        }
        return .assigned(only)
    }

    public static func suggestionRecords(
        entries: [ModelReportEntry],
        confirmed: [UsageAttribution.Record],
        subscriptionClients: [String],
        routedSubscriptions: RoutedSubscriptions = [:]
    ) -> [UsageAttribution.Record] {
        rows(entries: entries, confirmed: confirmed, suggestions: []).compactMap { row in
            guard case .unassigned = row.state,
                  let proposed = suggestionTarget(
                    sourceClient: row.client,
                    provider: row.provider,
                    subscriptionClients: subscriptionClients,
                    routedSubscriptions: routedSubscriptions)
            else { return nil }
            return UsageAttribution.Record(
                client: row.client, provider: row.provider, state: proposed)
        }
    }

    /// Returns only provider-level proposals that are still unassigned. The
    /// caller stores them with `suggestionsRaw`; only explicit acceptance may
    /// pass the same records to `confirmedRaw`.
    public static func acceptanceRecords(rows: [Row]) -> [UsageAttribution.Record] {
        rows.compactMap { row in
            guard case .unassigned = row.state,
                  let proposed = row.suggestedState
            else { return nil }
            return UsageAttribution.Record(
                client: row.client, provider: row.provider, state: proposed)
        }
    }

    public static func writeFailure(
        table: UsageAttribution.Table,
        record: UsageAttribution.Record,
        result: String?
    ) -> WriteFailure? {
        writeFailure(table: table, records: [record], result: result)
    }

    public static func writeFailure(
        table: UsageAttribution.Table,
        records updates: [UsageAttribution.Record],
        result: String?
    ) -> WriteFailure? {
        guard result == nil else { return nil }
        guard table.isWritable else { return .invalidExistingValue }
        var records = table.records
        for update in updates {
            records.removeAll {
                $0.client == update.client && $0.provider == update.provider
                    && $0.model == update.model
            }
            if case .unassigned = update.state { continue }
            records.append(update)
        }
        if records.count > UsageAttribution.maxEntries { return .entryLimit }
        return .sizeOrInvalidRecord
    }

    /// `targetsKnown` distinguishes "no subscriptions" from "not asked yet".
    /// Both render `subscriptionClients` as an empty list, so without it a
    /// payload that arrives with zero candidates produces an unchanged signature
    /// and the reconciliation that should clear stale proposals never runs.
    public static func signature(
        entries: [ModelReportEntry], subscriptionClients: [String], targetsKnown: Bool = true,
        routedSubscriptions: RoutedSubscriptions = [:]
    ) -> String {
        let entrySignature = entries.map {
            [
                $0.client, $0.provider, $0.model, String($0.total),
                String($0.cost.bitPattern),
            ].joined(separator: "\u{1f}")
        }.joined(separator: "\u{1e}")
        // Routing is a second, independent input to every suggestion: opencode
        // gaining or losing an oauth entry changes the answer while the resolved
        // target list can stay identical, because a Codex snapshot already
        // contributes `codex` either way.
        let routing = routedSubscriptions.keys.sorted()
            .map { "\($0)>\(routedSubscriptions[$0]!.sorted().joined(separator: "+"))" }
            .joined(separator: ";")
        return entrySignature + "|" + (targetsKnown ? "known" : "pending")
            + "|" + subscriptionClients.joined(separator: ",")
            + "|" + routing
    }

    private static func sourceKey(client: String, provider: String) -> String {
        "\(client)\u{0}\(provider)"
    }
}
