import AppKit
import Combine
import Foundation
import Security
import SwiftUI
import SwiftTerm

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case terminal
    case models
    case agents
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "General"
        case .terminal: return "Terminal"
        case .models: return "Models"
        case .agents: return "Agents"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .terminal: return "terminal"
        case .models: return "sparkles"
        case .agents: return "person.2"
        case .about: return "info.circle"
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }
}

enum AIProvider: String, CaseIterable, Identifiable {
    case openAI = "OpenAI"
    case anthropic = "Anthropic"
    case openRouter = "OpenRouter"
    case ollama = "Ollama"
    case lmStudio = "LM Studio"
    case compatible = "OpenAI Compatible"

    var id: Self { self }

    var isLocal: Bool {
        self == .ollama || self == .lmStudio
    }

    var requiresAPIKey: Bool {
        switch self {
        case .openAI, .anthropic, .openRouter:
            return true
        case .ollama, .lmStudio, .compatible:
            return false
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .ollama: return "http://localhost:11434/v1"
        case .lmStudio: return "http://localhost:1234/v1"
        case .compatible: return "http://localhost:1234/v1"
        }
    }

    var keychainAccount: String {
        "api-key-\(rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))"
    }
}

struct AIModel: Identifiable, Hashable {
    let id: String
    let name: String
    let hint: String

    init(_ id: String, _ name: String = "", _ hint: String = "") {
        self.id = id
        self.name = name.isEmpty ? id : name
        self.hint = hint
    }

    var label: String {
        hint.isEmpty ? name : "\(name) · \(hint)"
    }
}

struct AIMessage: Identifiable, Equatable {
    enum Role: String {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    let content: String
}

enum KeychainStore {
    private static let service = "dev.swiftty.terminal"

    static func read(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func write(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) != errSecSuccess {
            var item = query
            item[kSecValueData as String] = data
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    private let defaults: UserDefaults

    @Published var selectedSettingsTab: SettingsTab = .general
    @Published var appearance: AppAppearance {
        didSet { persist("appearance", appearance.rawValue) }
    }
    @Published var showHiddenFiles: Bool {
        didSet { persist("showHiddenFiles", showHiddenFiles) }
    }
    @Published var terminalFontSize: Double {
        didSet { persist("terminalFontSize", terminalFontSize) }
    }

    /// Bounds the font can be nudged between with ⌘+/⌘-.
    static let fontSizeRange: ClosedRange<Double> = 9...28
    private static let defaultFontSize: Double = 13

    func adjustFontSize(by delta: Double) {
        terminalFontSize = min(max(terminalFontSize + delta, Self.fontSizeRange.lowerBound),
                               Self.fontSizeRange.upperBound)
    }

    func resetFontSize() {
        terminalFontSize = Self.defaultFontSize
    }
    @Published var terminalCursorBlink: Bool {
        didSet { persist("terminalCursorBlink", terminalCursorBlink) }
    }
    /// How much of the desktop shows through the window, 0.5–1.0.
    @Published var windowOpacity: Double {
        didSet { persist("windowOpacity", windowOpacity) }
    }
    /// Frosts whatever is behind the window instead of showing it sharply.
    @Published var windowBlur: Bool {
        didSet { persist("windowBlur", windowBlur) }
    }
    /// Width of the file explorer, in points.
    @Published var sidebarWidth: Double {
        didSet { persist("sidebarWidth", sidebarWidth) }
    }
    /// Tightens the spacing between blocks to fit more on screen.
    @Published var compactBlocks: Bool {
        didSet { persist("compactBlocks", compactBlocks) }
    }

    /// True when the window should let the desktop through at all.
    var isTranslucent: Bool { windowOpacity < 0.99 }
    @Published var shellPath: String {
        didSet { persist("shellPath", shellPath) }
    }

    @Published var selectedProvider: AIProvider {
        didSet { persist("aiProvider", selectedProvider.rawValue) }
    }
    @Published var selectedModelID: String {
        didSet {
            persist("aiModel", selectedModelID)
            persist("aiModel.\(selectedProvider.rawValue)", selectedModelID)
        }
    }
    @Published var baseURL: String {
        didSet { persist("aiBaseURL", baseURL) }
    }
    @Published private(set) var apiKey: String
    @Published var customInstructions: String {
        didSet { persist("customInstructions", customInstructions) }
    }
    @Published var selectedAgent: String {
        didSet { persist("selectedAgent", selectedAgent) }
    }
    @Published private(set) var discoveredModels: [AIModel] = []
    @Published private(set) var modelsLoading = false
    @Published private(set) var modelError: String?

    private var modelDiscoveryGeneration = UUID()
    private static let legacyModelIDs: Set<String> = [
        "gpt-5.6-luna",
        "gpt-5.6-terra",
        "gpt-5.6",
        "claude-sonnet-4-20250514",
        "claude-3-7-sonnet-latest",
        "openai/gpt-4o-mini",
        "anthropic/claude-3.7-sonnet",
        "google/gemini-2.5-flash",
        "llama3.2",
        "qwen2.5-coder",
        "mistral",
        "local-model",
        "custom-model",
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = AppAppearance(rawValue: defaults.string(forKey: "appearance") ?? "system") ?? .system
        showHiddenFiles = defaults.bool(forKey: "showHiddenFiles")
        terminalFontSize = defaults.object(forKey: "terminalFontSize") as? Double ?? 13
        terminalCursorBlink = defaults.object(forKey: "terminalCursorBlink") as? Bool ?? true
        windowOpacity = defaults.object(forKey: "windowOpacity") as? Double ?? 0.75
        windowBlur = defaults.object(forKey: "windowBlur") as? Bool ?? true
        compactBlocks = defaults.object(forKey: "compactBlocks") as? Bool ?? false
        sidebarWidth = defaults.object(forKey: "sidebarWidth") as? Double ?? 260
        shellPath = defaults.string(forKey: "shellPath") ?? ShellInfo.path
        let provider = AIProvider(rawValue: defaults.string(forKey: "aiProvider") ?? "OpenAI") ?? .openAI
        selectedProvider = provider
        let storedModel = defaults.string(forKey: "aiModel.\(provider.rawValue)")
            ?? defaults.string(forKey: "aiModel")
            ?? ""
        selectedModelID = Self.sanitizedStoredModel(storedModel)
        baseURL = defaults.string(forKey: "aiBaseURL") ?? provider.defaultBaseURL
        apiKey = KeychainStore.read(account: provider.keychainAccount)
        customInstructions = defaults.string(forKey: "customInstructions") ?? ""
        selectedAgent = defaults.string(forKey: "selectedAgent") ?? "Coder"
    }

    var modelOptions: [AIModel] {
        var options = discoveredModels
        let manualID = selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manualID.isEmpty && !options.contains(where: { $0.id == manualID }) {
            options.insert(AIModel(manualID, manualID, "Manual"), at: 0)
        }
        return options
    }

    var selectedModel: String {
        selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isConfigured: Bool {
        let hasKey = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !selectedModel.isEmpty && (!selectedProvider.requiresAPIKey || hasKey)
    }

    func setProvider(_ provider: AIProvider) {
        selectedProvider = provider
        let storedModel = defaults.string(forKey: "aiModel.\(provider.rawValue)") ?? ""
        selectedModelID = Self.sanitizedStoredModel(storedModel)
        baseURL = provider.defaultBaseURL
        apiKey = KeychainStore.read(account: provider.keychainAccount)
        discoveredModels = []
        modelError = nil
        Task { await refreshModels() }
    }

    func setAPIKey(_ value: String) {
        apiKey = value
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            KeychainStore.delete(account: selectedProvider.keychainAccount)
        } else {
            KeychainStore.write(value, account: selectedProvider.keychainAccount)
        }
    }

    func refreshModels() async {
        let generation = UUID()
        modelDiscoveryGeneration = generation
        modelsLoading = true
        modelError = nil

        do {
            let models = try await AIGateway.listModels(
                provider: selectedProvider,
                apiKey: apiKey,
                baseURL: baseURL
            )
            guard generation == modelDiscoveryGeneration else { return }
            discoveredModels = models
        } catch {
            guard generation == modelDiscoveryGeneration else { return }
            discoveredModels = []
            modelError = error.localizedDescription
        }

        if generation == modelDiscoveryGeneration {
            modelsLoading = false
        }
    }

    private static func sanitizedStoredModel(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return legacyModelIDs.contains(trimmed) ? "" : trimmed
    }

    func persist(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
    }
}

enum AIGatewayError: LocalizedError {
    case missingAPIKey
    case missingModel
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Add an API key in Settings → Models first."
        case .missingModel: return "Choose or enter a model ID in Settings → Models first."
        case .invalidResponse: return "The provider returned an unreadable response."
        case .server(let message): return message
        }
    }
}

enum AIGateway {
    static func listModels(
        provider: AIProvider,
        apiKey: String,
        baseURL: String
    ) async throws -> [AIModel] {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provider.requiresAPIKey || !trimmedKey.isEmpty else {
            throw AIGatewayError.missingAPIKey
        }

        let endpoint: URL
        if provider == .ollama {
            endpoint = try ollamaModelsURL(baseURL)
        } else {
            endpoint = try endpointURL(baseURL, path: "models")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        if !trimmedKey.isEmpty {
            if provider == .anthropic {
                request.setValue(trimmedKey, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else {
                request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
            }
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        let models = try parseModels(data)
        guard !models.isEmpty else {
            throw AIGatewayError.server("The provider returned no models. Enter the exact model ID manually.")
        }
        return models
    }

    static func complete(
        provider: AIProvider,
        model: String,
        apiKey: String,
        baseURL: String,
        agent: String,
        customInstructions: String,
        messages: [AIMessage]
    ) async throws -> String {
        guard !provider.requiresAPIKey || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIGatewayError.missingAPIKey
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIGatewayError.missingModel
        }

        if provider == .anthropic {
            return try await completeAnthropic(
                model: model,
                apiKey: apiKey,
                baseURL: baseURL,
                agent: agent,
                customInstructions: customInstructions,
                messages: messages
            )
        }

        let endpoint = try endpointURL(baseURL, path: "chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        var requestMessages: [[String: String]] = messages.map {
            ["role": $0.role.rawValue, "content": $0.content]
        }
        let systemPrompt = systemPrompt(agent: agent, customInstructions: customInstructions)
        if !systemPrompt.isEmpty {
            requestMessages.insert(["role": "system", "content": systemPrompt], at: 0)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": requestMessages,
            "temperature": 0.4,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIGatewayError.invalidResponse
        }
        return content
    }

    private static func completeAnthropic(
        model: String,
        apiKey: String,
        baseURL: String,
        agent: String,
        customInstructions: String,
        messages: [AIMessage]
    ) async throws -> String {
        let endpoint = try endpointURL(baseURL, path: "messages")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let systemPrompt = systemPrompt(agent: agent, customInstructions: customInstructions)
        var payload: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
        ]
        if !systemPrompt.isEmpty { payload["system"] = systemPrompt }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = root["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            throw AIGatewayError.invalidResponse
        }
        return text
    }

    private static func endpointURL(_ baseURL: String, path: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmed)/\(path)") else { throw AIGatewayError.invalidResponse }
        return url
    }

    private static func ollamaModelsURL(_ baseURL: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var url = URL(string: trimmed) else { throw AIGatewayError.invalidResponse }
        if url.path.hasSuffix("/v1") {
            url.deleteLastPathComponent()
        }
        return url.appendingPathComponent("api/tags")
    }

    private static func parseModels(_ data: Data) throws -> [AIModel] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIGatewayError.invalidResponse
        }

