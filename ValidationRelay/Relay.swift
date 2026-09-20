import Foundation
import Network
import NWWebSocket
import SwiftUI
import UIKit

private func copyMobileGestaltString(_ key: String) -> String? {
    guard let answer = MGCopyAnswer(key as CFString) else {
        return nil
    }
    return answer.takeRetainedValue() as? String
}

func getIdentifiers() -> [String: String]? {
    var systemInfo = utsname()
    uname(&systemInfo)
    var machineInfo = systemInfo.machine
    let machineCapacity = MemoryLayout.size(ofValue: machineInfo)
    let machine = withUnsafePointer(to: &machineInfo) {
        $0.withMemoryRebound(to: CChar.self, capacity: machineCapacity) {
            String(cString: $0)
        }
    }

    guard let softwareBuildID = buildNumber(),
          let uniqueDeviceID = copyMobileGestaltString("UniqueDeviceID"),
          let serialNumber = copyMobileGestaltString("SerialNumber") else {
        return nil
    }

    return [
        "hardware_version": machine,
        "software_name": "iPhone OS",
        "software_version": UIDevice.current.systemVersion,
        "software_build_id": softwareBuildID,
        "unique_device_id": uniqueDeviceID,
        "serial_number": serialNumber
    ]
}

final class RelayConnectionManager: ObservableObject {
    private enum ConnectionState {
        case stopped
        case connecting
        case connected
        case waitingToReconnect
    }

    @Published private(set) var registrationCode = "None"
    @Published var connectionStatusMessage = ""
    @Published var logItems = LogItems()

    private let credentialStore: RelayCredentialStore
    private let connectionTimeout: TimeInterval = 30
    private let heartbeatInterval: TimeInterval = 30
    private let staleConnectionInterval: TimeInterval = 90

    private var connectionState: ConnectionState = .stopped
    private var currentURL: URL?
    private var connectionDelegate: RelayConnectionDelegate?
    private var reconnectWork: DispatchWorkItem?
    private var connectionTimeoutWork: DispatchWorkItem?
    private var watchdogTimer: DispatchSourceTimer?
    private var lastActivityAt: Date?
    private var connectionStartedAt: Date?
    private var shouldConnect = false
    private var reconnectPolicy = RelayReconnectPolicy()

    init(credentialStore: RelayCredentialStore = RelayCredentialStore()) {
        self.credentialStore = credentialStore
        if case .available(let credentials) = credentialStore.load() {
            registrationCode = credentials.code
        }
    }

    func connectIfNeeded(_ url: URL) {
        guard shouldConnect,
              currentURL == url,
              connectionDelegate != nil else {
            connect(url)
            return
        }

        switch connectionState {
        case .connecting, .connected, .waitingToReconnect:
            return
        case .stopped:
            connect(url)
        }
    }

    func connect(_ url: URL) {
        guard credentialStore.load() != .incomplete else {
            shouldConnect = false
            connectionStatusMessage = "Saved relay credentials are incomplete. Reset the registration code to create a new relay ID."
            logItems.log("Refusing to replace incomplete saved relay credentials", isError: true)
            return
        }

        shouldConnect = true
        currentURL = url
        reconnectPolicy.reset()
        cancelScheduledWork()
        stopWatchdog()
        retireActiveConnection()
        beginConnection(to: url)
    }

    func disconnect() {
        logItems.log("Disconnecting on request")
        shouldConnect = false
        currentURL = nil
        connectionState = .stopped
        connectionStatusMessage = ""
        cancelScheduledWork()
        stopWatchdog()
        retireActiveConnection()
    }

    func refreshOnForeground(_ url: URL) {
        guard shouldConnect, currentURL == url else {
            connect(url)
            return
        }

        if connectionState == .connected,
           let lastActivityAt,
           Date().timeIntervalSince(lastActivityAt) <= staleConnectionInterval {
            return
        }

        if connectionState == .connecting,
           let connectionStartedAt,
           Date().timeIntervalSince(connectionStartedAt) <= connectionTimeout {
            return
        }

        logItems.log("App became active; reconnecting immediately")
        reconnectPolicy.reset()
        cancelScheduledWork()
        stopWatchdog()
        retireActiveConnection()
        beginConnection(to: url)
    }

    func resetRegistration() {
        credentialStore.clear()
        registrationCode = "None"
        disconnect()
    }

    fileprivate func isActive(_ delegate: RelayConnectionDelegate) -> Bool {
        connectionDelegate === delegate
    }

