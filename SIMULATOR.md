# 模拟器选择与注意事项

跑 `GemIOSDemo`（以及任何依赖 `gemstone-swift` 的 iOS 工程）时，
模拟器怎么选、有哪些坑。

实测环境：macOS (Apple Silicon) · Xcode 26.5 · `gemstone-swift 2.114.10` · 2026-09-14

---

## 0. 三条硬约束

| 约束 | 值 | 违反的后果 |
|---|---|---|
| Mac 芯片 | **必须 Apple Silicon** | Intel Mac 链接期直接失败 |
| iOS 版本 | **≥ 17.0** | SPM 解析阶段就报错 |
| 设备类型 | iPhone / iPad 均可 | — |

---

## 1. 🔴 Intel Mac 跑不了模拟器

发布的 XCFramework **只有 arm64 切片**：

```bash
$ plutil -p GemstoneFFI.xcframework/Info.plist | grep -A1 SupportedArchitectures
  "SupportedArchitectures" => [ 0 => "arm64" ]      # ios-arm64（真机）
  "SupportedArchitectures" => [ 0 => "arm64" ]      # ios-arm64-simulator
```

```bash
$ lipo -info ios-arm64-simulator/libgemstone.a
Non-fat file: ... is architecture: arm64
```

**没有 `x86_64` 模拟器切片。** Intel Mac 的模拟器跑的是 x86_64，
链接时会报找不到符号（`undefined symbols for architecture x86_64`）。

### 原因在发布脚本

`scripts/release.sh` 只编两个 target：

```bash
GEMSTONE_IOS_TARGETS='aarch64-apple-ios aarch64-apple-ios-sim'
```

没有 `x86_64-apple-ios`。

### 如果团队里有 Intel Mac

三个选择：

| 方案 | 代价 |
|---|---|
| 换 Apple Silicon 机器 | 最干净 |
| 只用真机调试（真机都是 arm64） | 不能用模拟器 |
| 让 core 团队加 `x86_64-apple-ios` 切片 | 产物体积增加，发布耗时变长 |

> 📌 **开工前先统计一遍 iOS 团队的机器**。这事等到有人编不过才发现，代价高得多。

---

## 2. iOS 版本

`gemstone-swift` 声明的下限：

```swift
platforms: [ .iOS(.v17), .macOS(.v15) ]
```

低于 iOS 17 的模拟器，SPM 在**解析阶段**就会拒绝，连编都编不了。

### ⚠️ 一个当前未覆盖的验证缺口

本机只装了一个运行时：

```bash
$ xcrun simctl list runtimes
iOS 26.5 (26.5 - 23F77) - com.apple.CoreSimulator.SimRuntime.iOS-26-5
```

也就是说 **iOS 17 这个下限从未被实测验证过** —— 我们一直在 26.5 上跑。
理论上声明了就该支持，但没验证过的兼容性声明不能当结论。

真要覆盖，得单独下 iOS 17 运行时：

```bash
xcodebuild -downloadPlatform iOS -buildVersion 17.5
```

**代价不小**：每个运行时镜像约 8 GB。按需下，别默认全装。

---

## 3. 选哪个机型

本机可用的（`xcrun simctl list devices available`）：

```
iPhone 17            ← build.sh 默认
iPhone 17 Pro
iPhone 17 Pro Max
iPhone 17e
iPhone Air
iPad Pro 13-inch (M5)    iPad Pro 11-inch (M5)
iPad mini (A17 Pro)      iPad Air 13/11-inch (M4)
iPad (A16)
```

### 推荐

**日常开发用 `iPhone 17`**（`build.sh` 的默认值）。

理由很简单：gemstone 是纯逻辑库，**不涉及任何 UI 或设备特性**——
没有相机、没有传感器、不依赖屏幕尺寸。换机型对它没有任何影响。
选一个启动快、常驻不关的就行。

```bash
./build.sh                    # iPhone 17
./build.sh "iPhone 17 Pro"    # 换机型
./build.sh "iPad Air 11-inch (M4)"
```

### 什么时候才需要换机型

| 场景 | 换成 |
|---|---|
| 验证你自己的 UI 适配 | 各尺寸轮着来 |
| 验证 iPad 分栏布局 | 任一 iPad |
| **验证 gemstone 本身** | **不需要换，任选一个** |

---

## 4. 磁盘占用（实测）

```
/Library/Developer/CoreSimulator/Volumes         16 G    运行时镜像
~/Library/Developer/CoreSimulator/Devices       2.2 G    各模拟器的数据
单个运行时镜像                                    7.9 G
```

