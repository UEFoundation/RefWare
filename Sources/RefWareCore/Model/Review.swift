import Foundation

/// One attributed step in a claim's review: a judgment (a status), a flag ("this needs
/// another look"), a comment, or a resolution of a flag. Kept forever — the claim's
/// current status is the latest *final* judgment; everything before stays visible.
public struct ReviewEvent: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case judgment, flag, comment, resolution }
    public enum ReviewerType: String, Codable, Sendable { case human, ai }
    /// Judgments: `proposed` (an AI's suggestion awaiting a person), `final`, or `superseded`.
    /// Flags: `open` until resolved, then `resolved`. Comments and resolutions are `final`.
    public enum State: String, Codable, Sendable { case proposed, final, superseded, open, resolved }

    public var id: UUID
    public var date: Date
    public var kind: Kind
    public var reviewer: String
    public var reviewerType: ReviewerType
    /// The model behind an AI reviewer, when known (`REFWARE_MODEL`).
    public var model: String?
    /// For judgments: the status given.
    public var status: ClaimStatus?
    /// Short reason codes (`weak-quote`, `overclaim`, `wrong-source`…), free-form.
    public var reasons: [String]
    public var rationale: String?
    /// The quotes the reviewer relied on.
    public var quoteTags: [String]
    public var state: State
    /// For resolutions and accepted proposals: the event this answers.
    public var responds: UUID?

    public init(kind: Kind, reviewer: Reviewer, status: ClaimStatus? = nil, reasons: [String] = [], rationale: String? = nil,
                quoteTags: [String] = [], state: State, responds: UUID? = nil, date: Date = Date()) {
        id = UUID()
        self.date = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
        self.kind = kind
        self.reviewer = reviewer.name
        reviewerType = reviewer.type
        model = reviewer.model
        self.status = status
        self.reasons = reasons
        self.rationale = rationale
        self.quoteTags = quoteTags
        self.state = state
        self.responds = responds
    }
}

/// Who is reviewing. In the app it's the person at the keyboard; on the command line it's
/// `--by` / `REFWARE_ACTOR`, with `REFWARE_ACTOR_TYPE` (`human` or `ai`) and `REFWARE_MODEL`.
/// A named actor without a type is taken to be an AI agent (that's who AGENTS.md asks to set it).
public struct Reviewer: Hashable, Sendable {
    public var name: String
    public var type: ReviewEvent.ReviewerType
    public var model: String?

    public init(name: String, type: ReviewEvent.ReviewerType, model: String? = nil) {
        self.name = name
        self.type = type
        self.model = model
    }

    nonisolated(unsafe) public static var typeOverride: ReviewEvent.ReviewerType?

    /// The reviewer for this process. `fallbackHuman` names the person when no actor is set.
    public static func current(fallbackHuman: String) -> Reviewer {
        let env = ProcessInfo.processInfo.environment
        guard let name = HistoryEvent.defaultActor, !name.isEmpty else { return Reviewer(name: fallbackHuman, type: .human) }
        let type = typeOverride ?? env["REFWARE_ACTOR_TYPE"].flatMap { ReviewEvent.ReviewerType(rawValue: $0.lowercased()) } ?? .ai
        return Reviewer(name: name, type: type, model: type == .ai ? env["REFWARE_MODEL"] : nil)
    }
}

public enum ReviewOutcome: Equatable, Sendable {
    case applied
    /// An AI's judgment, recorded as a proposal for a person to accept.
    case proposed
}

extension Claim {
    public var reviews: [ReviewEvent] {
        get { reviewLog ?? [] }
        set { reviewLog = newValue.isEmpty ? nil : newValue }
    }
    /// Questioned: someone flagged it and nobody has resolved that yet. Independent of status —
    /// a supported claim can be questioned.
    public var openFlags: [ReviewEvent] { reviews.filter { $0.kind == .flag && $0.state == .open } }
    public var isQuestioned: Bool { !openFlags.isEmpty }
    public var pendingProposals: [ReviewEvent] { reviews.filter { $0.kind == .judgment && $0.state == .proposed } }
}

extension Library {
    private mutating func withClaim<T>(_ project: String, _ claimID: String, _ body: (inout Claim, ProjectCitationIndex) throws -> T) throws -> T {
        guard var index = projects[project] else { throw EvidenceError.unknownProject(project) }
        guard let c = index.claimIndex(claimID) else { throw EvidenceError.unknownClaim(claimID) }
        let result = try body(&index.claims[c], index)
        projects[project] = index
        return result
    }

