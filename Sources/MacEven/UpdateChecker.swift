import Foundation
import AppKit
import CryptoKit
import MacEvenCore

/// 更新包的校验和来源
public enum UpdateChecksum: Equatable, Sendable {
    /// Releases API 直接给出的 SHA-256：随检查更新的响应一起拿到，安装时无需再发请求
    case digest(String)
    /// 回退：发布里同名的 .sha256 文件（旧发布没有 digest 字段时使用）
    case file(URL)
}

public enum UpdateCheckStatus: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case updateAvailable(version: String, releaseURL: URL, downloadURL: URL?, checksum: UpdateChecksum?)
    case downloading(progress: Double)
    case installing
    case failed(String)

    /// 检查、下载或安装正在进行
    public var isInProgress: Bool {
        switch self {
        case .checking, .downloading, .installing:
            return true
        default:
            return false
        }
    }
}

public final class UpdateChecker: NSObject, ObservableObject, @unchecked Sendable {
    public static let shared = UpdateChecker()

    /// 状态变化后在主线程发出
    public static let statusDidChangeNotification = Notification.Name("local.maceven.updateStatusDidChange")

    @Published public private(set) var currentStatus: UpdateCheckStatus = .idle {
        didSet {
            guard currentStatus != oldValue else { return }
            // 统一在主线程发出通知
            if Thread.isMainThread {
                NotificationCenter.default.post(name: Self.statusDidChangeNotification, object: self)
            } else {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Self.statusDidChangeNotification, object: self)
                }
            }
        }
    }

    private var lastCheckedDate: Date?
    private var activeDownloadSession: URLSession?
    private var downloadDelegate: UpdateDownloadDelegate?

    private override init() {
        super.init()
    }

    /// 仓库信息，支持环境变量 MACEVEN_UPDATE_REPO（默认 'funny-dog/MacEven'）
    public var updateRepo: String {
        if let repo = ProcessInfo.processInfo.environment["MACEVEN_UPDATE_REPO"], !repo.isEmpty {
            return repo
        }
        return "funny-dog/MacEven"
    }

    private var repoOwner: String {
        let parts = updateRepo.split(separator: "/")
        return parts.count >= 2 ? String(parts[0]) : "funny-dog"
    }

    private var repoName: String {
        let parts = updateRepo.split(separator: "/")
        return parts.count >= 2 ? String(parts[1]) : "MacEven"
    }

    /// 当前本地版本号（例如 "0.28.0"）
    public var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.28.0"
    }

    /// 当前本地构建版本号（例如 "46"）
    public var currentBuildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "46"
    }

    /// 执行更新检查
    /// - Parameters:
    ///   - force: 是否强制刷新（默认若 10 分钟内检查过，则复用结果）
    ///   - completion: 检查完成后的主线程回调
    public func check(force: Bool = false, completion: @escaping @Sendable (UpdateCheckStatus) -> Void) {
        if currentStatus.isInProgress {
            completion(currentStatus)
            return
        }
        if !force, let last = lastCheckedDate, Date().timeIntervalSince(last) < 600, currentStatus != .idle {
            completion(currentStatus)
            return
        }

        currentStatus = .checking
        completion(.checking)

        guard let apiURL = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest") else {
            let status = UpdateCheckStatus.failed(localized("无效的请求地址"))
            self.currentStatus = status
            completion(status)
            return
        }

        var request = URLRequest(url: apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("MacEven-App", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    let status = UpdateCheckStatus.failed(error.localizedDescription)
                    self.currentStatus = status
                    completion(status)
                }
                return
            }

            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode != 200 {
                DispatchQueue.main.async {
                    let msg = httpResp.statusCode == 403 ? localized("GitHub 请求超限，请稍后再试") : localized("检查失败 (\(httpResp.statusCode))")
                    let status = UpdateCheckStatus.failed(msg)
                    self.currentStatus = status
                    completion(status)
                }
                return
            }

            guard let data = data else {
                DispatchQueue.main.async {
                    let status = UpdateCheckStatus.failed(localized("未接收到数据"))
                    self.currentStatus = status
                    completion(status)
                }
                return
            }

            do {
                let release = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
                let remoteTag = release.tagName

                let cleanRemote = self.stripVersionPrefix(remoteTag)
                let cleanCurrent = self.stripVersionPrefix(self.currentAppVersion)

                let isNewer: Bool
                if let comparison = SoftwareUpdates.compareVersions(cleanRemote, cleanCurrent) {
                    isNewer = (comparison == .orderedDescending)
                } else {
                    isNewer = (cleanRemote.compare(cleanCurrent, options: .numeric) == .orderedDescending)
                }

                let fallbackURL = URL(string: "https://github.com/\(self.repoOwner)/\(self.repoName)/releases/latest")!
                let releaseURL = URL(string: release.htmlUrl) ?? fallbackURL

                // 提取 .zip asset 和 SHA-256（通过 digest 或 .sha256 文件）
                var downloadURL: URL?
                var checksum: UpdateChecksum?
                if let assets = release.assets,
                   let zipAsset = assets.first(where: { $0.name.hasSuffix(".zip") }),
                   let zipURL = URL(string: zipAsset.browserDownloadUrl) {
                    if let hash = UpdateIntegrity.parseAssetDigest(zipAsset.digest) {
                        checksum = .digest(hash)
                    } else if let shaAsset = assets.first(where: { $0.name == zipAsset.name + ".sha256" }),
                              let shaURL = URL(string: shaAsset.browserDownloadUrl) {
                        checksum = .file(shaURL)
                    }
                    if checksum != nil {
                        downloadURL = zipURL
                    }
                }

                DispatchQueue.main.async {
                    let status: UpdateCheckStatus
                    if isNewer {
                        status = .updateAvailable(version: remoteTag, releaseURL: releaseURL, downloadURL: downloadURL, checksum: checksum)
                    } else {
                        status = .upToDate
                    }
                    self.currentStatus = status
                    self.lastCheckedDate = Date()
                    completion(status)
                }
            } catch {
                DispatchQueue.main.async {
                    let status = UpdateCheckStatus.failed(localized("解析版本信息失败"))
                    self.currentStatus = status
                    completion(status)
                }
            }
        }

        task.resume()
    }

    private func stripVersionPrefix(_ version: String) -> String {
        var trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }
        return trimmed
    }

    /// .sha256 文件的最大尝试次数
    private static let checksumFetchAttempts = 3

    /// 开始下载并自动安装更新
    public func startDownloadAndInstall(
        downloadURL: URL,
        checksum: UpdateChecksum?,
        statusHandler: @escaping @Sendable (UpdateCheckStatus) -> Void
    ) {
        let updateStatus = UpdateCheckStatus.downloading(progress: 0.0)
        self.currentStatus = updateStatus
        statusHandler(updateStatus)

        switch checksum {
        case .digest(let hash):
            downloadPackage(downloadURL: downloadURL, expectedHash: hash, statusHandler: statusHandler)
        case .file(let sha256URL):
            fetchChecksum(from: sha256URL, attempt: 1) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let hash):
                    self.downloadPackage(downloadURL: downloadURL, expectedHash: hash, statusHandler: statusHandler)
                case .failure(let error):
                    self.fail(error.localizedDescription, statusHandler: statusHandler)
                }
            }
        case nil:
            NSLog(localized("[UpdateChecker] 拒绝安装：发布中缺少校验和"))
            fail(localized("更新包缺少校验和文件，已取消自动安装，请前往发布页手动下载"), statusHandler: statusHandler)
        }
    }

    /// 拉取并解析 .sha256 文件，失败时换新连接重试；回调在主线程
    private func fetchChecksum(from url: URL, attempt: Int, completion: @escaping @Sendable (Result<String, Error>) -> Void) {
        var shaReq = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        shaReq.setValue("MacEven-App", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: shaReq) { [weak self] data, response, error in
            let result: Result<String, Error>
            if let error = error {
                result = .failure(UpdateError(localized("校验和下载失败: \(error.localizedDescription)")))
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure(UpdateError(localized("校验和下载失败 (HTTP \(http.statusCode))")))
            } else if let data = data,
                      let text = String(data: data, encoding: .utf8),
                      let hash = UpdateIntegrity.parseChecksum(text) {
                result = .success(hash)
            } else {
                result = .failure(UpdateError(localized("无法解析校验和文件")))
            }

            DispatchQueue.main.async {
                guard let self = self else { return }
                if case .failure(let failure) = result, attempt < Self.checksumFetchAttempts {
                    NSLog(localized("[UpdateChecker] 校验和第 %d 次获取失败，稍后重试：%@"), attempt, failure.localizedDescription)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        self.fetchChecksum(from: url, attempt: attempt + 1, completion: completion)
                    }
                    return
                }
                completion(result)
            }
        }.resume()
    }

    private func downloadPackage(downloadURL: URL, expectedHash: String, statusHandler: @escaping @Sendable (UpdateCheckStatus) -> Void) {
        let delegate = UpdateDownloadDelegate(
            onProgress: { [weak self] progress in
                guard let self = self else { return }
                let status = UpdateCheckStatus.downloading(progress: progress)
                self.currentStatus = status
                statusHandler(status)
            },
            onFinish: { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let zipLocation):
                    self.verifyAndInstall(zipLocation: zipLocation, expectedHash: expectedHash, statusHandler: statusHandler)
                case .failure(let error):
                    self.fail(localized("下载失败: \(error.localizedDescription)"), statusHandler: statusHandler)
                }
            }
        )

        self.downloadDelegate = delegate
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: OperationQueue.main)
        self.activeDownloadSession = session

        var request = URLRequest(url: downloadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("MacEven-App", forHTTPHeaderField: "User-Agent")
        let downloadTask = session.downloadTask(with: request)
        downloadTask.resume()
    }

    private func verifyAndInstall(zipLocation: URL, expectedHash: String, statusHandler: @escaping @Sendable (UpdateCheckStatus) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let zipData = try Data(contentsOf: zipLocation)
                let actualHash = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
                guard actualHash.lowercased() == expectedHash.lowercased() else {
                    DispatchQueue.main.async {
                        self.fail(localized("更新包校验失败: SHA256 不匹配"), statusHandler: statusHandler)
                    }
                    return
                }
            } catch {
                DispatchQueue.main.async {
                    self.fail(localized("计算更新包哈希失败: \(error.localizedDescription)"), statusHandler: statusHandler)
                }
                return
            }

            self.proceedToInstall(zipLocation: zipLocation, statusHandler: statusHandler)
        }
    }

    /// 在主线程调用：记录并上报失败状态
    private func fail(_ message: String, statusHandler: @escaping @Sendable (UpdateCheckStatus) -> Void) {
        let failed = UpdateCheckStatus.failed(message)
        currentStatus = failed
        statusHandler(failed)
    }

    private func proceedToInstall(zipLocation: URL, statusHandler: @escaping @Sendable (UpdateCheckStatus) -> Void) {
        let status = UpdateCheckStatus.installing
        self.currentStatus = status
        DispatchQueue.main.async {
            statusHandler(status)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.performInstallAndRelaunch(zipURL: zipLocation) { installError in
                if let installError = installError {
                    DispatchQueue.main.async {
                        let failedStatus = UpdateCheckStatus.failed(localized("安装失败: \(installError.localizedDescription)"))
                        self.currentStatus = failedStatus
                        statusHandler(failedStatus)
                    }
                }
            }
        }
    }

    /// 解压、覆盖替换当前应用并重新拉起新版
    private func performInstallAndRelaunch(zipURL: URL, completion: @escaping @Sendable (Error?) -> Void) {
        let fileManager = FileManager.default
        let baseDir = zipURL.deletingLastPathComponent()
        let extractDir = baseDir.appendingPathComponent("extracted")

        do {
            try fileManager.createDirectory(at: extractDir, withIntermediateDirectories: true)

            // 1. 解压 ZIP
            let unzipProc = Process()
            unzipProc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzipProc.arguments = ["-q", "-o", zipURL.path, "-d", extractDir.path]
            try unzipProc.run()
            unzipProc.waitUntilExit()

            guard unzipProc.terminationStatus == 0 else {
                throw NSError(domain: "UpdateChecker", code: 1, userInfo: [NSLocalizedDescriptionKey: localized("解压更新包失败")])
            }

            // 2. 找到解压后的 MacEven.app
            let newAppURL = extractDir.appendingPathComponent("MacEven.app")
            guard fileManager.fileExists(atPath: newAppURL.path) else {
                throw NSError(domain: "UpdateChecker", code: 2, userInfo: [NSLocalizedDescriptionKey: localized("未在更新包中找到有效的 MacEven.app")])
            }

            // 2.5 验签：如果当前版本有 leaf 证书，则验证新版 MacEven.app 必须由相同证书签发且 bundle id 一致；签名不一致则拒绝安装
            if let leaf = CodeSignatureCheck.leafCertificateSHA1(ofCodeAt: Bundle.main.bundleURL) {
                let bundleId = Bundle.main.bundleIdentifier ?? "local.maceven.app"
                let required = UpdateIntegrity.signingRequirements(bundleIdentifier: bundleId, leafCertificateSHA1: leaf)
                guard CodeSignatureCheck.codeAt(newAppURL, satisfies: required) else {
                    throw NSError(domain: "UpdateChecker", code: 4, userInfo: [NSLocalizedDescriptionKey: localized("更新包的签名与当前版本不一致，已拒绝安装")])
                }
            } else {
                NSLog(localized("[UpdateChecker] 当前版本为 ad-hoc 签名，无证书可比对，仅依赖 SHA-256 校验"))
            }

            // 3. 确定目标路径：优先当前运行路径；若非 /Applications 且 /Applications/MacEven.app 存在，则覆盖 /Applications/MacEven.app
            var targetAppURL = Bundle.main.bundleURL
            if !targetAppURL.path.hasPrefix("/Applications") && fileManager.fileExists(atPath: "/Applications/MacEven.app") {
                targetAppURL = URL(fileURLWithPath: "/Applications/MacEven.app")
            }

            // 检查目标路径及其父目录的写权限
            let targetDir = targetAppURL.deletingLastPathComponent()
            let isTargetWritable = fileManager.isWritableFile(atPath: targetAppURL.path)
            let isParentWritable = fileManager.isWritableFile(atPath: targetDir.path)
            if (fileManager.fileExists(atPath: targetAppURL.path) && !isTargetWritable) || !isParentWritable {
                let errMsg = localized("无权限写入 \(targetAppURL.path)，请手动下载安装")
                DispatchQueue.main.async {
                    if let releaseURL = URL(string: "https://github.com/\(self.repoOwner)/\(self.repoName)/releases/latest") {
                        NSWorkspace.shared.open(releaseURL)
                    }
                }
                throw NSError(domain: "UpdateChecker", code: 3, userInfo: [NSLocalizedDescriptionKey: errMsg])
            }

            // 4. 清除解压产物的隔离属性（Quarantine）
            let xattrProc = Process()
            xattrProc.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattrProc.arguments = ["-dr", "com.apple.quarantine", newAppURL.path]
            try? xattrProc.run()
            xattrProc.waitUntilExit()

            // 5. 编写后台替换与重启脚本
            let pid = ProcessInfo.processInfo.processIdentifier
            let scriptContent = """
            #!/bin/bash
            # 等待原进程退出
            while /bin/kill -0 \(pid) 2>/dev/null; do
                /bin/sleep 0.2
            done

            TARGET="\(targetAppURL.path)"
            TARGET_DIR="$(dirname "$TARGET")"
            NEW_APP="$TARGET_DIR/MacEven.new.app"
            OLD_APP="$TARGET_DIR/MacEven.old.app"
            ERROR_LOG="$HOME/Library/Application Support/MacEven/last-update-error.txt"

            /bin/mkdir -p "$(dirname "$ERROR_LOG")"

            # 清理历史可能残留的临时文件
            /bin/rm -rf "$NEW_APP" "$OLD_APP"

            # 1. 先复制到同目录临时位置
            if ! /bin/cp -R "\(newAppURL.path)" "$NEW_APP"; then
                echo "\(localized("复制新版本到临时目录失败"))" > "$ERROR_LOG"
                /bin/rm -rf "$NEW_APP"
                /usr/bin/open "$TARGET" 2>/dev/null || true
                exit 1
            fi

            # 2. 成功后 mv 旧 App 到备份位置
            if ! /bin/mv "$TARGET" "$OLD_APP"; then
                echo "\(localized("备份旧版本失败"))" > "$ERROR_LOG"
                /bin/rm -rf "$NEW_APP"
                /usr/bin/open "$TARGET" 2>/dev/null || true
                exit 1
            fi

            # 3. mv 新的到位
            if ! /bin/mv "$NEW_APP" "$TARGET"; then
                echo "\(localized("移动新版本到目标目录失败，已回滚旧版本"))" > "$ERROR_LOG"
                /bin/mv "$OLD_APP" "$TARGET"
                /bin/rm -rf "$NEW_APP"
                /usr/bin/open "$TARGET" 2>/dev/null || true
                exit 1
            fi

            # 4. 成功后清理 .old 备份
            /bin/rm -rf "$OLD_APP"

            # 确保清除隔离属性并刷新注册
            /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
            /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET" 2>/dev/null || true

            # 重新打开新版
            /usr/bin/open "$TARGET"

            # 清理下载解压临时文件
            /bin/rm -rf "\(baseDir.path)"
            """

            let scriptURL = baseDir.appendingPathComponent("relaunch.sh")
            try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

            // 6. 运行独立脚本
            let relaunchProc = Process()
            relaunchProc.executableURL = URL(fileURLWithPath: "/bin/bash")
            relaunchProc.arguments = [scriptURL.path]
            try relaunchProc.run()

            // 7. 退出当前进程以交接
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        } catch {
            completion(error)
        }
    }

    /// 如果存在 last-update-error.txt，读取并清理，返回可选错误信息
    @discardableResult
    public static func checkLastUpdateError() -> String? {
        let fileManager = FileManager.default
        let home = NSHomeDirectory()
        let errorFileURL = URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/MacEven/last-update-error.txt")

        guard fileManager.fileExists(atPath: errorFileURL.path),
              let content = try? String(contentsOf: errorFileURL, encoding: .utf8) else {
            return nil
        }

        try? fileManager.removeItem(at: errorFileURL)
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 实例快捷方法
    @discardableResult
    public func checkLastUpdateError() -> String? {
        Self.checkLastUpdateError()
    }
}

// MARK: - 下载进度与回调代理

private final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private let onFinish: @Sendable (Result<URL, Error>) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void, onFinish: @escaping @Sendable (Result<URL, Error>) -> Void) {
        self.onProgress = onProgress
        self.onFinish = onFinish
        super.init()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            DispatchQueue.main.async {
                self.onProgress(min(max(progress, 0.0), 1.0))
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = tempDir.appendingPathComponent("update.zip")
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: destination)
            DispatchQueue.main.async {
                self.onFinish(.success(destination))
            }
        } catch {
            DispatchQueue.main.async {
                self.onFinish(.failure(error))
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            DispatchQueue.main.async {
                self.onFinish(.failure(error))
            }
        }
    }
}

// MARK: - 数据模型与错误类型

private struct GitHubReleaseResponse: Decodable {
    let tagName: String
    let htmlUrl: String
    let assets: [GitHubReleaseAsset]?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlUrl = "html_url"
        case assets
    }
}

private struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadUrl: String
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
        case digest
    }
}

private struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
