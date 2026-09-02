import Foundation
for v in [0, 1, 2, 3488, -1] {
    let n = NSNumber(value: v)
    let asBool = n as? Bool
    let asInt = n as? Int
    print("NSNumber(\(v)):  as? Bool = \(asBool.map(String.init) ?? "nil")   as? Int = \(asInt.map(String.init) ?? "nil")   objCType = \(String(cString: n.objCType))")
}
let d: [String: Any] = ["zero": NSNumber(value: 0), "one": NSNumber(value: 1), "many": NSNumber(value: 3488)]
for k in ["zero", "one", "many"] {
    print("dict[\(k)] as? Bool = \((d[k] as? Bool).map(String.init) ?? "nil")")
}
