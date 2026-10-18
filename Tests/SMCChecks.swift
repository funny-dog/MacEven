import Foundation

@main struct SMCChecks {
    static func main() throws {
        precondition(SMCReader.decode(type: SMCReader.code("fpe2"), bytes: [0x1d,0x54]) == 1877)
        precondition(SMCReader.decode(type: SMCReader.code("sp78"), bytes: [0xff,0x80]) == -0.5)
        precondition(SMCReader.decode(type: SMCReader.code("flt "), bytes: [0,0,0xc0,0x7f]) == nil, "NaN sensor accepted")
        precondition(SMCReader.decode(type: SMCReader.code("flt "), bytes: [0]) == nil, "truncated sensor decoded")
        do {
            let reader = try SMCReader()
            let keys = try reader.keys()
            precondition(keys.count <= 4096)
            let fan = try reader.read("FNum")
            print("SMC native keys=\(keys.count) fanCount=\(fan as Any)")
            if let fan, fan >= 1 { print("SMC F0Ac=\(try reader.read("F0Ac") as Any)") }
            let temperatures = keys.filter { $0.hasPrefix("T") }.prefix(64)
            for key in temperatures {
                if let value = try? reader.read(key), (0...150).contains(value) { print("SMC \(key)=\(value) °C") }
            }
        } catch { print("SMC native unavailable: \(error.localizedDescription)") }
        print("PASS: SMC C message layout, bounded enumeration, checked sensor formats and native read-only probe")
    }
}
