import Foundation
import Gemstone

/// 一个账户 = 一条链上的派生地址。
/// 同一个钱包下的所有账户都来自**同一个助记词**，只是派生路径不同。
struct AccountEntry: Codable, Equatable, Identifiable {
    let chain: Chain
    let address: String
    let derivationPath: String

    /// BIP44 账户索引。
    ///
    /// 🔴 M1 恒为 0 —— core 的 `default_derivation_path(chain)` 返回编译期常量，
    ///    一条链只能派生一个地址，做不了 MetaMask 那种 Account 1/2/3。
    ///    字段先留着：core 支持后，数据结构与表结构都不用动，
    ///    只需把 core 返回的真实 index 填进来。详见 README §5。
    let index: Int

    /// 同一条链将来会有多个账户，所以 id 必须带 index
    var id: String { "\(chain)#\(index)" }
}

/// 钱包列表项 = 一个助记词。
///
/// 🔴 这里**没有助记词、没有私钥、没有密码**。
///    Rust 只按 keystoreId 收活，从不告诉你有哪些钱包（GemKeystore 没有
///    list/getAll 接口），所以清单必须 App 自己维护 ——
///    但只放「找得回来」所需的最小信息，秘密留在加密的 keystore 文件里。
struct WalletEntry: Codable, Identifiable, Equatable {
    let walletId: String
    let createdAt: Date
    var accounts: [AccountEntry]

    var id: String { walletId }

    /// 🔴 不存，现算。
    ///    keystoreId 是 walletId 的 UUID v5 派生值（确定性），存进清单是冗余，
    ///    冗余字段迟早会和真值不一致。需要时调 keystoreIdForWallet() 即可。
    var keystoreId: String { keystoreIdForWallet(walletId: walletId) }
}

/// 钱包清单。实际存储在 SQLite，见 WalletDatabase。
///
/// 🔴 清单里没有助记词、私钥、密码 —— 表结构里根本没有它们的位置。
///    固定 schema 比运行时断言更强：想存秘密得先显式改表。
///    秘密只在加密的 keystore 文件里，由 Rust 管。
enum WalletStore {
    static func all() -> [WalletEntry] { WalletDatabase.shared.all() }
    static func upsert(_ entry: WalletEntry) { WalletDatabase.shared.upsert(entry) }
    static func remove(walletId: String) { WalletDatabase.shared.remove(walletId: walletId) }
}

/// 钱包创建与读取。
///
/// 🔴 刻意放在 SwiftUI View 外面：View 默认是 @MainActor，
///    把这些方法写进 View 里的话，即使包在 Task.detached 中也会被弹回主 actor，
///    Argon2id（19 MiB / 2 轮）照样卡 UI，且 Swift 6 语言模式下是编译错误。
enum WalletFactory {

    /// 建钱包时默认派生这几条链的地址，全部来自同一个助记词。
    static let defaultChains: [Chain] = ["ethereum", "solana", "bitcoin"]

    /// 详情页可以再补的链。
    /// ⚠️ 链名是裸字符串（`typealias Chain = String`），拼错不报编译错误。
    ///    core 也没导出「全量链列表」接口，只能照 Rust 侧 Chain 枚举手抄
    ///    （strum serialize_all = "lowercase"，所以 SmartChain → "smartchain"）。
    static let extraChains: [Chain] = [
        "smartchain", "polygon", "arbitrum", "optimism", "base",
        "avalanchec", "cosmos", "tron", "ton", "sui", "aptos", "doge",
    ]

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

    private static func keystore() throws -> GemKeystore {
        try GemKeystore(baseDir: keystoreDirectory)
    }

    /// 生成新钱包：一个助记词 → 多条链的派生地址 → keystore 落盘 → 记进清单
    static func create(chains: [Chain] = defaultChains) throws -> WalletEntry {
        let words = try GemMnemonic().generate(wordCount: 12)

        let wallet = try keystore().createStore(
            import: .multicoinPhrase(words: words, chains: chains),
            password: demoPassword
        )

        let entry = WalletEntry(
            walletId: wallet.walletId,
            createdAt: Date(),
            accounts: wallet.accounts.map {
                // core 暂不返回 index，M1 固定 0（见 AccountEntry.index 注释）
                AccountEntry(chain: $0.chain,
                             address: $0.address,
                             derivationPath: $0.derivationPath,
                             index: 0)
            }
        )

        // 把「keystoreId 由 walletId 派生」这条关系钉死：
        // core 若改了派生规则，这里立刻炸，而不是等到解密时报文件找不到。
        assert(entry.keystoreId == wallet.keystoreId,
               "keystoreIdForWallet 推导值与 createStore 返回值不一致："
               + "\(entry.keystoreId) vs \(wallet.keystoreId)")

        WalletStore.upsert(entry)
        return entry
    }

    /// 给已有钱包补链 —— 仍是同一个助记词派生出来的地址。
    ///
    /// ⚠️ gem 导出的 API 只支持「一条链一个地址」：
    ///    addAccounts 只接受 chains，没有 index 参数，
    ///    GemKeystoreAccount 也没有 index 字段。
    ///    所以做不了 MetaMask 那种同链多账户（Account 1 / 2 / 3）。
    static func addChains(_ entry: WalletEntry, chains: [Chain]) throws -> WalletEntry {
        let added = try keystore().addAccounts(
            keystoreId: entry.keystoreId,
            password: demoPassword,
            chains: chains
        )

        var updated = entry
        let known = Set(entry.accounts.map(\.chain))
        updated.accounts += added
            .filter { !known.contains($0.chain) }
            .map { AccountEntry(chain: $0.chain,
                                address: $0.address,
                                derivationPath: $0.derivationPath,
                                index: 0) }

        WalletStore.upsert(updated)
        return updated
    }

    /// 取回助记词。
    ///
    /// 🔴 重点：助记词**没有存在任何地方**，
    ///    是现场从加密的 keystore 文件里解出来的。
    ///    真实产品调这个之前必须过生物识别。
    static func recoveryPhrase(keystoreId: String) throws -> [String] {
        try keystore().exportRecoveryPhrase(keystoreId: keystoreId, password: demoPassword)
    }

    /// 删除钱包：keystore 文件 + 清单记录都要清，否则会留下孤儿文件
    static func delete(_ entry: WalletEntry) throws {
        _ = try keystore().delete(keystoreId: entry.keystoreId)
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
