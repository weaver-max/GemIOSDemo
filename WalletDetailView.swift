import SwiftUI
import Gemstone

/// 钱包详情：walletId / keystoreId / 助记词。
///
/// 助记词不是从列表里读的 —— 列表里根本没有。
/// 进页面时调 exportRecoveryPhrase，从加密的 keystore 文件现场解出来。
struct WalletDetailView: View {

    let entry: WalletEntry
    var onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var words: [String] = []
    @State private var error: String?
    @State private var busy = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    banner

                    field("地址", entry.address, mono: true)
                    field("链", entry.chain)
                    field("walletId", entry.walletId, mono: true)
                    field("keystoreId", entry.keystoreId, mono: true)

                    mnemonicSection
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

    private func load() {
        busy = true
        // Argon2id 解密同样很重，必须离开主线程
        Task.detached(priority: .userInitiated) {
            do {
                let w = try WalletFactory.recoveryPhrase(keystoreId: entry.keystoreId)
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
