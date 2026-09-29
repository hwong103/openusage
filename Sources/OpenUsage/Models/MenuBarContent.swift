import Foundation

/// Resolved, ordered, capped data for the menu-bar strip, built from the pinned metrics and their live
/// values. The renderers consume this: `groups` drives the Text style (one segment per pinned provider,
/// each with its 1–2 pinned metrics), `bars` drives the Bars style (the first four bounded metrics — any
/// with a fill, not just percentages — in order). `isEmpty` means render the plain app icon.
struct MenuBarContent: Equatable {
    /// One resolved pinned metric.
    struct Metric: Equatable {
        let id: String          // descriptor id
        let label: String       // metric label, e.g. "Session" (shown when a provider has two metrics)
        let value: String       // tray display: a "%" for bounded metrics, the raw value (e.g. "$5.23") for unbounded, or the no-data marker
        let fraction: Double     // 0...1 fill, meaningful for bounded metrics (drives the bars)
        let isBounded: Bool      // has a limit → has a fill, so it can render as a bar
        let hasData: Bool
    }

    /// A provider and its pinned metrics, in order. One segment of the Text strip.
    struct Group: Equatable {
        let providerID: String
        let displayName: String
        let icon: IconSource
        let metrics: [Metric]
    }

    /// Provider groups for the Text style, in Customize order. Dynamic: only metrics that currently
    /// have real data appear, and a provider whose pinned metrics all lack data drops out entirely
    /// (no orphan icon) — so the strip never renders "—" placeholders.
    let groups: [Group]
    /// Bounded metrics (those with a fill) for the Bars style, flattened in order and capped to four.
    let bars: [Metric]

    /// Nothing is pinned, every pinned provider is disabled, or no pinned metric has data yet — the
    /// menu bar falls back to the app icon.
    var isEmpty: Bool { groups.isEmpty }

    /// VoiceOver summary for the rendered strip image, e.g.
    /// "Claude Session 41%, Weekly 12%; Cursor Credits $12".
    var accessibilityText: String {
        groups.map { group in
            let metrics = group.metrics.map { "\($0.label) \($0.value)" }.joined(separator: ", ")
            return "\(group.displayName) \(metrics)"
        }
        .joined(separator: "; ")
    }
}

@MainActor
enum MenuBarContentBuilder {
    /// Max bars the compact style renders (matches the original OpenUsage tray).
    static let maxBars = 4

    /// Resolve pinned provider groups into menu-bar content. `groups` is `LayoutStore.pinnedGroups`
    /// (already ordered, disabled providers excluded); `data` resolves each descriptor to its live
    /// `WidgetData` (i.e. `WidgetDataStore.data(for:)`), so the values follow the global meter style
    /// just like the dashboard tiles.
    ///
    /// The strip is dynamic: a pinned metric without data is dropped (one of two pins renders alone at
    /// full size), and a provider with no data-carrying pins contributes no icon at all. Pins are
    /// membership; the strip shows whatever subset is real right now.
    ///
    /// `registry` is optional and only consulted for providers whose tray reading depends on a metric
    /// the user may not have pinned (Command Code's Monthly drives its Balance/percentage swap). With
    /// no registry the substitution is skipped and pins render literally, which is what the non-CC
    /// providers do anyway.
    static func build(
        groups: [ProviderMetrics],
        data: (WidgetDescriptor) -> WidgetData,
        registry: WidgetRegistry? = nil
    ) -> MenuBarContent {
        let resolvedGroups = groups.compactMap { group -> MenuBarContent.Group? in
            let metrics = resolveMetrics(group, data: data, registry: registry)
            guard !metrics.isEmpty else { return nil }
            return MenuBarContent.Group(
                providerID: group.provider.id,
                displayName: group.provider.displayName,
                icon: group.provider.icon,
                metrics: metrics
            )
        }
        // Bars show any *bounded* metric (it has a fill), not just percentages. Unbounded values (raw
        // spend/credits, no limit) have no fill and are dropped.
        let bars = resolvedGroups
            .flatMap(\.metrics)
            .filter(\.isBounded)
            .prefix(maxBars)
        return MenuBarContent(groups: resolvedGroups, bars: Array(bars))
    }

    /// A provider's pinned metrics, with any data-dependent tray substitution applied, resolved and
    /// filtered to those that have data.
    private static func resolveMetrics(
        _ group: ProviderMetrics,
        data: (WidgetDescriptor) -> WidgetData,
        registry: WidgetRegistry?
    ) -> [MenuBarContent.Metric] {
        let descriptors = traySubstituted(group, data: data, registry: registry)
        return descriptors.map { resolve($0, data($0)) }.filter(\.hasData)
    }

