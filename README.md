# GemIOSDemo

iOS 端调用 Rust 编译产物（`gemstone-swift`）的最小可运行示例。

两个页面：

| Tab | 演示什么 |
|---|---|
| **FFI** | `libVersion()` 正向调用 + `AlienProvider` 反向回调 |
| **钱包** | 列表 + 生成 + 详情（助记词现场解密） |

```
FFI                              钱包列表          点进详情
Gemstone lib version: 2.114.10   0xF03A75f5…        地址/链/walletId/keystoreId
https://httpbin.org/get?foo=bar  0x9681c8A6…        助记词（由 keystore 现场解密）
-> 200, 464 bytes                                   ✓ keystore 文件存在 620 字节
```

### 🔴 钱包列表必须 App 自己存

`GemKeystore` 的 9 个方法（`createStore` `sign` `delete` `exportPrivateKey`
`exportRecoveryPhrase` `addAccounts` `previewImport` `signAuth` `migrateV3`）
**没有任何 list / getAll**，而且除 `createStore` 外每个都要求传入 `keystoreId`。

Rust 从不告诉你有哪些钱包 —— 它只按 id 收活。App 不自己记，生成完就再也找不回来。

| | 存什么 | 在哪 |
|---|---|---|
| Rust | 加密的密钥材料 | `<baseDir>/<keystoreId>.json`，一钱包一文件 |
| App | 钱包清单与元数据 | SQLite（本 demo 用 UserDefaults 从简） |

清单里**只放找得回来所需的最小信息**，秘密仍留在加密文件里。实测 UserDefaults 内容：

```json
[{ "walletId": "multicoin_0x98200302…", "keystoreId": "b74f9283-…",
   "chain": "ethereum", "address": "0x98200302…", "createdAt": 811068890.39 }]
```

助记词一个字都没有 —— 详情页的助记词是 `exportRecoveryPhrase()` 现场解出来的，
所以杀掉 App 重启后照样能显示。

> 真实产品应该用 SQLite 而非 UserDefaults，关键原因是**响应式查询**：
> GRDB / Room 能在数据变化时自动刷新 UI，UserDefaults 只能手动 reload。
> gem 主 App 的两张表：`wallets` 与 `wallets_accounts`。

```bash
./build.sh                    # 编译 + 装进模拟器 + 启动
./build.sh "iPhone 17 Pro"    # 指定机型
```

> 🔴 **需要 Apple Silicon 的 Mac**（发布的库只有 arm64 切片，Intel 跑不了模拟器）。
> 模拟器怎么选、有哪些坑，见 [SIMULATOR.md](SIMULATOR.md)。

---

## 1. 这个库是什么

`gemstone-swift` 是 gem 的 Rust core 编译给 iOS 用的产物，一个 SPM 包：

| 内容 | 说明 |
|---|---|
| `Gemstone.swift` | UniFFI 生成的 Swift 绑定，24,331 行 |
| `GemstoneFFI.xcframework` | Rust 静态库，含真机 + 模拟器两个切片 |

**你只需要 `import Gemstone`**，不需要接触 Rust、不需要装 Rust 工具链。

> ⚠️ 只能用 `core/`（MIT）。仓库里的 `ios/` 和 `android/` 是 GPL-3.0，
> 抄过去会让你整个 App 被传染成 GPL。

---

## 2. 接入

Xcode → File → Add Package Dependencies：

```
https://github.com/weaver-max/gemstone-swift
```

选 **Exact Version** `2.114.10`。或写进 `Package.swift`：

```swift
dependencies: [
    .package(url: "https://github.com/weaver-max/gemstone-swift.git", exact: "2.114.10")
]
```

无需鉴权——SPM 下载 binaryTarget 时不带认证头，所以该仓库是 public 的。

> 📌 Android 侧相反：GitHub Packages 即使 public 也强制要 token。

---

## 3. 三种调用方式

### 3.1 顶层函数 —— 纯计算，直接调

