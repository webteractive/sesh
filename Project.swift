import ProjectDescription

let project = Project(
    name: "sshconfig",
    packages: [
        .local(path: "."),
    ],
    targets: [
        .target(
            name: "Sesh",
            destinations: .macOS,
            product: .app,
            bundleId: "co.webteractive.sesh",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleName": "Sesh",
                "CFBundleDisplayName": "Sesh",
                "CFBundleShortVersionString": "0.9.0",
                "LSMultipleInstancesProhibited": true,
                "CFBundleIconName": "AppIcon",
                // Menu-bar-only app: no Dock icon, no window forced at launch.
                "LSUIElement": true,
            ]),
            sources: ["App/Sources/**"],
            resources: ["App/Resources/**"],
            dependencies: [
                .package(product: "SSHConfigCore"),
            ]
        ),
    ]
)
