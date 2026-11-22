import Foundation

/// What the harness an agent runs on can do (the host's capability descriptor,
/// docs/harness-adapter-design.md §3): its name, its login, its models, thinking
/// depths and permission modes, which features it has, and the terminal
/// commands copy names. `hello` carries one per harness and `harness.updated`
/// a new one when its models change. A host from before it sends none: then
/// `claudeCodeFallback` (the lists the app had built in) stands in, so every
/// Claude Code list lives in this one place.
public struct HarnessCapabilities: Decodable, Sendable, Hashable {
    public struct Login: Decodable, Sendable, Hashable {
        /// "oauth-code" (a link out, a code back), "api-key" or "none".
        public var kind: String
        /// Whose account it signs in with ("Claude").
        public var account: String
        /// Signing in again from the phone works.
        public var fromPhone: Bool

        public init(kind: String, account: String, fromPhone: Bool) {
            self.kind = kind; self.account = account; self.fromPhone = fromPhone
        }

        public init(from decoder: Decoder) throws {
            let l = try Lenient(decoder)
            kind = l.string("kind", or: "none")
            account = l.string("account", or: "")
            fromPhone = l.bool("fromPhone", or: false)
        }
    }

    public struct Features: Decodable, Sendable, Hashable {
        public var rewind: Bool
        public var restoreFiles: Bool
        public var compact: Bool
        public var autoCompact: Bool
        public var takeOverTerminal: Bool
        public var handBackToTerminal: Bool
        public var rename: Bool
        public var subagents: Bool
        public var backgroundTasks: Bool
        public var images: Bool
        public var files: Bool
        public var questionsMultiSelect: Bool
        public var liveModelSwitch: Bool
        public var liveModeSwitch: Bool
        public var projectMemory: Bool
        public var globalHooks: Bool

        /// Everything on (Claude Code's).
        public static let all = Features(rewind: true, restoreFiles: true, compact: true, autoCompact: true, takeOverTerminal: true,
                                         handBackToTerminal: true, rename: true, subagents: true, backgroundTasks: true, images: true,
                                         files: true, questionsMultiSelect: true, liveModelSwitch: true, liveModeSwitch: true,
                                         projectMemory: true, globalHooks: true)

        public init(rewind: Bool, restoreFiles: Bool, compact: Bool, autoCompact: Bool, takeOverTerminal: Bool, handBackToTerminal: Bool,
                    rename: Bool, subagents: Bool, backgroundTasks: Bool, images: Bool, files: Bool, questionsMultiSelect: Bool,
                    liveModelSwitch: Bool, liveModeSwitch: Bool, projectMemory: Bool, globalHooks: Bool) {
            self.rewind = rewind; self.restoreFiles = restoreFiles; self.compact = compact; self.autoCompact = autoCompact
            self.takeOverTerminal = takeOverTerminal; self.handBackToTerminal = handBackToTerminal; self.rename = rename
            self.subagents = subagents; self.backgroundTasks = backgroundTasks; self.images = images; self.files = files
            self.questionsMultiSelect = questionsMultiSelect; self.liveModelSwitch = liveModelSwitch; self.liveModeSwitch = liveModeSwitch
            self.projectMemory = projectMemory; self.globalHooks = globalHooks
        }

        enum Q: String, CodingKey { case multiSelect, maxOptions }

        public init(from decoder: Decoder) throws {
            let l = try Lenient(decoder)
            // A feature the host doesn't name is off (a newer harness may lack one an older list assumed).
            rewind = l.bool("rewind") ?? false
            restoreFiles = l.bool("restoreFiles") ?? false
            compact = l.bool("compact") ?? false
            autoCompact = l.bool("autoCompact") ?? false
            takeOverTerminal = l.bool("takeOverTerminal") ?? false
            handBackToTerminal = l.bool("handBackToTerminal") ?? false
            rename = l.bool("rename") ?? false
            subagents = l.bool("subagents") ?? false
            backgroundTasks = l.bool("backgroundTasks") ?? false
            images = l.bool("images") ?? false
            files = l.bool("files") ?? false
            questionsMultiSelect = l.decode(QuestionsFeature.self, "questions")?.multiSelect ?? false
            liveModelSwitch = l.bool("liveModelSwitch") ?? false
            liveModeSwitch = l.bool("liveModeSwitch") ?? false
            projectMemory = l.bool("projectMemory") ?? false
            globalHooks = l.bool("globalHooks") ?? false
        }
    }

    struct QuestionsFeature: Decodable, Sendable, Hashable {
        var multiSelect: Bool
        var maxOptions: Int
        init(from decoder: Decoder) throws {
            let l = try Lenient(decoder)
            multiSelect = l.bool("multiSelect", or: false)
            maxOptions = l.int("maxOptions", or: 0)
        }
    }

