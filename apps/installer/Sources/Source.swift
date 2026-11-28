import Foundation

/// The game's source: a git checkout of Wiicompiled-tv at a release tag, with the aurora-main
/// submodule. Both repositories are public, so nothing asks for an account. Blobs are fetched as
/// needed (a partial clone), which keeps the first download small.
enum Source {
    static let url = "https://github.com/\(Releases.repository).git"
    static let git = "/usr/bin/git"

    static func exists(_ workspace: Workspace) -> Bool {
        FileManager.default.fileExists(atPath: workspace.source.appendingPathComponent(".git").path)
    }

    /// Brings the checkout up to date with GitHub: cloned the first time (without checking anything
    /// out), then the tags fetched.
    static func fetchCommands(_ workspace: Workspace) -> [(label: String, arguments: [String])] {
        let folder = workspace.source.path
        var steps: [(String, [String])] = []
        if !exists(workspace) {
            steps.append(("Downloading the source",
                          ["clone", "--progress", "--filter=blob:none", "--no-checkout", url, folder]))
        }
        steps.append(("Looking for releases", ["-C", folder, "fetch", "--progress", "--force", "--tags", "--prune", "origin"]))
        return steps
    }

    /// Checks `tag` out (whatever was changed there goes; the ignored Assets/ and generated/ stay) and
    /// brings the submodule to the tag's commit.
    static func checkoutCommands(_ tag: String, _ workspace: Workspace) -> [(label: String, arguments: [String])] {
        let folder = workspace.source.path
        return [
            ("Switching to \(tag)", ["-C", folder, "-c", "advice.detachedHead=false", "checkout", "--force", "tags/\(tag)"]),
            ("Downloading the graphics library", ["-C", folder, "submodule", "sync", "--recursive"]),
            ("Downloading the graphics library", ["-C", folder, "submodule", "update", "--init", "--recursive", "--force",
                                                  "--progress", "--filter=blob:none"]),
        ]
    }

    /// git's progress lines ("Receiving objects:  45% (…)") as a fraction.
    static func progress(in line: String) -> Double? {
        guard line.contains("Receiving objects") || line.contains("Resolving deltas") || line.contains("Updating files"),
              let percent = line.range(of: #"(\d+)%"#, options: .regularExpression) else {
            return nil
        }
        return Double(line[percent].dropLast()).map { $0 / 100 }
    }
}

/// A build tool the installer downloads into the workspace's tools folder, so a player needs neither
/// Homebrew nor any other installer. Each is pinned to a version and checked against its published
/// checksum before it's unpacked.
struct Tool: Identifiable, Sendable {
    enum Packaging: Sendable {
        /// A single executable, saved as `executable` in `binFolder`.
        case binary
        case zip
        case tarball
    }

    enum Digest: Sendable {
        case sha256(String)
        case sha512(String)
    }

    let id: String
    let title: String
    let version: String
    let url: URL
    let digest: Digest
    let packaging: Packaging
    /// What it's unpacked into, inside the tools folder (the archive's own folder for CMake).
    let folder: String
    /// The folder holding its executable, inside the tools folder; it goes on the tools' PATH.
    let binFolder: String
    let executable: String
    let size: String
    let purpose: String

    func installed(_ workspace: Workspace) -> Bool {
        FileManager.default.isExecutableFile(atPath: workspace.tools.appendingPathComponent(binFolder + "/" + executable).path)
    }

    /// Kitware's universal build (cmake-4.5.1-SHA-256.txt).
    static let cmake = Tool(
        id: "cmake", title: "CMake", version: "4.5.1",
        url: URL(string: "https://github.com/Kitware/CMake/releases/download/v4.5.1/cmake-4.5.1-macos-universal.tar.gz")!,
        digest: .sha256("e1fb288543e4eb2a410e385ecebc64323bda51f0205782f2b094ccd5d572ca2d"), packaging: .tarball,
        folder: "", binFolder: "cmake-4.5.1-macos-universal/CMake.app/Contents/bin", executable: "cmake",
        size: "about 80 MB", purpose: "The build tool the game uses")