        let rows = (root["data"] as? [[String: Any]]) ?? (root["models"] as? [[String: Any]]) ?? []
        let IDs = rows.compactMap { row in
            (row["id"] as? String)
                ?? (row["name"] as? String)
                ?? (row["model"] as? String)
        }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        return IDs
            .filter { seen.insert($0).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { AIModel($0, $0) }
    }

    private static func systemPrompt(agent: String, customInstructions: String) -> String {
        var parts = ["You are the \(agent) agent inside Swiftty. Be concise, practical, and honest."]
        let trimmed = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append(trimmed) }
        return parts.joined(separator: "\n\n")
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = (payload?["error"] as? [String: Any])?["message"] as? String
            throw AIGatewayError.server(error ?? "The provider returned an HTTP error.")
        }
    }
}

extension Notification.Name {
    static let swifttyOpenSettings = Notification.Name("SwifttyOpenSettings")
}

@MainActor
enum SettingsCoordinator {
    private static var preferences: AppPreferences?
    private static var store: TerminalStore?
    private static var settingsWindow: NSWindow?

    static func configure(preferences: AppPreferences, store: TerminalStore) {
        self.preferences = preferences
        self.store = store
    }

    static func open(tab: SettingsTab) {
        guard let preferences, let store else { return }
        preferences.selectedSettingsTab = tab
        NotificationCenter.default.post(name: .swifttyOpenSettings, object: tab)

        if settingsWindow == nil {
            let root = SettingsView()
                .environmentObject(preferences)
                .environmentObject(store)
            let controller = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: controller)
            window.title = "Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 820, height: 590))
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SwifttyCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Settings…") {
                SettingsCoordinator.open(tab: .general)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

@main
struct SwifttyApp: App {
    @StateObject private var preferences: AppPreferences
    @StateObject private var store: TerminalStore

    init() {
        let preferences = AppPreferences()
        let store = TerminalStore(preferences: preferences)
        _preferences = StateObject(wrappedValue: preferences)
        _store = StateObject(wrappedValue: store)
        SettingsCoordinator.configure(preferences: preferences, store: store)
    }

    var body: some Scene {
        WindowGroup {
            TerminalWorkspace()
                .environmentObject(store)
                .environmentObject(preferences)
                .frame(minWidth: 860, minHeight: 540)
                .ignoresSafeArea(.container, edges: .top)
        }
        // Drops the title bar so the tab strip becomes the top of the window.
        // The traffic lights stay, floating over the chrome row, which is why
        // that row carries a leading inset wide enough to clear them.
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .toolbar) {
                // "+" is Shift-"=", so binding "+" alone would demand Shift.
                // Binding the bare "=" as well means ⌘= works without it — the
                // way every browser and editor lets you zoom.
                Button("Increase Text Size") {
                    preferences.adjustFontSize(by: 1)
                }
                .keyboardShortcut("+", modifiers: .command)
                Button("Increase Text Size") {
                    preferences.adjustFontSize(by: 1)
                }
                .keyboardShortcut("=", modifiers: .command)

                Button("Decrease Text Size") {
                    preferences.adjustFontSize(by: -1)
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Reset Text Size") {
                    preferences.resetFontSize()
                }
                .keyboardShortcut("0", modifiers: .command)
            }

            CommandGroup(after: .newItem) {
                Button("New Tab") {
                    store.newTab()
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("Select Tab 1") { store.select(index: 0) }
                    .keyboardShortcut("1", modifiers: .command)
                    .disabled(store.tabs.count < 1)
                Button("Select Tab 2") { store.select(index: 1) }
                    .keyboardShortcut("2", modifiers: .command)
                    .disabled(store.tabs.count < 2)
                Button("Select Tab 3") { store.select(index: 2) }
                    .keyboardShortcut("3", modifiers: .command)
                    .disabled(store.tabs.count < 3)
                Button("Select Tab 4") { store.select(index: 3) }
                    .keyboardShortcut("4", modifiers: .command)
                    .disabled(store.tabs.count < 4)
                Button("Select Tab 5") { store.select(index: 4) }
                    .keyboardShortcut("5", modifiers: .command)
                    .disabled(store.tabs.count < 5)
                Button("Select Tab 6") { store.select(index: 5) }
                    .keyboardShortcut("6", modifiers: .command)
                    .disabled(store.tabs.count < 6)
                Button("Select Tab 7") { store.select(index: 6) }
                    .keyboardShortcut("7", modifiers: .command)
                    .disabled(store.tabs.count < 7)
                Button("Select Tab 8") { store.select(index: 7) }
                    .keyboardShortcut("8", modifiers: .command)
                    .disabled(store.tabs.count < 8)
                Button("Select Tab 9") { store.select(index: 8) }
                    .keyboardShortcut("9", modifiers: .command)
                    .disabled(store.tabs.count < 9)

                Button("Next Tab") {
                    store.selectRelativeTab(by: 1)
                }
                .keyboardShortcut(.tab, modifiers: .control)

                Button("Previous Tab") {
                    store.selectRelativeTab(by: -1)
                }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])

                Button("Close Tab") {
                    store.closeActiveTab()
                }
                .keyboardShortcut("w", modifiers: .command)

                Button("Toggle AI Agent") {
                    store.toggleAIPanel()
                }
                .keyboardShortcut("i", modifiers: .command)

                Divider()

                Button("Toggle File Explorer") {
                    store.toggleSidebar()
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("Enable Blocks in This Session") {
                    store.activeBlockTracker?.warpifySession()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button("Find in Blocks") {
                    store.beginSearch()
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("Clear Blocks") {
                    store.clearBlocks()
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("Previous Block") {
                    store.stepBlockSelection(by: -1)
                }
                .keyboardShortcut(.upArrow, modifiers: .command)

                Button("Next Block") {
                    store.stepBlockSelection(by: 1)
                }
                .keyboardShortcut(.downArrow, modifiers: .command)

                Button("Copy Block Output") {
                    store.copySelectedBlockOutput()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }

            SwifttyCommands()
        }
        .windowToolbarStyle(.unifiedCompact)

    }
}

@MainActor
final class TerminalStore: ObservableObject {
    @Published private(set) var tabs: [TerminalTab] = [.init()]
    @Published private(set) var activeTabID: TerminalTab.ID
    @Published var sidebarVisible = true
    @Published var aiPanelVisible = false
    /// Filters the block history. Empty shows everything.
    @Published var searchQuery = ""
    /// The find bar is only on screen while searching.
    @Published var searchVisible = false
    /// Bumped by ⌘F to pull focus into the search field.
    @Published var searchFocusRequests = 0
    /// Which match Return has stepped to. Wrapped against the match count.
    @Published var searchMatchIndex = 0
    @Published private(set) var aiMessages: [AIMessage] = []
    @Published private(set) var aiSending = false

    /// One block tracker per tab, kept here so the panel and the terminal view
    /// share the same one and it outlives SwiftUI view updates.
    ///
    /// Deliberately not `@Published`: views observe individual trackers, and
    /// publishing the dictionary would fire while a view body is reading it.
    private var blockTrackers: [TerminalTab.ID: BlockTracker] = [:]

    let preferences: AppPreferences

    init(preferences: AppPreferences) {
        self.preferences = preferences
        let initialTab = TerminalTab()
        tabs = [initialTab]
        activeTabID = initialTab.id
        blockTrackers[initialTab.id] = BlockTracker()
    }

    var activeTab: TerminalTab? {
        tabs.first { $0.id == activeTabID }
    }

    func newTab() {
        let tab = TerminalTab()
        blockTrackers[tab.id] = BlockTracker()
        tabs.append(tab)
        activeTabID = tab.id
    }

    func select(_ tabID: TerminalTab.ID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        activeTabID = tabID
    }

    /// Cycles tabs, wrapping at either end.
    func selectRelativeTab(by offset: Int) {
        guard tabs.count > 1,
              let current = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        let next = (current + offset + tabs.count) % tabs.count
        activeTabID = tabs[next].id
    }

    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeTabID = tabs[index].id
    }

    func beginSearch() {
        searchVisible = true
        searchFocusRequests += 1
    }

    func endSearch() {
        searchVisible = false
        searchQuery = ""
        searchMatchIndex = 0
    }

    /// Return in the search field steps to the next match.
    func advanceSearchMatch(by offset: Int = 1) {
        searchMatchIndex += offset
    }

    func toggleSidebar() {
        sidebarVisible.toggle()
    }

    func toggleAIPanel() {
        aiPanelVisible.toggle()
    }

    /// The tracker for a tab. Trackers are created alongside their tab, so the
    /// fallback here only ever fires for a tab that has already been closed.
    func blockTracker(for tabID: TerminalTab.ID) -> BlockTracker {
        blockTrackers[tabID] ?? BlockTracker()
    }

    var activeBlockTracker: BlockTracker? {
        blockTrackers[activeTabID]
    }

    /// Wipes the active tab's block history.
    func clearBlocks() {
        activeBlockTracker?.clearHistory()
    }

    /// Moves the block selection in the active tab. `offset` is -1 for the
    /// previous block, +1 for the next.
    func stepBlockSelection(by offset: Int) {
        activeBlockTracker?.moveSelection(by: offset)
    }

    /// Copies the selected block's output, falling back to the most recent
    /// finished block when nothing is selected.
    func copySelectedBlockOutput() {
        guard let tracker = activeBlockTracker else { return }
        let block = tracker.selectedBlock
            ?? tracker.blocks.last { !$0.command.isEmpty }
        guard let block else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(tracker.plainOutput(for: block), forType: .string)
    }

    func clearAIChat() {
        aiMessages.removeAll()
    }

    func sendAI(_ prompt: String) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !aiSending else { return }

        let userMessage = AIMessage(role: .user, content: trimmed)
        aiMessages.append(userMessage)
        aiSending = true
        defer { aiSending = false }

        do {
            let response = try await AIGateway.complete(
                provider: preferences.selectedProvider,
                model: preferences.selectedModel,
                apiKey: preferences.apiKey,
                baseURL: preferences.baseURL,
                agent: preferences.selectedAgent,
                customInstructions: preferences.customInstructions,
                messages: aiMessages
            )
            aiMessages.append(AIMessage(role: .assistant, content: response))
        } catch {
            aiMessages.append(
                AIMessage(
                    role: .assistant,
                    content: "Request failed: \(error.localizedDescription)"
                )
            )
        }
    }

    func closeActiveTab() {
        close(activeTabID)
    }

    func close(_ tabID: TerminalTab.ID) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == tabID }) else {
            return
        }

