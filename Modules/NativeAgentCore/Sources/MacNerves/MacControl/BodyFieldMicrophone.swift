import CoreAudio
import Dispatch
import Foundation

// Blueprint: | `BodyFieldMicrophone.swift` | CoreAudio default-input and device-running property observation for the somatic joint |

// The microphone queue owns the Core Audio listener registrations.
package final class BodyFieldMicrophone: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.nativeagent.body.microphone")
    private let updates = AsyncStream<Bool?>.makeStream(bufferingPolicy: .bufferingNewest(1))
    package var changes: AsyncStream<Bool?> { updates.stream }
    private var defaultInput: Listener?
    private var running: Listener?

    package init() {
        queue.async { [self] in
            defaultInput = Listener(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, queue: queue) { [weak self] in
                self?.bindDevice()
            }
            bindDevice()
        }
    }

    private func bindDevice() {
        let device = defaultInput?.read()
        if device != running?.object {
            running?.remove()
            running = nil
            if let device, device != kAudioObjectUnknown {
                running = Listener(device, kAudioDevicePropertyDeviceIsRunningSomewhere, queue: queue) { [weak self] in
                    self?.readRunning()
                }
            }
        }
        readRunning()
    }

    private func readRunning() {
        let value = running?.read()
        updates.continuation.yield(value.map { $0 != 0 })
    }

    package func stop() {
        queue.sync {
            defaultInput?.remove()
            running?.remove()
            defaultInput = nil
            running = nil
            updates.continuation.finish()
        }
    }

    private final class Listener {
        let object: AudioObjectID
        private var address: AudioObjectPropertyAddress
        private let queue: DispatchQueue
        private let block: AudioObjectPropertyListenerBlock

        init?(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, queue: DispatchQueue,
              changed: @escaping @Sendable () -> Void) {
            self.object = object
            self.queue = queue
            address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
            block = { _, _ in changed() }
            let status = AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
            guard status == noErr else {
                NSLog("Microphone observation unavailable for object %u property %u: %d", object, selector, status)
                return nil
            }
        }

        func read() -> UInt32? {
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout.size(ofValue: value))
            let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
            guard status == noErr, size == MemoryLayout<UInt32>.size else {
                NSLog("Microphone read unavailable for object %u property %u: %d (%u bytes)", object, address.mSelector, status, size)
                return nil
            }
            return value
        }

        func remove() {
            let status = AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
            if status != noErr {
                NSLog("Microphone listener removal for object %u property %u: %d", object, address.mSelector, status)
            }
        }
    }
}
