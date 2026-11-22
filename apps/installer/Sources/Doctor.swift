import Foundation

/// What the Setup screen checks before anything is built, and what each missing piece's button does.
struct DoctorItem: Identifiable, Sendable {
    enum Status: Sendable {
        case ok, missing, optional, checking
    }

    enum Action: Sendable, Hashable {
        case installXcode, openXcode, downloadTool(String), downloadPlatform(Platform), openAccounts
    }

    let id: String
    let title: String
    var status: Status
    var detail: String
    var action: Action?
    var actionTitle: String?
}

enum Doctor {
    static func check(_ workspace: Workspace) async -> [DoctorItem] {
        var items: [DoctorItem] = []

        // Xcode, selected and set up (its first launch installs the parts builds need).
        let selected = await Shell.output("/usr/bin/xcode-select", ["-p"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let xcodeVersion = await Shell.output("/usr/bin/xcodebuild", ["-version"])?
            .split(separator: "\n").first.map(String.init)
        let major = xcodeVersion.flatMap { $0.split(separator: " ").last }.flatMap { Int($0.split(separator: ".")[0]) } ?? 0
        if selected == nil || selected!.contains("CommandLineTools") || xcodeVersion == nil {
            items.append(DoctorItem(id: "xcode", title: "Xcode 27", status: .missing,
                                    detail: "Install Xcode from the App Store. It's free, and about 10 GB.",
                                    action: .installXcode, actionTitle: "Open the App Store"))
        } else if major < 27 {
            items.append(DoctorItem(id: "xcode", title: "Xcode 27", status: .missing,
                                    detail: "\(xcodeVersion!) is installed; the game needs Xcode 27 or later. Update it in the App Store.",
                                    action: .installXcode, actionTitle: "Open the App Store"))
        } else if await Shell.output("/usr/bin/xcodebuild", ["-checkFirstLaunchStatus"]) == nil {
            items.append(DoctorItem(id: "xcode", title: "Xcode 27", status: .missing,
                                    detail: "Open Xcode once and let it install its components (it asks for your password).",
                                    action: .openXcode, actionTitle: "Open Xcode"))
        } else {
            items.append(DoctorItem(id: "xcode", title: "Xcode 27", status: .ok, detail: xcodeVersion!))
        }
        let xcodeReady = items.last?.status == .ok

        // Apple TV support in Xcode.
        let sdks = xcodeReady ? await Shell.output("/usr/bin/xcodebuild", ["-showsdks", "-json"]) ?? "" : ""
        let platform = Platform.tvos
        let hasTV = sdks.contains("\"\(platform.sdk)")
        items.append(DoctorItem(id: "platform-tvos", title: "tvOS support in Xcode", status: hasTV ? .ok : .missing,
                                detail: hasTV ? "Installed" : "Xcode's Apple TV platform (a few GB).",
                                action: hasTV || !xcodeReady ? nil : .downloadPlatform(platform),
                                actionTitle: hasTV ? nil : "Install"))

        // Python 3 comes with Xcode; the build script runs on it.
        let python = await Shell.output("/usr/bin/python3", ["--version"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pythonMinor = python.flatMap { $0.split(separator: " ").last?.split(separator: ".").dropFirst().first }
            .flatMap { Int($0) } ?? 0
        items.append(DoctorItem(id: "python", title: "Python 3", status: python != nil && pythonMinor >= 9 ? .ok : .missing,
                                detail: python ?? "Comes with Xcode: install Xcode first."))

        // The build tools: the installer's own copies, or ones already on this Mac.
        let path = Shell.path(tools: workspace.tools)
        for tool in Tool.all {
            items.append(await check(tool, workspace: workspace, path: path))
        }

        // An Apple ID signed in to Xcode signs the app. A free one works for 7 days at a time.
        let teams = await xcodeTeams()
        let paid = teams.filter { !$0.free }
        let detail: String
        let status: DoctorItem.Status
        if let team = paid.first {
            detail = "\(team.name) (\(team.id)). Installs keep opening for a year."
            status = .ok
        } else if let team = teams.first {
            detail = "\(team.name) (\(team.id)), a free team: installs stop opening after 7 days, then press Reinstall. A paid Apple Developer membership lasts a year."
            status = .ok
        } else {
            detail = "Sign in to Xcode with your Apple ID (Xcode → Settings → Accounts). A free one works; its installs open for 7 days."
            status = .missing
        }
        items.append(DoctorItem(id: "account", title: "Apple ID in Xcode", status: status, detail: detail,
                                action: teams.isEmpty && xcodeReady ? .openAccounts : nil,
                                actionTitle: teams.isEmpty ? "Open Xcode Settings" : nil))
        return items
    }

    /// One build tool: fine when the installer's copy, or one on the PATH, answers its version.
    private static func check(_ tool: Tool, workspace: Workspace, path: String) async -> DoctorItem {
        let version = await Shell.output("/usr/bin/env", [tool.executable, "--version"], path: path)?
            .split(separator: "\n").first.map(String.init)
        if tool.installed(workspace) {
            return DoctorItem(id: tool.id, title: tool.title, status: .ok,
                              detail: "\(tool.title) \(tool.version), downloaded by the installer")
        }
        if let version, acceptable(tool, version) {
            return DoctorItem(id: tool.id, title: tool.title, status: .ok, detail: version)
        }
        return DoctorItem(id: tool.id, title: tool.title, status: .missing,
                          detail: "\(tool.purpose). The installer downloads it (\(tool.size)).",
                          action: .downloadTool(tool.id), actionTitle: "Download")
    }

    /// Whether a copy already on this Mac will do.
    private static func acceptable(_ tool: Tool, _ version: String) -> Bool {
        let numbers = version.split(whereSeparator: { !$0.isNumber && $0 != "." })
            .first { $0.contains(".") }.map { $0.split(separator: ".").compactMap { Int($0) } } ?? []
        switch tool.id {
        case "cmake": return numbers.count >= 2 && (numbers[0], numbers[1]) >= (3, 25)
        case "dotnet": return (numbers.first ?? 0) >= 8
        default: return true
        }
    }

    struct Team: Sendable {
        let id: String
        let name: String
        let free: Bool
    }

    /// The teams of the Apple IDs signed in to Xcode (as tools/tvos/port's xcode_teams reads them).
    static func xcodeTeams() async -> [Team] {
        guard let text = await Shell.output("/usr/bin/defaults", ["export", "com.apple.dt.Xcode", "-"]),
              let plist = try? PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [String: Any],
              let byAccount = plist["IDEProvisioningTeamByIdentifier"] as? [String: Any] else {
            return []
        }
        var teams: [Team] = []
        for case let account as [[String: Any]] in byAccount.values {
            for team in account {
                guard let id = team["teamID"] as? String, !teams.contains(where: { $0.id == id }) else {
                    continue
                }
                teams.append(Team(id: id, name: team["teamName"] as? String ?? "",
                                  free: (team["isFreeProvisioningTeam"] as? Bool) ?? false))
            }
        }
        return teams
    }
}
