import SwiftUI
import Gemstone

/// 钱包列表。
///
/// 这个页面存在的意义：**Rust 不管列表**。
/// GemKeystore 的 9 个方法里没有任何 list/getAll，每个方法都要求传入 keystoreId ——
/// App 不自己记，生成完就再也找不回来了。
struct WalletView: View {

    /// 自动化验证用，见 GemIOSDemoApp 的启动参数说明
    var autoGenerate: Bool = false
    var autoOpenDetail: Bool = false

    @State private var entries: [WalletEntry] = []
    @State private var selected: WalletEntry?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        generate()
                    } label: {
                        Label(busy ? "生成中…" : "生成新钱包",
                              systemImage: "plus.circle.fill")
                    }
                    .disabled(busy)

                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                } footer: {
                    Text("每个钱包是一个助记词，下挂多条链的派生地址。"
                         + "清单存在 UserDefaults，不含助记词 —— "
                         + "详情页的助记词是从加密的 keystore 文件现场解出来的。")
                }

                Section("钱包（\(entries.count)）") {
                    if entries.isEmpty {
                        Text("还没有钱包").foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        Button { selected = entry } label: { row(entry) }
                            .buttonStyle(.plain)
                    }
                    .onDelete(perform: delete)
                }
            }
            .navigationTitle("钱包")
            .sheet(item: $selected) { entry in
                WalletDetailView(entry: entry,
                                 onDelete: { remove(entry) },
                                 onChange: { _ in reload() })
            }
        }
        .task {
            reload()
            // -autowallet 的语义就是「生成一个」，不看列表当前状态。
            // 不带这个参数时不会自动生成，得手点按钮。
            if autoGenerate { generate() }
            if autoOpenDetail { selected = entries.first }
        }
    }

    // ── 子视图 ──────────────────────────────────────────────

    private func row(_ entry: WalletEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                // 一个钱包 = 一个助记词，下面挂着多条链的派生地址
                Text(entry.accounts.first?.address ?? "(无账户)")
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(entry.accounts.count) 条链 · "
                     + entry.createdAt.formatted(date: .omitted, time: .standard))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    // ── 逻辑 ────────────────────────────────────────────────

    private func reload() { entries = WalletStore.all() }

    private func generate() {
        busy = true
        error = nil
        // Argon2id 很重（19 MiB / 2 轮），必须离开主线程。
        // WalletFactory 刻意定义在 View 外面，否则会被 @MainActor 隔离弹回主线程。
        Task.detached(priority: .userInitiated) {
            do {
                _ = try WalletFactory.create()
                await MainActor.run { reload(); busy = false }
            } catch {
                await MainActor.run {
                    self.error = "生成失败: \(error)"
                    busy = false
                }
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        offsets.map { entries[$0] }.forEach(remove)
    }

    private func remove(_ entry: WalletEntry) {
        // keystore 文件和列表记录要一起删，否则会留下孤儿文件
        do {
            try WalletFactory.delete(entry)
            reload()
        } catch {
            self.error = "删除失败: \(error)"
        }
    }
}
