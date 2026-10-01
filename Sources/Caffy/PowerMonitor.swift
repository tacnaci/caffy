import Foundation
import IOKit.ps

struct BatteryInfo {
    let percent: Int
    let onACPower: Bool
}

enum PowerMonitor {
    /// 当前电池信息；台式机等无电池设备返回 nil。
    static func battery() -> BatteryInfo? {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let onAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return BatteryInfo(percent: current * 100 / max, onACPower: onAC)
        }
        return nil
    }

    static var isOverheated: Bool {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: true
        default: false
        }
    }
}
