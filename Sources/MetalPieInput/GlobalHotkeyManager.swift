import Carbon
import Foundation
import MetalPieCore
import os

/// Private memory-safe bridge passed as `userData` to Carbon's `InstallEventHandler`.
private final class CarbonHotkeyBridge: @unchecked Sendable {
    private let callbackLock = OSAllocatedUnfairLock<(@Sendable (UInt32) -> Void)?>(initialState: nil)

    init(callback: @escaping @Sendable (UInt32) -> Void) {
        callbackLock.withLock { $0 = callback }
    }

    func invalidate() {
        callbackLock.withLock { $0 = nil }
    }

    func handleHotKeyID(_ id: UInt32) {
        let cb = callbackLock.withLock { $0 }
        cb?(id)
    }
}

/// Global keyboard shortcut manager powered by Carbon `RegisterEventHotKey` + `InstallEventHandler`.
///
/// Key properties:
/// - Works globally across all apps and native Full-Screen Spaces **WITHOUT Accessibility permission**.
/// - Registers all 4 customizable Magpie hotkeys (`toggleFullscreen`, `toggleWindowed`, `toggleToolbar`,
///   `captureScreenshot`) from `HotkeyConfig`.
/// - **Always registers the reserved, non-overridable Panic Stop chord `⌃⌥⌘⎋` (`HotkeyBinding.panicStop`)**,
///   which immediately restores cursor visibility and triggers emergency session teardown with zero debounce.
/// - Clean re-registration on config edits and guaranteed complete unregistration on `unregisterAll()` / `deinit`.
public final class GlobalHotkeyManager: HotkeyManaging, @unchecked Sendable {
    /// Four-character Carbon hotkey signature `'MPIE'` (`0x4D504945`).
    public static let hotKeySignature: OSType = 0x4D50_4945

    private struct RegistrationState {
        var eventHandlerRef: EventHandlerRef?
        var bridge: CarbonHotkeyBridge?
        var hotKeyRefs: [HotkeyAction: EventHotKeyRef] = [:]
        var activeBindings: [HotkeyAction: HotkeyBinding] = [:]
        var failedRegistrations: [HotkeyAction: OSStatus] = [:]
        var handler: (@Sendable (HotkeyAction) -> Void)?
        var lastTriggerUptime: [HotkeyAction: TimeInterval] = [:]
    }

    public let debounceIntervalSeconds: TimeInterval
    private let state = OSAllocatedUnfairLock(uncheckedState: RegistrationState())

    public init(debounceIntervalSeconds: TimeInterval = 0.1) {
        self.debounceIntervalSeconds = max(0.0, debounceIntervalSeconds)
    }

    deinit {
        unregisterAll()
    }

    // MARK: - Inspection

    /// Currently active Carbon-registered shortcuts by action.
    public var activeBindings: [HotkeyAction: HotkeyBinding] {
        state.withLockUnchecked { $0.activeBindings }
    }

    /// Any shortcuts that failed to register (e.g. OSStatus conflict with another app) during the last `register` call.
    public var failedRegistrations: [HotkeyAction: OSStatus] {
        state.withLockUnchecked { $0.failedRegistrations }
    }

    /// True if at least one global hotkey (including `panicStop`) is currently registered.
    public var isRegistered: Bool {
        state.withLockUnchecked { !$0.hotKeyRefs.isEmpty }
    }

    // MARK: - HotkeyManaging

