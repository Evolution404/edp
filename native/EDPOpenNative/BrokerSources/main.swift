import Foundation

let delegate = RawBrokerListenerDelegate()
let listener = NSXPCListener(machServiceName: RawBrokerConstants.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