        let closingID = tabs[index].id
        tabs.remove(at: index)
        blockTrackers.removeValue(forKey: closingID)
        ShellIntegration.cleanUp(tabID: closingID)
        guard closingID == activeTabID else { return }
        activeTabID = tabs[min(index, tabs.count - 1)].id
    }

    func updateTitle(_ title: String, for tabID: TerminalTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tabs[index].title = trimmed
    }

    func updateDirectory(_ directory: String?, for tabID: TerminalTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].directory = directory
    }

    func markExited(for tabID: TerminalTab.ID, code: Int32?) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].exitCode = code

        // A shell that exited is a dead tab — `exit` should close it the way it
        // would in any terminal. Only the *local* shell process ending reaches
        // here; exiting an SSH session returns to the local shell and never
        // terminates it.
        if tabs.count > 1 {
            close(tabID)
        } else {
            // The last tab: close the window, which quits the app.
            NSApp.keyWindow?.close()
        }
    }
}

struct TerminalTab: Identifiable, Equatable {
    let id: UUID
    var title: String
    var directory: String?
    var exitCode: Int32?

    init(
        id: UUID = UUID(),
        title: String = ShellInfo.displayName,
        directory: String? = FileManager.default.homeDirectoryForCurrentUser.path,
        exitCode: Int32? = nil
    ) {
        self.id = id
        self.title = title
        self.directory = directory
        self.exitCode = exitCode
    }
}

