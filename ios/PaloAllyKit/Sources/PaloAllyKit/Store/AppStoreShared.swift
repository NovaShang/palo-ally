import Foundation
import Observation

/// The state of one computer that every conversation on it shares: the
/// link, the lists, the cards, the settings. The assistant's store and each
/// Pal's scoped store read and write it through their own properties
/// (`AppStore.connection`, `.approvals`, …); a view observes whichever store
/// it holds and sees the same values.
@MainActor
@Observable
final class AppStoreShared {
    var connection: AppStore.Connection = .idle
    var displayedConnection: AppStore.Connection = .idle
    var connectionTrouble = false
    var hostName = ""
    var hostVersion = ""
    var tasks: [AllyTask] = []
    var approvals: [Approval] = []
    var questions: [Question] = []
    var watches: [Watch] = []
    var artifacts: [Artifact] = []
    var settings: HostSettings?
    var commands: [SlashCommand] = []
    var modelInfo: ModelInfo?
    var copiedClipboardIDs: Set<String> = []

    var allies: [AllyInfo] = []
    var alliesSupported: Bool?
    var allyLogs: [String: [AllyEntry]] = [:]
    var allyLogHasMore: [String: Bool] = [:]
    var looseAllyEntries: [String: AllyEntry] = [:]

    var sessions: [CCSession] = []
    var sessionsSupported: Bool?
    var sessionHooksEnabled: Bool?
    var sessionHistories: [String: [CCMessage]] = [:]
    var sessionHistoryHasMore: [String: Bool] = [:]
    var helperDecisions: [String: HelperProposalStatus] = [:]
    var helperSessions: [String: String] = [:]
    var watchedSessions: [String: Int] = [:]

    var pals: [Pal] = []
    var otherSessions: [CCSession] = []
    var palsSupported: Bool?
    var adoptions: [String: PalAdoption] = [:]
    var cancelledWaits: Set<String> = []
    var recentSessions: [RecentSession]?
    var recentSupported: Bool?
    var adoptDecisions: [String: PalAdoptProposalStatus] = [:]
    var adoptProposalPals: [String: String] = [:]

    var workspaces: [Workspace] = []
    var workspacesSupported: Bool?
    var earlierItems: [EarlierItem]?
    var earlierSupported: Bool?
}

/// A session on its way to becoming a Pal (`pals.adopt`).
public enum PalAdoption: Sendable, Hashable {
    /// Asked; the host is stopping the original and resuming its record.
    case working
    /// A terminal session: the owner quits it there (/exit), and the host
    /// carries on as soon as it has gone.
    case waitingForExit
    /// Didn't happen: why, in the host's words.
    case failed(String)
}
