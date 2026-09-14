import SwiftUI
import Gemstone

/// 生成钱包的最小完整闭环：
///   GemMnemonic.generate → GemKeystore.createStore → 落盘 → 显示地址
///
/// ⚠️ 仅供演示。真实产品里助记词绝不能这样明文显示，
///    密码也必须来自用户输入 + Keychain/生物识别保护。
struct WalletView: View {

    /// 自动化验证用，见 GemIOSDemoApp.autoWallet
    var autoGenerate: Bool = false

    @State private var result: WalletResult?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                warningBanner

                Button(busy ? "生成中…" : "生成新钱包") { generate() }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)

                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if let result {
                    mnemonicSection(result.words)
                    field("walletId", result.walletId)
                    field("keystoreId", result.keystoreId)
                    field("地址（\(result.chain)）", result.address)
                    fileSection(result)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { if autoGenerate && result == nil { generate() } }
    }

    // ── 子视图 ──────────────────────────────────────────────

    private var warningBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("⚠️")
            VStack(alignment: .leading, spacing: 2) {
                Text("DEMO ONLY").font(.caption).bold()
                Text("助记词明文显示，切勿用于真实资金")
                    .font(.caption2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private func mnemonicSection(_ words: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("助记词（\(words.count)）").font(.caption).foregroundStyle(.secondary)
            Text(words.joined(separator: " "))
                .font(.system(.footnote, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func fileSection(_ r: WalletResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // 这一条才是真正的验证点：文件确实落到磁盘了，不只是内存里的对象
            Text(r.fileExists ? "✓ keystore 文件已写入" : "✗ 文件未找到")
                .font(.caption).bold()
                .foregroundStyle(r.fileExists ? .green : .red)
            Text("\(r.fileName)  \(r.fileSize) 字节")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    // ── 逻辑 ────────────────────────────────────────────────

    private func generate() {
        busy = true
        error = nil
        result = nil

        // 🔴 必须调用 View 之外的类型。
        //    SwiftUI 的 View 默认是 @MainActor，把 createWallet 写成 View 的方法的话，
        //    即使包在 Task.detached 里也会被弹回主 actor —— Argon2id 照样卡 UI，
        //    而且 Swift 6 语言模式下直接是编译错误。
        Task.detached(priority: .userInitiated) {
            do {
                let r = try WalletFactory.create()
                await MainActor.run { result = r; busy = false }
            } catch {
                await MainActor.run {
                    self.error = "失败: \(error)"
                    busy = false
                }
            }
        }
    }
}

/// 钱包创建逻辑。刻意放在 View 外面，避免被 @MainActor 隔离 —— 见上方注释。
enum WalletFactory {

    /// keystore 文件的落盘位置。真实 App 应放在不参与 iCloud 备份的目录，
    /// 这里用 Application Support 只是为了演示时好找。
    static let keystoreDirectory: String = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("GemKeystore", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.path
    }()

    static func create() throws -> WalletResult {
        let chain: Chain = "ethereum"

        let words = try GemMnemonic().generate(wordCount: 12)

        // password 是 Data 不是 String。演示用固定密码，
        // 真实产品必须来自用户输入，并考虑 Keychain / 生物识别。
        let password = Data("demo-password".utf8)

        let keystore = try GemKeystore(baseDir: keystoreDirectory)
        let wallet = try keystore.createStore(
            import: .multicoinPhrase(words: words, chains: [chain]),
            password: password
        )

        // keystore 文件名就是 keystoreId，一个钱包一个文件
        let path = (keystoreDirectory as NSString)
            .appendingPathComponent("\(wallet.keystoreId).json")
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)

        return WalletResult(
            words: words,
            walletId: wallet.walletId,
            keystoreId: wallet.keystoreId,
            chain: chain,
            address: wallet.accounts.first?.address ?? "(无账户)",
            fileExists: FileManager.default.fileExists(atPath: path),
            fileName: "\(wallet.keystoreId).json",
            fileSize: (attrs?[.size] as? Int) ?? 0
        )
    }
}

struct WalletResult {
    let words: [String]
    let walletId: String
    let keystoreId: String
    let chain: Chain
    let address: String
    let fileExists: Bool
    let fileName: String
    let fileSize: Int
}