    fileprivate func didConnect(_ delegate: RelayConnectionDelegate) -> Bool {
        guard isActive(delegate) else {
            return false
        }

        connectionState = .connected
        connectionStatusMessage = "Connected"
        connectionTimeoutWork?.cancel()
        connectionTimeoutWork = nil
        lastActivityAt = Date()
        startWatchdog()
        logItems.log("Websocket connected")
        return true
    }

    fileprivate func noteActivity(from delegate: RelayConnectionDelegate) {
        guard isActive(delegate) else {
            return
        }
        lastActivityAt = Date()
        reconnectPolicy.reset()
    }

    fileprivate func credentials(for url: URL) -> RelayCredentials? {
        guard case .available(let credentials) = credentialStore.load(),
              credentials.serverURL == url.absoluteString else {
            return nil
        }
        return credentials
    }

    fileprivate func saveCredentials(code: String, secret: String, from delegate: RelayConnectionDelegate) {
        guard isActive(delegate),
              Self.isValidCredentialValue(code, maximumLength: 128),
              Self.isValidCredentialValue(secret, maximumLength: 512) else {
            if isActive(delegate) {
                logItems.log("Rejected malformed registration credentials", isError: true)
            }
            return
        }

        let credentials = RelayCredentials(
            code: code,
            secret: secret,
            serverURL: delegate.url.absoluteString
        )
        let isNewCode = registrationCode != code
        credentialStore.save(credentials)
        registrationCode = code
        if isNewCode {
            logItems.log("Received new registration credentials")
        }
    }

    fileprivate func connectionFailed(_ delegate: RelayConnectionDelegate, message: String) {
        guard isActive(delegate) else {
            return
        }
        logItems.log(message, isError: true)
        scheduleReconnect(afterFailureFrom: delegate)
    }

    private func beginConnection(to url: URL) {
        guard shouldConnect, currentURL == url else {
            return
        }

        connectionState = .connecting
        connectionStatusMessage = "Connecting..."
        connectionStartedAt = Date()
        logItems.log("Connecting to \(Self.redactedEndpoint(url))")

        let delegate = RelayConnectionDelegate(manager: self, url: url)
        connectionDelegate = delegate
        scheduleConnectionTimeout(for: delegate)
        delegate.connect(heartbeatInterval: heartbeatInterval)
    }

    private func scheduleConnectionTimeout(for delegate: RelayConnectionDelegate) {
        connectionTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak delegate] in
            guard let self, let delegate, self.isActive(delegate), self.connectionState == .connecting else {
                return
            }
            self.connectionTimeoutWork = nil
            self.connectionFailed(delegate, message: "Websocket connection timed out")
        }
        connectionTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + connectionTimeout, execute: work)
    }

    private func scheduleReconnect(afterFailureFrom delegate: RelayConnectionDelegate) {
        guard isActive(delegate), shouldConnect, let url = currentURL else {
            return
        }

        cancelScheduledWork()
        stopWatchdog()
        retireActiveConnection()

        let delay = reconnectPolicy.consumeDelay()
        connectionState = .waitingToReconnect
        connectionStatusMessage = "Reconnecting..."
        logItems.log("Retrying websocket connection in \(Int(delay)) seconds")

        let work = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.reconnectWork = nil
            guard self.shouldConnect, self.currentURL == url else {
                return
            }
            self.beginConnection(to: url)
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startWatchdog() {
        stopWatchdog(clearLastActivity: false)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval)
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.connectionState == .connected,
                  let delegate = self.connectionDelegate,
                  let lastActivityAt = self.lastActivityAt,
                  Date().timeIntervalSince(lastActivityAt) > self.staleConnectionInterval else {
                return
            }
            self.connectionFailed(delegate, message: "Websocket heartbeat timed out")
        }
        watchdogTimer = timer
        timer.resume()
    }

    private func stopWatchdog(clearLastActivity: Bool = true) {
        watchdogTimer?.cancel()
        watchdogTimer = nil
        if clearLastActivity {
            lastActivityAt = nil
        }
    }

    private func cancelScheduledWork() {
        reconnectWork?.cancel()
        reconnectWork = nil
        connectionTimeoutWork?.cancel()
        connectionTimeoutWork = nil
    }

    private func retireActiveConnection() {
        let oldDelegate = connectionDelegate
        connectionDelegate = nil
        connectionStartedAt = nil
        oldDelegate?.disconnect()
    }

    private static func redactedEndpoint(_ url: URL) -> String {
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(url.scheme ?? "wss")://\(url.host ?? "relay")\(port)"
    }

    private static func isValidCredentialValue(_ value: String, maximumLength: Int) -> Bool {
        !value.isEmpty
            && value.count <= maximumLength
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}

