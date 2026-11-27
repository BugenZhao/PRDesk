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
            sources: ["PRDesk/Sources/**", "Shared/Sources/**"],
            resources: ["Shared/Resources/AppIcon.icon", "Shared/Resources/Assets.xcassets", "Shared/Resources/Web/**"],
            dependencies: [
                .package(product: "GRDB"),
            ],
            settings: .settings(
                base: [
                    "SWIFT_VERSION": "6.0",
                    // Icon Composer icon (Shared/Resources/AppIcon.icon), compiled by actool.
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                    // No asset-catalog accent color; the app follows the system accent.
                    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "",
                    "MARKETING_VERSION": "0.1",
                    "CURRENT_PROJECT_VERSION": "1",
                    // The commit an install is built from (`AppVersion`), set by the install scripts.
                    "PRDESK_COMMIT": "",
                    // Local-only app: sign to run locally, no sandbox (needs to run `gh`).
                    "CODE_SIGN_IDENTITY": "-",
                    "CODE_SIGN_STYLE": "Manual",
                    "ENABLE_HARDENED_RUNTIME": "NO",
                ]
            )
        ),
        // The iPad (and iPhone) desk: GitHub (the board, notifications) is its only source of
        // truth, and it never runs the Mac's rules (subscriptions, approvals). See Shared/.
        .target(
            name: "PRDeskMobile",
            destinations: [.iPhone, .iPad],
            product: .app,
            bundleId: "com.bugenzhao.PRDesk.mobile",
            deploymentTargets: .iOS("27.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "PR Desk",
                "UILaunchScreen": [:],
                // Any orientation on both: the layout follows the window's size, whatever it is.
                "UISupportedInterfaceOrientations": [
                    "UIInterfaceOrientationPortrait",
                    "UIInterfaceOrientationLandscapeLeft",
                    "UIInterfaceOrientationLandscapeRight",
                ],
                "UISupportedInterfaceOrientations~ipad": [
                    "UIInterfaceOrientationPortrait",
                    "UIInterfaceOrientationPortraitUpsideDown",
                    "UIInterfaceOrientationLandscapeLeft",
                    "UIInterfaceOrientationLandscapeRight",
                ],
                // Sends to Grok Bots open its app with a draft.
                "LSApplicationQueriesSchemes": ["grokbot"],
                // Handoff of the item being looked at (`ItemHandoff`), as in the Mac's Info.plist.
                "NSUserActivityTypes": ["com.bugenzhao.PRDesk.item"],
                // `prdesk://open?url=` and a GitHub link, from the share sheet's action (`ExternalLinks`).
                "CFBundleURLTypes": [
                    ["CFBundleURLName": "com.bugenzhao.PRDesk.mobile", "CFBundleURLSchemes": ["prdesk"]],
                ],
                // CloudKit's silent pushes, for another device's hints (`CloudHints`).
                "UIBackgroundModes": ["remote-notification"],
                "PRDeskCommit": "$(PRDESK_COMMIT)",
            ]),
            sources: ["PRDeskMobile/Sources/**", "Shared/Sources/**"],
            resources: ["Shared/Resources/AppIcon.icon", "Shared/Resources/Assets.xcassets", "Shared/Resources/Web/**"],
            // iCloud and pushes for the hints between devices; signed by the device scripts,
            // left out of a simulator's unsigned build.
            entitlements: .file(path: "PRDeskMobile/PRDeskMobile.entitlements"),
            dependencies: [
                .package(product: "GRDB"),
                .target(name: "PRDeskMobileOpen"),
            ],
            settings: .settings(
                base: [
                    "SWIFT_VERSION": "6.0",
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "",
                    "MARKETING_VERSION": "0.1",
                    "CURRENT_PROJECT_VERSION": "1",
                    // The commit an install is built from (`AppVersion`), set by the install scripts.
                    "PRDESK_COMMIT": "",
                ]
            )
        ),
        // "Open in PR Desk" in the share sheet (Safari, the GitHub app): an action that hands a
        // GitHub link to the app by its URL scheme. It shares nothing else with the app.
        .target(
            name: "PRDeskMobileOpen",
            destinations: [.iPhone, .iPad],
            product: .appExtension,
            bundleId: "com.bugenzhao.PRDesk.mobile.open",
            deploymentTargets: .iOS("27.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "Open in PR Desk",
                "NSExtension": [
                    "NSExtensionPointIdentifier": "com.apple.ui-services",
                    "NSExtensionPrincipalClass": "$(PRODUCT_MODULE_NAME).OpenActionViewController",
                    "NSExtensionAttributes": [
                        "NSExtensionActionWantsFullScreenPresentation": false,
                        "NSExtensionServiceAllowsFinderPreviewItem": false,
                        // A single web page: Safari's, or a link the GitHub app shares.
                        "NSExtensionActivationRule": [
                            "NSExtensionActivationSupportsWebURLWithMaxCount": 1,
                        ],
                    ],
                ],
            ]),
            sources: ["PRDeskMobileOpen/Sources/**"],
            // iOS draws an action's icon from its alpha, as a template: a black glyph on clear.
            resources: ["PRDeskMobileOpen/Resources/Assets.xcassets"],
            settings: .settings(
                base: [
                    "SWIFT_VERSION": "6.0",
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                    "MARKETING_VERSION": "0.1",
                    "CURRENT_PROJECT_VERSION": "1",
                ]
            )
        ),
    ]
)
