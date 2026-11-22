import Foundation

// One agent's details, the assistant's and a Pal's alike: what the details
// page shows (docs/workbench-design/structure-wireframe.html §3). The host
// sends them in two shapes (`model.get` + `status` for the assistant,
// `pals.detail` for an agent); the page reads only this one.

/// One model the owner can pick, and the thinking depths it takes.
public struct ModelChoice: Sendable, Hashable, Identifiable {
    /// What the host takes to switch to it.
    public var id: String
    public var name: String
    public var description: String
    public var efforts: [String]

    public init(id: String, name: String, description: String = "", efforts: [String] = []) {
        self.id = id; self.name = name; self.description = description; self.efforts = efforts
    }

    public init(_ o: ModelOption) { self.init(id: o.value, name: o.displayName, description: o.description, efforts: o.efforts) }
    public init(_ o: PalModelOption) { self.init(id: o.id, name: o.name, efforts: o.efforts) }
}

/// A background task or subagent, running or ended.
public struct AgentTask: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// A subagent it sent off.
        case subagent
        /// A shell command left running.
        case background
        /// One of the assistant's tasks (its own page: `TaskDetailView`).
        case task
    }

    public var id: String
    public var title: String
    public var kind: Kind
    public var startedAt: Int64
    public var summary: String?
    /// Ended: when, and how.
    public var endedAt: Int64?
    public var ending: PalTask.Ending?
    /// It waits on the owner (an assistant's task that asked something).
    public var needsYou: Bool

    public init(id: String, title: String, kind: Kind, startedAt: Int64, summary: String? = nil,
                endedAt: Int64? = nil, ending: PalTask.Ending? = nil, needsYou: Bool = false) {
        self.id = id; self.title = title; self.kind = kind; self.startedAt = startedAt; self.summary = summary
        self.endedAt = endedAt; self.ending = ending; self.needsYou = needsYou
    }

    public init(_ t: PalTask) {
        self.init(id: t.id, title: t.title, kind: t.kind == .subagent ? .subagent : .background, startedAt: t.startedAt,
                  summary: t.summary, endedAt: t.endedAt, ending: t.status)
    }

    public init(_ t: AllyTask) {
        let ending: PalTask.Ending? = switch t.status {
        case .running, .needsInput: nil
        case .done: .done
        case .failed: .failed
        case .stopped: .stopped
        case .unknown: .unknown
        }
        self.init(id: t.id, title: t.title, kind: .task, startedAt: t.createdAt, summary: t.summary.isEmpty ? nil : t.summary,
                  endedAt: ending == nil ? nil : t.updatedAt, ending: ending, needsYou: t.status == .needsInput)
    }
}

public struct AgentDetail: Sendable, Equatable {
    /// What one kind of agent has that the other hasn't (the page's flags).
    public struct Capabilities: Sendable, Equatable {
        /// The first model is the default: picking it sends none, and 思考深度 has a 默认 row.
        public var defaultChoice: Bool
        /// 压缩 on the context row.
        public var compact: Bool
        /// A running task can be stopped one by one.
        public var stopTasks: Bool
        /// 定时 (the assistant's watches).
        public var timers: Bool
        /// 说话的语言.
        public var language: Bool
        /// 名字和颜色 (the assistant's color is the app's); else 名字 alone.
        public var color: Bool
        /// 工作区 (which one it's in).
        public var workspace: Bool
        /// 归档 at the bottom (else 让助理停下).
        public var archive: Bool

        public static let assistant = Capabilities(defaultChoice: true, compact: false, stopTasks: false, timers: true,
                                                   language: true, color: true, workspace: false, archive: false)
        public static let agent = Capabilities(defaultChoice: false, compact: true, stopTasks: true, timers: false,
                                               language: false, color: false, workspace: true, archive: true)
    }