struct TerminalWorkspace: View {
    @EnvironmentObject private var store: TerminalStore
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        ZStack {
            WindowBackdrop(
                opacity: preferences.windowOpacity,
                blurred: preferences.windowBlur
            )

            VStack(spacing: 0) {
                WorkspaceChrome()

                HStack(spacing: 0) {
                    if store.sidebarVisible {
                        WorkspaceSidebar(tracker: store.blockTracker(for: store.activeTabID))
                            .frame(width: preferences.sidebarWidth)
                            .transition(.move(edge: .leading).combined(with: .opacity))

                        SidebarResizer()
                    }

                    WorkspaceMain()
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeOut(duration: 0.24), value: store.sidebarVisible)
            }
        }
        .preferredColorScheme(preferredColorScheme)
    }

    private var preferredColorScheme: ColorScheme? {
        switch preferences.appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct WorkspaceChrome: View {
    @EnvironmentObject private var store: TerminalStore
    @State private var commandPalettePresented = false

    var body: some View {
        Group {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    ChromeButton(systemName: "sidebar.left", help: "Toggle sidebar") {
                        store.toggleSidebar()
                    }

                    ChromeButton(systemName: "command", help: "Command palette") {
                        commandPalettePresented.toggle()
                    }
                    .popover(isPresented: $commandPalettePresented, arrowEdge: .top) {
                        CommandPaletteView {
                            commandPalettePresented = false
                        }
                        .environmentObject(store)
                        .frame(width: 290)
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.06))
                .clipShape(Capsule())

                HStack(spacing: 5) {
                    Text("Default")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

                TerminalTabStrip()

                Spacer(minLength: 8)

                HStack(spacing: 2) {
                    ChromeButton(
                        systemName: "sparkles",
                        help: store.aiPanelVisible ? "Close AI agent (⌘I)" : "Open AI agent (⌘I)"
                    ) {
                        store.toggleAIPanel()
                    }
                    ChromeButton(systemName: "bell", help: "Notifications") {}
                    ChromeButton(systemName: "gearshape", help: "Settings") {
                        SettingsCoordinator.open(tab: .general)
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.06))
                .clipShape(Capsule())
            }
        }
        // Leaves room for the traffic lights, which now float over this row
        // rather than sitting in a title bar of their own.
        .padding(.leading, 82)
        .padding(.trailing, 8)
        .frame(height: 46)
        .background {
            // Without this the row would swallow drags and the window could
            // only be moved by its edges.
            Surface.chrome
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 1)
        }
    }
}

/// The drag handle between the explorer and the terminal.
struct SidebarResizer: View {
    @EnvironmentObject private var preferences: AppPreferences
    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(isHovering ? 0.14 : 0.07))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            // The hit area is wider than the hairline, or the handle would be
            // almost impossible to grab.
            .contentShape(Rectangle().inset(by: -4))
            .onHover { hovering in
                isHovering = hovering
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        preferences.sidebarWidth = min(max(
                            preferences.sidebarWidth + value.translation.width, 200
                        ), 520)
                    }
            )
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// A plain button that dips and dims slightly while pressed, so every control
/// gives a bit of tactile feedback instead of firing dead.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct ChromeButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(.secondary)
        .help(help)
    }
}


struct TerminalTabStrip: View {
    @EnvironmentObject private var store: TerminalStore

    var body: some View {
        HStack(spacing: 4) {
            ForEach(store.tabs) { tab in
                TerminalTabButton(
                    tracker: store.blockTracker(for: tab.id),
                    isActive: tab.id == store.activeTabID,
                    onSelect: { store.select(tab.id) }
                )
                // A new tab grows in from the trailing edge; a closed one
                // collapses away, so the strip reshuffles smoothly instead of
                // snapping.
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.8, anchor: .leading)
                        .combined(with: .opacity)
                        .combined(with: .move(edge: .leading)),
                    removal: .scale(scale: 0.8, anchor: .center)
                        .combined(with: .opacity)
                ))
            }

            ChromeButton(systemName: "plus", help: "New tab") {
                store.newTab()
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: store.tabs.count)
        .animation(.easeOut(duration: 0.18), value: store.activeTabID)
    }
}

struct TerminalTabButton: View {
    // Observed, not read through the store: the label changes when a command
    // starts or the directory moves, and the store publishes neither.
    @ObservedObject var tracker: BlockTracker
    let isActive: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 7) {
                Image(systemName: tracker.runningBlock == nil
                    ? "terminal"
                    : "circle.dotted")
                    .font(.system(size: 12, weight: .medium))
                    .symbolEffect(.pulse, isActive: tracker.runningBlock != nil)

                Text(tracker.tabLabel)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(isActive ? .primary : .secondary)
        .background(
            Capsule().fill(Color.white.opacity(isActive ? 0.08 : 0))
        )
        .clipShape(Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Terminal tab " + tracker.tabLabel)
        .animation(.easeOut(duration: 0.15), value: tracker.tabLabel)
        .animation(.easeOut(duration: 0.2), value: isActive)
    }
}

extension TerminalTab {
    var displayLabel: String {
        guard let directory, !directory.isEmpty else { return ShellInfo.userName }
        return (directory as NSString).lastPathComponent.isEmpty
            ? ShellInfo.userName
            : (directory as NSString).lastPathComponent
    }
}

struct WorkspaceMain: View {
    @EnvironmentObject private var store: TerminalStore
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                ForEach(store.tabs) { tab in
                    let tracker = store.blockTracker(for: tab.id)
                    BlockStack(
                        tracker: tracker,
                        terminal: TerminalSessionView(
                            tabID: tab.id,
                            isActive: tab.id == store.activeTabID,
                            // The editor owns the keyboard until a command runs
                            // long enough to be shown live; the terminal takes it
                            // back then, for a full-screen program, or for a
                            // shell we could not instrument. Keying on
                            // runningVisible rather than runningBlock keeps the
                            // editor focused through quick commands.
                            wantsFocus: tracker.runningVisible
                                || tracker.isAlternateScreen
                                || !tracker.isIntegrationActive,
                            tracker: tracker,
                            onTitle: { store.updateTitle($0, for: tab.id) },
                            onDirectory: { store.updateDirectory($0, for: tab.id) },
                            onExit: { store.markExited(for: tab.id, code: $0) }
                        )
                    )
                    // The active tab fades to the front; the rest fade back.
                    // No scale transform here — a fractional scale on the
                    // AppKit-backed terminal keeps AppKit re-running autolayout
                    // every frame, burning CPU at idle. Opacity alone is free.
                    .opacity(tab.id == store.activeTabID ? 1 : 0)
                    .allowsHitTesting(tab.id == store.activeTabID)
                    .accessibilityHidden(tab.id != store.activeTabID)
                }
            }
            .padding(.top, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.18), value: store.activeTabID)

            if store.aiPanelVisible {
                Divider()
                AIAgentPanel()
                    .frame(width: 340)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.24), value: store.aiPanelVisible)
        
    }
}

