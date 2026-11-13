import Foundation

// Used on the main thread. Each sample is bounded and runs off the UI thread.
final class GuardianStatusObserver {
    private let queue = DispatchQueue(label: "local.wakecup.guardian.status")
    private var identity: ProcessIdentity?
    private var bootID: String?
    private var lastResponse: TimeInterval?
    private var nextProbe = 0.0
    private var probing = false

    func isResponding(_ status: SessionStatus, at now: TimeInterval) -> Bool {
        guard let current = status.helperIdentity, current.pid == status.helperPID,
              processExists(current.pid), let sessionBoot = status.bootID else { return false }
        if let actual = processIdentity(current.pid), actual != current { return false }
        if identity != current || bootID != sessionBoot {
            guard sessionBoot == (try? systemBootID()) else { return false }
            identity = current
            bootID = sessionBoot
            lastResponse = nil
            nextProbe = 0
        }
        if !probing && now >= nextProbe {
            probing = true
            nextProbe = now + 4
            queue.async {
                let reply = GuardianStatusSocket.probe(pid: current.pid)
                let receivedAt = continuousNow()
                DispatchQueue.main.async {
                    self.probing = false
                    if reply == .responsive && self.identity == current && self.bootID == sessionBoot {
                        self.lastResponse = receivedAt
                    }
                }
            }
        }
        return status.hasRecentActivity(at: now, lastSocketResponse: lastResponse)
    }
}
