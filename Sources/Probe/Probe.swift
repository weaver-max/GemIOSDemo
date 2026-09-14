// SPM 要求 Package.swift 里声明的 target 必须有源文件，否则 `swift package resolve` 会失败。
// 本项目真正的代码是根目录那些 .swift（由 build.sh 用 swiftc 手工编译），
// 这个 Package.swift 只承担一件事：把 gemstone-swift 拉下来并校验 checksum。
// 所以这里放一个空壳即可。
import Gemstone
