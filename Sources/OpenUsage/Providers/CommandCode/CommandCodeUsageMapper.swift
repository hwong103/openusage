import Foundation

struct CommandCodeMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

struct CommandCodeSubscriptionContext: Equatable, Sendable {
    var planID: String
    var planName: String
    var currentPeriodStart: String
    var currentPeriodEnd: Date
    var periodDurationMs: Int
}

enum CommandCodeUsageMapper {
    private static let usableSubscriptionStatuses = Set(["active", "trialing", "past_due"])
    private static let planNames: [String: String] = [
        "individual-pro-v1": "Pro",
        "individual-provider": "Provider",
        "individual-goat": "GOAT",
        "individual-go": "Go",
        "individual-pro": "Pro",
        "individual-max": "Max",
        "individual-ultra": "Ultra",
        "teams-pro": "Teams Pro"
    ]

    static func organizationID(from body: Data) throws -> String? {
        let payload: WhoamiPayload = try decode(body)
        if payload.success == false { throw CommandCodeUsageError.invalidResponse }
        return nonEmpty(payload.organizationID)
    }

    static func subscriptionContext(from body: Data) throws -> CommandCodeSubscriptionContext? {
        let payload: SubscriptionPayload = try decode(body)
        if payload.success == false { throw CommandCodeUsageError.invalidResponse }
        guard let details = payload.details else { return nil }
        if let status = nonEmpty(details.status),
           !usableSubscriptionStatuses.contains(status.lowercased()) {
            return nil
        }
        guard let planID = nonEmpty(details.planID),
              let currentPeriodStart = nonEmpty(details.currentPeriodStart),
              let currentPeriodEnd = nonEmpty(details.currentPeriodEnd),
              let start = OpenUsageISO8601.date(from: currentPeriodStart),
              let end = OpenUsageISO8601.date(from: currentPeriodEnd)
        else {
            throw CommandCodeUsageError.invalidResponse
        }

        let durationMs = end.timeIntervalSince(start) * 1000
        guard durationMs.isFinite, durationMs > 0, durationMs < Double(Int.max) else {
            throw CommandCodeUsageError.invalidResponse
        }
        return CommandCodeSubscriptionContext(
            planID: planID,
            planName: planName(for: planID),
            currentPeriodStart: currentPeriodStart,
            currentPeriodEnd: end,
            periodDurationMs: Int(durationMs.rounded())
        )
    }

    static func map(
        creditsBody: Data,
        summaryBody: Data?,
        subscription: CommandCodeSubscriptionContext?
    ) throws -> CommandCodeMappedUsage {
        let credits: CreditsPayload = try decode(creditsBody)
        let summary = try summaryBody.map { try decode(UsageSummaryPayload.self, from: $0) }

        let monthlyRemaining = try nonnegative(credits.credits.monthlyCredits ?? 0)
        let purchasedRemaining = try nonnegative(credits.credits.purchasedCredits ?? 0)
        let freeRemaining = try nonnegative(credits.credits.freeCredits ?? 0)
        let balance = monthlyRemaining + purchasedRemaining + freeRemaining
        guard balance.isFinite else { throw CommandCodeUsageError.invalidResponse }

        var lines: [MetricLine] = []
        if let fiveHour = credits.windowLimits?.fiveHour {
            lines.append(try windowLine(
                label: "Session",
                window: fiveHour,
                periodDurationMs: MetricPeriod.sessionMs
            ))
        }
        if let weekly = credits.windowLimits?.weekly {
            lines.append(try windowLine(
                label: "Weekly",
                window: weekly,
                periodDurationMs: MetricPeriod.weekMs
            ))
        }

        if let summary {
            let totalCount = try nonnegative(summary.totalCount ?? 0)
            lines.append(.values(
                label: "Requests",
                values: [MetricValue(number: totalCount, kind: .count, label: "requests")]
            ))
            if let subscription {
                let monthlyUsed = try nonnegative(summary.totalMonthlyCredits ?? 0)
                let monthlyLimit = monthlyUsed + monthlyRemaining
                guard monthlyLimit.isFinite else { throw CommandCodeUsageError.invalidResponse }
                if monthlyLimit > 0 {
                    lines.insert(.progress(
                        label: "Monthly",
                        used: min(100, monthlyUsed / monthlyLimit * 100),
                        limit: 100,
                        format: .percent,
                        resetsAt: subscription.currentPeriodEnd,
                        periodDurationMs: subscription.periodDurationMs
                    ), at: min(2, lines.count))
                }
            }
        }

        if credits.credits.monthlyCredits != nil
            || credits.credits.purchasedCredits != nil
            || credits.credits.freeCredits != nil {
            lines.append(.values(
                label: "Balance",
                values: [MetricValue(number: balance, kind: .dollars)]
            ))
        }
        MetricLine.appendNoDataIfNeeded(&lines)
        return CommandCodeMappedUsage(plan: subscription?.planName, lines: lines)
    }