    public var models: [ModelChoice]
    /// The option it runs on; nil: none of them (a full id the list doesn't offer), or the default for the assistant.
    public var model: String?
    /// What runs, as the host names it (shown when no option matches).
    public var runningModel: String
    public var effort: String?
    /// The depths its model takes (none: no picker).
    public var efforts: [String]
    public var contextPct: Int?
    public var contextTokens: Int?
    public var contextWindow: Int?
    /// Running now.
    public var tasks: [AgentTask]
    /// Ended, newest first.
    public var pastTasks: [AgentTask]
    /// The permission mode chosen for it; nil: none to choose (the assistant, an older host).
    public var permissionMode: String?
    /// The one Claude Code says it runs in now, when that's another.
    public var runningMode: String?
    public var permissionModes: [String]
    public var capabilities: Capabilities
    /// What its harness can do: the words for its depths and modes, its lists when the page has none of its own.
    public var harness: HarnessCapabilities = .claudeCodeFallback

    public init(models: [ModelChoice] = [], model: String? = nil, runningModel: String = "", effort: String? = nil,
                efforts: [String] = [], contextPct: Int? = nil, contextTokens: Int? = nil, contextWindow: Int? = nil,
                tasks: [AgentTask] = [], pastTasks: [AgentTask] = [], permissionMode: String? = nil,
                runningMode: String? = nil, permissionModes: [String] = [], capabilities: Capabilities) {
        self.models = models; self.model = model; self.runningModel = runningModel; self.effort = effort
        self.efforts = efforts; self.contextPct = contextPct; self.contextTokens = contextTokens
        self.contextWindow = contextWindow; self.tasks = tasks; self.pastTasks = pastTasks
        self.permissionMode = permissionMode; self.runningMode = runningMode; self.permissionModes = permissionModes
        self.capabilities = capabilities
    }

    /// The selected option's id for the picker: the saved choice, else the
    /// default (the first) when there is one, else what runs.
    public var selectedModel: String {
        model ?? (capabilities.defaultChoice ? models.first?.id : nil) ?? runningModel
    }

    /// The context bar's fill: from the token counts when known, else the percent.
    public var contextFill: Int? {
        if let t = contextTokens, let w = contextWindow, w > 0 { return min(100, Int((Double(t) / Double(w) * 100).rounded())) }
        return contextPct
    }

    /// `pals.detail`.
    public init(_ d: PalDetail, harness: HarnessCapabilities = .claudeCodeFallback) {
        let models = d.models.map(ModelChoice.init)
        let current = d.modelOption ?? d.model ?? d.pal?.model
        self.init(models: models, model: models.contains { $0.id == current } ? current : nil,
                  runningModel: d.model ?? d.pal?.model ?? "", effort: d.effort ?? d.pal?.effort, efforts: d.efforts,
                  contextPct: d.pal?.contextPct, contextTokens: d.contextTokens, contextWindow: d.contextWindow,
                  tasks: d.tasks.map(AgentTask.init), pastTasks: d.pastTasks.map(AgentTask.init),
                  permissionMode: d.permissionMode,
                  runningMode: d.runningMode.flatMap { $0 == d.permissionMode ? nil : $0 },
                  permissionModes: d.permissionModes, capabilities: .agent)
        self.harness = harness
    }

    /// The assistant's: its model list (`model.get`), its status, its tasks.
    public init(assistant info: ModelInfo?, status: HostStatus?, tasks: [AllyTask], harness: HarnessCapabilities = .claudeCodeFallback) {
        // model.get's list; until it has come, the harness' own (the descriptor's)
        let models = (info?.models ?? harness.models).map(ModelChoice.init)
        let saved = info?.setting
        let selected = saved.flatMap { s in models.contains { $0.id == s } ? s : nil }
        let on = selected ?? models.first?.id
        let sorted = tasks.sorted { $0.updatedAt > $1.updatedAt }
        self.init(models: models, model: selected, runningModel: status?.model ?? info?.model ?? "",
                  effort: status?.effort ?? info?.effort, efforts: models.first { $0.id == on }?.efforts ?? [],
                  contextPct: status?.contextPct, contextTokens: status?.contextTokens, contextWindow: status?.contextWindow,
                  tasks: sorted.filter(\.isActive).map(AgentTask.init),
                  pastTasks: sorted.filter { !$0.isActive }.map(AgentTask.init), capabilities: .assistant)
        self.harness = harness
    }
}
