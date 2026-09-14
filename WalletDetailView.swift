import SwiftUI
import Gemstone

/// 钱包详情：walletId / keystoreId / 助记词。
///
/// 助记词不是从列表里读的 —— 列表里根本没有。
/// 进页面时调 exportRecoveryPhrase，从加密的 keystore 文件现场解出来。
struct WalletDetailView: View {

    let initial: WalletEntry
    var onDelete: () -> Void
    var onChange: (WalletEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var entry: WalletEntry
    @State private var words: [String] = []
    @State private var error: String?
    @State private var busy = true
    @State private var adding = false

    init(entry: WalletEntry,
         onDelete: @escaping () -> Void,
         onChange: @escaping (WalletEntry) -> Void) {
        self.initial = entry
        self.onDelete = onDelete
        self.onChange = onChange
        _entry = State(initialValue: entry)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    banner

                    field("walletId", entry.walletId, mono: true)
                    field("keystoreId（由 walletId 派生，不存盘）",
                          entry.keystoreId, mono: true)

                    mnemonicSection
                    accountsSection
                    fileSection

                    Button(role: .destructive) {
                        onDelete()
                        dismiss()
                    } label: {
                        Label("删除钱包", systemImage: "trash")
                    }
                    .padding(.top, 8)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("钱包详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task { load() }
    }

    // ── 子视图 ──────────────────────────────────────────────

    private var banner: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("⚠️")
            VStack(alignment: .leading, spacing: 2) {
                Text("DEMO ONLY").font(.caption).bold()
                Text("真实产品展示助记词前必须过生物识别")
                    .font(.caption2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private var mnemonicSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("助记词").font(.caption).foregroundStyle(.secondary)
                Spacer()
                // 说明来源，这是本页最想传达的一点
                Text("由 keystore 现场解密")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if busy {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("解密中…").font(.footnote).foregroundStyle(.secondary)
                }
            } else if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            } else {
                Text(words.joined(separator: " "))
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    /// 本页最想说明的一点：下面所有地址都来自**同一个助记词**，
    /// 只是派生路径不同。加新链不会产生新助记词。
    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("派生地址（\(entry.accounts.count)）")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("同一助记词")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            ForEach(entry.accounts) { account in
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.chain).font(.caption).bold()
                    Text(account.address)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                    Text(account.derivationPath)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            Button {
                addChains()
            } label: {
                Label(adding ? "派生中…" : "再派生 3 条链", systemImage: "plus")
                    .font(.caption)
            }
            .disabled(adding || remainingChains.isEmpty)
        }
    }

    private var remainingChains: [Chain] {
        let have = Set(entry.accounts.map(\.chain))
        return WalletFactory.extraChains.filter { !have.contains($0) }
    }

    private var fileSection: some View {
        let info = WalletFactory.fileInfo(keystoreId: entry.keystoreId)
        return VStack(alignment: .leading, spacing: 2) {
            Text(info.exists ? "✓ keystore 文件存在" : "✗ 文件未找到")
                .font(.caption).bold()
                .foregroundStyle(info.exists ? .green : .red)
            Text("\(info.name)  \(info.size) 字节")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func field(_ label: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(mono ? .system(.caption, design: .monospaced) : .callout)
                .textSelection(.enabled)
        }
    }

    // ── 逻辑 ────────────────────────────────────────────────

    private func addChains() {
        adding = true
        error = nil
        let next = Array(remainingChains.prefix(3))
        let current = entry
        Task.detached(priority: .userInitiated) {
            do {
                let updated = try WalletFactory.addChains(current, chains: next)
                await MainActor.run {
                    entry = updated
                    onChange(updated)
                    adding = false
                }
            } catch {
                await MainActor.run {
                    self.error = "派生失败: \(error)"
                    adding = false
                }
            }
        }
    }

    private func load() {
        busy = true
        // 先在主 actor 上取出值再进后台 —— entry 是 @State，
        // 在 Task.detached 里直接读它会触发 actor 隔离错误（Swift 6 下是编译错误）。
        let keystoreId = entry.keystoreId
        // Argon2id 解密同样很重，必须离开主线程
        Task.detached(priority: .userInitiated) {
            do {
                let w = try WalletFactory.recoveryPhrase(keystoreId: keystoreId)
                await MainActor.run { words = w; busy = false }
            } catch {
                await MainActor.run {
                    self.error = "解密失败: \(error)"
                    busy = false
                }
            }
        }
    }
}
