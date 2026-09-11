import Foundation

// Client (agent) display registry, ported from the Tauri app's
// src/lib/clients.ts. SVG icons are not ported yet (later phase); this carries
// the display name + brand disc color used by chart legends and model rows.

public struct ClientStyle: Sendable {
    public let id: String
    public let displayName: String
    /// Brand disc color, hex.
    public let color: String
}

public enum ClientRegistry {
    static let entries: [String: (displayName: String, color: String)] = [
        "claude": ("Claude Code", "#d97706"),
        "openclaw": ("OpenClaw", "#dc2626"),
        "gemini": ("Gemini CLI", "#60a5fa"),
        // The `opencode` client also carries the OpenCode Go subscription quota
        // card (ported from mana.bar's OpenCodeGoProvider), fed by the
        // opencode-go api key in auth.json. No separate client id, mirroring how
        // the Copilot quota feeds the `copilot` tab.
        "opencode": ("OpenCode", "#1f2937"),
        // No form-factor suffix on these three: their sources are not
        // surface-scoped. `codex` reads ~/.codex/sessions, written by Codex
        // Desktop / the IDE extension / the CLI alike (a 1733-file sample was
        // 70% "Codex Desktop", 4% CLI). `copilot` merges the CLI/VS Code OTel
        // export with the desktop app's ~/.copilot/data.db. `cursor` is not a
        // session parser at all — it reads Cursor's account usage export CSV,
        // which bills IDE, cursor-agent and cloud agents into one undifferentiated
        // ledger.
        "codex": ("Codex", "#9ca3af"),
        "copilot": ("Copilot", "#1f2937"),
        "cursor": ("Cursor", "#0ea5e9"),
        "amp": ("Amp", "#10b981"),
        "droid": ("Droid", "#22c55e"),
        "hermes": ("Hermes", "#a78bfa"),
        "pi": ("Pi", "#f472b6"),
        "kimi": ("Kimi", "#fbbf24"),
        "junie": ("Junie", "#6b7280"),
        "opencodereview": ("OpenCodeReview", "#6b7280"),
        "qwen": ("Qwen CLI", "#7c3aed"),
        "roocode": ("Roo Code", "#ef4444"),
        "kilocode": ("KiloCode", "#f97316"),
        "kilo": ("Kilo CLI", "#f59e0b"),
        "mux": ("Mux", "#06b6d4"),
        "crush": ("Crush", "#ec4899"),
        "synthetic": ("Synthetic", "#64748b"),
        "goose": ("Goose", "#14b8a6"),
        "codebuff": ("Codebuff", "#8b5cf6"),
        "antigravity": ("Antigravity", "#3b82f6"),
        "zed": ("Zed", "#084fff"),
        "kiro": ("Kiro", "#9046ff"),
        "trae": ("Trae", "#ef4444"),
        "warp": ("Warp", "#01a4ff"),
        "cline": ("Cline", "#5b8def"),
        "antigravity-cli": ("Antigravity CLI", "#6366f1"),
        "jcode": ("Jcode", "#84cc16"),
        "micode": ("MiMo Code", "#fb923c"),
        "gjc": ("gjc", "#e11d48"),
        "grok": ("Grok Build", "#1f2937"),
    ]

    /// Every registered client id, sorted. Demo fixtures use this canonical
    /// universe so every usage surface renders the same client set.
    public static var allIds: [String] { entries.keys.sorted() }

    public static func style(_ id: String) -> ClientStyle {
        if let entry = entries[id] {
            return ClientStyle(id: id, displayName: entry.displayName, color: entry.color)
        }
        // Fallback: title-case the id, neutral grey disc.
        let displayName = id.prefix(1).uppercased() + id.dropFirst()
        return ClientStyle(id: id, displayName: displayName, color: "#6b7280")
    }

    /// Display name with the trailing form-factor word dropped, as the chart
    /// legend does ("Claude Code" → "Claude").
    public static func shortName(_ id: String) -> String {
        let name = style(id).displayName
        let registeredNames = Set(entries.values.map { $0.displayName })
        for suffix in [" CLI", " Code"] where name.hasSuffix(suffix) {
            let base = String(name.dropLast(suffix.count))
            // Don't collapse onto a base that is itself another client's full
            // name — e.g. "Antigravity CLI" must stay distinct from the IDE
            // client "Antigravity".
            if !registeredNames.contains(base) {
                return base
            }
        }
        return name
    }

    // MARK: - Tab bar display order & visibility (new for tabs improvement)

    public static let tabOrderKey = "tokenbar.tabs.order"
    public static let tabHiddenKey = "tokenbar.tabs.hidden"
    /// Independent from `tabHiddenKey`: hides a client's Agent-limits quota
    /// card only, leaving its top tab (and cost/token/model data) visible.
    /// Added for accounts whose plan has no OAuth quota (e.g. Claude Console).
    public static let limitsHiddenKey = "tokenbar.limits.hidden"

