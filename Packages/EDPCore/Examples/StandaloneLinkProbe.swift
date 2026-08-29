import EDPCore
import Foundation

let key = Array<UInt8>(repeating: 1, count: 16)
let cipher = try EDPSM4(key: key)
var data = Data(repeating: 0x5a, count: 1024 * 1024)
try cipher.encryptInPlace(&data)
try cipher.decryptInPlace(&data)
precondition(data.allSatisfy { $0 == 0x5a })
print("RESULT=EDP_CORE_STANDALONE_LINK_OK backend=\(EDPCrypto.sm4BackendName)")