enum SidebarView: String {
    case files
    case sourceControl
}

struct WorkspaceSidebar: View {
    @ObservedObject var tracker: BlockTracker

    @State private var activeView: SidebarView = .files
    @State private var searchPresented = false
    @StateObject private var explorerModel = FileExplorerModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "folder")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                if let host = explorerModel.remoteHost {
                    Image(systemName: "link")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.blue)
                        .help("Showing files on \(host)")
                }

                Text(explorerModel.rootLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(explorerModel.rootURL.path)

                Spacer(minLength: 0)

                ChromeButton(systemName: "magnifyingglass", help: "Search files") {
                    withAnimation(.easeOut(duration: 0.16)) {
                        searchPresented.toggle()
                        if !searchPresented {
                            explorerModel.searchQuery = ""
                        }
                    }
                }
                ChromeButton(systemName: "arrow.up.doc", help: "New file") {
                    explorerModel.createFile()
                }
                ChromeButton(systemName: "folder.badge.plus", help: "New folder") {
                    explorerModel.createFolder()
                }
                ChromeButton(systemName: "arrow.clockwise", help: "Refresh explorer") {
                    explorerModel.refresh()
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 1)
            }

            if searchPresented {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    TextField("Search files", text: $explorerModel.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))

                    if !explorerModel.searchQuery.isEmpty {
                        Button {
                            explorerModel.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(Color.white.opacity(0.045))
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.white.opacity(0.05))
                        .frame(height: 1)
                }
            }

            ZStack {
                if activeView == .files {
                    FileExplorerPreview(model: explorerModel)
                        .transition(.opacity)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                        Text("No changes")
                            .font(.system(size: 12, weight: .medium))
                        Text("Source control will appear here")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.18), value: activeView)

            Group {
                HStack(spacing: 3) {
                    SidebarRailButton(title: "Files", systemName: "folder", isActive: activeView == .files) {
                        activeView = .files
                    }

                    SidebarRailButton(title: "Source Control", systemName: "arrow.triangle.branch", isActive: activeView == .sourceControl) {
                        activeView = .sourceControl
                    }
                }
            }
            .padding(5)
            .frame(height: 36)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 1)
            }
        }
        .background(Surface.chrome)
        .onChange(of: tracker.currentDirectory, initial: true) { _, directory in
            syncExplorer(directory: directory)
        }
        .onChange(of: tracker.subshell, initial: true) { _, _ in
            syncExplorer(directory: tracker.currentDirectory)
        }
        .onChange(of: tracker.remoteListings) { _, _ in
            syncExplorer(directory: tracker.currentDirectory)
        }
    }
}

extension WorkspaceSidebar {
    /// Points the explorer at whichever machine the shell is actually on.
    fileprivate func syncExplorer(directory: String) {
        guard let host = tracker.subshell else {
            explorerModel.showLocal()
            explorerModel.setRoot(URL(fileURLWithPath: directory))
            return
        }

        if let entries = tracker.remoteEntries(for: directory) {
            explorerModel.showRemote(host: host, path: directory, entries: entries)
        } else {
            tracker.requestRemoteListing(directory)
        }
    }
}

struct FileExplorerPreview: View {
    @EnvironmentObject private var preferences: AppPreferences
    @ObservedObject var model: FileExplorerModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if model.filteredRootEntries.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: model.searchQuery.isEmpty ? "folder" : "magnifyingglass")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                        Text(model.searchQuery.isEmpty ? "No files" : "No matches")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                } else {
                    FileExplorerRows(
                        entries: model.filteredRootEntries,
                        depth: 0,
                        model: model
                    )
                    .transition(.opacity)
                }
            }
            .padding(.vertical, 7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.2), value: model.rootURL)
        .animation(.easeOut(duration: 0.15), value: model.expandedPaths)
        .onAppear {
            model.refresh(showHidden: preferences.showHiddenFiles)
        }
        .onChange(of: preferences.showHiddenFiles) { _, showHidden in
            model.refresh(showHidden: showHidden)
        }
    }
}

struct SidebarFileRow: View {
    let entry: FileExplorerEntry
    let depth: Int
    let isExpanded: Bool
    let isSelected: Bool
    let onActivate: () -> Void

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: 6) {
                Image(systemName: entry.isDirectory
                    ? (isExpanded ? "chevron.down" : "chevron.right")
                    : "circle")
                    .font(.system(size: entry.isDirectory ? 8 : 4, weight: .semibold))
                    .frame(width: 10)
                    .foregroundStyle(.secondary)

                Image(systemName: entry.isDirectory ? "folder" : "doc.text")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(entry.isDirectory ? Color.blue.opacity(0.82) : .secondary)
                    .frame(width: 16)

                Text(entry.name)
                    .font(.system(size: 13))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.leading, 10 + CGFloat(depth * 14))
            .padding(.trailing, 10)
            .frame(height: 25)
            .foregroundStyle(.primary)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(entry.isDirectory
            ? (isExpanded ? "Collapse \(entry.name)" : "Expand \(entry.name)")
            : entry.name)
        .accessibilityLabel((entry.isDirectory ? "Folder " : "File ") + entry.name)
        .accessibilityValue(entry.isDirectory ? (isExpanded ? "Expanded" : "Collapsed") : "")
    }
}

struct FileExplorerRows: View {
    let entries: [FileExplorerEntry]
    let depth: Int
    @ObservedObject var model: FileExplorerModel

    var body: some View {
        ForEach(entries) { entry in
            SidebarFileRow(
                entry: entry,
                depth: depth,
                isExpanded: model.expandedPaths.contains(entry.id),
                isSelected: model.selectedPath == entry.id,
                onActivate: { model.activate(entry) }
            )

            if entry.isDirectory && model.expandedPaths.contains(entry.id) {
                AnyView(
                    FileExplorerRows(
                        entries: model.filtered(model.children(for: entry)),
                        depth: depth + 1,
                        model: model
                    )
                )
            }
        }
    }
}

struct SidebarRailButton: View {
    let title: String
    let systemName: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemName)
                .font(.system(size: 10, weight: .medium))
                .frame(maxWidth: .infinity)
                // Enough vertical room that the capsule is a pill rather than
                // a squashed oval.
                .padding(.vertical, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(isActive ? Color.primary : Color.secondary)
        .background(Capsule().fill(Color.white.opacity(isActive ? 0.08 : 0)))
        .clipShape(Capsule())
        .animation(.easeOut(duration: 0.18), value: isActive)
    }
}

struct FileExplorerEntry: Identifiable {
    let id: String
    let url: URL
    let name: String
    let isDirectory: Bool
}

@MainActor
final class FileExplorerModel: ObservableObject {
    @Published private(set) var rootEntries: [FileExplorerEntry] = []
    @Published private(set) var childrenByPath: [String: [FileExplorerEntry]] = [:]
    @Published var expandedPaths: Set<String> = []
    @Published var selectedPath: String?
    @Published var searchQuery = ""