    /// Canonicalize a live-tail client id to the registry's short id. The
    /// usage trace reports raw ids (`claude-code`, `codex-cli`, `gemini-cli`)
    /// while the hidden set, quota snapshots, and registry all key on short ids
    /// (`claude`, `codex`, `gemini`). EXPLICIT aliases only — no generic `-cli`
    /// suffix rule: `antigravity-cli` is a registered client id distinct from
    /// the `antigravity` IDE, so stripping `-cli` would conflate the two (hiding
    /// one would mis-target the other). Single source shared by the trace
    /// deny-filters and `AgentLimitsCard.normalizeTraceClient` (which layers its
    /// own generic `-cli` fold on top for quota-card attribution).
    public static func canonicalClient(_ id: String) -> String {
        switch id {
        case "claude-code": return "claude"
        case "codex-cli": return "codex"
        case "gemini-cli": return "gemini"
        default: return id
        }
    }

    /// The client whose quota snapshot a client's usage is served by, where the
    /// two identities differ. `antigravity-cli` is a registered client in its own
    /// right — process identity, tab, icon and preferences all stay distinct —
    /// but it draws on the `antigravity` subscription and the quota views have
    /// always folded it that way. Anything reasoning about which subscription a
    /// client's tokens consume has to fold it too, or it will conclude the CLI
    /// owns no subscription at all.
    public static func quotaOwner(_ id: String) -> String {
        id == "antigravity-cli" ? "antigravity" : id
    }

    /// The registered client behind an opencode subscription label. opencode
    /// reports which providers it is authed against as display labels rather
    /// than ids (`agent_usage.rs` builds them in `subscription_label`), so a
    /// consumer that needs the id must map them back here.
    /// The four labels `subscription_label` renames outright, and the client
    /// each names. Everything else it emits is a capitalized provider key, which
    /// cannot be resolved from this table alone. Kept as data rather than a
    /// `switch` so a caller can tell a rename from a passthrough — three of the
    /// four lowercase to their own id, so comparing the result against
    /// `label.lowercased()` cannot make that distinction.
    public static let subscriptionLabelAliases: [String: String] = [
        "Codex": "codex",
        "Claude": "claude",
        "Copilot": "copilot",
        "Gemini": "antigravity",
    ]

    public static func clientId(forSubscriptionLabel label: String) -> String {
        subscriptionLabelAliases[label] ?? label.lowercased()
    }

    /// Parses the comma-separated id form persisted by the tab order/hidden
    /// defaults into a set, tolerating an empty string. Single source of the
    /// CSV split so callers (and the reactive views, which pass their observed
    /// @AppStorage string) all agree on the shape.
    public static func parseIdSet(_ raw: String) -> Set<String> {
        Set(raw.isEmpty ? [] : raw.split(separator: ",").map(String.init))
    }

    /// Ordered variant of `parseIdSet` — keeps the saved sequence for callers
    /// that need positions (reorder/order sorting), not just membership.
    public static func parseIdList(_ raw: String) -> [String] {
        raw.isEmpty ? [] : raw.split(separator: ",").map(String.init)
    }

    /// Returns the set of client ids that the user has hidden from the top tabs (and now also from Agent limits cards).
    public static func hiddenClients() -> Set<String> {
        parseIdSet(UserDefaults.standard.string(forKey: tabHiddenKey) ?? "")
    }

    /// Returns the set of client ids whose Agent-limits card the user has
    /// hidden, independent of top-tab visibility.
    public static func hiddenLimitsClients() -> Set<String> {
        parseIdSet(UserDefaults.standard.string(forKey: limitsHiddenKey) ?? "")
    }

    /// Clients excluded from the menu-bar quota AUTO pick: tab-hidden ∪
    /// limits-hidden. A client hidden from either surface must not drive the
    /// tray quota % (an explicit tray selection is honored separately).
    public static func quotaExcludedClients() -> Set<String> {
        hiddenClients().union(hiddenLimitsClients())
    }

    /// The superset of client ids that can show a row in the multi-agent
    /// Agent-limits card: `present` clients that carry a known limit
    /// (a placeholder row or a live quota snapshot), unioned with every client
    /// that has a quota snapshot right now. Some agents (e.g. Antigravity)
    /// report OAuth quota with no local session logs, so they are absent from
    /// `present` yet must still be offered a management row. `quotaIds` is the
    /// ordered list of snapshot client ids; `placeholders` the ids rendered
    /// with a placeholder row even without a snapshot. Pure — the View layer
    /// passes plain arrays/sets so TokenBarCore imports no UI types.
    public static func knownLimitsClients(
        present: [String], quotaIds: [String], placeholders: Set<String>
    ) -> [String] {
        let quotaSet = Set(quotaIds)
        func known(_ id: String) -> Bool { placeholders.contains(id) || quotaSet.contains(id) }
        var seen = Set<String>()
        return (present.filter(known) + quotaIds).filter { seen.insert($0).inserted }
    }