### 清理

```bash
# 删掉所有已卸载/不可用的模拟器
xcrun simctl delete unavailable

# 重置单个模拟器（清数据，保留设备）
xcrun simctl erase <UDID>

# 看谁在占空间
xcrun simctl list devices | grep -v "^==" 
du -sh ~/Library/Developer/CoreSimulator/Devices/*
```

> 💡 `Devices` 目录会随着反复装 App 持续膨胀。
> 本 Demo 的 `.app` 有 21 MB（含 Rust 静态库），装几十次就是 GB 级。
> `build.sh` 每次会先 `simctl uninstall` 再装，避免堆积。

---

## 5. 常用命令

```bash
# 列可用设备 / 运行时
xcrun simctl list devices available
xcrun simctl list runtimes

# 取某个机型的 UDID
xcrun simctl list devices available | grep "iPhone 17 (" | grep -oE "[0-9A-F-]{36}"

# 启动并等就绪（bootstatus 会阻塞到真正可用）
xcrun simctl boot <UDID>
xcrun simctl bootstatus <UDID> -b
open -a Simulator

# 装 / 启 / 卸
xcrun simctl install <UDID> path/to/App.app
xcrun simctl launch  <UDID> com.example.gemiosdemo
xcrun simctl uninstall <UDID> com.example.gemiosdemo

# 截图 / 录屏
xcrun simctl io <UDID> screenshot /tmp/s.png
xcrun simctl io <UDID> recordVideo /tmp/v.mov

# 看日志（相当于 Android 的 logcat）
xcrun simctl spawn <UDID> log stream --level debug \
  --predicate 'process == "GemIOSDemo"'

# 关掉
xcrun simctl shutdown <UDID>
xcrun simctl shutdown all
```

---

## 6. 与 Android 模拟器的差异

踩过的坑，避免按 Android 的习惯操作：

| | Android | iOS |
|---|---|---|
| 注入点击 | `adb shell input tap x y` | ❌ **没有等价命令** |
| 看日志 | `adb logcat` | `simctl spawn <UDID> log stream` |
| 装包 | `adb install` | `simctl install` |
| 等开机 | 轮询 `sys.boot_completed` | `simctl bootstatus -b`（会阻塞） |
| 架构选择 | AAR 含 3 个 ABI，自动选 | **只有 arm64，Intel Mac 不可用** |
| 网络 | 走宿主机，但 DNS 常出问题 | 直接用宿主机网络栈，基本不出问题 |

### 🔴 没有 `input tap` 的应对

iOS 模拟器无法命令行注入点击。本 Demo 的做法是**进页面自动触发一次**：

```swift
.task { fetch() }   // 按钮保留，可手动重跑
```

走的是同一条代码路径，不降低验证强度，但让无人值守的验证成为可能。

其他方案（`osascript` 点窗口、XCUITest）要么依赖辅助功能授权、
要么要建完整测试 target，对验证场景都太重。

### ⚠️ 模拟器的 `ping` 不可信（Android 侧的教训）

Android 模拟器的 `ping` 返回伪 ICMP（`0.000 rtt` + `duplicates`），
拿它判断网络会把排查方向带偏。iOS 模拟器直接用宿主机网络栈，没这个问题，
但**判断网络一律以真实 HTTP 请求为准**，别信 ping。

---

## 7. 检查清单

新同事上手前过一遍：

```
□ Mac 是 Apple Silicon？          → Intel 直接卡死，见 §1
□ Xcode 是完整版不是 CLT？        → xcrun --show-sdk-path --sdk iphonesimulator
□ 装了 iOS 运行时？                → xcrun simctl list runtimes
□ 磁盘余量 > 20 GB？              → 运行时 8 G + 数据 2 G 起
□ 知道 gemstone 不挑机型？         → 别浪费时间轮着试
```

一键自检：

```bash
[[ $(uname -m) == arm64 ]] && echo "✓ Apple Silicon" || echo "✗ Intel，跑不了模拟器"
xcrun --show-sdk-path --sdk iphonesimulator >/dev/null 2>&1 \
  && echo "✓ iOS Simulator SDK" || echo "✗ 缺 SDK"
xcrun simctl list runtimes | grep -q iOS \
  && echo "✓ 有 iOS 运行时" || echo "✗ 无运行时：xcodebuild -downloadPlatform iOS"
```

---

*本文档由 AI 辅助整理，所有命令输出、磁盘数字、架构信息均为 2026-09-14 实测。
§2 的「iOS 17 下限未被验证」是明确的覆盖缺口，不是推断。*
