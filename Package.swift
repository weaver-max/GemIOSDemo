// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Probe",
    platforms: [.iOS(.v17)],
    products: [.library(name: "Probe", targets: ["Probe"])],
    dependencies: [
        .package(url: "https://github.com/weaver-max/gemstone-swift.git", exact: "2.114.10")
    ],
    targets: [.target(name: "Probe", dependencies: [
        .product(name: "Gemstone", package: "gemstone-swift")])]
)