    static func planName(for planID: String) -> String {
        let normalized = planID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "_", with: "-")
        if let match = planNames.keys.sorted(by: { $0.count > $1.count }).first(where: {
            normalized == $0 || normalized.hasPrefix($0 + "-")
        }) {
            return planNames[match]!
        }
        let readable = normalized.split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")
        return readable.isEmpty ? planID : readable
    }

    private static func windowLine(
        label: String,
        window: WindowPayload,
        periodDurationMs: Int
    ) throws -> MetricLine {
        let used = try nonnegative(window.used)
        let cap = try nonnegative(window.cap)
        guard cap > 0, window.resetAt.isFinite, window.resetAt >= 0 else {
            throw CommandCodeUsageError.invalidResponse
        }
        // The API reports each window's budget in dollars, but what a user reads is how much of the
        // window is gone, so the meter carries the percentage and `limit` is the percent domain's
        // 100 (the same shape Claude's `utilization` and Codex's `usedPercent` meters already use).
        let percent = min(100, used / cap * 100)
        return .progress(
            label: label,
            used: percent,
            limit: 100,
            format: .percent,
            resetsAt: window.resetAt > 0 ? Date(timeIntervalSince1970: window.resetAt / 1000) : nil,
            periodDurationMs: periodDurationMs
        )
    }

    private static func nonnegative(_ value: Double) throws -> Double {
        guard value.isFinite, value >= 0 else { throw CommandCodeUsageError.invalidResponse }
        return value
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func decode<T: Decodable>(_ body: Data) throws -> T {
        try decode(T.self, from: body)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from body: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: body)
        } catch {
            throw CommandCodeUsageError.invalidResponse
        }
    }
}

fileprivate struct WhoamiPayload: Decodable {
    fileprivate var success: Bool?
    fileprivate var organizationID: String?

    private enum CodingKeys: String, CodingKey {
        case success, org, data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = try container.decodeIfPresent(Bool.self, forKey: .success)
        if let org = try container.decodeIfPresent(Organization.self, forKey: .org) {
            organizationID = org.id
        } else if let data = try container.decodeIfPresent(DataPayload.self, forKey: .data) {
            organizationID = data.org?.id
        } else {
            organizationID = nil
        }
    }

    fileprivate struct Organization: Decodable { fileprivate var id: String? }
    fileprivate struct DataPayload: Decodable { fileprivate var org: Organization? }
}

fileprivate struct SubscriptionPayload: Decodable {
    fileprivate var success: Bool?
    fileprivate var details: Details?

    private enum CodingKeys: String, CodingKey {
        case success, data
        case status, currentPeriodStart, currentPeriodEnd, planId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = try container.decodeIfPresent(Bool.self, forKey: .success)
        if let data = try container.decodeIfPresent(Details.self, forKey: .data) {
            details = data
        } else {
            details = try container.decodeIfPresent(Details.self, forKey: .data)
        }
    }

    fileprivate struct Details: Decodable {
        fileprivate var status: String?
        fileprivate var currentPeriodStart: String?
        fileprivate var currentPeriodEnd: String?
        fileprivate var planID: String?

        private enum CodingKeys: String, CodingKey {
            case status, currentPeriodStart, currentPeriodEnd, planId
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decodeIfPresent(String.self, forKey: .status)
            currentPeriodStart = try container.decodeIfPresent(String.self, forKey: .currentPeriodStart)
            currentPeriodEnd = try container.decodeIfPresent(String.self, forKey: .currentPeriodEnd)
            planID = try container.decodeIfPresent(String.self, forKey: .planId)
        }
    }
}

fileprivate struct CreditsPayload: Decodable {
    fileprivate var credits: Credits
    fileprivate var windowLimits: WindowLimitsPayload?

    private enum CodingKeys: String, CodingKey {
        case credits, windowLimits, data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let credits = try container.decodeIfPresent(Credits.self, forKey: .credits) {
            self.credits = credits
            windowLimits = try container.decodeIfPresent(WindowLimitsPayload.self, forKey: .windowLimits)
        } else {
            let data = try container.decode(DataPayload.self, forKey: .data)
            credits = data.credits
            windowLimits = data.windowLimits
        }
    }

    fileprivate struct Credits: Decodable {
        fileprivate var monthlyCredits: Double?
        fileprivate var purchasedCredits: Double?
        fileprivate var freeCredits: Double?
    }

    fileprivate struct WindowLimitsPayload: Decodable {
        fileprivate var fiveHour: WindowPayload?
        fileprivate var weekly: WindowPayload?

        private enum CodingKeys: String, CodingKey {
            case fiveHour, five_hour, weekly
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fiveHour = try container.decodeIfPresent(WindowPayload.self, forKey: .fiveHour)
                ?? container.decodeIfPresent(WindowPayload.self, forKey: .five_hour)
            weekly = try container.decodeIfPresent(WindowPayload.self, forKey: .weekly)
        }
    }

    fileprivate struct DataPayload: Decodable {
        fileprivate var credits: Credits
        fileprivate var windowLimits: WindowLimitsPayload?
    }
}

fileprivate struct WindowPayload: Decodable {
    fileprivate var used: Double
    fileprivate var cap: Double
    fileprivate var resetAt: Double
}

fileprivate struct UsageSummaryPayload: Decodable {
    fileprivate var totalCount: Double?
    fileprivate var totalMonthlyCredits: Double?
}
