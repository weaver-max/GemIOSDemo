import SwiftUI
import Gemstone

/// Swift 侧实现 AlienProvider，由 Rust 反向调用。
/// 对应 Android 示例的 NativeProvider.kt。
final class NativeProvider: AlienProvider, @unchecked Sendable {

    /// 把状态码与字节数回传给 UI —— AlienResponse 是不透明对象（uniffi::Object），
    /// 构造之后读不出内容，所以只能在包装前记录。
    var onResult: (@Sendable (String) -> Void)?

    func getEndpoint(chain: Chain) throws -> String {
        "https://ethereum.publicnode.com"
    }

    func request(target: AlienTarget) async throws -> AlienResponse {
        guard let url = URL(string: target.url) else {
            throw AlienError.RequestError(msg: "invalid url: \(target.url)")
        }

        var req = URLRequest(url: url)
        req.httpMethod = alienMethodToString(method: target.method)
        target.headers?.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.httpBody = target.body

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode

        onResult?("\(target.url)\n-> \(status.map(String.init) ?? "nil"), \(data.count) bytes")

        return AlienResponse(status: status.map(UInt16.init), data: data)
    }
}

struct ContentView: View {
    @State private var result = "尚未请求"
    @State private var busy = false
    private let provider = NativeProvider()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // 这一行来自 Rust，不是硬编码 —— 证明 FFI 正向调用通了
            Text("Gemstone lib version: \(libVersion())")
                .font(.headline)

            Button("Fetch Data") { fetch() }
                .buttonStyle(.borderedProminent)
                .disabled(busy)

            Text(result)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        // 进页面自动跑一次 —— iOS 模拟器没有 adb input tap 那样的注入命令，
        // 自动触发才能在无人值守的情况下验证反向回调。按钮仍可手动重跑。
        .task { fetch() }
    }

    private func fetch() {
        busy = true
        result = "请求中…"
        provider.onResult = { text in
            Task { @MainActor in
                result = text
                busy = false
            }
        }
        Task {
            let target = AlienTarget(
                url: "https://httpbin.org/get?foo=bar",
                method: .get,
                headers: ["X-Header": "X-Value"],
                body: nil
            )
            do {
                // 返回值交给 Rust 消费，Swift 侧读不出内容
                _ = try await provider.request(target: target)
            } catch {
                await MainActor.run {
                    result = "失败: \(error)"
                    busy = false
                }
            }
        }
    }
}

@main
struct GemIOSDemoApp: App {

    /// iOS 模拟器没有 `adb shell input tap` 那样的注入命令，用启动参数替代：
    ///   -wallet      跳到钱包页（只看，不生成）
    ///   -autowallet  跳到钱包页并生成一个钱包
    ///   -detail      跳到钱包页并打开最新一个钱包的详情
    /// 正常使用不带参数，从 FFI 页进，钱包要手点按钮生成。
    private static let args = ProcessInfo.processInfo.arguments
    static var autoGenerate: Bool { args.contains("-autowallet") }
    static var autoDetail: Bool { args.contains("-detail") }
    static var startOnWallet: Bool { autoGenerate || autoDetail || args.contains("-wallet") }

    /// 🔴 必须是 @State 而不是 .constant()。
    ///    .constant() 是只读绑定，Tab 会被焊死，用户点不动。
    @State private var tab = GemIOSDemoApp.startOnWallet ? 1 : 0

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                ContentView()
                    .tabItem { Label("FFI", systemImage: "arrow.left.arrow.right") }
                    .tag(0)
                WalletView(autoGenerate: Self.autoGenerate,
                           autoOpenDetail: Self.autoDetail)
                    .tabItem { Label("钱包", systemImage: "wallet.pass") }
                    .tag(1)
            }
        }
    }
}