    /// Registers all enabled hotkeys from `config` plus the always-active reserved `HotkeyBinding.panicStop` (`⌃⌥⌘⎋`).
    ///
    /// Cleanly unregisters any prior bindings first so config edits re-register without leaks or duplicates.
    /// If one or more customizable bindings conflict with another app or with the reserved panic chord,
    /// all valid bindings (including `panicStop`) remain active and `EngineError.hotkeyRegistrationFailed` is thrown
    /// for the first conflict so the UI can alert the user.
    public func register(
        config: HotkeyConfig,
        handler: @escaping @Sendable (HotkeyAction) -> Void
    ) throws {
        // Clear any previous registrations cleanly before re-registering.
        unregisterHotKeysOnly()

        try ensureEventHandlerInstalled()

        state.withLockUnchecked { s in
            s.handler = handler
            s.failedRegistrations.removeAll()
            s.lastTriggerUptime.removeAll()
        }

        var firstError: EngineError?

        // 1. ALWAYS register the reserved Panic Stop chord (`⌃⌥⌘⎋`) first.
        let panicBinding = HotkeyBinding.panicStop
        let panicStatus = registerSingleHotKey(action: .panicStop, binding: panicBinding)
        if panicStatus != noErr {
            PipelineLog.shared.error(
                .input,
                "Failed to register reserved panic stop hotkey \(panicBinding.displayString) (OSStatus \(panicStatus))."
            )
            firstError = .hotkeyRegistrationFailed(.panicStop, panicStatus)
        } else {
            PipelineLog.shared.info(
                .input,
                "Registered reserved panic stop hotkey \(panicBinding.displayString)."
            )
        }

        // 2. Register all 4 customizable Magpie hotkeys.
        let customizableActions: [HotkeyAction] = [
            .toggleFullscreen,
            .toggleWindowed,
            .toggleToolbar,
            .captureScreenshot
        ]

        var seenChords: Set<ChordKey> = [
            ChordKey(keyCode: panicBinding.keyCode, modifiers: panicBinding.modifiers)
        ]

        for action in customizableActions {
            let binding = config.binding(for: action)
            guard binding.isEnabled else { continue }

            let chord = ChordKey(keyCode: binding.keyCode, modifiers: binding.modifiers)
            if seenChords.contains(chord) {
                let conflictStatus = OSStatus(eventHotKeyExistsErr)
                state.withLockUnchecked { $0.failedRegistrations[action] = conflictStatus }
                PipelineLog.shared.warning(
                    .input,
                    "Skipped conflicting hotkey '\(action.rawValue)' (\(binding.displayString)) — duplicates reserved or already-bound chord."
                )
                if firstError == nil {
                    firstError = .hotkeyRegistrationFailed(action, conflictStatus)
                }
                continue
            }

            let status = registerSingleHotKey(action: action, binding: binding)
            if status == noErr {
                seenChords.insert(chord)
                PipelineLog.shared.info(
                    .input,
                    "Registered global hotkey '\(action.rawValue)' -> \(binding.displayString)."
                )
            } else {
                PipelineLog.shared.warning(
                    .input,
                    "Failed to register global hotkey '\(action.rawValue)' (\(binding.displayString), OSStatus \(status))."
                )
                if firstError == nil {
                    firstError = .hotkeyRegistrationFailed(action, status)
                }
            }
        }

        if let firstError {
            throw firstError
        }
    }

    /// Unregisters all Carbon hotkeys and removes the Carbon application event handler cleanly.
    public func unregisterAll() {
        let teardown = state.withLockUnchecked { s -> ([EventHotKeyRef], EventHandlerRef?, CarbonHotkeyBridge?) in
            let refs = Array(s.hotKeyRefs.values)
            let handlerRef = s.eventHandlerRef
            let bridge = s.bridge
            s.hotKeyRefs.removeAll()
            s.activeBindings.removeAll()
            s.failedRegistrations.removeAll()
            s.lastTriggerUptime.removeAll()
            s.handler = nil
            s.eventHandlerRef = nil
            s.bridge = nil
            return (refs, handlerRef, bridge)
        }

        for ref in teardown.0 {
            UnregisterEventHotKey(ref)
        }

        teardown.2?.invalidate()
        if let handlerRef = teardown.1 {
            RemoveEventHandler(handlerRef)
        }

        if !teardown.0.isEmpty || teardown.1 != nil {
            PipelineLog.shared.info(.input, "Unregistered all Carbon global hotkeys.")
        }
    }

    // MARK: - Internal Carbon Plumbing

    private struct ChordKey: Hashable {
        let keyCode: UInt32
        let modifiers: HotkeyModifiers
    }

