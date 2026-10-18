import Foundation
import IOKit

// AppleSMC's C message is 80 bytes. Swift structs may reuse nested tail padding.
final class SMCReader {
    private var connection: io_connect_t = 0
    private var keyInfo: [String: Data] = [:]
    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw NSError(domain: "AppleSMC", code: -1, userInfo: [NSLocalizedDescriptionKey: localized("未发现 AppleSMC 服务。")] ) }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == kIOReturnSuccess else { throw failure(result) }
    }
    deinit { if connection != 0 { IOServiceClose(connection) } }
    private func failure(_ code: Int32) -> NSError {
        NSError(domain: "AppleSMC", code: Int(code), userInfo: [NSLocalizedDescriptionKey: localized("AppleSMC 读取失败（\(code)）。")])
    }
    static func code(_ key: String) -> UInt32 { key.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) } }
    private func call(_ input: Data) throws -> Data {
        var output = Data(count: 80); var size = 80
        let status = input.withUnsafeBytes { a in
            output.withUnsafeMutableBytes { b in IOConnectCallStructMethod(connection, 2, a.baseAddress, 80, b.baseAddress, &size) }
        }
        guard status == kIOReturnSuccess else { throw failure(status) }
        guard size == 80, output[40] == 0 else { throw failure(Int32(output[40])) }
        return output
    }
    func keys() throws -> [String] {
        guard let count = try read("#KEY"), count > 0, count <= 4096 else { throw failure(-2) }
        var result: [String] = []
        for index in 0..<Int(count) {
            var input = Data(count: 80); input[42] = 8
            input.withUnsafeMutableBytes { $0.storeBytes(of: UInt32(index), toByteOffset: 44, as: UInt32.self) }
            let value = try call(input).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            result.append(String(bytes: [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)], encoding: .ascii) ?? "")
        }
        return result
    }
    func read(_ key: String) throws -> Double? {
        guard key.utf8.count == 4 else { return nil }
        var input = Data(count: 80)
        input.withUnsafeMutableBytes { $0.storeBytes(of: Self.code(key), as: UInt32.self) }
        let info: Data
        if let cached = keyInfo[key] { info = cached }
        else {
            input[42] = 9; info = try call(input)
            if keyInfo.count < 4096 { keyInfo[key] = info }
        }
        let size = info.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 28, as: UInt32.self) }
        let type = info.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 32, as: UInt32.self) }
        guard size > 0, size <= 32 else { return nil }
        input.replaceSubrange(28..<40, with: info[28..<40]); input[42] = 5
        let output = try call(input)
        return Self.decode(type: type, bytes: Array(output[48..<48 + Int(size)]))
    }
    static func decode(type: UInt32, bytes: [UInt8]) -> Double? {
        let value: Double
        switch type {
        case code("ui8 ") where bytes.count == 1: value = Double(bytes[0])
        case code("ui16") where bytes.count == 2: value = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case code("ui32") where bytes.count == 4: value = Double(bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        case code("fpe2") where bytes.count == 2: value = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case code("sp78") where bytes.count == 2: value = Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case code("flt ") where bytes.count == 4: value = Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        default: return nil
        }
        return value.isFinite ? value : nil
    }
}