    /// The universal build the upstream project's packaging pins too (.github/workflows/package.yml).
    static let ninja = Tool(
        id: "ninja", title: "Ninja", version: "1.13.2",
        url: URL(string: "https://github.com/ninja-build/ninja/releases/download/v1.13.2/ninja-mac.zip")!,
        digest: .sha256("c99048673aa765960a99cf10c6ddb9f1fad506099ff0a0e137ad8960a88f321b"), packaging: .zip,
        folder: "ninja-1.13.2", binFolder: "ninja-1.13.2", executable: "ninja",
        size: "under 1 MB", purpose: "Runs the compiler for CMake")

    /// encounter/nod's disc tool, as package.yml pins it.
    static let nodtool = Tool(
        id: "nodtool", title: "nodtool", version: "2.0.0-alpha.10",
        url: URL(string: "https://github.com/encounter/nod/releases/download/v2.0.0-alpha.10/nodtool-macos-arm64")!,
        digest: .sha256("e23ca466999b720c55e6d29c9683fce8cc74451ba64ead2e543d50129f24528a"), packaging: .binary,
        folder: "nodtool-2.0.0-alpha.10", binFolder: "nodtool-2.0.0-alpha.10", executable: "nodtool",
        size: "about 5 MB", purpose: "Reads your disc image")

    /// yonaskolb/XcodeGen (GitHub's digest for the release asset).
    static let xcodegen = Tool(
        id: "xcodegen", title: "XcodeGen", version: "2.46.0",
        url: URL(string: "https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip")!,
        digest: .sha256("4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"), packaging: .zip,
        folder: "xcodegen-2.46.0", binFolder: "xcodegen-2.46.0/xcodegen/bin", executable: "xcodegen",
        size: "about 15 MB", purpose: "Asks Xcode for the Apple TV app's signing profile")

    /// Microsoft's .NET 8 SDK for Apple silicon (the SHA-512 from its releases.json). The translator
    /// targets .NET 8.
    static let dotnet = Tool(
        id: "dotnet", title: ".NET SDK", version: "8.0.427",
        url: URL(string: "https://builds.dotnet.microsoft.com/dotnet/Sdk/8.0.427/dotnet-sdk-8.0.427-osx-arm64.tar.gz")!,
        digest: .sha512("79786b93f249d233b15f1d6338d4798bd71c8143f267c5e84de76c9eb8a1054920e56ea5478f7bddfb74b951cc58aaca11fbd780cf134350b7cb7cdcb42a8c8c"),
        packaging: .tarball, folder: "dotnet-sdk-8.0.427", binFolder: "dotnet-sdk-8.0.427", executable: "dotnet",
        size: "about 220 MB", purpose: "Runs the translator that turns the game into C++")

    static let all: [Tool] = [cmake, ninja, nodtool, xcodegen, dotnet]
}

/// A paired device devicectl can install on.
struct Device: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let model: String
    let platform: Platform

    var title: String { model.isEmpty ? name : "\(name) (\(model))" }

    /// The paired, physical devices of `platform`.
    static func list(_ platform: Platform) async -> [Device] {
        let wanted = platform.devicePlatform
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wiicompiled-devices-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = await Shell.output("/usr/bin/xcrun", ["devicectl", "list", "devices", "--json-output", file.path])
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let entries = result["devices"] as? [[String: Any]] else {
            return []
        }
        return entries.compactMap { entry -> Device? in
            let hardware = entry["hardwareProperties"] as? [String: Any] ?? [:]
            let properties = entry["deviceProperties"] as? [String: Any] ?? [:]
            guard hardware["platform"] as? String == wanted,
                  (hardware["reality"] as? String ?? "physical") == "physical",
                  let id = entry["identifier"] as? String else {
                return nil
            }
            return Device(id: id, name: properties["name"] as? String ?? id,
                          model: hardware["marketingName"] as? String ?? "", platform: platform)
        }
        .sorted { $0.name < $1.name }
    }
}
