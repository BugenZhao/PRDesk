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
            infoPlist: .extendingDefault(with: [
                "CFBundleName": "PR Desk",
                "CFBundleDisplayName": "PR Desk",
                "LSApplicationCategoryType": "public.app-category.developer-tools",
            ]),
            sources: ["PRDesk/Sources/**"],
            dependencies: [
                .package(product: "GRDB"),
            ],
            settings: .settings(
                base: [
                    "SWIFT_VERSION": "6.0",
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
