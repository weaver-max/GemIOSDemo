# GemIOSDemo

iOS 怎么调用 Rust 编译出来的 gem 核心库。一个能跑的最小例子。

```bash
./build.sh          # 编译 + 装进模拟器 + 启动
./build.sh --clean  # 顺便清空钱包数据
```

> 需要 **Apple Silicon 的 Mac** —— 发布的库只有 arm64 切片，Intel 跑不了模拟器。
> 详见 [SIMULATOR.md](SIMULATOR.md)。

App 有两页：**钱包**（生成、看地址、看助记词）和 **FFI**（版本号、网络回调）。

> 📐 **先搞清楚谁负责什么**：[App 端和 Core 端的功能边界](app端和core端的功能边界.md)
> —— 网络全部由你发（core 里没编译 HTTP 客户端）、存储只有 keystore 文件归 Rust。

---

## 1. 接入

Xcode → File → Add Package Dependencies，填：

```
https://github.com/weaver-max/gemstone-swift
```

选 Exact Version `2.114.10`。然后 `import Gemstone` 就能用了。

不需要装 Rust，不需要编译任何东西 —— 这个包里已经含好了 Rust 编译产物。

> ⚠️ 只能用 `core/`（MIT）。gem 仓库里的 `ios/` 和 `android/` 是 GPL-3.0，
> 抄过去你整个 App 都得开源。

---

## 2. 怎么调

### 直接调函数

```swift
import Gemstone

libVersion()                                      // "2.114.10"
validateAddress(address: addr, chain: "ethereum") // 地址合法吗
checksumAddress(address: addr, chain: "ethereum") // EIP-55 大小写
shortAddress(address: addr, chain: "ethereum")    // "0x1234…abcd"
```

这类纯计算的函数有 40 多个，在 `Gemstone.swift` 里搜 `public func`。

### 创建对象

```swift
// 助记词
let words = try GemMnemonic().generate(wordCount: 12)

// 钱包
let keystore = try GemKeystore(baseDir: 某个目录)
let wallet = try keystore.createStore(
    import: .multicoinPhrase(words: words, chains: ["ethereum", "solana"]),
    password: Data("用户密码".utf8)
)
wallet.walletId    // multicoin_0x1C20…
wallet.accounts    // 每条链一个地址
```

### 实现协议让 Rust 回调你

Rust 不自己发网络请求、不自己存偏好设置，它定义协议让你实现：

| 协议 | 你提供 | 为什么不让 Rust 做 |
|---|---|---|
| `AlienProvider` | 发 HTTP | 复用 URLSession 的连接池、代理、证书校验 |
| `GemPreferences` | 键值存储 | 复用 UserDefaults / Keychain |

```swift
final class NativeProvider: AlienProvider, @unchecked Sendable {
    func getEndpoint(chain: Chain) throws -> String { "https://ethereum.publicnode.com" }

    func request(target: AlienTarget) async throws -> AlienResponse {
        var req = URLRequest(url: URL(string: target.url)!)
        req.httpMethod = alienMethodToString(method: target.method)
        target.headers?.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.httpBody = target.body

        let (data, response) = try await URLSession.shared.data(for: req)
        return AlienResponse(status: (response as? HTTPURLResponse)?.statusCode.map(UInt16.init),
                             data: data)
    }
}
```

完整版见 [App.swift](App.swift)。

---

## 3. 五个容易踩的坑

### 链名是字符串，不是枚举

```swift
public typealias Chain = String

validateAddress(address: addr, chain: "ethereum")  // ✅
validateAddress(address: addr, chain: .ethereum)   // ❌ 编不过
```

全小写无下划线：`"ethereum"` `"smartchain"` `"solana"`。
**拼错不会报编译错误，只在运行时失败。** 建议自己包一层 enum 兜底。

### 密码是 `Data` 不是 `String`

```swift
let password = Data(userPassword.utf8)
```

### 私钥不过 FFI

签名在 Rust 内部完成，只返回签名结果：

```swift
let signed = try keystore.sign(keystoreId: id, chain: "ethereum",
                               input: signerInput, password: password)
```

Swift 侧拿不到私钥。只有用户主动导出时例外 —— `exportPrivateKey` /
`exportRecoveryPhrase`，这两个调用前必须过生物识别。

### `AlienResponse` 读不出内容

它只有构造函数，没有 getter：

```swift
let resp = AlienResponse(status: 200, data: data)
resp.status   // ❌ 没这个属性
```

它是给 Rust 消费的。要记状态码就在构造之前记。

### `createStore` 很慢，且不能写在 View 里

Argon2id 要 19 MiB 内存、跑 2 轮，必须放后台线程。

注意 SwiftUI 的 `View` 默认是 `@MainActor` —— 把创建逻辑写成 View 的方法，
**就算包在 `Task.detached` 里也会被弹回主线程**。要放在 View 外面的类型里
（本项目是 `WalletFactory`）。

---

## 4. 钱包清单得你自己存

`GemKeystore` 一共 9 个方法，**没有 list、没有 getAll**，而且除了 `createStore`
每个都要求你传 `keystoreId`。

Rust 从不告诉你有哪些钱包，它只按 id 干活。**你不自己记，生成完就找不回来了。**

| | 存什么 | 存哪 |
|---|---|---|
| Rust | 加密后的助记词 | `<baseDir>/<keystoreId>.json`，一钱包一文件 |
| 你 | 钱包清单、地址、名字、排序 | 数据库 |

本项目的表（照搬 gem 主 App 的设计）：