final class RelayConnectionDelegate: WebSocketConnectionDelegate {
    let url: URL

    private var connection: WebSocketConnection
    private weak var manager: RelayConnectionManager?

    init(manager: RelayConnectionManager, url: URL) {
        self.manager = manager
        self.url = url
        connection = NWWebSocket(url: url, connectAutomatically: false, connectionQueue: .main)
        connection.delegate = self
    }

    func connect(heartbeatInterval: TimeInterval) {
        connection.connect()
        connection.ping(interval: heartbeatInterval)
    }

    func disconnect() {
        connection.delegate = nil
        connection.disconnect(closeCode: .protocolCode(.normalClosure))
    }

    func webSocketDidConnect(connection: WebSocketConnection) {
        guard let manager, manager.didConnect(self) else {
            disconnect()
            return
        }

        var registrationData: [String: String] = [:]
        if let credentials = manager.credentials(for: url) {
            manager.logItems.log("Using saved registration credentials")
            registrationData = ["code": credentials.code, "secret": credentials.secret]
        }
        sendJSON(["command": "register", "data": registrationData], over: connection)
    }

    func webSocketDidDisconnect(
        connection: WebSocketConnection,
        closeCode: NWProtocolWebSocket.CloseCode,
        reason: Data?
    ) {
        manager?.connectionFailed(self, message: "Websocket disconnected")
    }

    func webSocketViabilityDidChange(connection: WebSocketConnection, isViable: Bool) {
        guard !isViable, let manager, manager.isActive(self) else {
            return
        }
        manager.logItems.log("Websocket network path is temporarily unavailable")
    }

    func webSocketDidAttemptBetterPathMigration(result: Result<WebSocketConnection, NWError>) {
        guard let manager, manager.isActive(self) else {
            return
        }
        if case .failure = result {
            manager.logItems.log("Websocket network path migration failed", isError: true)
        }
    }

    func webSocketDidReceiveError(connection: WebSocketConnection, error: NWError) {
        manager?.connectionFailed(self, message: "Websocket error: \(error)")
    }

    func webSocketDidReceivePong(connection: WebSocketConnection) {
        manager?.noteActivity(from: self)
    }

    func webSocketDidReceiveMessage(connection: WebSocketConnection, string: String) {
        guard let manager, manager.isActive(self) else {
            return
        }
        manager.noteActivity(from: self)

        guard let encodedMessage = string.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: encodedMessage) as? [String: Any] else {
            manager.logItems.log("Received an invalid relay message", isError: true)
            return
        }

        if message["command"] as? String == "response",
           let data = message["data"] as? [String: Any],
           let code = data["code"] as? String,
           let secret = data["secret"] as? String {
            manager.saveCredentials(code: code, secret: secret, from: self)
        }

        guard let command = message["command"] as? String,
              command == "get-version-info" || command == "get-validation-data" else {
            return
        }
        guard let requestID = message["id"] else {
            manager.logItems.log("Received a relay request without an id", isError: true)
            return
        }

        if command == "get-version-info" {
            guard let identifiers = getIdentifiers() else {
                manager.logItems.log("Failed to read device identifiers", isError: true)
                return
            }
            manager.logItems.log("Sending device version information")
            sendJSON(
                ["command": "response", "data": ["versions": identifiers], "id": requestID],
                over: connection
            )
        } else {
            manager.logItems.log("Generating validation data")
            let validationData = generateValidationData()
            manager.logItems.log("Generated validation data")
            sendJSON(
                [
                    "command": "response",
                    "data": ["data": validationData.base64EncodedString()],
                    "id": requestID
                ],
                over: connection
            )
        }
    }

    func webSocketDidReceiveMessage(connection: WebSocketConnection, data: Data) {
        guard let manager, manager.isActive(self) else {
            return
        }
        manager.noteActivity(from: self)
        manager.logItems.log("Received an unexpected binary relay message", isError: true)
    }

    private func sendJSON(_ object: [String: Any], over connection: WebSocketConnection) {
        guard let manager, manager.isActive(self) else {
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            guard let message = String(data: data, encoding: .utf8) else {
                manager.logItems.log("Failed to encode relay response", isError: true)
                return
            }
            connection.send(string: message)
        } catch {
            manager.logItems.log("Failed to create relay response", isError: true)
        }
    }
}
