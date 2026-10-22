import ProjectDescription

let project = Project(
    name: "PRDesk",
    packages: [
        .remote(url: "https://github.com/groue/GRDB.swift", requirement: .upToNextMajor(from: "7.11.1")),
    ],
    targets: [
        .target(
            name: "PRDesk",
            destinations: .macOS,
            product: .app,
            bundleId: "com.bugenzhao.PRDesk",
            deploymentTargets: .macOS("26.0"),
            // Not Tuist's default plist, which names a Main storyboard this app doesn't have.
            infoPlist: .file(path: "PRDesk/Info.plist"),
            sources: ["PRDesk/Sources/**"],
            resources: ["PRDesk/AppIcon.icon", "PRDesk/Assets.xcassets", "PRDesk/Web/**"],
            dependencies: [
                .package(product: "GRDB"),
            ],
            settings: .settings(
                base: [
                    "SWIFT_VERSION": "6.0",
                    // Icon Composer icon (PRDesk/AppIcon.icon), compiled by actool.
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                    // No asset-catalog accent color; the app follows the system accent.
                    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "",
                    "MARKETING_VERSION": "0.1",
                    "CURRENT_PROJECT_VERSION": "1",
                    // Local-only app: sign to run locally, no sandbox (needs to run `gh`).
                    "CODE_SIGN_IDENTITY": "-",
                    "CODE_SIGN_STYLE": "Manual",
                    "ENABLE_HARDENED_RUNTIME": "NO",
                ]
            )
        ),
    ]
)