```sql
CREATE TABLE wallets (
    id          TEXT PRIMARY KEY NOT NULL,   -- walletId
    created_at  REAL NOT NULL
);
CREATE TABLE wallets_accounts (
    wallet_id       TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
    chain           TEXT NOT NULL,
    address         TEXT NOT NULL,
    derivation_path TEXT NOT NULL,
    account_index   INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (wallet_id, chain, account_index)
);
```

`account_index` **M1 恒为 0**，Swift 侧的 `AccountEntry.index` 也一样。
后续 core 支持同链多账户时，数据结构与表结构都不用改，把真实 index 填进来即可。
注意主键从一开始就带上了 `account_index` —— 只写 `(wallet_id, chain)` 的话将来会撞主键。

**表里没有助记词和私钥的位置。** 这比写个检查函数更可靠 —— 想存秘密得先改表结构。

助记词在详情页是调 `exportRecoveryPhrase(keystoreId:password:)` 现场解出来的，
所以杀掉 App 重启照样能看到。

> 本项目用裸 `libsqlite3`（SDK 自带，零依赖）。真实项目请用 **GRDB** ——
> 它支持响应式查询，数据一变 UI 自动刷新。这才是清单该放数据库而不是
> UserDefaults 的真正理由。

---

## 5. 一个助记词，多条链，但同链只有一个地址

生成钱包时，一个助记词会派生出多条链的地址：

```
ethereum  0x4C7e2482a22E7C82…   m/44'/60'/0'/0/0
solana    8RsFvRbHNUeUKmSXYA…   m/44'/501'/0'/0'
bitcoin   bc1qgz3990q9e4slpy…   m/84'/0'/0'/0/0
```

EVM 系列链（ethereum / polygon / arbitrum…）**共用同一个地址**，因为派生路径相同。

### 🔴 做不了 MetaMask 那种「添加账户」

同一条链上派生 Account 1 / 2 / 3，**gem 目前做不到**。不是没导出，是 core 里就没有：

```rust
// core/crates/gem_derivation/src/private_key/path.rs
pub fn default_derivation_path(chain: Chain) -> &'static str {
    match chain {
        Chain::Ethereum | ... => "m/44'/60'/0'/0/0",   // 编译期常量
```

路径是写死的字符串，整个 crate 没有任何函数接受 index 参数。

要支持的话改动不小 —— `walletId` 现在**就是** index 0 的以太坊地址，
加索引等于改钱包身份模型，还要动 keystore 文件格式。
表里的 `account_index` 列是为此预留的，现在恒为 0。

---

## 6. 跑起来和验证

```bash
./build.sh
```

五步：拉包 → 编 Gemstone module → 编 App → 组 .app → 装进模拟器。
默认覆盖安装，**钱包数据跨重编保留**；加 `--clean` 才清空。

iOS 模拟器没法用命令行注入点击，所以功能验证靠启动参数：

```bash
xcrun simctl launch <UDID> com.example.gemiosdemo -selftest
sleep 20
C=$(xcrun simctl get_app_container <UDID> com.example.gemiosdemo data)
cat "$C/Documents/selftest.txt"
```

跑 15 项：生成、多链派生、落盘、助记词解密、再派生后助记词与 walletId 不变、
派生路径与地址的对应关系、`index` 恒为 0、数据库不含秘密、删除后文件与清单同步清理。

> 「数据库不含助记词」这条查的是**连续两词**，不是单个词。
> SQLite 把建表语句存进 `sqlite_master`，schema 里的 `index` `address`
> 恰好都在 BIP39 词表里，逐词匹配必然误报。这条断言注入过假泄漏验证确实能抓到。

其他参数：`-autowallet` 生成一个 · `-detail` 打开详情 · `-ffi` 落在 FFI 页。

---

## 7. 常见问题

**`no such module 'Gemstone'`**
Xcode 里确认 target 的 Frameworks 加了 `Gemstone` 库产品。

**`clang: warning: using sysroot for 'MacOSX' but targeting 'iPhone'`**
已知无害，消不掉。判断产物对不对看 `vtool -show-build-version`，
应该是 `platform IOSSIMULATOR`。`build.sh` 里已经加了这条断言。

**真机能跑模拟器不能（或反过来）**
XCFramework 有两个切片，Xcode 会自动选。手工编译要指对。

---

## 文件

```
Package.swift            只用来拉 gemstone-swift 并校验 checksum
App.swift                Tab 容器 + FFI 页
WalletView.swift         钱包列表
WalletDetailView.swift   钱包详情（助记词现场解密）
WalletStore.swift        清单接口 + 创建/解密/删除
WalletDatabase.swift     SQLite
SelfTest.swift           无头自检
build.sh                 一键构建运行
SIMULATOR.md             模拟器选择与注意事项
app端和core端的功能边界.md   网络与存储的职责划分
```

> ⚠️ 本项目用 `swiftc` 手工编译、手工组 `.app`，**不是** Xcode 工程。
> 这样每一步都显式可见，适合验证发布产物。真实项目请正常用 Xcode + SPM。

更多背景：

- [App 端和 Core 端的功能边界](app端和core端的功能边界.md) —— 网络与存储的职责划分，附实测证据
- [完整集成指南](https://github.com/weaver-max/gemstone-swift/blob/main/iOS-Integration-Guide.md) —— API 逐个讲
- gem 仓库根目录的 `gem私钥管理.md`、`旧钱包存量迁移.md`、
  `ios跑模拟器出现的问题以及解决.md`
