import Foundation
import SQLite3

/// SQLite 持久化，表结构照搬 gem 主 App（`ios/Packages/Store`）的设计：
///   wallets            一个助记词一行
///   wallets_accounts   一条链一行，外键挂到 wallets，级联删除
///
/// 用裸 libsqlite3 而不是 GRDB —— iOS SDK 自带，不引入外部依赖，
/// 本 demo 的手工 swiftc 构建流程不用为此复杂化。
/// 真实项目请用 GRDB：它提供响应式查询（数据变了 UI 自动刷新），
/// 这正是「钱包清单该放数据库而不是 UserDefaults」的核心理由。
///
/// 🔴 表里没有助记词、私钥、密码的位置。
///    固定 schema 比字段白名单断言更强 —— 想存秘密得先改表结构，
///    那是个显式动作，不会手滑写进去。
final class WalletDatabase {

    static let shared = WalletDatabase()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "gem.demo.db")

    /// SQLite 要求告诉它绑定的字符串是否需要拷贝。
    /// TRANSIENT = 让 SQLite 自己拷一份，避免 Swift 字符串提前释放。
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private init() {
        let path = Self.databasePath
        guard sqlite3_open_v2(path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK else {
            assertionFailure("无法打开数据库: \(path)")
            return
        }
        exec("PRAGMA foreign_keys = ON;")   // 默认是关的，不开级联删除不生效
        migrate()
    }

    static var databasePath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("wallets.sqlite").path
    }

    // ── schema ──────────────────────────────────────────────

    private func migrate() {
        exec("""
        CREATE TABLE IF NOT EXISTS wallets (
            id          TEXT PRIMARY KEY NOT NULL,
            created_at  REAL NOT NULL
        );
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS wallets_accounts (
            wallet_id       TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
            chain           TEXT NOT NULL,
            address         TEXT NOT NULL,
            derivation_path TEXT NOT NULL,
            account_index   INTEGER NOT NULL DEFAULT 0,
            -- 🔴 主键必须带 account_index。M1 它恒为 0，但将来同链多账户时
            --    (wallet_id, chain) 会撞主键 —— 现在定对了以后就不用改表。
            PRIMARY KEY (wallet_id, chain, account_index)
        );
        """)
        // account_index 现在恒为 0：core 的 default_derivation_path 是编译期常量，
        // 一条链只能派生一个地址。留着这列是零成本对冲 —— core 若支持了同链多账户，
        // App 侧不用改表结构。gem 主 App 的 wallets_accounts 也有这一列。
        exec("CREATE INDEX IF NOT EXISTS idx_accounts_wallet ON wallets_accounts(wallet_id);")
    }

    // ── 读写 ────────────────────────────────────────────────

    func all() -> [WalletEntry] {
        queue.sync {
            var wallets: [(id: String, createdAt: Date)] = []
            query("SELECT id, created_at FROM wallets ORDER BY created_at DESC;") { stmt in
                wallets.append((text(stmt, 0), Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1))))
            }

            return wallets.map { wallet in
                var accounts: [AccountEntry] = []
                query("""
                SELECT chain, address, derivation_path, account_index FROM wallets_accounts
                WHERE wallet_id = '\(escape(wallet.id))' ORDER BY chain, account_index;
                """) { stmt in
                    accounts.append(AccountEntry(chain: text(stmt, 0),
                                                 address: text(stmt, 1),
                                                 derivationPath: text(stmt, 2),
                                                 index: Int(sqlite3_column_int(stmt, 3))))
                }
                return WalletEntry(walletId: wallet.id, createdAt: wallet.createdAt, accounts: accounts)
            }
        }
    }

    func upsert(_ entry: WalletEntry) {
        queue.sync {
            exec("BEGIN;")
            exec("""
            INSERT INTO wallets (id, created_at) VALUES ('\(escape(entry.walletId))', \(entry.createdAt.timeIntervalSinceReferenceDate))
            ON CONFLICT(id) DO NOTHING;
            """)
            for a in entry.accounts {
                exec("""
                INSERT INTO wallets_accounts (wallet_id, chain, address, derivation_path, account_index)
                VALUES ('\(escape(entry.walletId))', '\(escape(a.chain))', '\(escape(a.address))', '\(escape(a.derivationPath))', \(a.index))
                ON CONFLICT(wallet_id, chain, account_index) DO UPDATE SET
                    address = excluded.address,
                    derivation_path = excluded.derivation_path;
                """)
            }
            exec("COMMIT;")
        }
    }

    func remove(walletId: String) {
        // wallets_accounts 有 ON DELETE CASCADE，删主表即可
        queue.sync { exec("DELETE FROM wallets WHERE id = '\(escape(walletId))';") }
    }

    // ── 内部工具 ────────────────────────────────────────────

    /// demo 的值都来自 core 派生（地址、链名、路径），不含用户输入，
    /// 转义单引号足够。真实项目请一律用 sqlite3_bind_* 参数绑定。
    private func escape(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "''") }

    private func text(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK, let err {
            assertionFailure("SQL 失败: \(String(cString: err))\n\(sql)")
            sqlite3_free(err)
        }
    }

    private func query(_ sql: String, _ row: (OpaquePointer?) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            assertionFailure("prepare 失败: \(sql)")
            return
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }
}
