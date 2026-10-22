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
    /// The manual order of the sessions in no workspace; nil from a host that has none.
    var sessionOrder: [String]?
    var workspacesSupported: Bool?
    var earlierItems: [EarlierItem]?
    var earlierSupported: Bool?

    /// Each Pal asked for alone (`AppStore.singlePal`), kept in step with `pals`.
    @ObservationIgnored private var palSlots: [String: PalSlot] = [:]

    func palSlot(_ id: String) -> PalSlot {
        if let s = palSlots[id] { return s }
        let s = PalSlot(pals.first { $0.id == id })
        palSlots[id] = s
        return s
    }

    /// After `pals` changed: only the slots whose Pal changed are written.
    func syncPalSlots() {
        for (id, slot) in palSlots {
            let p = pals.first { $0.id == id }
            if slot.pal != p { slot.pal = p }
        }
    }
}

/// One Pal, observed on its own: a view reading it is re-rendered when this
/// Pal changes, not when any other on the list does (a split workspace's
/// tiles each follow their own session while the others tick).
@MainActor
@Observable
final class PalSlot {
    var pal: Pal?
    init(_ pal: Pal?) { self.pal = pal }
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
