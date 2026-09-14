import Foundation
import Gemstone

/// 钱包列表项。
///
/// 🔴 注意这里**没有助记词、没有私钥**。
///    Rust 只按 keystoreId 收活，从不告诉你有哪些钱包（GemKeystore 没有任何
///    list/getAll 接口），所以这份清单必须由 App 自己维护。
///    但清单里只放「找得回来」所需的最小信息，秘密仍然躺在加密的 keystore 文件里。
struct WalletEntry: Codable, Identifiable, Equatable {
    let walletId: String
    let keystoreId: String
    let chain: Chain
    let address: String
    let createdAt: Date

    var id: String { walletId }
}

/// 列表持久化。
///
/// ⚠️ 演示用 UserDefaults。真实产品应该用 SQLite——
///    gem 主 App 走的是 GRDB，两张表：
///      wallets(id, name, type, index, order, isPinned, imageUrl, source, updatedAt)
///      wallets_accounts(walletId, chain, address, derivationPath, extendedPublicKey, index)
///    用数据库的关键原因是**响应式查询**：数据一变 UI 自动刷新。
///    UserDefaults 没有这个能力，所以本 demo 得手动 reload。
enum WalletStore {
    private static let key = "gem.demo.wallets"

    static func all() -> [WalletEntry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([WalletEntry].self, from: data)
        else { return [] }
        return list.sorted { $0.createdAt > $1.createdAt }
    }

    static func add(_ entry: WalletEntry) {
        save(all() + [entry])
    }

    static func remove(walletId: String) {
        save(all().filter { $0.walletId != walletId })
    }

    private static func save(_ list: [WalletEntry]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// 钱包创建与读取。
///
/// 🔴 刻意放在 SwiftUI View 外面：View 默认是 @MainActor，
///    把这些方法写进 View 里的话，即使包在 Task.detached 中也会被弹回主 actor，
///    Argon2id（19 MiB / 2 轮）照样卡 UI，且 Swift 6 语言模式下是编译错误。
enum WalletFactory {

    /// 演示用固定密码。真实产品必须来自用户输入，
    /// 并用 Keychain + 生物识别保护，绝不能硬编码。
    static let demoPassword = Data("demo-password".utf8)

    /// keystore 落盘位置。真实 App 应放在不参与 iCloud 备份的目录。
    static let keystoreDirectory: String = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("GemKeystore", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.path
    }()

    /// 生成新钱包：助记词 → keystore 落盘 → 记进列表
    static func create(chain: Chain = "ethereum") throws -> WalletEntry {
        let words = try GemMnemonic().generate(wordCount: 12)

        let keystore = try GemKeystore(baseDir: keystoreDirectory)
        let wallet = try keystore.createStore(
            import: .multicoinPhrase(words: words, chains: [chain]),
            password: demoPassword
        )

        let entry = WalletEntry(
            walletId: wallet.walletId,
            keystoreId: wallet.keystoreId,
            chain: chain,
            address: wallet.accounts.first?.address ?? "(无账户)",
            createdAt: Date()
        )
        WalletStore.add(entry)
        return entry
    }

    /// 取回助记词。
    ///
    /// 🔴 这才是重点：助记词**没有存在任何地方**，
    ///    是现场从加密的 keystore 文件里解出来的。
    ///    真实产品调这个之前必须过生物识别。
    static func recoveryPhrase(keystoreId: String) throws -> [String] {
        let keystore = try GemKeystore(baseDir: keystoreDirectory)
        return try keystore.exportRecoveryPhrase(keystoreId: keystoreId,
                                                 password: demoPassword)
    }

    /// 删除钱包：keystore 文件 + 列表记录都要清
    static func delete(_ entry: WalletEntry) throws {
        let keystore = try GemKeystore(baseDir: keystoreDirectory)
        _ = try keystore.delete(keystoreId: entry.keystoreId)
        WalletStore.remove(walletId: entry.walletId)
    }

    /// keystore 文件的实际路径与大小，用于演示「确实落盘了」
    static func fileInfo(keystoreId: String) -> (exists: Bool, name: String, size: Int) {
        let name = "\(keystoreId).json"
        let path = (keystoreDirectory as NSString).appendingPathComponent(name)
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (FileManager.default.fileExists(atPath: path),
                name,
                (attrs?[.size] as? Int) ?? 0)
    }
}