    /// Records a judgment. A person's judgment (or an AI's, where the project allows it)
    /// sets the status and supersedes open proposals; otherwise it's kept as a proposal.
    @discardableResult
    public mutating func judge(project: String, claim claimID: String, status: ClaimStatus, by reviewer: Reviewer,
                               reasons: [String] = [], rationale: String? = nil, note: String? = nil) throws -> ReviewOutcome {
        let mayFinalize = reviewer.type == .human || projects[project]?.aiMayFinalize == true
        let quotes = projects[project].flatMap { i in i.claimIndex(claimID).map { i.claims[$0].quotes } } ?? []
        if mayFinalize {
            try setClaimStatus(project: project, claim: claimID, status: status, note: note, by: reviewer.name)
        } else if status == .supported {
            // Same rule as a final judgment: no proposal of "supported" without a current verified quote.
            try checkSupportable(project: project, claim: claimID)
        }
        return try withClaim(project, claimID) { claim, _ in
            if mayFinalize {
                for i in claim.reviews.indices where claim.reviews[i].kind == .judgment && claim.reviews[i].state != .superseded {
                    claim.reviews[i].state = .superseded
                }
            }
            claim.reviews.append(ReviewEvent(kind: .judgment, reviewer: reviewer, status: status, reasons: reasons, rationale: rationale,
                                             quoteTags: quotes, state: mayFinalize ? .final : .proposed))
            return mayFinalize ? .applied : .proposed
        }
    }

    /// A person accepts the latest pending proposal: its status becomes the claim's.
    public mutating func acceptProposal(project: String, claim claimID: String, by reviewer: Reviewer, note: String? = nil) throws -> ClaimStatus {
        guard reviewer.type == .human || projects[project]?.aiMayFinalize == true else { throw ReviewError.needsPerson }
        let proposal = try withClaim(project, claimID) { claim, _ in claim.pendingProposals.last }
        guard let proposal, let status = proposal.status else { throw ReviewError.noProposal(claimID) }
        try setClaimStatus(project: project, claim: claimID, status: status, note: nil, by: reviewer.name)
        try withClaim(project, claimID) { claim, _ in
            for i in claim.reviews.indices where claim.reviews[i].kind == .judgment && claim.reviews[i].state != .superseded { claim.reviews[i].state = .superseded }
            claim.reviews.append(ReviewEvent(kind: .judgment, reviewer: reviewer, status: status,
                                             rationale: note ?? "Accepted the proposal by \(proposal.reviewer)", quoteTags: proposal.quoteTags,
                                             state: .final, responds: proposal.id))
        }
        return status
    }

    /// Declines pending proposals; the status stays as it is.
    public mutating func rejectProposals(project: String, claim claimID: String, by reviewer: Reviewer, note: String?) throws -> Int {
        try withClaim(project, claimID) { claim, _ in
            let pending = claim.pendingProposals
            guard let last = pending.last else { throw ReviewError.noProposal(claimID) }
            for i in claim.reviews.indices where claim.reviews[i].state == .proposed { claim.reviews[i].state = .superseded }
            claim.reviews.append(ReviewEvent(kind: .comment, reviewer: reviewer, rationale: note ?? "Declined the proposal", state: .final, responds: last.id))
            return pending.count
        }
    }

    /// Flags a claim as questioned. Anyone may flag; the status is untouched.
    public mutating func flag(project: String, claim claimID: String, by reviewer: Reviewer, reasons: [String], rationale: String?) throws {
        try withClaim(project, claimID) { claim, index in
            claim.reviews.append(ReviewEvent(kind: .flag, reviewer: reviewer, reasons: reasons, rationale: rationale, quoteTags: claim.quotes, state: .open))
        }
    }

    public mutating func comment(project: String, claim claimID: String, by reviewer: Reviewer, text: String) throws {
        try withClaim(project, claimID) { claim, _ in
            claim.reviews.append(ReviewEvent(kind: .comment, reviewer: reviewer, rationale: text, state: .final))
        }
    }

    /// Resolves the open flags (all, or the one given). Returns how many were resolved.
    @discardableResult
    public mutating func resolveFlags(project: String, claim claimID: String, by reviewer: Reviewer, note: String?) throws -> Int {
        try withClaim(project, claimID) { claim, _ in
            let open = claim.reviews.indices.filter { claim.reviews[$0].kind == .flag && claim.reviews[$0].state == .open }
            guard !open.isEmpty else { throw ReviewError.noOpenFlag(claimID) }
            for i in open {
                claim.reviews[i].state = .resolved
                claim.reviews.append(ReviewEvent(kind: .resolution, reviewer: reviewer, rationale: note, state: .final, responds: claim.reviews[i].id))
            }
            return open.count
        }
    }
}

public enum ReviewError: Error, CustomStringConvertible, Equatable {
    case noProposal(String)
    case noOpenFlag(String)
    case needsPerson

    public var description: String {
        switch self {
        case .noProposal(let c): "\(c) has no pending proposal"
        case .noOpenFlag(let c): "\(c) has no open flag"
        case .needsPerson: "only a person can accept a proposal in this project (an AI may finalize only where the project allows it: `refware project policy <UEF-XXXX> --ai-may-finalize yes`)"
        }
    }
}
