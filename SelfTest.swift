import Foundation
import Gemstone

/// 无头自检：iOS 模拟器没法注入点击，靠启动参数跑完整条钱包链路。
///   xcrun simctl launch <UDID> com.example.gemiosdemo -selftest
/// 结果打到 stdout，用 `simctl spawn <UDID> log stream` 或看进程输出。
enum SelfTest {

    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-selftest") else { return }
        var failed = 0
        var lines: [String] = []

        // print() 走 stdout，不进 unified log，simctl 那边抓不到。
        // 写进 Documents，用 simctl get_app_container 读，最可靠。
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            lines.append("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
            if !ok { failed += 1 }
        }

        defer {
            lines.append("DONE failed=\(failed)")
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("selftest.txt")
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }

        do {
            let before = WalletStore.all().count

            // 1. 生成
            let w = try WalletFactory.create()
            check("生成钱包", WalletStore.all().count == before + 1)
            check("默认派生 3 条链", w.accounts.count == 3, "实际 \(w.accounts.count)")

            // 2. keystoreId 由 walletId 推导，且文件确实落盘
            let info = WalletFactory.fileInfo(keystoreId: w.keystoreId)
            check("keystore 文件落盘", info.exists, "\(info.name) \(info.size) 字节")

            // 3. 助记词现场解密 —— 验证推导出的 keystoreId 是对的
            let words = try WalletFactory.recoveryPhrase(keystoreId: w.keystoreId)
            check("助记词解密", words.count == 12, "\(words.count) 个词")

            // 4. 同一助记词派生新链，助记词不能变
            let added = try WalletFactory.addChains(w, chains: ["polygon", "tron"])
            check("再派生 2 条链", added.accounts.count == 5, "实际 \(added.accounts.count)")
            let words2 = try WalletFactory.recoveryPhrase(keystoreId: added.keystoreId)
            check("助记词未变", words == words2)
            check("walletId 未变", added.walletId == w.walletId)

            // 5. 地址与派生路径一一对应。
            //    ⚠️ 不能断言「地址互不相同」—— EVM 系列链共用 m/44'/60'/0'/0/0，
            //    ethereum 和 polygon 本来就是同一个地址，这是正确行为。
            //    真正的不变量是：同路径必同地址，异路径必异地址。
            var byPath: [String: Set<String>] = [:]
            for a in added.accounts { byPath[a.derivationPath, default: []].insert(a.address) }
            check("同派生路径 → 同地址", byPath.values.allSatisfy { $0.count == 1 })
            check("异派生路径 → 异地址",
                  Set(byPath.values.map { $0.first! }).count == byPath.count,
                  "\(byPath.count) 条不同路径")
            let evm = added.accounts.filter { $0.derivationPath == "m/44'/60'/0'/0/0" }
            check("EVM 链共用地址", evm.count < 2 || Set(evm.map(\.address)).count == 1,
                  evm.map(\.chain).joined(separator: "/"))

            // 6. 直接扫数据库文件的原始字节 —— 比查字段更硬，
            //    连写进未使用列或残留页的情况都能抓到。
            let dbBytes = (try? Data(contentsOf: URL(fileURLWithPath: WalletDatabase.databasePath))) ?? Data()
            let raw = String(decoding: dbBytes, as: UTF8.self)
            check("数据库不含助记词", !words.contains { raw.contains($0) },
                  "\(dbBytes.count) 字节")
            check("数据库不含 keystoreId", !raw.contains(w.keystoreId))

            // 7. 删除：文件与清单都要清
            try WalletFactory.delete(added)
            check("删除后清单移除", !WalletStore.all().contains { $0.walletId == w.walletId })
            check("删除后文件移除", !WalletFactory.fileInfo(keystoreId: w.keystoreId).exists)

        } catch {
            check("未抛异常", false, "\(error)")
        }

    }
}