    private(set) var showHidden = false
    @Published private(set) var rootURL = FileManager.default.homeDirectoryForCurrentUser
    /// Set while the explorer is showing a remote host's files, which arrive
    /// from the shell on the far end rather than from local disk.
    @Published private(set) var remoteHost: String?
    private var remoteEntries: [String] = []

    init() {
        refresh()
    }

    /// Home shows as `~`, everything else by its own folder name.
    var rootLabel: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if rootURL.path == home { return "~" }
        return rootURL.lastPathComponent.isEmpty ? rootURL.path : rootURL.lastPathComponent
    }

    /// Shows a listing that came back from a remote shell.
    ///
    /// Local disk is the wrong machine once a session is remote — the paths
    /// happen to resolve, which makes the wrong answer look like a right one.
    func showRemote(host: String, path: String, entries: [String]) {
        remoteHost = host
        remoteEntries = entries
        rootURL = URL(fileURLWithPath: path)
        expandedPaths.removeAll()
        childrenByPath.removeAll()
        selectedPath = nil
        rebuildRemoteRows()
    }

    /// Returns to the local filesystem when a remote session ends.
    func showLocal() {
        guard remoteHost != nil else { return }
        remoteHost = nil
        remoteEntries = []
        refresh()
    }

    private func rebuildRemoteRows() {
        let base = rootURL.path
        rootEntries = remoteEntries
            .filter { showHidden || !$0.hasPrefix(".") }
            .map { entry in
                let isDirectory = entry.hasSuffix("/")
                let name = isDirectory ? String(entry.dropLast()) : entry
                return FileExplorerEntry(
                    id: (base as NSString).appendingPathComponent(name),
                    url: URL(fileURLWithPath: (base as NSString).appendingPathComponent(name)),
                    name: name,
                    isDirectory: isDirectory
                )
            }
            .sorted { lhs, rhs in
                lhs.isDirectory == rhs.isDirectory
                    ? lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                    : lhs.isDirectory
            }
    }

    /// Points the explorer at a new directory, following the shell.
    ///
    /// Expansion and selection are dropped rather than carried over: they are
    /// keyed by absolute path, and holding on to paths from the old tree would
    /// leave rows expanded that are no longer part of it.
    func setRoot(_ url: URL) {
        let resolved = url.standardizedFileURL
        guard resolved != rootURL else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }

        rootURL = resolved
        expandedPaths.removeAll()
        childrenByPath.removeAll()
        selectedPath = nil
        refresh()
    }

    var filteredRootEntries: [FileExplorerEntry] {
        filtered(rootEntries)
    }

    func refresh(showHidden: Bool? = nil) {
        if let showHidden {
            self.showHidden = showHidden
        }
        if remoteHost != nil {
            rebuildRemoteRows()
            return
        }

        rootEntries = loadDirectory(rootURL)
        let loadedPaths = Array(childrenByPath.keys)
        for path in loadedPaths {
            let directoryURL = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: directoryURL.path) {
                childrenByPath[path] = loadDirectory(directoryURL)
            } else {
                childrenByPath.removeValue(forKey: path)
                expandedPaths.remove(path)
            }
        }
    }

    func activate(_ entry: FileExplorerEntry) {
        selectedPath = entry.id
        // Expanding a remote folder would need another round trip; the shell's
        // own `cd` is the way to move around a remote tree for now.
        guard entry.isDirectory, remoteHost == nil else { return }

        if expandedPaths.contains(entry.id) {
            expandedPaths.remove(entry.id)
        } else {
            childrenByPath[entry.id] = loadDirectory(entry.url)
            expandedPaths.insert(entry.id)
        }
    }

    func children(for entry: FileExplorerEntry) -> [FileExplorerEntry] {
        childrenByPath[entry.id] ?? []
    }

    func filtered(_ entries: [FileExplorerEntry]) -> [FileExplorerEntry] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    func createFile() {
        let directory = targetDirectory()
        guard let name = requestName(
            title: "New File",
            message: "Create a file in \(directory.lastPathComponent).",
            defaultName: "untitled.txt"
        ) else { return }

        let url = directory.appendingPathComponent(name, isDirectory: false)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            showError("A file or folder named “\(name)” already exists.")
            return
        }

        guard FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil) else {
            showError("Swiftty could not create “\(name)”.")
            return
        }
        refresh()
        selectedPath = url.path
    }

    func createFolder() {
        let directory = targetDirectory()
        guard let name = requestName(
            title: "New Folder",
            message: "Create a folder in \(directory.lastPathComponent).",
            defaultName: "New Folder"
        ) else { return }

        let url = directory.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            showError("A file or folder named “\(name)” already exists.")
            return
        }

        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            refresh()
            selectedPath = url.path
        } catch {
            showError("Swiftty could not create “\(name)”.")
        }
    }

    private func targetDirectory() -> URL {
        guard let selectedPath else { return rootURL }
        let selectedURL = URL(fileURLWithPath: selectedPath)
        let isDirectory = (try? selectedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        return isDirectory ? selectedURL : selectedURL.deletingLastPathComponent()
    }

    private func loadDirectory(_ directory: URL) -> [FileExplorerEntry] {
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: options
        )) ?? []

        return urls
            .map { url in
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return FileExplorerEntry(
                    id: url.path,
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: isDirectory
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .prefix(200)
            .map { $0 }
    }

    private func requestName(title: String, message: String, defaultName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(string: defaultName)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            showError("Choose a valid name without “/”.")
            return nil
        }
        return name
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could not update the explorer"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}


struct CommandPaletteView: View {
    @EnvironmentObject private var store: TerminalStore
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Command palette")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 9)

            CommandPaletteRow(title: "New tab", shortcut: "⌘T", systemName: "plus") {
                store.newTab()
                onDismiss()
            }
            CommandPaletteRow(title: "Toggle file explorer", shortcut: "⌘S", systemName: "sidebar.left") {
                store.toggleSidebar()
                onDismiss()
            }
            CommandPaletteRow(title: "Enable blocks in this session", shortcut: "⇧⌘E", systemName: "link") {
                onDismiss()
                store.activeBlockTracker?.warpifySession()
            }
            CommandPaletteRow(title: "Find in blocks", shortcut: "⌘F", systemName: "magnifyingglass") {
                onDismiss()
                store.beginSearch()
            }
            CommandPaletteRow(title: "Clear blocks", shortcut: "⌘K", systemName: "square.stack.3d.up.slash") {
                store.clearBlocks()
                onDismiss()
            }
            CommandPaletteRow(
                title: store.aiPanelVisible ? "Close AI agent" : "Open AI agent",
                shortcut: "⌘I",
                systemName: "sparkles"
            ) {
                store.toggleAIPanel()
                onDismiss()
            }
            CommandPaletteRow(title: "Settings", shortcut: "⌘,", systemName: "gearshape") {
                onDismiss()
                SettingsCoordinator.open(tab: .general)
            }
            CommandPaletteRow(title: "Configure models", shortcut: nil, systemName: "cpu") {
                onDismiss()
                SettingsCoordinator.open(tab: .models)
            }
        }
        .padding(.vertical, 8)
        .background(Color(nsColor: NSColor(calibratedWhite: 0.13, alpha: 0.98)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct CommandPaletteRow: View {
    let title: String
    let shortcut: String?
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemName)
                    .frame(width: 17)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 12))
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

struct AIAgentPanel: View {
    @EnvironmentObject private var store: TerminalStore
    @EnvironmentObject private var preferences: AppPreferences
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 1) {
                    Text("AI agent")
                        .font(.system(size: 13, weight: .semibold))
                    Text(preferences.selectedProvider.rawValue)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Button { store.clearAIChat() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Clear conversation")
                Button {
                    SettingsCoordinator.open(tab: .models)
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Configure models")
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 1)
            }

            if preferences.modelOptions.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("No model selected")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Button("Configure") {
                        SettingsCoordinator.open(tab: .models)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            } else {
                Picker("Model", selection: Binding(
                    get: { preferences.selectedModel },
                    set: { preferences.selectedModelID = $0 }
                )) {
                    ForEach(preferences.modelOptions) { model in
                        Text(model.label).tag(model.id)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }

            Divider()

            if store.aiMessages.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 25))
                        .foregroundStyle(.secondary)
                    Text("Ask your agent")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Use the selected model to explain code, plan a change, or troubleshoot the terminal.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 240)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(store.aiMessages) { message in
                            AIMessageBubble(message: message)
                        }
                    }
                    .padding(12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack(spacing: 7) {
                TextField("Ask the agent…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .padding(9)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onSubmit {
                        sendDraft()
                    }

                HStack {
                    Circle()
                        .fill(preferences.isConfigured ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(preferences.isConfigured ? "Ready" : "Configure a model in Settings")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { sendDraft() } label: {
                        if store.aiSending {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.up")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.aiSending)
                }
            }
            .padding(10)
        }
        .background(Surface.chrome)
    }

    private func sendDraft() {
        let prompt = draft
        draft = ""
        Task { await store.sendAI(prompt) }
    }
}

struct AIMessageBubble: View {
    let message: AIMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.role == .user ? "You" : "Agent")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(message.role == .user ? .blue : .purple)
            Text(message.content)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == .user ? Color.blue.opacity(0.10) : Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct SettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @State private var selection: SettingsTab = .general

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettingsView()
                .tabItem { Label(SettingsTab.general.title, systemImage: SettingsTab.general.systemImage) }
                .tag(SettingsTab.general)
            TerminalSettingsView()
                .tabItem { Label(SettingsTab.terminal.title, systemImage: SettingsTab.terminal.systemImage) }
                .tag(SettingsTab.terminal)
            ModelsSettingsView()
                .tabItem { Label(SettingsTab.models.title, systemImage: SettingsTab.models.systemImage) }
                .tag(SettingsTab.models)
            AgentsSettingsView()
                .tabItem { Label(SettingsTab.agents.title, systemImage: SettingsTab.agents.systemImage) }
                .tag(SettingsTab.agents)
            AboutSettingsView()
                .tabItem { Label(SettingsTab.about.title, systemImage: SettingsTab.about.systemImage) }
                .tag(SettingsTab.about)
        }
        .padding(22)
        .onAppear { selection = preferences.selectedSettingsTab }
        .onChange(of: selection) { _, newValue in
            preferences.selectedSettingsTab = newValue
        }
        .onReceive(NotificationCenter.default.publisher(for: .swifttyOpenSettings)) { notification in
            if let tab = notification.object as? SettingsTab {
                selection = tab
            }
        }
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $preferences.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.rawValue.capitalized).tag(appearance)
                    }
                }
                Toggle("Show hidden files", isOn: $preferences.showHiddenFiles)
            } header: {
                SettingsSectionHeader(title: "General", subtitle: "Workspace appearance and explorer behavior.")
            }

            Section {
                HStack {
                    Text("Window opacity")
                    Slider(value: $preferences.windowOpacity, in: 0.5...1.0)
                    Text("\(Int(preferences.windowOpacity * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 48, alignment: .trailing)
                }

                Toggle("Blur what's behind the window", isOn: $preferences.windowBlur)
                    .disabled(!preferences.isTranslucent)
                Text(preferences.isTranslucent
                    ? "Frosts the desktop behind Swiftty instead of showing it sharply."
                    : "Lower the opacity below 100% to let the desktop show through.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } header: {
                Text("Window")
            }

            Section {
                Text("Blocks work over SSH and inside containers once the remote shell announces itself. Add one line to the shell config **on the remote host** — nothing is installed there, and Swiftty sends the hooks over the connection you already have.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                SnippetRow(
                    label: "zsh — add to ~/.zshrc",
                    snippet: ShellIntegration.handshakeSnippet(for: .zsh)
                )
                SnippetRow(
                    label: "bash — add to ~/.bashrc",
                    snippet: ShellIntegration.handshakeSnippet(for: .bash)
                )
            } header: {
                Text("Remote sessions")
            }

            Section {
                Toggle("Compact blocks", isOn: $preferences.compactBlocks)
                Text("Tightens the spacing between blocks so more fits on screen.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } header: {
                Text("Blocks")
            }

            Section {
                HStack {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text("Home directory")
                    Spacer()
                    Text(ShellInfo.homePath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } header: {
                Text("Workspace")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 680)
    }
}

struct TerminalSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Font size")
                    Slider(value: $preferences.terminalFontSize, in: 10...22, step: 1)
                    Text("\(Int(preferences.terminalFontSize)) pt")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 48, alignment: .trailing)
                }
                Toggle("Blinking cursor", isOn: $preferences.terminalCursorBlink)
            } header: {
                SettingsSectionHeader(title: "Terminal", subtitle: "Tune the terminal without touching the shell configuration.")
            }

            Section {
                TextField("Shell path", text: $preferences.shellPath)
                    .font(.system(size: 12, design: .monospaced))
                Text("New tabs use this executable with a login shell. Changes apply to new tabs.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } header: {
                Text("Shell")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 680)
    }
}