    /// Sorts `ids` by the user's saved tab order (`tabOrderKey`), appending
    /// ids not yet in the saved order at the end in their incoming order.
    public static func orderedClients(_ ids: [String]) -> [String] {
        orderedClients(ids, orderRaw: UserDefaults.standard.string(forKey: tabOrderKey) ?? "")
    }

    /// Reactive overload: sorts against an explicitly-passed saved order string
    /// so a SwiftUI view that observes the @AppStorage raw re-renders when the
    /// order changes (the zero-arg variant reads UserDefaults for non-view
    /// callers and never invalidates a body on its own).
    public static func orderedClients(_ ids: [String], orderRaw: String) -> [String] {
        let order = parseIdList(orderRaw)
        guard !order.isEmpty else { return ids }
        return ids.sorted { a, b in
            let ia = order.firstIndex(of: a) ?? Int.max
            let ib = order.firstIndex(of: b) ?? Int.max
            if ia == ib {
                // Preserve relative order among items with no explicit position.
                return ids.firstIndex(of: a)! < ids.firstIndex(of: b)!
            }
            return ia < ib
        }
    }

    /// Returns the subset of `present` clients to show in the top tab bar,
    /// filtered by hidden list and sorted according to the user's saved order.
    /// Clients not yet in the saved order are appended at the end (so newly
    /// discovered agents become visible without breaking existing custom order).
    public static func displayClients(present: [String]) -> [String] {
        let hidden = hiddenClients()
        return orderedClients(present.filter { !hidden.contains($0) })
    }

    /// Reactive overload of `displayClients`: takes the observed hidden/order
    /// raw strings so a SwiftUI view (e.g. the settings live preview) re-renders
    /// the instant the user toggles a tab or reorders, instead of waiting for
    /// the next poller tick to re-read UserDefaults.
    public static func displayClients(
        present: [String], hiddenRaw: String, orderRaw: String
    ) -> [String] {
        let hidden = parseIdSet(hiddenRaw)
        return orderedClients(present.filter { !hidden.contains($0) }, orderRaw: orderRaw)
    }

    /// Direction-aware reorder helper (drag down inserts after, up before).
    /// Mirrors the logic used in AgentLimitsCard.
    public static func reorder(_ list: [String], from: String, to: String) -> [String] {
        guard let fromI = list.firstIndex(of: from),
              let toI = list.firstIndex(of: to),
              fromI != toI
        else { return list }

        var out = list.filter { $0 != from }
        let anchor = out.firstIndex(of: to)!
        out.insert(from, at: fromI < toI ? anchor + 1 : anchor)
        return out
    }

    /// Reorder a `visible` subset while preserving the positions of every id in
    /// `full` that isn't part of that subset. The drag operates on `visible`
    /// (e.g. the quota cards actually on screen — a subset that excludes hidden
    /// and non-quota clients), yet the saved order key drives the whole tab
    /// universe: writing only the reordered visible sequence would silently
    /// drop every off-screen id from the shared order. This recomputes the
    /// visible sequence, then rebuilds the full order by refilling the visible
    /// slots in their new order and leaving non-visible ids exactly where they
    /// were. Visible ids absent from `full` are appended at the end (the
    /// existing "newly discovered agent" semantics).
    public static func mergeReorder(
        full: [String], visible: [String], from: String, to: String
    ) -> [String] {
        let newVisible = reorder(visible, from: from, to: to)
        let visibleSet = Set(visible)
        var queue = newVisible[...]
        var out: [String] = []
        for id in full {
            if visibleSet.contains(id) {
                // Refill this visible slot with the next id from the reordered
                // sequence. `queue` starts as a permutation of `visible`, so it
                // has at least as many ids as there are visible slots in `full`.
                if let next = queue.first {
                    queue = queue.dropFirst()
                    out.append(next)
                }
            } else {
                out.append(id)
            }
        }
        // Visible ids that weren't already positioned in `full` land at the end.
        out.append(contentsOf: queue)
        return out
    }

    /// One-time migration: the Agent-limits drag order used to persist under
    /// "tokenbar.limits.order". It now shares `tabOrderKey` with the client tab
    /// bar, so fold an existing legacy value across once — otherwise upgrading
    /// users would silently lose their saved card arrangement. Idempotent: only
    /// fires when the new key is unset and a non-empty legacy value exists.
    public static func migrateLegacyOrderKey() {
        let defaults = UserDefaults.standard
        let legacyKey = "tokenbar.limits.order"
        guard defaults.object(forKey: tabOrderKey) == nil,
              let legacy = defaults.string(forKey: legacyKey),
              !legacy.isEmpty
        else { return }
        defaults.set(legacy, forKey: tabOrderKey)
    }
}