```swift
import Gemstone

libVersion()                                           // "2.114.10"
validateAddress(address: addr, chain: "ethereum")      // Bool
checksumAddress(address: addr, chain: "ethereum")      // EIP-55
shortAddress(address: addr, chain: "ethereum")         // "0x1234…abcd"
keystoreIdForWallet(walletId: "multicoin_0x…")         // UUID v5
```

> 🔴 **`chain` 是 `String`，不是枚举** —— 见 [§4](#4-五个必须知道的约束)。
> 写 `.ethereum` 编不过。

还有 `calculateTransferAmount`、`getDefaultSlippage`、`paymentDecodeUrl`、
`siweTryParse` 等 40 多个，全在 `Gemstone.swift` 里搜 `public func`。

### 3.2 对象 —— 有状态的能力

```swift
// 助记词
let mnemonic = GemMnemonic()
let words = try mnemonic.generate(wordCount: 12)
mnemonic.isValid(words: words)
mnemonic.suggestWords(prefix: "aban", limit: 5)

// 密钥库
let passwordData = Data(userPassword.utf8)     // 注意是 Data 不是 String
let keystore = try GemKeystore(baseDir: keystoreDirectory)
let wallet = try keystore.createStore(
    import: .multicoinPhrase(words: words, chains: ["ethereum"]),
    password: passwordData
)
// wallet.walletId / wallet.keystoreId / wallet.accounts
// accounts[0].address / .chain / .derivationPath / .publicKey
```

完整可运行版本见 [WalletView.swift](WalletView.swift)。

> 🔴 **`createStore` 很重**：Argon2id 用 19 MiB 内存、2 轮迭代，
> 必须放到后台线程。注意 SwiftUI 的 `View` 默认是 `@MainActor`——
> 把创建逻辑写成 View 的方法，即使包在 `Task.detached` 里也会被弹回主 actor。
> 要放在 View **外面**的类型里，见 `WalletFactory`。

### 3.3 反向回调 —— Rust 调你写的 Swift

这是最容易漏掉的一环。有些能力 Rust 不自己做，**定义协议让平台实现**：

| 协议 | 你要提供 | 为什么不让 Rust 做 |
|---|---|---|
| `AlienProvider` | 发 HTTP 请求 | 复用 URLSession 的连接池、代理、证书校验 |
| `GemPreferences` | 键值存储 | 复用 UserDefaults / Keychain |

```swift
final class NativeProvider: AlienProvider, @unchecked Sendable {

    func getEndpoint(chain: Chain) throws -> String {
        "https://ethereum.publicnode.com"
    }

    func request(target: AlienTarget) async throws -> AlienResponse {
        guard let url = URL(string: target.url) else {
            throw AlienError.RequestError(msg: "invalid url")
        }
        var req = URLRequest(url: url)
        req.httpMethod = alienMethodToString(method: target.method)
        target.headers?.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.httpBody = target.body

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode
        return AlienResponse(status: status.map(UInt16.init), data: data)
    }
}
```

完整可运行版本见 [App.swift](App.swift)。

---

## 4. 五个必须知道的约束

### 🔴 `Chain` 是 `String`，没有编译期检查

```swift
public typealias Chain = String
```

Rust 侧是 `uniffi::custom_type!(Chain, String)`，所以 Swift 拿到的是裸字符串：

```swift
validateAddress(address: addr, chain: "ethereum")   // ✅
validateAddress(address: addr, chain: .ethereum)    // ❌ 编不过，没有这个成员
```

**写法：全小写、无下划线** —— `"ethereum"` · `"smartchain"` · `"solana"`。
拼错不会报编译错误，只会在运行时失败。建议自己包一层：

```swift
enum GemChain: String {
    case ethereum, solana, smartchain
    var id: Chain { rawValue }
}
validateAddress(address: addr, chain: GemChain.ethereum.id)
```

### 🔴 私钥不过 FFI

签名在 Rust 内部完成，**只返回签名结果**：

```swift
let signed = try keystore.sign(
    keystoreId: id, chain: "ethereum",
    input: signerInput, password: passwordData
)   // -> [GemSignedTransaction]，不是私钥
```

Swift 侧从头到尾拿不到私钥。只有用户显式导出时才例外：
`exportPrivateKey(...)` / `exportRecoveryPhrase(...)`——这两个要走生物识别确认。

### 🔴 `AlienResponse` 读不出内容

它是 `uniffi::Object`（不透明句柄），只有构造函数，**没有 getter**：

```swift
let resp = AlienResponse(status: 200, data: data)
resp.status    // ❌ 编译不过，没这个属性
```

它的用途是交给 Rust 消费。要记状态码就在构造**之前**记。

### 🔴 `password` 是 `Data` 不是 `String`

```swift
let passwordData = Data(userPassword.utf8)
```

### 🔴 `walletId` 恒由以太坊地址派生

即使只启用了 Solana，`walletId` 仍是 `multicoin_{eth_address}`。
`keystoreId` 再由它算 UUID v5。别自己拼这个格式，用 `keystoreIdForWallet()`。

---

## 5. 本 Demo 的构建方式（与真实项目不同）

`build.sh` 用 `swiftc` 手工编译、手工组 `.app` bundle，**没有 Xcode 工程**。

这是刻意的：每一环（取包 → 编 module → 链接 → 装包）都显式可见，
适合验证「发布出去的产物下游能不能真正用起来」。

**真实项目请用 Xcode 工程 + SPM 依赖**，不要照抄这个流程。

五步：

```
1. swift package resolve      拉已发布的包，校验 checksum
2. 编 Gemstone module         必须单独编，否则 import 不到
3. 编 App 并链接               + vtool 平台自检
4. 组 .app bundle             Info.plist + plutil -lint
5. simctl install / launch
```

### 为什么第 2 步要单独编

同一次 `swiftc` 调用里的所有源文件属于**同一个 module**。
`Gemstone.swift` 和 `App.swift` 一起编就成了一个 module，
`App.swift` 再 `import Gemstone` 会报 `no such module`。

---

## 6. 常见问题

**编译报 `no such module 'Gemstone'`**
Xcode 工程里：确认 target 的 Frameworks 里加了 `Gemstone` 库产品。
手工编译：见 §5。

**真机能跑模拟器不能（或反过来）**
XCFramework 有 `ios-arm64` 和 `ios-arm64-simulator` 两个切片，
Xcode 会自动选。手工编译要显式指向对的那个。

**`clang: warning: using sysroot for 'MacOSX' but targeting 'iPhone'`**
已知无害，消不掉。判断产物对不对看 `vtool -show-build-version`，
应该是 `platform IOSSIMULATOR`。`build.sh` 里已加这条断言。

**想确认版本对不对**
`libVersion()` 返回的就是发布版本号，和 SPM 里 pin 的版本应当一致。

---

## 7. 延伸阅读

| 文档 | 内容 |
|---|---|
| [iOS-Integration-Guide.md](https://github.com/weaver-max/gemstone-swift/blob/main/iOS-Integration-Guide.md) | 完整集成指南（796 行），API 逐个讲 |
| `ios跑模拟器出现的问题以及解决.md` | 本 Demo 的构建过程与踩坑记录 |
| `gem私钥管理.md` | keystore 格式、walletId 派生、签名流程 |
| `旧钱包存量迁移.md` | 从旧钱包导入助记词/私钥该调哪些接口 |

后三份在 `wallet` 仓库根目录。

---

## 文件说明

```
GemIOSDemo/
├── Package.swift      依赖 gemstone-swift 2.114.10
├── App.swift          Tab 容器 + FFI 页（AlienProvider 实现）
├── WalletView.swift   钱包列表 + 生成
├── WalletStore.swift  列表持久化 + WalletFactory（创建/解密/删除）
├── WalletDetailView.swift  详情：助记词现场解密
├── build.sh           五步构建脚本
├── README.md          本文件 —— 怎么调用
└── SIMULATOR.md       模拟器选择与注意事项
```