struct ModelsSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @State private var apiKeyDraft = ""
    @State private var savedMessage = ""

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: Binding(
                    get: { preferences.selectedProvider },
                    set: { preferences.setProvider($0) }
                )) {
                    ForEach(AIProvider.allCases) { provider in
                        HStack {
                            Image(systemName: provider.isLocal ? "desktopcomputer" : "cloud")
                            Text(provider.rawValue)
                        }
                        .tag(provider)
                    }
                }
                Text(providerDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } header: {
                SettingsSectionHeader(title: "Models", subtitle: "Choose which provider powers the AI agent.")
            }

            Section("Model") {
                HStack(spacing: 10) {
                    if preferences.modelsLoading {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Text(preferences.discoveredModels.isEmpty
                        ? "No models discovered"
                        : "\(preferences.discoveredModels.count) models discovered")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Discover") {
                        Task { await preferences.refreshModels() }
                    }
                    .disabled(preferences.modelsLoading)
                }

                if !preferences.modelOptions.isEmpty {
                    Picker("Chat model", selection: Binding(
                        get: { preferences.selectedModel },
                        set: { preferences.selectedModelID = $0 }
                    )) {
                        ForEach(preferences.modelOptions) { model in
                            Text(model.label).tag(model.id)
                        }
                    }
                }

                TextField("Model ID (exact)", text: $preferences.selectedModelID)
                    .font(.system(size: 12, design: .monospaced))
                Text(preferences.selectedProvider == .ollama
                    ? "Enter the exact identifier shown by “ollama ls”, including any tag."
                    : "Enter the exact model identifier accepted by the selected endpoint.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                if let modelError = preferences.modelError {
                    Text(modelError)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }

            Section("Connection") {
                TextField("Base URL", text: $preferences.baseURL)
                    .font(.system(size: 12, design: .monospaced))

                if preferences.selectedProvider.requiresAPIKey || preferences.selectedProvider == .compatible {
                    SecureField(
                        preferences.selectedProvider == .compatible ? "API key (optional)" : "API key",
                        text: $apiKeyDraft
                    )
                    HStack {
                        Button("Save key") {
                            preferences.setAPIKey(apiKeyDraft)
                            savedMessage = apiKeyDraft.isEmpty ? "Key cleared" : "Key saved to Keychain"
                            Task { await preferences.refreshModels() }
                        }
                        Button("Clear") {
                            apiKeyDraft = ""
                            preferences.setAPIKey("")
                            savedMessage = "Key cleared"
                            Task { await preferences.refreshModels() }
                        }
                        if !savedMessage.isEmpty {
                            Text(savedMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Local providers do not require an API key. Make sure the local server is running before opening the agent.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack(spacing: 8) {
                    Circle()
                        .fill(preferences.isConfigured ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(preferences.isConfigured ? "Ready to send requests" : "Configuration incomplete")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(preferences.selectedProvider.rawValue)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 680)
        .onAppear { apiKeyDraft = preferences.apiKey }
        .onChange(of: preferences.selectedProvider) { _, _ in
            apiKeyDraft = preferences.apiKey
        }
        .task { await preferences.refreshModels() }
    }

    private var providerDescription: String {
        switch preferences.selectedProvider {
        case .openAI: return "Discover models from OpenAI’s model catalog, then use the selected ID with Chat Completions."
        case .anthropic: return "Anthropic models through the Messages API."
        case .openRouter: return "Route multiple hosted model families through one OpenRouter key."
        case .ollama: return "Use models served locally by Ollama."
        case .lmStudio: return "Use a model served by LM Studio’s local OpenAI-compatible server."
        case .compatible: return "Connect any OpenAI-compatible endpoint by URL and model ID."
        }
    }
}

struct AgentsSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        Form {
            Section {
                Picker("Active agent", selection: $preferences.selectedAgent) {
                    Text("Coder").tag("Coder")
                    Text("Reviewer").tag("Reviewer")
                    Text("Architect").tag("Architect")
                    Text("Custom").tag("Custom")
                }
            } header: {
                SettingsSectionHeader(title: "Agents", subtitle: "Choose the persona and instructions used by the AI pane.")
            }

            Section("Custom instructions") {
                TextEditor(text: $preferences.customInstructions)
                    .font(.system(size: 12))
                    .frame(minHeight: 150)
                Text("These instructions are kept locally and sent with future agent requests.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 680)
    }
}

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Swiftty")
                .font(.system(size: 22, weight: .semibold))
            Text("A native Swift terminal workspace with an integrated AI agent.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Version 0.1.0")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A copyable one-liner for the user to paste into a remote shell config.
struct SnippetRow: View {
    let label: String
    let snippet: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text(snippet)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                Button(copied ? "Copied" : "Copy") {
                    Pasteboard.copy(snippet)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

struct SettingsSectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 3)
    }
}

struct TerminalSessionView: NSViewRepresentable {
    @EnvironmentObject private var preferences: AppPreferences
    let tabID: TerminalTab.ID
    let isActive: Bool
    let wantsFocus: Bool
    let tracker: BlockTracker
    let onTitle: (String) -> Void
    let onDirectory: (String?) -> Void
    let onExit: (Int32?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTitle: onTitle, onDirectory: onDirectory, onExit: onExit)
    }

    func makeNSView(context: Context) -> SwifttyTerminalView {
        let terminal = SwifttyTerminalView(frame: .zero)
        terminal.font = NSFont.monospacedSystemFont(ofSize: preferences.terminalFontSize, weight: .regular)
        terminal.nativeForegroundColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        terminal.caretColor = .systemGreen
        terminal.caretViewTracksFocus = true
        // Rebuild only the rows that changed, rather than the whole screen every
        // frame. This is the cheaper mode for interactive use — typing, scrolling
        // output — which is nearly all of ours; only a handful of rows are dirty
        // per frame. `.perFrameAggregated` suits a TUI that repaints everything,
        // but even then this only rebuilds what actually changed.
        terminal.metalBufferingMode = .perRowPersistent
        try? terminal.setUseMetal(true)
        // After setUseMetal, so there is an MTKView to make non-opaque.
        terminal.applyBackground(opacity: preferences.windowOpacity)
        terminal.processDelegate = context.coordinator
        context.coordinator.terminal = terminal

        let shell = preferences.shellPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ShellInfo.path
            : preferences.shellPath
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Swiftty"
        environment["TERM_PROGRAM_VERSION"] = "0.1"

        // Load the OSC 133 hooks that command blocks are built on. Shells we
        // cannot instrument just start normally and produce no blocks.
        var arguments = ["-l"]
        var execName = "-" + (shell as NSString).lastPathComponent
        if let injection = ShellIntegration.prepare(shellPath: shell, tabID: tabID) {
            environment.merge(injection.environment) { _, new in new }
            if !injection.arguments.isEmpty { arguments = injection.arguments }
            if let name = injection.execName { execName = name }
        }

        // The tracker has to be listening before the shell's first prompt, so
        // register the OSC handler ahead of startProcess.
        tracker.attach(to: terminal)

        terminal.startProcess(
            executable: shell,
            args: arguments,
            environment: environment.map { $0.key + "=" + $0.value },
            execName: execName,
            currentDirectory: ShellInfo.homePath
        )

        terminal.setCursorBlink(preferences.terminalCursorBlink)

        DispatchQueue.main.async {
            guard isActive, wantsFocus else { return }
            terminal.window?.makeFirstResponder(terminal)
        }
        return terminal
    }

    func updateNSView(_ terminal: SwifttyTerminalView, context: Context) {
        context.coordinator.onTitle = onTitle
        context.coordinator.onDirectory = onDirectory
        context.coordinator.onExit = onExit
        terminal.setCursorBlink(preferences.terminalCursorBlink)
        terminal.font = NSFont.monospacedSystemFont(ofSize: preferences.terminalFontSize, weight: .regular)
        terminal.applyBackground(opacity: preferences.windowOpacity)

        guard isActive, wantsFocus else { return }
        DispatchQueue.main.async {
            // Only claim focus if something else has not already taken it, or
            // this would fight the editor for the keyboard every redraw.
            guard terminal.window?.firstResponder !== terminal else { return }
            terminal.window?.makeFirstResponder(terminal)
        }
    }

    static func dismantleNSView(_ terminal: SwifttyTerminalView, coordinator: Coordinator) {
        terminal.terminate()
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        weak var terminal: SwifttyTerminalView?
        var onTitle: (String) -> Void
        var onDirectory: (String?) -> Void
        var onExit: (Int32?) -> Void

        init(
            onTitle: @escaping (String) -> Void,
            onDirectory: @escaping (String?) -> Void,
            onExit: @escaping (Int32?) -> Void
        ) {
            self.onTitle = onTitle
            self.onDirectory = onDirectory
            self.onExit = onExit
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            onTitle(title)
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            onDirectory(Self.path(from: directory))
        }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            onExit(exitCode)
        }

        private static func path(from directory: String?) -> String? {
            guard let directory, !directory.isEmpty else { return nil }
            if let url = URL(string: directory), url.isFileURL {
                return url.path
            }
            return directory
        }
    }
}

enum ShellInfo {
    static let homePath = FileManager.default.homeDirectoryForCurrentUser.path
    static let userName = NSUserName()
    static let path = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    static let displayName = (path as NSString).lastPathComponent
}
