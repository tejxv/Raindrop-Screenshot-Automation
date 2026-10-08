import Foundation
#if os(macOS)
import IOKit.ps
#endif

public enum PowerSourceHelper {
    /// Determines whether the device is currently running on external AC power.
    /// Returns `true` if connected to a charger, or if the device does not have a battery (e.g. Mac Studio, Mac mini, Mac Pro, iMac).
    public static func isOnACPower() -> Bool {
        #if os(macOS)
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return true }
        guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return true }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let powerSourceState = desc[kIOPSPowerSourceStateKey as String] as? String {
                if powerSourceState == (kIOPSACPowerValue as String) {
                    return true
                }
            }
        }
        return sources.isEmpty
        #else
        return true
        #endif
    }
}
