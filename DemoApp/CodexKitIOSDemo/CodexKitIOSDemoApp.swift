import SwiftUI
import Security

enum DemoTab: Hashable {
    case assistant
    case structuredOutput
    case memory
    case healthCoach
}

@main
struct GoDogCodexApp: App {
    var body: some Scene {
        WindowGroup { GoDogChatView() }
    }
}

private struct ChatLine: Identifiable {
    let id = UUID()
    let role: String
    var text: String
}

private enum SecretStore {
    static let service = "com.godog.codex.api"
    static let account = "api-key"

    static func load() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    static func save(_ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

private struct ResponseInput: Encodable {
    let role: String
    let content: String
}

private struct ResponsesRequest: Encodable {
    let model: String
    let input: [ResponseInput]
    let stream: Bool
    let store: Bool
}

@available(iOS 17.0, *)
private struct GoDogChatView: View {
    @AppStorage("godog.codex.endpoint") private var endpoint = "https://synflux.org/v1/responses"
    @AppStorage("godog.codex.model") private var model = "gpt-5.6-sol"
    @State private var apiKey = SecretStore.load()
    @State private var draft = ""
    @State private var lines: [ChatLine] = []
    @State private var busy = false
    @State private var errorText: String?
    @State private var showSettings = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if lines.isEmpty {
                    ContentUnavailableView("GoDog Codex", systemImage: "bubble.left.and.bubble.right", description: Text("使用你自己的 Responses API 地址和 Key。"))
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                ForEach(lines) { line in
                                    HStack {
                                        if line.role == "assistant" {
                                            Text(line.text.isEmpty ? "思考中…" : line.text)
                                                .padding(12).background(.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                                            Spacer(minLength: 44)
                                        } else {
                                            Spacer(minLength: 44)
                                            Text(line.text)
                                                .padding(12).background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
                                        }
                                    }.id(line.id)
                                }
                            }.padding()
                        }
                        .onChange(of: lines.last?.text) { _, _ in
                            if let id = lines.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                        }
                    }
                }
                if let errorText {
                    Text(errorText).font(.footnote).foregroundStyle(.red).padding(.horizontal)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("发消息给 Codex…", text: $draft, axis: .vertical)
                        .lineLimit(1...5).focused($inputFocused).padding(12)
                        .background(.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
                    Button { Task { await send() } } label: {
                        if busy { ProgressView() } else { Image(systemName: "arrow.up.circle.fill").font(.system(size: 34)) }
                    }.disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || apiKey.isEmpty)
                }.padding()
            }
            .navigationTitle("GoDog Codex")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { lines.removeAll(); errorText = nil } label: { Image(systemName: "square.and.pencil") }
                }
            }
            .sheet(isPresented: $showSettings) {
                settingsView
            }
        }
    }

    private var settingsView: some View {
        NavigationStack {
            Form {
                Section("服务配置") {
                    TextField("Responses API 完整地址", text: $endpoint).textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                    TextField("模型 ID", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("API Key（保存在 iOS 钥匙串）", text: $apiKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Text("请求直接发送到上面的地址，使用 Authorization: Bearer。此应用不会伪装官方 Codex 客户端；若服务商只允许官方客户端，需让服务商开放第三方 API。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("API 设置")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { SecretStore.save(apiKey); showSettings = false }
                }
            }
        }
    }

    @MainActor
    private func send() async {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !busy else { return }
        guard let url = URL(string: endpoint), ["https"].contains(url.scheme?.lowercased() ?? "") else {
            errorText = "请填写有效的 HTTPS Responses API 地址。"; return
        }
        guard !apiKey.isEmpty else { showSettings = true; errorText = "请先在设置中填写 API Key。"; return }

        draft = ""
        inputFocused = false
        errorText = nil
        lines.append(ChatLine(role: "user", text: prompt))
        lines.append(ChatLine(role: "assistant", text: ""))
        let assistantIndex = lines.count - 1
        busy = true
        defer { busy = false }

        do {
            let history = lines.dropLast().map { ResponseInput(role: $0.role, content: $0.text) }
            let payload = ResponsesRequest(model: model, input: Array(history), stream: true, store: false)
            var request = URLRequest(url: url, timeoutInterval: 600)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("GoDog-Codex-iOS/1.0", forHTTPHeaderField: "User-Agent")
            request.httpBody = try JSONEncoder().encode(payload)

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw ChatError.message("服务器没有返回 HTTP 响应。") }
            guard (200..<300).contains(http.statusCode) else {
                var body = ""
                for try await byte in bytes.lines { body += byte + "\n"; if body.count > 1200 { break } }
                throw ChatError.message("HTTP \(http.statusCode)：\(Self.cleanError(body))")
            }

            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let dataLine = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if dataLine == "[DONE]" { break }
                guard let data = dataLine.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let type = object["type"] as? String ?? ""
                if type == "response.output_text.delta", let delta = object["delta"] as? String {
                    lines[assistantIndex].text += delta
                } else if type == "response.failed" || type == "error" {
                    let err = object["error"] as? [String: Any]
                    throw ChatError.message(Self.cleanError(err?["message"] as? String ?? "Responses 请求失败"))
                }
            }
        } catch {
            lines[assistantIndex].text = ""
            errorText = error.localizedDescription
        }
    }

    private static func cleanError(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().contains("<!doctype html") || value.lowercased().contains("<html") {
            return "上游返回了 HTML 错误页；请检查服务商地址、API 兼容性或服务状态。"
        }
        return String(value.prefix(1000))
    }
}

private enum ChatError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}
