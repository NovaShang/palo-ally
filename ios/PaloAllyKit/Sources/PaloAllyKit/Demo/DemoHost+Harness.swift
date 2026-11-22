import Foundation

// The demo host imitates a Claude Code host: what its harness can do (the
// capability descriptor hello carries) and the lists its model and agent
// pages offer, in this one place.
extension DemoHost {
    /// The demo's Claude Code models, as model.get lists them (the first is the default).
    static let claudeCodeModels: JSONValue = [
        ["value": "default", "displayName": "默认（推荐）", "description": "Opus 5.5", "efforts": ["low", "medium", "high", "xhigh", "max"]],
        ["value": "sonnet", "displayName": "Sonnet", "description": "Sonnet 5 · 日常够用", "efforts": ["low", "medium", "high", "xhigh", "max"]],
        ["value": "haiku", "displayName": "Haiku", "description": "Haiku 4.5 · 最快", "efforts": []],
    ]
    static let claudeCodeEfforts: JSONValue = ["low", "medium", "high", "xhigh", "max"]
    static let claudeCodeModes: [String] = ["default", "auto", "acceptEdits", "plan"]

    /// The descriptor, as the real host sends it (host/src/harness/claude/index.ts).
    static let claudeCode: JSONValue = [
        "id": "claude-code",
        "name": "Claude Code",
        "commandPrefix": "/",
        "login": ["kind": "oauth-code", "account": "Claude", "fromPhone": true],
        "models": claudeCodeModels,
        "efforts": claudeCodeEfforts,
        "permissionModes": .array(claudeCodeModes.map { .string($0) }),
        "labels": [:],
        "features": [
            "rewind": true, "restoreFiles": true, "compact": true, "autoCompact": true, "takeOverTerminal": true,
            "handBackToTerminal": true, "rename": true, "subagents": true, "backgroundTasks": true, "images": true, "files": true,
            "questions": ["multiSelect": true, "maxOptions": 4], "liveModelSwitch": true, "liveModeSwitch": true,
            "projectMemory": true, "globalHooks": true,
        ],
        "terminal": ["exitCommand": "/exit", "resumeCommand": "claude --resume {sessionId}", "newCommand": "claude"],
        "memory": ["projectFile": "CLAUDE.md"],
    ]
}
