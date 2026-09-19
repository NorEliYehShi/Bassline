import CoreAudio
import Foundation

enum CoreAudioError: Error, LocalizedError {
    case osStatus(OSStatus, String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .osStatus(let code, let context): return "\(context): OSStatus \(code)"
        case .notFound(let message): return message
        }
    }

    /// True when the failure looks like a denied System Audio Recording grant.
    ///
    /// Note: on several macOS versions the tap is created successfully even
    /// without the grant and simply never delivers audio, so this check alone
    /// is not enough. `ProcessTap` also runs a delivery watchdog.
    var isPermissionFailure: Bool {
        guard case .osStatus(let code, _) = self else { return false }
        return code == kAudioHardwareIllegalOperationError
            || code == kAudio_UnimplementedError
            || code == kAudioHardwareBadObjectError
    }

    var shortDescription: String {
        switch self {
        case .osStatus(let code, let context): return "\(context) (\(code))"
        case .notFound(let message): return message
        }
    }
}

func caCheck(_ status: OSStatus, _ context: String) throws {
    guard status == noErr else {
        throw CoreAudioError.osStatus(status, context)
    }
}

func getAudioProperty<T>(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) throws -> T {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    var size = UInt32(MemoryLayout<T>.size)
    let storage = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size),
        alignment: MemoryLayout<T>.alignment
    )
    defer { storage.deallocate() }
    try caCheck(
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, storage),
        "getAudioProperty \(selector)"
    )
    return storage.load(as: T.self)
}

func getAudioPropertyString(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) throws -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(MemoryLayout<CFString>.size)
    let pointer = UnsafeMutablePointer<Unmanaged<CFString>?>.allocate(capacity: 1)
    pointer.initialize(to: nil)
    defer {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }
    try caCheck(
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer),
        "getAudioPropertyString \(selector)"
    )
    guard let unmanaged = pointer.pointee else {
        throw CoreAudioError.notFound("No string value for selector \(selector)")
    }
    return unmanaged.takeUnretainedValue() as String
}

func getDefaultOutputDeviceID() throws -> AudioObjectID {
    try getAudioProperty(
        objectID: AudioObjectID(kAudioObjectSystemObject),
        selector: kAudioHardwarePropertyDefaultOutputDevice
    )
}

func getDefaultOutputDeviceUID() throws -> String {
    try getAudioPropertyString(
        objectID: try getDefaultOutputDeviceID(),
        selector: kAudioDevicePropertyDeviceUID
    )
}

/// Wraps a registered property listener so it is always removed with the exact
/// address and block it was added with.
///
/// Listener blocks are delivered on a dedicated serial queue, never the main
/// queue. `AudioObjectRemovePropertyListenerBlock` can block until pending
/// blocks on the target queue have run, so removing a main-queue listener from
/// the main thread (which is what quitting does) risks a deadlock.
final class AudioPropertyListener {
    private static let queue = DispatchQueue(
        label: "com.NorEliYehShi.bassline.listeners",
        qos: .utility
    )

    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock
    private var isRegistered = false

    init(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        block: @escaping AudioObjectPropertyListenerBlock
    ) {
        self.objectID = objectID
        self.address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        self.block = block
    }

    deinit { remove() }

    func install() {
        guard !isRegistered else { return }
        let status = AudioObjectAddPropertyListenerBlock(objectID, &address, Self.queue, block)
        if status == noErr {
            isRegistered = true
        } else {
            log.error("AddPropertyListener failed: OSStatus \(status, privacy: .public)")
        }
    }

    func remove() {
        guard isRegistered else { return }
        isRegistered = false
        AudioObjectRemovePropertyListenerBlock(objectID, &address, Self.queue, block)
    }
}
