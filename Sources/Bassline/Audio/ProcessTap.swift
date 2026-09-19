import AudioToolbox
import BasslineCore
import CoreAudio
import Foundation
import QuartzCore

/// Core Audio process tap on a single application, mixed down to stereo and
/// delivered through a private aggregate device.
@available(macOS 14.2, *)
final class ProcessTap {
    var onOutputLatencyChanged: ((Double) -> Void)?
    var onStreamFormatChanged: ((Double) -> Void)?

    let analyzer: SpectrumAnalyzer

    private static let preferredBufferFrames: UInt32 = 512
    private static let hostTimeToSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    private let targetProcessID: AudioObjectID
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapUUIDString = ""
    private var deviceChangeListener: AudioPropertyListener?
    private var sampleRateListener: AudioPropertyListener?
    private let audioQueue = DispatchQueue(
        label: "com.NorEliYehShi.bassline.audio",
        qos: .userInteractive
    )
    private var isRunning = false
    private var hasStopped = false
    private var watchdogTimer: Timer?

    private static let watchdogDelay: TimeInterval = 4

    init(targetProcessID: AudioObjectID, analyzer: SpectrumAnalyzer) {
        self.targetProcessID = targetProcessID
        self.analyzer = analyzer
    }

    deinit { stop() }

    func start() throws {
        try createTap()
        try createAggregateDevice()
        try startIO()
        installListeners()
        isRunning = true
        startDeliveryWatchdog()
    }

    func stop() {
        guard !hasStopped else { return }
        hasStopped = true
        isRunning = false

        watchdogTimer?.invalidate()
        watchdogTimer = nil
        deviceChangeListener?.remove()
        deviceChangeListener = nil
        sampleRateListener?.remove()
        sampleRateListener = nil
        stopIO()
        destroyAggregateDevice()
        destroyTap()
    }

    // MARK: - Delivery watchdog

    /// Without the System Audio Recording grant the HAL still creates the tap
    /// and the aggregate device without error on several macOS versions — it
    /// just never delivers a buffer. The only reliable signal is that no frame
    /// ever arrives, so check for that instead of trusting the OSStatus.
    private func startDeliveryWatchdog() {
        watchdogTimer?.invalidate()
        let timer = Timer(timeInterval: Self.watchdogDelay, repeats: false) { [weak self] _ in
            guard let self, self.isRunning else { return }
            guard self.analyzer.frames.writtenFrameCount == 0 else { return }
            log.error("No audio delivered \(Int(Self.watchdogDelay), privacy: .public)s after starting the tap")
            StatusCenter.shared.set(.noAudioReceived)
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    // MARK: - Tap

    private func createTap() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: [targetProcessID])
        let uuid = UUID()
        description.uuid = uuid
        description.isPrivate = true
        description.muteBehavior = .unmuted
        tapUUIDString = uuid.uuidString

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        try caCheck(AudioHardwareCreateProcessTap(description, &newTapID), "CreateProcessTap")
        tapID = newTapID
    }

    private func destroyTap() {
        guard tapID != kAudioObjectUnknown else { return }
        AudioHardwareDestroyProcessTap(tapID)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: - Aggregate device

    private func createAggregateDevice() throws {
        let outputUID = try getDefaultOutputDeviceUID()

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Bassline Tap",
            kAudioAggregateDeviceUIDKey: "com.NorEliYehShi.bassline.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUIDString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        try caCheck(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID),
            "CreateAggregateDevice"
        )
        aggregateID = newAggregateID
    }

    private func destroyAggregateDevice() {
        guard aggregateID != kAudioObjectUnknown else { return }
        AudioHardwareDestroyAggregateDevice(aggregateID)
        aggregateID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: - IO

    private func startIO() throws {
        guard aggregateID != kAudioObjectUnknown else { return }

        configureBufferSize()
        let sampleRate = try readAggregateSampleRate()
        analyzer.updateSampleRate(sampleRate)
        onStreamFormatChanged?(sampleRate)
        log.info("Tap format: \(sampleRate, privacy: .public) Hz")

        // The analyzer is captured directly (not via self) so the IO thread
        // never touches the tap object, and the closure body performs no
        // allocation, locking or logging.
        let analyzer = self.analyzer
        let toSeconds = Self.hostTimeToSeconds
        var newIOProcID: AudioDeviceIOProcID?

        try caCheck(
            AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateID, audioQueue) {
                _, inputData, inputTime, _, _ in

                let bufferList = inputData.pointee
                guard bufferList.mNumberBuffers > 0,
                      let data = bufferList.mBuffers.mData else { return }

                let channels = max(1, Int(bufferList.mBuffers.mNumberChannels))
                let frameCount = Int(bufferList.mBuffers.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                guard frameCount > 0 else { return }

                let now = CACurrentMediaTime()
                var hostTime = now
                let stamp = inputTime.pointee
                if stamp.mFlags.contains(.hostTimeValid) {
                    let candidate = Double(stamp.mHostTime) * toSeconds
                    if abs(candidate - now) < 1 { hostTime = candidate }
                }

                analyzer.process(
                    buffer: data.assumingMemoryBound(to: Float.self),
                    frameCount: frameCount,
                    channelCount: channels,
                    sampleRate: analyzer.currentSampleRate,
                    hostTime: hostTime
                )
            },
            "CreateIOProcID"
        )

        ioProcID = newIOProcID
        if let newIOProcID {
            try caCheck(AudioDeviceStart(aggregateID, newIOProcID), "AudioDeviceStart")
        }

        let latency = computeOutputLatency()
        log.info("Output latency: \(Int(latency * 1000), privacy: .public) ms")
        onOutputLatencyChanged?(latency)
    }

    private func stopIO() {
        guard aggregateID != kAudioObjectUnknown, let ioProcID else { return }
        AudioDeviceStop(aggregateID, ioProcID)
        AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        self.ioProcID = nil
    }

    private func configureBufferSize() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var frames = Self.preferredBufferFrames
        let status = AudioObjectSetPropertyData(
            aggregateID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames
        )
        if status != noErr {
            log.info("Could not set buffer size: OSStatus \(status, privacy: .public)")
        }
    }

