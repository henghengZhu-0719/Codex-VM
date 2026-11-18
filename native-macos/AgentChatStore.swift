import Foundation

struct ChatFileChange: Codable {
    var path: String
    var kind: String
}

struct ChatStepItem: Codable {
    var id: String
    var type: String
    var status: String?
    var text: String?
    var command: String?
    var output: String?
    var exitCode: Int?
    var changes: [ChatFileChange]?

    enum CodingKeys: String, CodingKey {
        case id, type, status, text, command, output
        case exitCode = "exit_code"
        case changes
    }
}

struct ChatTokenUsage: Codable {
    var inputTokens: Int?
    var cachedInputTokens: Int?
    var outputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case outputTokens = "output_tokens"
    }
}

struct ChatMessage: Codable {
    var id: String
    var role: String
    var text: String
    var status: String
    var error: String?
    var startedAt: TimeInterval?
    var finishedAt: TimeInterval?
    var items: [ChatStepItem]?
    var usage: ChatTokenUsage?
    var attachments: [String]?
}

struct AgentSession: Codable {
    var id: String
    var vmName: String
    var agent: String
    var title: String
    var workdir: String
    var mode: String
    var threadId: String
    var createdAt: TimeInterval
    var updatedAt: TimeInterval
    var messages: [ChatMessage]
}

@MainActor
final class AgentChatStore {
    private(set) var sessionsByVM: [String: [AgentSession]] = [:]
    private(set) var activeSessionByVM: [String: String] = [:]
    private var saveWorkItems: [String: DispatchWorkItem] = [:]