    /// Command Code meters a *pool*, so its percentage windows and its dollar Balance are the same money
    /// seen from two sides, and which one is worth showing depends on the pool state rather than on a
    /// fixed pin:
    ///
    /// - While the included monthly allowance still has room, the percentage windows are the honest
    ///   reading and the dollar Balance is that same allowance restated in dollars, so a pinned Balance
    ///   reads as noise and yields its slot to the Monthly percentage.
    /// - Once the allowance is spent, the remaining Balance is *purchased top-up credit* — additional,
    ///   finite, and the one figure worth watching — so the Monthly percentage is dropped in favour of it.
    ///
    /// The substitution is presentational only: pins, their order, and the Customize layout are
    /// untouched. It is decided from live Monthly data whether or not Monthly is itself pinned, because
    /// the pool state — not the pin set — decides which reading is real.
    private static func traySubstituted(
        _ group: ProviderMetrics,
        data: (WidgetDescriptor) -> WidgetData,
        registry: WidgetRegistry?
    ) -> [WidgetDescriptor] {
        let pinned = group.metrics
        let balanceID = CommandCodeProvider.balanceMetricID
        let monthlyID = CommandCodeProvider.monthlyMetricID
        guard group.provider.id == CommandCodeProvider.providerID,
              let monthly = registry?.descriptor(id: monthlyID)
        else {
            return pinned
        }
        // Both readings explicitly pinned is a deliberate choice — never override it.
        let hasBalance = pinned.contains { $0.id == balanceID }
        let hasMonthly = pinned.contains { $0.id == monthlyID }
        guard hasBalance != hasMonthly else { return pinned }

        // No live Monthly reading (provider still loading, or the API omitted it) is no evidence that the
        // allowance is spent, so the percentage — correct in the common case — is what gets shown.
        let monthlyData = data(monthly)
        let allowanceSpent = monthlyData.hasData
            && monthlyData.used > 0
            && monthlyData.remainingFraction <= Self.creditTopUpThreshold

        // Pool intact: the pinned dollars are the allowance restated, so stand Monthly in their slot.
        // Pool spent: the dollars are top-up credit and are kept, and an unpinned Monthly is withheld so
        // a permanent 100% never crowds out the finite balance.
        if hasBalance {
            guard !allowanceSpent else { return pinned }
            // Substitute the Monthly *descriptor* rather than rewriting Balance's sample: `data(for:)`
            // resolves a descriptor against its provider's metric lines by `metricLabel`, so handing it
            // the real Monthly descriptor is what makes the tray read the percentage.
            return pinned.map { $0.id == balanceID ? monthly : $0 }
        }
        guard allowanceSpent else { return pinned }
        let order = Self.trayOrder(in: group, registry: registry)
        let position = order.firstIndex(of: monthlyID) ?? order.count
        var result = pinned
        let balance = registry?.descriptor(id: balanceID)
        if let balance {
            result.insert(balance, at: min(position, result.count))
        }
        return result
    }

    /// The provider's own metric order, used to place a substituted metric where it belongs rather than
    /// wherever the pin set happens to leave a gap.
    private static func trayOrder(in group: ProviderMetrics, registry: WidgetRegistry?) -> [String] {
        if let ordered = registry?.descriptors(for: group.provider.id), !ordered.isEmpty {
            return ordered.map(\.id)
        }
        return group.metrics.map(\.id)
    }

    /// How much of the included monthly allowance must be spent before the tray treats the dollar
    /// Balance as purchased top-up credit rather than a restatement of that allowance. One percent
    /// absorbs API rounding, so a pool reading 100% used while a cent of credit remains still counts as
    /// spent — the state where the dollar figure is the one worth watching.
    private static let creditTopUpThreshold = 0.01

    private static func resolve(_ descriptor: WidgetDescriptor, _ data: WidgetData) -> MenuBarContent.Metric {
        MenuBarContent.Metric(
            id: descriptor.id,
            label: trayLabel(descriptor.metricLabel),
            value: data.menuBarValue,
            fraction: data.fraction,
            isBounded: data.isBounded,
            hasData: data.hasData
        )
    }

    /// Tray-only label shortening (the dashboard keeps the full names): the long time-window metrics
    /// collapse to a single letter so a two-metric stack stays narrow. Unknown labels pass through.
    private static func trayLabel(_ metricLabel: String) -> String {
        switch metricLabel.lowercased() {
        case "today": return "T"
        case "yesterday": return "Y"
        case "last 30 days": return "M"
        default: return metricLabel
        }
    }
}
