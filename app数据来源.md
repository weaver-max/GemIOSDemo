# App 的数据从哪来

钱包界面上每一个数字，追到底都来自三个地方之一。**搞混了会严重误判排期。**

配套阅读：[App 端和 Core 端的功能边界](app端和core端的功能边界.md)

本文结论均为实测，环境：`gemstone-swift 2.114.10` · 2026-09-14

---

## 0. 一张图

```
① 后端索引器  ──直连──►  你  ──►  SQLite      有什么
   Rust 完全不参与                              代币列表 / 交易历史 / 价格 / NFT

② 经 Rust 取数，四个入口  ──►  你  ──►  SQLite      现在是多少
   链上 RPC    ──► GemGateway                  余额 / nonce / gas / 广播
   DEX 聚合器  ──► GemSwapper                  兑换报价与路由
   模拟服务    ──► WalletConnectSimulationClient
   gem 后端    ──► GemServiceStatus            服务健康检查
   ❗四者的请求全部由你的 AlienProvider 发出

③ keystore    ──►  Rust 独占                   加密的助记词
```

**后端告诉你「有什么」，链上告诉你「现在是多少」。**

> 📌 **判断某个 Rust 对象会不会发网络，看它构造时要不要传 `AlienProvider`。**
> 全仓库只有上面四个要传。其余对象（`GemKeystore` `GemMnemonic` `Explorer`…）
> 都是纯本地计算。

---

## 1. 🔴 最重要的一条：交易历史和代币发现都在后端

这两件事**链上 RPC 做不了**：

| 你想问 | 链上 RPC 能答吗 |
|---|---|
| 地址 A 持有代币 B 多少？ | ✅ 能 |
| **地址 A 持有哪些代币？** | ❌ **不能** |
| **地址 A 的所有历史交易？** | ❌ **不能** |

以太坊没有"查某地址全部交易"的接口。要覆盖完整历史，等于把全链扫一遍。
代币发现同理——链上只能正查，不能反查持仓。

**所以必须有后端索引器。** gem 的对应端点：

```
GET  /v2/devices/transactions      交易历史
GET  /v2/devices/assets            代币发现（这台设备该显示哪些资产）
POST /v2/devices/portfolio/assets  组合持仓
GET  /v2/devices/nft_assets        NFT
```

> ⚠️ **这条决定了钱包能不能用。**
> 后端索引没就绪的话，就算 core 全接通，用户看到的也只是
> 「只有原生币余额、没有交易记录」的半成品。

---

## 2. 后端直连：全部端点

**App 自己发、自己解析、自己入库，Rust 不参与。**

### 资产与行情

```
GET  /v1/assets/{asset_id}          单个资产元数据
POST /v1/assets                     批量
GET  /v1/assets/search              搜索
GET  /v1/charts/{asset_id}          K 线
GET  /v1/search                     全局搜索
GET  /v1/swap/assets                可兑换资产
GET  /v1/fiat/assets/{type}         可买/可卖法币资产
```

### 设备维度的数据

```
GET  /v2/devices                    设备信息
GET  /v2/devices/is_registered
GET  /v2/devices/assets             ← 代币发现
GET  /v2/devices/transactions       ← 交易历史
POST /v2/devices/portfolio/assets
GET  /v2/devices/nft_assets
GET  /v2/devices/notifications
GET  /v2/devices/subscriptions
GET  /v2/devices/price_alerts
GET  /v2/devices/rewards
GET  /v2/devices/wallet_configuration
GET  /v2/devices/token              推送 token
GET  /v2/devices/auth/nonce         设备鉴权
```

### 法币与其他

```
GET  /v2/devices/fiat/quotes/{type}/{asset_id}
GET  /v2/devices/fiat/transactions
GET  /v2/devices/name/resolve/{name}     域名解析
GET  /v2/devices/support/messages
GET  /v1/config
GET  /blockchains/{chain}/validators.json
```

### 🔴 唯一经过 Rust 的后端调用

```
POST /v2/devices/scan/transaction     交易风险扫描
```

对应 `GemGateway.getTransactionScan()`。这也是 `GemGateway(...)` 要传 `apiUrl`
的**唯一原因** —— 不用这个功能的话传占位符都能跑。

---

## 3. 经过 Rust 的四个入口

### 3.1 判断方法：构造要不要传 `AlienProvider`

```
GemGateway(provider, prefs, securePrefs, apiUrl)   ← 要传 → 会发网络
GemSwapper(provider)                                ← 要传 → 会发网络
GemServiceStatus(provider)                          ← 要传 → 会发网络
WalletConnectSimulationClient(provider)             ← 要传 → 会发网络

GemKeystore(baseDir)      ← 不传 → 纯本地
GemMnemonic()             ← 不传 → 纯本地
Explorer / Config / …     ← 不传 → 纯本地
```

**全仓库只有这四个对象能发网络**，而且都用同一个 `AlienProvider` 实例：

```swift
let provider = NativeProvider()      // 你只需要写一个

GemGateway(provider: provider, …)
GemSwapper(rpcProvider: provider)
GemServiceStatus(provider: provider)
```

