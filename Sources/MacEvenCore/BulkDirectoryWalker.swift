import Foundation
import Darwin

/// 用 getattrlistbulk 深度优先前序遍历目录，语义对齐 NSDirectoryEnumerator（level 从 1 开始、skipDescendants）。
/// 每项只取名称、类型、Finder 标志、数据长度、链接数与文件标志；需要精确身份的项再由调用方 stat。
/// 不跟随符号链接；同时打开的目录 fd 有上限，超过后父目录改为一次读完并按路径操作子项。
final class BulkDirectoryWalker {
    struct Entry {
        let path: String
        let name: String
        let level: Int
        let type: UInt32
        let dataLength: Int64
        let linkCount: UInt32
        let flags: UInt32
        let hasBundleBit: Bool
        let errorCode: UInt32
        var isDirectory: Bool { type == UInt32(VDIR.rawValue) }
        var isRegular: Bool { type == UInt32(VREG.rawValue) }
    }

    struct Failure {
        let path: String
        let code: Int32
    }

    private final class Frame {
        var fd: Int32
        let path: String
        let level: Int
        var pending: [Entry] = []
        var index = 0
        var exhausted = false
        init(fd: Int32, path: String, level: Int) { self.fd = fd; self.path = path; self.level = level }
    }

    private static let bufferSize = 64 * 1024
    private static let maxOpenFrames = 24
    private var frames: [Frame] = []
    private var descend: Entry?
    private let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
    private var attributes: attrlist = {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ERROR) | attrgroup_t(ATTR_CMN_NAME) |
            attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_FNDRINFO) | attrgroup_t(ATTR_CMN_FLAGS)
        list.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_DATALENGTH)
        return list
    }()
    /// 打不开或读不完的目录，由调用方在每次 next() 后取走。
    private(set) var failures: [Failure] = []

    /// 根目录打不开时返回 nil，由调用方按入口错误处理。
    init?(root: String) {
        let fd = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        // 存储属性已全部初始化，返回 nil 后 deinit 仍会执行并释放缓冲区。
        guard fd >= 0 else { return nil }
        frames.append(Frame(fd: fd, path: root, level: 0))
    }

    deinit {
        for frame in frames where frame.fd >= 0 { close(frame.fd) }
        buffer.deallocate()
    }

    func takeFailures() -> [Failure] {
        defer { failures.removeAll() }
        return failures
    }

    /// 刚返回的目录不再展开。
    func skipDescendants() { descend = nil }

    func next() -> Entry? {
        if let directory = descend {
            descend = nil
            openChild(directory)
        }
        while let top = frames.last {
            if top.index < top.pending.count {
                let entry = top.pending[top.index]
                top.index += 1
                if top.index == top.pending.count { top.pending.removeAll(keepingCapacity: true); top.index = 0 }
                if entry.isDirectory { descend = entry }
                return entry
            }
            if top.exhausted || top.fd < 0 {
                if top.fd >= 0 { close(top.fd) }
                frames.removeLast()
                continue
            }
            refill(top)
        }
        return nil
    }

    /// 对刚由 next() 返回的项取 lstat 口径的状态（父目录仍在栈顶）。
    func status(of entry: Entry) -> stat? {
        var info = stat()
        let code: Int32
        if let parent = frames.last, parent.fd >= 0 {
            code = fstatat(parent.fd, entry.name, &info, AT_SYMLINK_NOFOLLOW)
        } else {
            code = lstat(entry.path, &info)
        }
        return code == 0 ? info : nil
    }

    /// APFS 克隆信息：数据块被其他文件共享时返回 true；文件系统不支持时返回 nil。
    func sharesBlocks(_ entry: Entry, allocated: Int64) -> Bool? {
        Self.sharesBlocks(path: entry.path, name: entry.name, fd: frames.last?.fd ?? -1, allocated: allocated)
    }

    static func sharesBlocks(path: String, name: String = "", fd: Int32 = -1, allocated: Int64) -> Bool? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        list.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) | attrgroup_t(ATTR_CMNEXT_CLONE_REFCNT)
        var raw = (UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0))
        return withUnsafeMutableBytes(of: &raw) { bytes -> Bool? in
            let options = UInt(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)
            let code: Int32
            if fd >= 0 {
                code = getattrlistat(fd, name, &list, bytes.baseAddress, bytes.count, options)
            } else {
                code = getattrlist(path, &list, bytes.baseAddress, bytes.count, UInt32(options))
            }
            guard code == 0, let base = bytes.baseAddress else { return nil }
            var cursor = base + 4
            let returned = cursor.loadUnaligned(as: attribute_set_t.self)
            cursor += MemoryLayout<attribute_set_t>.size
            var privateSize: Int64?, references: UInt32?
            if returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 {
                privateSize = cursor.loadUnaligned(as: Int64.self); cursor += 8
            }
            if returned.forkattr & attrgroup_t(ATTR_CMNEXT_CLONE_REFCNT) != 0 {
                references = cursor.loadUnaligned(as: UInt32.self)
            }
            if privateSize == nil && references == nil { return nil }
            return (references ?? 1) > 1 || (privateSize.map { $0 < allocated } ?? false)
        }
    }

    private func openChild(_ directory: Entry) {
        guard let parent = frames.last else { return }
        let fd: Int32
        if parent.fd >= 0 {
            fd = openat(parent.fd, directory.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        } else {
            fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        }
        guard fd >= 0 else { failures.append(Failure(path: directory.path, code: errno)); return }
        // 深层目录：父目录一次读完后关闭 fd，子项改用路径操作，限制同时打开的 fd 数。
        if frames.count >= Self.maxOpenFrames, parent.fd >= 0 {
            while !parent.exhausted { refill(parent) }
            close(parent.fd); parent.fd = -1
        }
        frames.append(Frame(fd: fd, path: directory.path, level: directory.level))
    }

    private func refill(_ frame: Frame) {
        let count = getattrlistbulk(frame.fd, &attributes, buffer, Self.bufferSize, 0)
        if count < 0 {
            failures.append(Failure(path: frame.path, code: errno))
            frame.exhausted = true
            return
        }
        if count == 0 { frame.exhausted = true; return }
        var record = buffer
        for _ in 0..<count {
            let length = Int(record.load(as: UInt32.self))
            if let entry = parse(record, parent: frame) { frame.pending.append(entry) }
            record += length
        }
    }

    private func parse(_ record: UnsafeMutableRawPointer, parent: Frame) -> Entry? {
        var cursor = record + 4
        let returned = cursor.loadUnaligned(as: attribute_set_t.self)
        cursor += MemoryLayout<attribute_set_t>.size
        let common = returned.commonattr, file = returned.fileattr
        // ATTR_CMN_ERROR 紧随返回掩码，其余按位序排列。
        var errorCode: UInt32 = 0
        if common & attrgroup_t(ATTR_CMN_ERROR) != 0 { errorCode = cursor.loadUnaligned(as: UInt32.self); cursor += 4 }
        guard common & attrgroup_t(ATTR_CMN_NAME) != 0 else { return nil }
        let reference = cursor.loadUnaligned(as: attrreference_t.self)
        let name = String(cString: (cursor + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
        cursor += MemoryLayout<attrreference_t>.size
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        var type: UInt32 = UInt32(VNON.rawValue)
        if common & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 { type = cursor.loadUnaligned(as: UInt32.self); cursor += 4 }
        var hasBundleBit = false
        if common & attrgroup_t(ATTR_CMN_FNDRINFO) != 0 {
            // FileInfo / FolderInfo 的 finderFlags 位于第 8 字节，大端；kHasBundle = 0x2000。
            let high = cursor.load(fromByteOffset: 8, as: UInt8.self)
            hasBundleBit = high & 0x20 != 0
            cursor += 32
        }
        var flags: UInt32 = 0
        if common & attrgroup_t(ATTR_CMN_FLAGS) != 0 { flags = cursor.loadUnaligned(as: UInt32.self); cursor += 4 }
        var linkCount: UInt32 = 1, dataLength: Int64 = 0
        if file & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 { linkCount = cursor.loadUnaligned(as: UInt32.self); cursor += 4 }
        if file & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 { dataLength = cursor.loadUnaligned(as: Int64.self) }
        let path = parent.path == "/" ? "/" + name : parent.path + "/" + name
        return Entry(path: path, name: name, level: parent.level + 1, type: type, dataLength: dataLength,
                     linkCount: linkCount, flags: flags, hasBundleBit: hasBundleBit, errorCode: errorCode)
    }
}
