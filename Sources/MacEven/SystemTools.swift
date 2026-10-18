import AppKit
import MacEvenCore
import AVFoundation
import Combine
import Foundation
import Darwin
import IOKit.pwr_mgt

private struct MountedVolumeIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let uuid: String?
    init?(url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        device = info.st_dev; inode = info.st_ino
        uuid = (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
    }
}

@MainActor
public final class SystemTools: ObservableObject {
    public static let allowedMinutes: Set<Int> = [15, 30, 60]

    @Published public private(set) var error: String? = nil
    @Published public private(set) var awakeUntil: Date? = nil
    @Published public private(set) var cameraInUse: Bool? = nil
    @Published public private(set) var microphoneInUse: Bool? = nil
    @Published public private(set) var volumes: [URL] = []
    @Published public private(set) var volumeBusy: Bool = false

    private var volumeIdentities: [URL: MountedVolumeIdentity] = [:]
    private var volumeRefresh: Task<Void, Never>?
    private var stopped = false
    private var assertionID: IOPMAssertionID = 0
    private var awakeTimer: Timer?

    public init() {}

    deinit {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
        }
    }

    public func start() {
        stopped = false
        refreshPrivacy()
        refreshVolumes()
    }

    public func keepAwake(minutes: Int) {
        guard Self.allowedMinutes.contains(minutes) else {
            error = localized("无效常亮时长：\(minutes) 分钟，仅支持 15/30/60 分钟")
            return
        }
        stopAwake()
        guard assertionID == 0 else { return }
        var id: IOPMAssertionID = 0
        let reason = "MacEven 状态常亮" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &id
        )
        if result == kIOReturnSuccess {
            assertionID = id
            error = nil
            awakeUntil = Date().addingTimeInterval(Double(minutes * 60))
            awakeTimer = Timer.scheduledTimer(withTimeInterval: Double(minutes * 60), repeats: false) { [weak self] _ in
                Task { @MainActor in self?.stopAwake() }
            }
        } else {
            error = localized("无法创建常亮断言：\(result)")
        }
    }

    public func stopAwake() {
        awakeTimer?.invalidate(); awakeTimer = nil
        if assertionID != 0 {
            let result = IOPMAssertionRelease(assertionID)
            if result != kIOReturnSuccess {
                // Only forget a failed release when a successful system query proves it vanished.
                var raw: Unmanaged<CFDictionary>?
                let status = IOPMCopyAssertionsByProcess(&raw)
                var absent = false
                if status == kIOReturnSuccess, let all = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] {
                    let own = all[NSNumber(value: getpid())] ?? []
                    absent = !own.contains { $0[kIOPMAssertionNameKey as String] as? String == "MacEven 状态常亮" }
                }
                guard absent else { error = localized("释放常亮断言失败：\(result)，状态未知，请重试取消。"); return }
                error = localized("常亮断言已失效，已清除本地状态。")
            }
            assertionID = 0
        }
        awakeUntil = nil
    }

    public func refreshVolumes() {
        guard !stopped, volumeRefresh == nil else { return }
        volumeRefresh = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { Self.readVolumes() }.value
            guard let self else { return }
            self.volumeRefresh = nil
            guard !self.stopped else { return }
            self.volumes = result.map(\.key).sorted { $0.path < $1.path }
            self.volumeIdentities = result
        }
    }

    nonisolated private static func readVolumes() -> [URL: MountedVolumeIdentity] {
        let keys: Set<URLResourceKey> = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey]
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        let volumes = Array(mounted.filter { url in
            guard url.path != "/" else { return false }
            guard let vals = try? url.resourceValues(forKeys: keys) else { return false }
            return (vals.volumeIsRemovable ?? false) || (vals.volumeIsEjectable ?? false) || !(vals.volumeIsInternal ?? true)
        }.prefix(128))
        return Dictionary(volumes.compactMap { url in MountedVolumeIdentity(url: url).map { (url, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    public func eject(url: URL) async {
        guard !volumeBusy else { return }
        guard let expected = volumeIdentities[url], volumes.contains(url), url.path != "/", !stopped else { error = localized("卷已变化或不允许弹出，请刷新列表。"); return }
        volumeBusy = true
        defer { volumeBusy = false; refreshVolumes() }
        do {
            try await Task.detached(priority: .utility) {
                guard Self.readVolumes()[url] == expected, MountedVolumeIdentity(url: url) == expected else { throw NSError(domain: "MacEven.Volume", code: 1, userInfo: [NSLocalizedDescriptionKey: localized("挂载卷身份已变化，已取消弹出。")]) }
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            }.value
            error = nil
        } catch { self.error = localized("弹出 \(url.lastPathComponent) 失败：\(error.localizedDescription)") }
    }

    public func refreshPrivacy() {
        let videoSession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        cameraInUse = videoSession.devices.isEmpty ? nil : videoSession.devices.contains(where: { $0.isInUseByAnotherApplication })

        let audioSession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        microphoneInUse = audioSession.devices.isEmpty ? nil : audioSession.devices.contains(where: { $0.isInUseByAnotherApplication })
    }

    public func prepareForSleep() {
        stopAwake()
    }

    public func shutdown() {
        stopped = true
        stopAwake()
    }
}
