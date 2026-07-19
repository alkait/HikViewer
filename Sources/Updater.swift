// Updater.swift — self-update against GitHub Releases.
//
// The check asks the GitHub API for the latest *tagged* release
// (/releases/latest already excludes the rolling dev-* pre-releases the CI
// publishes on every push) and compares its semver against the baked-in
// appVersion. Applying an update opens a Terminal window running the official
// curl|bash installer, then quits the app — a running .app can't replace
// itself; the installer swaps /Applications/HikViewer.app and relaunches.
// curl-downloaded files don't carry com.apple.quarantine, which is why the
// installer is the supported update path for an ad-hoc-signed app.

import AppKit

enum Updater {
    /// GitHub owner/name this app self-updates from. Must match REPO in
    /// build/install.sh and the asset URLs in .github/workflows/release.yml.
    static let repoSlug = "alkait/hikviewer"

    /// releases/latest always resolves to the newest tagged (non-pre-release)
    /// release, so this URL never goes stale.
    static let installerURL = "https://github.com/\(repoSlug)/releases/latest/download/install.sh"

    /// An untagged local build ("0.0.0-dev", possibly suffixed) has no real
    /// release to update to — keep quiet rather than nagging the developer.
    static var isDevBuild: Bool {
        let v = appVersion.trimmingCharacters(in: .whitespaces)
        return v.isEmpty || v.hasPrefix("0.0.0-dev") || v.hasPrefix("v0.0.0-dev")
    }

    /// Launch-time check: silent unless a newer release actually exists.
    /// Network or parse failures stay quiet too — this is an optional
    /// background check, not something worth an alert.
    static func checkInBackground() {
        guard !isDevBuild else { return }
        fetchLatestRelease { result in
            guard case .success(let release) = result,
                  semverLess(appVersion, release.tag) else { return }
            DispatchQueue.main.async { offerUpdate(release) }
        }
    }

    /// Menu-driven check: always reports an outcome.
    static func checkInteractive() {
        guard !isDevBuild else {
            showInfo("Development build",
                     "This is a local build (\(appVersion)) and doesn't track released updates. Pull and rebuild instead.")
            return
        }
        fetchLatestRelease { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    showInfo("Update check failed", error.localizedDescription)
                case .success(let release) where semverLess(appVersion, release.tag):
                    offerUpdate(release)
                case .success(let release):
                    showInfo("Up to date",
                             "HikViewer \(appVersion) is the latest release (\(release.tag)).")
                }
            }
        }
    }

    // MARK: - GitHub release lookup

    struct Release {
        let tag: String
        let notesURL: String
    }

    private static func fetchLatestRelease(_ completion: @escaping (Result<Release, Error>) -> Void) {
        let url = URL(string: "https://api.github.com/repos/\(repoSlug)/releases/latest")!
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                completion(.failure(NSError(domain: "Updater", code: code, userInfo: [
                    NSLocalizedDescriptionKey: "GitHub returned HTTP \(code)",
                ])))
                return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String, !tag.isEmpty else {
                completion(.failure(NSError(domain: "Updater", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "could not parse the latest release from GitHub",
                ])))
                return
            }
            completion(.success(Release(tag: tag, notesURL: obj["html_url"] as? String ?? "")))
        }.resume()
    }

    // MARK: - Update prompt + apply

    private static func offerUpdate(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "HikViewer \(release.tag) is available"
        alert.informativeText = "You're running \(appVersion). The update runs the installer in a Terminal window; HikViewer quits, is replaced in /Applications, and relaunches."
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Later")
        if !release.notesURL.isEmpty {
            alert.addButton(withTitle: "Release Notes")
        }
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            applyUpdate()
        case .alertThirdButtonReturn:
            if let url = URL(string: release.notesURL) { NSWorkspace.shared.open(url) }
        default:
            break
        }
    }

    /// Open a Terminal window running the curl|bash installer, then quit. The
    /// installer is run visibly because once we quit there is no UI left to
    /// show progress; it prints its own steps and relaunches the new build.
    private static func applyUpdate() {
        let shellCmd = "clear && echo 'Updating HikViewer — this window can be closed when the installer finishes.' && "
            + "/bin/bash -c \"$(curl -fsSL \(installerURL))\""
        let quoted = appleScriptQuote(shellCmd)

        // Cold-launch window-reuse dance: if Terminal isn't already running,
        // the `tell` block launches it and it opens an empty default-profile
        // window; reuse that window instead of leaving it orphaned beside a
        // second one.
        let script = """
        tell application "Terminal"
        set wasRunning to running
        activate
        if wasRunning then
        do script \(quoted)
        else
        repeat 20 times
        if (count of windows) > 0 then exit repeat
        delay 0.05
        end repeat
        if (count of windows) > 0 then
        do script \(quoted) in window 1
        else
        do script \(quoted)
        end if
        end if
        end tell
        """

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        do {
            try task.run()
        } catch {
            showInfo("Update failed", "Could not launch the installer: \(error.localizedDescription)")
            return
        }
        // The installer quits us anyway, but exiting now avoids racing it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    private static func appleScriptQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
               .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func showInfo(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Semver compare

    /// Whether `a` is strictly older than `b`, comparing only the
    /// MAJOR.MINOR.PATCH core. A leading "v" and -prerelease/+build suffixes
    /// are ignored: every published release is a clean vX.Y.Z tag, and a dev
    /// build like 0.0.0-dev.12+sha compares as its 0.0.0 core. Unparseable
    /// input compares as not-less (stay quiet).
    static func semverLess(_ a: String, _ b: String) -> Bool {
        guard let av = semverCore(a), let bv = semverCore(b) else { return false }
        if av.0 != bv.0 { return av.0 < bv.0 }
        if av.1 != bv.1 { return av.1 < bv.1 }
        return av.2 < bv.2
    }

    private static func semverCore(_ v: String) -> (Int, Int, Int)? {
        var s = v.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") { s.removeFirst() }
        if let cut = s.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            s = String(s[..<cut])
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let maj = Int(parts[0]), let min = Int(parts[1]), let pat = Int(parts[2]) else {
            return nil
        }
        return (maj, min, pat)
    }
}
