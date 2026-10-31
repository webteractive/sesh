import ProjectDescription

let project = Project(
    name: "sshconfig",
    packages: [
        .local(path: "."),
        .remote(url: "https://github.com/apple/swift-argument-parser", requirement: .exact("1.8.2")),
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
                "CFBundleShortVersionString": "0.1.5",
                // The commit a release is built from (scripts/package.sh sets
                // it); `sesh --version` prints it beside the version.
                "SeshCommit": "$(SESH_COMMIT)",
                "LSMultipleInstancesProhibited": true,
                "CFBundleIconName": "AppIcon",
                // Menu-bar-only app: no Dock icon, no window forced at launch.
                "LSUIElement": true,
            ]),
            sources: ["App/Sources/**"],
            resources: ["App/Resources/**"],
            scripts: [
                // The CLI rides inside the app, in Contents/Helpers (Contents/MacOS
                // would clash with Sesh on a case-insensitive disk).
                .post(
                    script: """
                    mkdir -p "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
                    cp -f "$BUILT_PRODUCTS_DIR/sesh" "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/sesh"
                    """,
                    name: "Embed sesh CLI",
                    inputPaths: ["$(BUILT_PRODUCTS_DIR)/sesh"],
                    outputPaths: ["$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers/sesh"]
                ),
            ],
            dependencies: [
                .package(product: "SSHConfigCore"),
                .target(name: "SeshCLI"),
            ]
        ),
        .target(
            name: "SeshCLI",
            destinations: .macOS,
            product: .commandLineTool,
            productName: "sesh",
            bundleId: "co.webteractive.sesh.cli",
            deploymentTargets: .macOS("15.0"),
            sources: ["CLI/Sources/**"],
            dependencies: [
                .package(product: "SSHConfigCore"),
                .package(product: "ArgumentParser"),
            ]
        ),
    ]
)