    public struct Terminal: Decodable, Sendable, Hashable {
        /// What quits a session in a terminal ("/exit").
        public var exitCommand: String
        /// The line that resumes a session, with `{sessionId}` in it.
        public var resumeCommand: String
        public var newCommand: String

        public init(exitCommand: String, resumeCommand: String, newCommand: String) {
            self.exitCommand = exitCommand; self.resumeCommand = resumeCommand; self.newCommand = newCommand
        }

        public init(from decoder: Decoder) throws {
            let l = try Lenient(decoder)
            exitCommand = l.string("exitCommand", or: "")
            resumeCommand = l.string("resumeCommand", or: "")
            newCommand = l.string("newCommand", or: "")
        }

        /// The resume line for one session.
        public func resume(_ sessionId: String) -> String {
            resumeCommand.replacingOccurrences(of: "{sessionId}", with: sessionId)
        }
    }

    public var id: String
    /// Its name, as copy says which tool runs an agent ("Claude Code").
    public var name: String
    /// What starts a slash command ("/"); nil: it has none.
    public var commandPrefix: String?
    public var login: Login
    /// Its models as it lists them (the first is its default); empty until a process of it has started.
    public var models: [ModelOption]
    /// Thinking depths, lowest first.
    public var efforts: [String]
    /// The permission modes the owner can switch an agent to.
    public var permissionModes: [String]
    /// Words for ids the app may not know, in the host's language.
    public var labels: [String: String]
    public var features: Features
    public var terminal: Terminal
    /// The project instruction file an agent reads ("CLAUDE.md").
    public var projectFile: String

    public init(id: String, name: String, commandPrefix: String?, login: Login, models: [ModelOption], efforts: [String],
                permissionModes: [String], labels: [String: String] = [:], features: Features, terminal: Terminal, projectFile: String) {
        self.id = id; self.name = name; self.commandPrefix = commandPrefix; self.login = login; self.models = models
        self.efforts = efforts; self.permissionModes = permissionModes; self.labels = labels; self.features = features
        self.terminal = terminal; self.projectFile = projectFile
    }

    struct Memory: Decodable { var projectFile: String? }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        let fallback = HarnessCapabilities.claudeCodeFallback
        id = l.string("id", or: fallback.id)
        name = l.string("name", or: id)
        commandPrefix = l.string("commandPrefix")
        login = l.decode(Login.self, "login", or: Login(kind: "none", account: "", fromPhone: false))
        models = l.array(ModelOption.self, "models", or: [])
        efforts = l.array(String.self, "efforts", or: [])
        permissionModes = l.array(String.self, "permissionModes", or: [])
        labels = l.decode([String: String].self, "labels") ?? [:]
        features = l.decode(Features.self, "features", or: Features.all)
        terminal = l.decode(Terminal.self, "terminal", or: fallback.terminal)
        projectFile = l.decode(Memory.self, "memory")?.projectFile ?? fallback.projectFile
    }

    /// What an older host's Claude Code is: the lists the app had built in before the descriptor.
    public static let claudeCodeFallback = HarnessCapabilities(
        id: "claude-code",
        name: "Claude Code",
        commandPrefix: "/",
        login: Login(kind: "oauth-code", account: "Claude", fromPhone: true),
        models: [],
        efforts: ["low", "medium", "high", "xhigh", "max"],
        permissionModes: ["default", "auto", "acceptEdits", "plan"],
        features: .all,
        terminal: Terminal(exitCommand: "/exit", resumeCommand: "claude --resume {sessionId}", newCommand: "claude"),
        projectFile: "CLAUDE.md"
    )

    /// A label for a thinking depth: the app's own words for a known id, else the host's, else the id.
    public func effortLabel(_ id: String?) -> String {
        guard let id else { return EffortName.label(nil) }
        if EffortName.known.contains(id) { return EffortName.label(id) }
        return labels[id] ?? id
    }

    /// A label for a permission mode: the app's own words for a known id, else the host's, else the id.
    public func modeLabel(_ id: String?) -> String {
        guard let id else { return PermissionModeName.label(nil) }
        if PermissionModeName.known.contains(id) { return PermissionModeName.label(id) }
        return labels[id] ?? id
    }
}

/// `harness.updated`: one harness' new descriptor (its models changed).
public struct HarnessUpdate: Decodable, Sendable {
    public var id: String
    public var capabilities: HarnessCapabilities

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        id = l.string("id", or: "")
        capabilities = l.decode(HarnessCapabilities.self, "capabilities", or: .claudeCodeFallback)
    }
}