所以抓包能看到全部流量，限流 / 重试 / 证书固定在一处加就够。

> 💡 `GemGateway` 构造时会给 provider 包一层 `coalescing_provider` ——
> 同一时刻打到同一 target 的重复请求自动合并（列表刷新余额时很有用）。
> **你不用自己去重。** 但 `GemSwapper` 和 `GemServiceStatus` 没有这层。

### 3.2 `GemGateway`：28 个方法

全是 `async`：

| 类别 | 方法 |
|---|---|
| **余额** | `getBalanceCoin` `getBalanceTokens` `getBalanceStaking` `getBalanceEarn` |
| **交易** | `getTransactionPreload` `getTransactionLoad` `transactionBroadcast` `getTransactionStatus` `getTransactionSwapStatus` |
| **费用** | `getFeeRates` |
| **链信息** | `getChainId` `getBlockNumber` `getNodeStatus` `getUtxos` |
| **代币** | `getTokenData` `getIsTokenAddress` |
| **质押** | `getStakingValidators` `getStakingDelegations` `getStakingDelegationValidators` |
| **理财** | `getEarnProviders` `getEarnPositions` |
| **永续** | `getPositions` `getPerpetual*` ×4 |
| 🔴 后端 | `getTransactionScan`（唯一例外） |

### 3.3 节点是你指定的

```swift
func getEndpoint(chain: Chain) throws -> String {
    "https://ethereum.publicnode.com"
}
```

Rust 问你要节点地址，然后自己拼出完整 URL，再通过 `AlienProvider` 发出来。

> ⚠️ **隐私提醒**：公共节点（publicnode / Infura / Alchemy）能看到
> 你查了哪些地址的余额。对隐私有要求的话，这里要换自建节点或付费服务。
> 这是产品与成本决策，core 解决不了。

### 3.4 有几个不是纯链上

| 方法 | 实际打到哪 |
|---|---|
| `getEarnData` / `getEarnPositions` / `getBalanceEarn` | 第三方理财协议（Yo）的 API |
| `getPerpetual*` | Hyperliquid 的服务 |

所以「链上 RPC」这个说法对余额、交易、UTXO 是准的，
但理财和永续实际是在调第三方协议接口。

### 3.5 另外三个入口

| 对象 | 用途 | 打到哪 |
|---|---|---|
| `GemSwapper` | 兑换报价与路由 | 各 DEX 聚合器的 API |
| `GemServiceStatus` | 服务健康检查 | gem 后端 |
| `WalletConnectSimulationClient` | WalletConnect 交易模拟 | 模拟服务 |

M1 若要做兑换，`GemSwapper` 是除 `GemGateway` 外最主要的一个，
它的依赖与数据来源需要单独摸一遍 —— 本文未覆盖。

---

## 4. 两者的耦合：先发现，再查余额

```
getDeviceAssets()        后端：这个设备有哪些代币
        ↓ 存进本地库
取出 tokenIds
        ↓
getBalanceTokens(chain, address, tokenIds)     链上：每个多少钱
        ↓
合并后入库 → 驱动 UI
```

**`getBalanceTokens` 要你传 `tokenIds`，Rust 不知道用户持有什么。**

它只按你给的列表去查。这个列表只能来自后端索引。

---

## 5. 本地存储：全部由你负责

不管数据来自后端还是链上，**落地都在你的 SQLite**：

```
wallets / wallets_accounts      钱包与账户
assets / balances / prices      资产、余额、价格
transactions                    交易历史
```

Rust 不碰数据库（实测：非测试代码里它的文件 I/O 只有 keystore 一处）。

选 GRDB / Room 的关键原因是**响应式查询** —— 数据一变 UI 自动刷新。
详见[功能边界 §4](app端和core端的功能边界.md)。

---

## 6. 对排期的影响

按数据来源拆，双端各自要做的：

| 工作 | 和 core 有关吗 | 双端各写一遍吗 |
|---|---|---|
| 后端 API 对接（30+ 端点） | ❌ 无关 | ✅ 是 |
| 本地数据库与查询 | ❌ 无关 | ✅ 是 |
| `AlienProvider` 实现 | ✅ 必需 | ✅ 是 |
| 调 `GemGateway` 的 28 个方法 | ✅ 是 | ✅ 是（但逻辑在 core） |
| 链协议、签名、精度换算 | ✅ **core 包办** | ❌ **不用写** |

> 🔴 **别因为"有 Rust 核心库"就从工作量里扣掉后端对接和本地库。**
> 那两块占了 App 侧的大头，而且和 core 完全无关。

### 还有一条前置依赖

**后端索引服务必须先就绪。** 交易历史和代币发现没有替代方案 ——
不是"先用链上凑合、以后再优化"，是链上根本查不了。

---

*本文档由 AI 辅助整理，端点列表取自 gem 主 App 的实际实现，
方法归属逐个核对过 `core/gemstone/src/gateway/mod.rs`。*
