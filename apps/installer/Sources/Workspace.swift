import Foundation

/// Where the installer keeps everything, in one folder: ~/Library/Application Support/WiiCompiled
/// Installer. Not inside the app: writing there breaks its signature, a quarantined copy runs read-only,
/// and replacing the app (a new download) would lose it all.
struct Workspace: Sendable {
    let root: URL

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WiiCompiled Installer", isDirectory: true)
    }

    /// The git checkout of the release being built, with its submodule. tools/tvos/port keeps the
    /// extracted disc and the translation in it (Assets/ and generated/, which git ignores, so they
    /// stay across updates).
    var source: URL { root.appendingPathComponent("source", isDirectory: true) }
    /// tools/tvos/port's --work-dir: the builds, kept across updates.
    var work: URL { root.appendingPathComponent("work", isDirectory: true) }
    var tools: URL { root.appendingPathComponent("tools", isDirectory: true) }
    var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    var stateFile: URL { root.appendingPathComponent("state.json") }
    var releasesCache: URL { root.appendingPathComponent("cache/releases.json") }
    var port: URL { source.appendingPathComponent("tools/tvos/port") }
    /// What Free Up Space removes: tools/tvos/port's compiled game (build-tvos) and the signed app made
    /// from it (package), which the next install makes again. The source, the extracted and translated
    /// disc (the slow part) and the tools stay.
    var rebuildable: [URL] {
        [work.appendingPathComponent("build-tvos", isDirectory: true), work.appendingPathComponent("package", isDirectory: true)]
    }

    /// Bytes on disk, everything in the folder.
    func size() -> Int64 {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                                                         options: [], errorHandler: { _, _ in true }) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    func load() -> InstallerState {
        guard let data = try? Data(contentsOf: stateFile),
              let state = try? JSONDecoder.installer.decode(InstallerState.self, from: data) else {
            return InstallerState()
        }
        return state
    }

    func save(_ state: InstallerState) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? JSONEncoder.installer.encode(state) {
            try? data.write(to: stateFile, options: .atomic)
        }
    }
}

/// What the game installs on. WiiCompiled is an Apple TV port, so there is one platform; the enum
/// keeps state.json and tools/tvos/port's --platform in the same shape as the other ports' installers.
enum Platform: String, Codable, CaseIterable, Identifiable, Sendable {
    case tvos

    var id: String { rawValue }
    var title: String { "Apple TV" }
    var symbol: String { "appletv" }
    /// devicectl's name for the platform.
    var devicePlatform: String { "tvOS" }
    /// xcodebuild's SDK.
    var sdk: String { "appletvos" }
    /// The name xcodebuild -downloadPlatform takes.
    var downloadName: String { "tvOS" }
}

/// An Apple TV the game is installed on.
struct Install: Codable, Identifiable, Hashable, Sendable {
    var platform: Platform = .tvos
    /// devicectl's identifier.
    var deviceId: String?
    var deviceName: String
    var version: String?
    var commit: String?
    var installedAt: Date?
    /// When the device's development profile stops the app opening.
    var expires: Date?
    /// The last update didn't reach it (it was off, or away): try again.
    var pending: Bool = false

    var id: String { platform.rawValue + ":" + (deviceId ?? "") }
}

/// What the installer remembers (state.json).
struct InstallerState: Codable, Sendable {
    /// The disc image.
    var disc: String = ""
    /// The release tag the source is at, once fetched.
    var tag: String?
    /// The team that signs the app; nil lets tools/tvos/port choose (a paid team first).
    var team: String?
    var installs: [Install] = []

    mutating func record(_ install: Install) {
        if let index = installs.firstIndex(where: { $0.id == install.id }) {
            installs[index] = install
        } else {
            installs.append(install)
        }
    }
}

extension JSONEncoder {
    static var installer: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var installer: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