    private func unregisterHotKeysOnly() {
        let refs = state.withLockUnchecked { s -> [EventHotKeyRef] in
            let current = Array(s.hotKeyRefs.values)
            s.hotKeyRefs.removeAll()
            s.activeBindings.removeAll()
            s.failedRegistrations.removeAll()
            return current
        }

        for ref in refs {
            UnregisterEventHotKey(ref)
        }
    }

    private func ensureEventHandlerInstalled() throws {
        let alreadyInstalled = state.withLockUnchecked { $0.eventHandlerRef != nil }
        guard !alreadyInstalled else { return }

        let bridge = CarbonHotkeyBridge { [weak self] rawID in
            self?.dispatchHotKeyPressed(rawID: rawID)
        }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, eventRef, userData in
            guard let eventRef, let userData else {
                return OSStatus(eventNotHandledErr)
            }

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            guard status == noErr, hotKeyID.signature == GlobalHotkeyManager.hotKeySignature else {
                return OSStatus(eventNotHandledErr)
            }

            let bridgeRef = Unmanaged<CarbonHotkeyBridge>.fromOpaque(userData).takeUnretainedValue()
            bridgeRef.handleHotKeyID(hotKeyID.id)
            return noErr
        }

        var handlerRef: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventSpec,
            Unmanaged.passUnretained(bridge).toOpaque(),
            &handlerRef
        )

        guard installStatus == noErr, let installedRef = handlerRef else {
            bridge.invalidate()
            PipelineLog.shared.error(.input, "InstallEventHandler failed with OSStatus \(installStatus).")
            throw EngineError.hotkeyRegistrationFailed(.panicStop, installStatus)
        }

        state.withLockUnchecked { s in
            s.eventHandlerRef = installedRef
            s.bridge = bridge
        }
    }

    private func registerSingleHotKey(action: HotkeyAction, binding: HotkeyBinding) -> OSStatus {
        let hotKeyID = EventHotKeyID(
            signature: Self.hotKeySignature,
            id: Self.numericID(for: action)
        )

        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.modifiers.carbonModifierFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr, let ref = hotKeyRef {
            state.withLockUnchecked { s in
                s.hotKeyRefs[action] = ref
                s.activeBindings[action] = binding
            }
        } else {
            state.withLockUnchecked { s in
                s.failedRegistrations[action] = status
            }
        }
        return status
    }

    private func dispatchHotKeyPressed(rawID: UInt32) {
        guard let action = Self.action(for: rawID) else { return }

        if action == .panicStop {
            // Panic stop NEVER debounces and IMMEDIATELY guarantees system cursor visibility.
            RunGuardWatchdog.forceRestoreSystemCursor()
            PipelineLog.shared.warning(.input, "Panic stop hotkey (⌃⌥⌘⎋) triggered!")
            let handler = state.withLockUnchecked { $0.handler }
            handler?(.panicStop)
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let handler: (@Sendable (HotkeyAction) -> Void)? = state.withLockUnchecked { s in
            if debounceIntervalSeconds > 0,
               let previous = s.lastTriggerUptime[action],
               (now - previous) < debounceIntervalSeconds
            {
                return nil
            }
            s.lastTriggerUptime[action] = now
            return s.handler
        }

        guard let handler else { return }
        PipelineLog.shared.debug(.input, "Global hotkey triggered: '\(action.rawValue)'.")
        handler(action)
    }

    /// Maps each `HotkeyAction` to a stable non-zero Carbon `EventHotKeyID.id`.
    public static func numericID(for action: HotkeyAction) -> UInt32 {
        switch action {
        case .toggleFullscreen: return 1
        case .toggleWindowed: return 2
        case .toggleToolbar: return 3
        case .captureScreenshot: return 4
        case .panicStop: return 5
        }
    }

    /// Reverse-maps a Carbon `EventHotKeyID.id` back to a `HotkeyAction`.
    public static func action(for numericID: UInt32) -> HotkeyAction? {
        switch numericID {
        case 1: return .toggleFullscreen
        case 2: return .toggleWindowed
        case 3: return .toggleToolbar
        case 4: return .captureScreenshot
        case 5: return .panicStop
        default: return nil
        }
    }
}