    private let sessionsDir: URL
    private let activeFile: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let state = ProcessInfo.processInfo.environment["AGENT_VM_STATE_DIR"] ?? (NSHomeDirectory() + "/.agent-vm")
        sessionsDir = URL(fileURLWithPath: state, isDirectory: true).appendingPathComponent("sessions", isDirectory: true)
        activeFile = sessionsDir.appendingPathComponent("_active.json")
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        loadAll()
    }

    private func vmFile(for vmName: String) -> URL {
        let safe = vmName.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return sessionsDir.appendingPathComponent("\(safe).json")
    }

    func loadAll() {
        let fm = FileManager.default
        try? fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let activeData = try? Data(contentsOf: activeFile),
           let active = try? decoder.decode([String: String].self, from: activeData) {
            activeSessionByVM = active
        }
        guard let files = try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension == "json" && url.lastPathComponent != "_active.json" {
            guard let data = try? Data(contentsOf: url),
                  var sessions = try? decoder.decode([AgentSession].self, from: data),
                  let firstVM = sessions.first?.vmName else { continue }
            // Any session left in "running" state from a prior crash/quit is normalized to "stopped".
            for i in sessions.indices {
                for j in sessions[i].messages.indices where sessions[i].messages[j].status == "running" {
                    sessions[i].messages[j].status = "stopped"
                    if sessions[i].messages[j].finishedAt == nil {
                        sessions[i].messages[j].finishedAt = sessions[i].updatedAt
                    }
                }
            }
            sessionsByVM[firstVM] = sessions.sorted { $0.updatedAt > $1.updatedAt }
            if activeSessionByVM[firstVM] == nil || !sessions.contains(where: { $0.id == activeSessionByVM[firstVM] }) {
                activeSessionByVM[firstVM] = sessionsByVM[firstVM]?.first?.id
            }
        }
    }

    func saveImmediate(for vmName: String) {
        saveWorkItems[vmName]?.cancel()
        saveWorkItems.removeValue(forKey: vmName)
        let list = sessionsByVM[vmName] ?? []
        let url = vmFile(for: vmName)
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if list.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? encoder.encode(list) {
            try? data.write(to: url, options: .atomic)
        }
        saveActiveMap()
    }

    private func scheduleSave(for vmName: String) {
        saveWorkItems[vmName]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.saveImmediate(for: vmName)
        }
        saveWorkItems[vmName] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    private func saveActiveMap() {
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? encoder.encode(activeSessionByVM) {
            try? data.write(to: activeFile, options: .atomic)
        }
    }

    func flushAll() {
        for (vmName, item) in saveWorkItems {
            item.cancel()
            saveWorkItems.removeValue(forKey: vmName)
            let list = sessionsByVM[vmName] ?? []
            if let data = try? encoder.encode(list) {
                try? data.write(to: vmFile(for: vmName), options: .atomic)
            }
        }
        saveActiveMap()
    }

    func sessions(for vmName: String) -> [AgentSession] {
        sessionsByVM[vmName] ?? []
    }

    func session(vmName: String, sessionId: String) -> AgentSession? {
        sessionsByVM[vmName]?.first { $0.id == sessionId }
    }

    @discardableResult
    func ensureActiveSession(vmName: String, defaultWorkdir: String = "/mnt/agent-vm-shared", defaultMode: String = "full-auto") -> AgentSession {
        let list = sessionsByVM[vmName] ?? []
        if let activeId = activeSessionByVM[vmName],
           let found = list.first(where: { $0.id == activeId }) {
            return found
        }
        if let first = list.first {
            activeSessionByVM[vmName] = first.id
            saveActiveMap()
            return first
        }
        return createSession(vmName: vmName, agent: "codex", workdir: defaultWorkdir, mode: defaultMode)
    }

    @discardableResult
    func createSession(vmName: String, agent: String = "codex", workdir: String = "/mnt/agent-vm-shared", mode: String = "full-auto") -> AgentSession {
        let now = Date().timeIntervalSince1970
        let cleanWorkdir = workdir.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = AgentSession(
            id: UUID().uuidString,
            vmName: vmName,
            agent: agent,
            title: "新对话",
            workdir: cleanWorkdir.isEmpty ? "/mnt/agent-vm-shared" : cleanWorkdir,
            mode: mode,
            threadId: "",
            createdAt: now,
            updatedAt: now,
            messages: []
        )
        var list = sessionsByVM[vmName] ?? []
        list.insert(session, at: 0)
        sessionsByVM[vmName] = list
        activeSessionByVM[vmName] = session.id
        saveImmediate(for: vmName)
        return session
    }

    func selectSession(vmName: String, sessionId: String) {
        guard let list = sessionsByVM[vmName], list.contains(where: { $0.id == sessionId }) else { return }
        activeSessionByVM[vmName] = sessionId
        saveActiveMap()
    }

    func renameSession(vmName: String, sessionId: String, title: String) {
        let trimmed = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !trimmed.isEmpty else { return }
        updateSession(vmName: vmName, sessionId: sessionId, immediateSave: true) { s in
            s.title = trimmed
        }
    }

    func deleteSession(vmName: String, sessionId: String) {
        guard var list = sessionsByVM[vmName] else { return }
        list.removeAll { $0.id == sessionId }
        sessionsByVM[vmName] = list
        if activeSessionByVM[vmName] == sessionId {
            activeSessionByVM[vmName] = list.first?.id
        }
        saveImmediate(for: vmName)
    }

    func removeAllSessions(for vmName: String) {
        sessionsByVM.removeValue(forKey: vmName)
        activeSessionByVM.removeValue(forKey: vmName)
        saveImmediate(for: vmName)
    }

    func updateSession(vmName: String, sessionId: String, immediateSave: Bool = false, mutate: (inout AgentSession) -> Void) {
        guard var list = sessionsByVM[vmName],
              let idx = list.firstIndex(where: { $0.id == sessionId }) else { return }
        mutate(&list[idx])
        list[idx].updatedAt = Date().timeIntervalSince1970
        list.sort { $0.updatedAt > $1.updatedAt }
        sessionsByVM[vmName] = list
        if immediateSave {
            saveImmediate(for: vmName)
        } else {
            scheduleSave(for: vmName)
        }
    }

    static func deriveTitle(from prompt: String) -> String {
        let oneLine = prompt
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if oneLine.isEmpty { return "新对话" }
        return oneLine.count > 36 ? String(oneLine.prefix(36)) + "…" : oneLine
    }

    func bridgePayload(runningSessions: Set<String>, runningVMs: Set<String>) -> [String: Any] {
        var serializedSessions: [String: [[String: Any]]] = [:]
        var activeThreads: [String: String] = [:]
        var activeMessages: [String: [[String: Any]]] = [:]

        for (vm, list) in sessionsByVM {
            if let data = try? encoder.encode(list),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                serializedSessions[vm] = arr
                let activeId = activeSessionByVM[vm] ?? list.first?.id
                if let activeId, let activeObj = arr.first(where: { ($0["id"] as? String) == activeId }) ?? arr.first {
                    activeThreads[vm] = activeObj["threadId"] as? String ?? ""
                    activeMessages[vm] = activeObj["messages"] as? [[String: Any]] ?? []
                }
            }
        }

        return [
            "runningVM": runningVMs.sorted().first ?? "",
            "runningVMs": runningVMs.sorted(),
            "runningSessions": runningSessions.sorted(),
            "activeSessions": activeSessionByVM,
            "sessions": serializedSessions,
            "threads": activeThreads,
            "messages": activeMessages
        ]
    }
}