    private func readAggregateSampleRate() throws -> Double {
        let rate: Float64 = try getAudioProperty(
            objectID: aggregateID,
            selector: kAudioDevicePropertyNominalSampleRate
        )
        return rate > 0 ? rate : 48_000
    }

    // MARK: - Latency

    private func computeOutputLatency() -> Double {
        guard let outputID = try? getDefaultOutputDeviceID(),
              let sampleRate: Float64 = try? getAudioProperty(
                  objectID: outputID,
                  selector: kAudioDevicePropertyNominalSampleRate
              ),
              sampleRate > 0 else { return 0 }

        let deviceLatency: UInt32 = (try? getAudioProperty(
            objectID: outputID,
            selector: kAudioDevicePropertyLatency,
            scope: kAudioObjectPropertyScopeOutput
        )) ?? 0
        let safetyOffset: UInt32 = (try? getAudioProperty(
            objectID: outputID,
            selector: kAudioDevicePropertySafetyOffset,
            scope: kAudioObjectPropertyScopeOutput
        )) ?? 0
        let bufferFrames: UInt32 = (try? getAudioProperty(
            objectID: aggregateID,
            selector: kAudioDevicePropertyBufferFrameSize
        )) ?? 0
        let streamLatency = firstOutputStreamLatency(of: outputID)

        let totalFrames = Double(deviceLatency) + Double(safetyOffset)
            + Double(bufferFrames) + Double(streamLatency)
        return totalFrames / sampleRate
    }

    private func firstOutputStreamLatency(of deviceID: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioStreamID>.size) else { return 0 }

        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &streams) == noErr,
              let first = streams.first else { return 0 }
        return (try? getAudioProperty(objectID: first, selector: kAudioStreamPropertyLatency)) ?? 0
    }

    // MARK: - Device and format changes

    private func installListeners() {
        deviceChangeListener = AudioPropertyListener(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice
        ) { [weak self] _, _ in
            DispatchQueue.main.async { self?.rebuildAfterDeviceChange() }
        }
        deviceChangeListener?.install()

        guard aggregateID != kAudioObjectUnknown else { return }
        sampleRateListener = AudioPropertyListener(
            objectID: aggregateID,
            selector: kAudioDevicePropertyNominalSampleRate
        ) { [weak self] _, _ in
            DispatchQueue.main.async { self?.handleSampleRateChange() }
        }
        sampleRateListener?.install()
    }

    /// The tap format can change without the default device changing, for
    /// example 48 kHz to 44.1 kHz. Without this the band mapping drifts.
    private func handleSampleRateChange() {
        guard isRunning, let rate = try? readAggregateSampleRate() else { return }
        analyzer.updateSampleRate(rate)
        onStreamFormatChanged?(rate)
        onOutputLatencyChanged?(computeOutputLatency())
        log.info("Sample rate changed to \(rate, privacy: .public) Hz")
    }

    private func rebuildAfterDeviceChange() {
        guard isRunning else { return }
        log.info("Default output device changed, rebuilding aggregate")

        sampleRateListener?.remove()
        sampleRateListener = nil
        stopIO()
        destroyAggregateDevice()

        do {
            try createAggregateDevice()
            try startIO()
            installSampleRateListener()
        } catch {
            log.error("Failed to rebuild after device change: \(String(describing: error), privacy: .public)")
            StatusCenter.shared.set(.failed((error as? CoreAudioError)?.shortDescription ?? "device change"))
        }
    }

    private func installSampleRateListener() {
        guard aggregateID != kAudioObjectUnknown else { return }
        sampleRateListener = AudioPropertyListener(
            objectID: aggregateID,
            selector: kAudioDevicePropertyNominalSampleRate
        ) { [weak self] _, _ in
            DispatchQueue.main.async { self?.handleSampleRateChange() }
        }
        sampleRateListener?.install()
    }
}
