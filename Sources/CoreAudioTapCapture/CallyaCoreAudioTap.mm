#import "CallyaCoreAudioTap.h"

#import <CoreAudio/AudioHardware.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/HostTime.h>
#import <Foundation/Foundation.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

namespace {

constexpr uint32_t kChannelCount = 2;
constexpr uint32_t kFramesPerPacket = 4096;
constexpr uint32_t kDefaultPacketCapacity = 128;
constexpr uint32_t kMinimumPacketCapacity = 8;
constexpr uint32_t kMaximumPacketCapacity = 2048;

enum AsyncFailure : int {
    kAsyncFailureNone = 0,
    kAsyncFailureUnexpectedBufferLayout = 1,
    kAsyncFailureTapFormatChanged = 2,
    kAsyncFailureAggregateDeviceStopped = 3,
    kAsyncFailureAudioServiceRestarted = 4,
};

static uint32_t NormalizedPacketCapacity(uint32_t requested) {
    const uint32_t selected = requested == 0 ? kDefaultPacketCapacity : requested;
    return std::max(kMinimumPacketCapacity, std::min(kMaximumPacketCapacity, selected));
}

struct Packet {
    uint32_t frameCount = 0;
    uint64_t hostTime = 0;
    float samples[kFramesPerPacket * kChannelCount] = {};
};

static std::string StatusText(OSStatus status) {
    char fourCC[5] = {};
    const uint32_t value = static_cast<uint32_t>(status);
    fourCC[0] = static_cast<char>((value >> 24) & 0xff);
    fourCC[1] = static_cast<char>((value >> 16) & 0xff);
    fourCC[2] = static_cast<char>((value >> 8) & 0xff);
    fourCC[3] = static_cast<char>(value & 0xff);
    const bool printable = fourCC[0] >= 32 && fourCC[0] <= 126
        && fourCC[1] >= 32 && fourCC[1] <= 126
        && fourCC[2] >= 32 && fourCC[2] <= 126
        && fourCC[3] >= 32 && fourCC[3] <= 126;
    if (printable) {
        return "OSStatus '" + std::string(fourCC, 4) + "' ("
            + std::to_string(status) + ")";
    }
    return "OSStatus " + std::to_string(status);
}

static CallyaAudioTapResult ResultForStatus(OSStatus status) {
    if (status == noErr) {
        return CallyaAudioTapResultOK;
    }
    if (status == kAudioDevicePermissionsError) {
        return CallyaAudioTapResultPermissionDenied;
    }
    if (status == kAudioHardwareUnsupportedOperationError) {
        return CallyaAudioTapResultUnsupported;
    }
    return CallyaAudioTapResultCoreAudioFailure;
}

static void SetError(char **destination, const std::string &message) {
    if (destination == nullptr) {
        return;
    }
    *destination = static_cast<char *>(std::malloc(message.size() + 1));
    if (*destination != nullptr) {
        std::memcpy(*destination, message.c_str(), message.size() + 1);
    }
}

static AudioObjectID ProcessObjectForPID(pid_t pid, OSStatus &status) {
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyTranslatePIDToProcessObject,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    AudioObjectID processObject = kAudioObjectUnknown;
    UInt32 outputSize = sizeof(processObject);
    status = AudioObjectGetPropertyData(
        kAudioObjectSystemObject,
        &address,
        sizeof(pid),
        &pid,
        &outputSize,
        &processObject
    );
    return processObject;
}

static OSStatus TapFormat(AudioObjectID tapID, AudioStreamBasicDescription &format) {
    AudioObjectPropertyAddress address = {
        kAudioTapPropertyFormat,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = sizeof(format);
    std::memset(&format, 0, sizeof(format));
    return AudioObjectGetPropertyData(tapID, &address, 0, nullptr, &size, &format);
}

static OSStatus WaitForDeviceAlive(AudioObjectID deviceID) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyDeviceIsAlive,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    // Aggregate publication is asynchronous even though creation already returned an ID.
    // Keep this wait on the wrapper's control queue, never on Core Audio's IO thread.
    for (uint32_t attempt = 0; attempt < 60; ++attempt) {
        UInt32 alive = 0;
        UInt32 size = sizeof(alive);
        const OSStatus status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nullptr,
            &size,
            &alive
        );
        if (status == noErr && alive != 0) {
            return noErr;
        }
        if (status != noErr && status != kAudioHardwareNotReadyError
            && status != kAudioHardwareBadObjectError) {
            return status;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    return kAudioHardwareNotReadyError;
}

class CaptureEngine {
public:
    CaptureEngine(
        CallyaAudioTapScope scope,
        std::vector<int32_t> processIdentifiers,
        uint32_t packetCapacity,
        CallyaAudioTapFramesCallback framesCallback,
        CallyaAudioTapErrorCallback errorCallback,
        void *context
    ) : scope_(scope),
        processIdentifiers_(std::move(processIdentifiers)),
        capacity_(NormalizedPacketCapacity(packetCapacity)),
        packets_(std::make_unique<Packet[]>(NormalizedPacketCapacity(packetCapacity))),
        framesCallback_(framesCallback),
        errorCallback_(errorCallback),
        context_(context) {}

    ~CaptureEngine() {
        std::string ignored;
        Stop(ignored);
    }

    CallyaAudioTapResult Start(std::string &error) {
        std::lock_guard<std::mutex> lock(lifecycleMutex_);
        if (running_) {
            error = "Core Audio tap is already running";
            return CallyaAudioTapResultAlreadyRunning;
        }

        asyncFailure_.store(kAsyncFailureNone, std::memory_order_relaxed);
        asyncFailureReported_ = false;
        @autoreleasepool {
            const CallyaAudioTapResult prepareResult = PrepareTap(error);
            if (prepareResult != CallyaAudioTapResultOK) {
                CleanupHALObjects();
                return prepareResult;
            }

            producerEnabled_.store(true, std::memory_order_release);
            workerShouldStop_.store(false, std::memory_order_release);
            readIndex_.store(0, std::memory_order_relaxed);
            writeIndex_.store(0, std::memory_order_relaxed);
            droppedPackets_.store(0, std::memory_order_relaxed);
            worker_ = std::thread([this] { DeliveryLoop(); });

            const OSStatus status = AudioDeviceStart(aggregateDeviceID_, ioProcID_);
            if (status != noErr) {
                producerEnabled_.store(false, std::memory_order_release);
                StopWorker();
                error = "AudioDeviceStart failed: " + StatusText(status);
                CleanupHALObjects();
                return ResultForStatus(status);
            }
            running_ = true;
        }
        return CallyaAudioTapResultOK;
    }

    CallyaAudioTapResult Stop(std::string &error) {
        std::unique_lock<std::mutex> lock(lifecycleMutex_);
        if (!running_ && tapID_ == kAudioObjectUnknown
            && aggregateDeviceID_ == kAudioObjectUnknown && ioProcID_ == nullptr) {
            return CallyaAudioTapResultOK;
        }

        producerEnabled_.store(false, std::memory_order_release);
        UnregisterListeners();
        OSStatus firstFailure = noErr;
        const char *operation = nullptr;

        if (running_ && aggregateDeviceID_ != kAudioObjectUnknown && ioProcID_ != nullptr) {
            const OSStatus status = AudioDeviceStop(aggregateDeviceID_, ioProcID_);
            if (status != noErr) {
                firstFailure = status;
                operation = "AudioDeviceStop";
            }
        }
        running_ = false;

        // Destroying the IOProc guarantees that Core Audio no longer references this object.
        if (aggregateDeviceID_ != kAudioObjectUnknown && ioProcID_ != nullptr) {
            const OSStatus status = AudioDeviceDestroyIOProcID(aggregateDeviceID_, ioProcID_);
            if (firstFailure == noErr && status != noErr) {
                firstFailure = status;
                operation = "AudioDeviceDestroyIOProcID";
            }
            ioProcID_ = nullptr;
        }

        StopWorker();

        if (aggregateDeviceID_ != kAudioObjectUnknown) {
            const OSStatus status = AudioHardwareDestroyAggregateDevice(aggregateDeviceID_);
            if (firstFailure == noErr && status != noErr) {
                firstFailure = status;
                operation = "AudioHardwareDestroyAggregateDevice";
            }
            aggregateDeviceID_ = kAudioObjectUnknown;
        }
        if (tapID_ != kAudioObjectUnknown) {
            const OSStatus status = AudioHardwareDestroyProcessTap(tapID_);
            if (firstFailure == noErr && status != noErr) {
                firstFailure = status;
                operation = "AudioHardwareDestroyProcessTap";
            }
            tapID_ = kAudioObjectUnknown;
        }

        if (firstFailure != noErr) {
            error = std::string(operation) + " failed: " + StatusText(firstFailure);
            return ResultForStatus(firstFailure);
        }
        return CallyaAudioTapResultOK;
    }

    uint64_t droppedPacketCount() const {
        return droppedPackets_.load(std::memory_order_relaxed);
    }

private:
    CallyaAudioTapResult PrepareTap(std::string &error) {
        NSMutableArray<NSNumber *> *processObjects = [NSMutableArray array];

        auto appendProcess = [&](pid_t pid, bool required) -> CallyaAudioTapResult {
            OSStatus status = noErr;
            const AudioObjectID objectID = ProcessObjectForPID(pid, status);
            if (status != noErr) {
                error = "Could not resolve PID " + std::to_string(pid) + ": " + StatusText(status);
                return ResultForStatus(status);
            }
            if (objectID == kAudioObjectUnknown) {
                if (required) {
                    error = "PID " + std::to_string(pid) + " is not connected to Core Audio";
                    return CallyaAudioTapResultProcessNotFound;
                }
                return CallyaAudioTapResultOK;
            }
            NSNumber *number = [NSNumber numberWithUnsignedInt:objectID];
            if (![processObjects containsObject:number]) {
                [processObjects addObject:number];
            }
            return CallyaAudioTapResultOK;
        };

        for (const int32_t processIdentifier : processIdentifiers_) {
            const CallyaAudioTapResult result = appendProcess(
                static_cast<pid_t>(processIdentifier),
                scope_ == CallyaAudioTapScopeIncludedProcesses
            );
            if (result != CallyaAudioTapResultOK) {
                return result;
            }
        }

        if (scope_ == CallyaAudioTapScopeGlobalExcludingProcesses) {
            // Never permit Callya's own playback into the global capture. Failing closed here
            // prevents an accidental feedback/echo path if HAL cannot resolve our process.
            const CallyaAudioTapResult result = appendProcess(getpid(), true);
            if (result != CallyaAudioTapResultOK) {
                return result;
            }
        } else if ([processObjects count] == 0) {
            error = "An included-process tap requires at least one active Core Audio process";
            return CallyaAudioTapResultProcessNotFound;
        }

        CATapDescription *description = nil;
        if (scope_ == CallyaAudioTapScopeGlobalExcludingProcesses) {
            description = [[CATapDescription alloc]
                initStereoGlobalTapButExcludeProcesses:processObjects];
        } else {
            description = [[CATapDescription alloc]
                initStereoMixdownOfProcesses:processObjects];
        }
        description.name = @"Callya System Audio";
        description.UUID = [NSUUID UUID];
        description.privateTap = YES;
        description.muteBehavior = CATapUnmuted;

        const OSStatus createTapStatus = AudioHardwareCreateProcessTap(description, &tapID_);
        if (createTapStatus != noErr) {
            error = "AudioHardwareCreateProcessTap failed: " + StatusText(createTapStatus);
#if !__has_feature(objc_arc)
            [description release];
#endif
            return ResultForStatus(createTapStatus);
        }

        const OSStatus formatStatus = TapFormat(tapID_, format_);
        if (formatStatus != noErr) {
            error = "Could not read process tap format: " + StatusText(formatStatus);
#if !__has_feature(objc_arc)
            [description release];
#endif
            return ResultForStatus(formatStatus);
        }

        const bool isFloat32PCM = format_.mFormatID == kAudioFormatLinearPCM
            && (format_.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && format_.mBitsPerChannel == 32
            && format_.mChannelsPerFrame == kChannelCount
            && format_.mSampleRate > 0;
        if (!isFloat32PCM) {
            error = "Core Audio process tap did not provide stereo Float32 PCM";
#if !__has_feature(objc_arc)
            [description release];
#endif
            return CallyaAudioTapResultUnsupported;
        }
        nonInterleaved_ = (format_.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;

        NSDictionary *tapEntry = @{
            @kAudioSubTapUIDKey: description.UUID.UUIDString,
            @kAudioSubTapDriftCompensationKey: [NSNumber numberWithBool:YES],
        };
        NSString *aggregateUID = [NSString stringWithFormat:@"com.callya.tap.%@", NSUUID.UUID.UUIDString];
        NSDictionary *aggregateDescription = @{
            @kAudioAggregateDeviceNameKey: @"Callya Private Audio Tap",
            @kAudioAggregateDeviceUIDKey: aggregateUID,
            @kAudioAggregateDeviceTapListKey: @[tapEntry],
            @kAudioAggregateDeviceIsPrivateKey: [NSNumber numberWithBool:YES],
        };
        const OSStatus aggregateStatus = AudioHardwareCreateAggregateDevice(
            (__bridge CFDictionaryRef)aggregateDescription,
            &aggregateDeviceID_
        );
#if !__has_feature(objc_arc)
        [description release];
#endif
        if (aggregateStatus != noErr) {
            error = "AudioHardwareCreateAggregateDevice failed: " + StatusText(aggregateStatus);
            return ResultForStatus(aggregateStatus);
        }

        const OSStatus aliveStatus = WaitForDeviceAlive(aggregateDeviceID_);
        if (aliveStatus != noErr) {
            error = "Private aggregate device did not become ready: " + StatusText(aliveStatus);
            return ResultForStatus(aliveStatus);
        }

        const OSStatus listenerStatus = RegisterListeners();
        if (listenerStatus != noErr) {
            error = "Could not monitor Core Audio tap lifetime: " + StatusText(listenerStatus);
            return ResultForStatus(listenerStatus);
        }

        const OSStatus ioProcStatus = AudioDeviceCreateIOProcID(
            aggregateDeviceID_,
            &CaptureEngine::IOProc,
            this,
            &ioProcID_
        );
        if (ioProcStatus != noErr) {
            error = "AudioDeviceCreateIOProcID failed: " + StatusText(ioProcStatus);
            return ResultForStatus(ioProcStatus);
        }
        return CallyaAudioTapResultOK;
    }

    void CleanupHALObjects() {
        UnregisterListeners();
        if (aggregateDeviceID_ != kAudioObjectUnknown && ioProcID_ != nullptr) {
            AudioDeviceDestroyIOProcID(aggregateDeviceID_, ioProcID_);
            ioProcID_ = nullptr;
        }
        if (aggregateDeviceID_ != kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID_);
            aggregateDeviceID_ = kAudioObjectUnknown;
        }
        if (tapID_ != kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID_);
            tapID_ = kAudioObjectUnknown;
        }
    }

    OSStatus RegisterListeners() {
        AudioObjectPropertyAddress tapFormatAddress = {
            kAudioTapPropertyFormat,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain,
        };
        OSStatus status = AudioObjectAddPropertyListener(
            tapID_,
            &tapFormatAddress,
            &CaptureEngine::PropertyChanged,
            this
        );
        if (status != noErr) {
            return status;
        }
        tapFormatListenerRegistered_ = true;

        AudioObjectPropertyAddress aliveAddress = {
            kAudioDevicePropertyDeviceIsAlive,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain,
        };
        status = AudioObjectAddPropertyListener(
            aggregateDeviceID_,
            &aliveAddress,
            &CaptureEngine::PropertyChanged,
            this
        );
        if (status != noErr) {
            UnregisterListeners();
            return status;
        }
        aggregateAliveListenerRegistered_ = true;

        AudioObjectPropertyAddress restartAddress = {
            kAudioHardwarePropertyServiceRestarted,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain,
        };
        status = AudioObjectAddPropertyListener(
            kAudioObjectSystemObject,
            &restartAddress,
            &CaptureEngine::PropertyChanged,
            this
        );
        if (status != noErr) {
            UnregisterListeners();
            return status;
        }
        serviceRestartListenerRegistered_ = true;
        return noErr;
    }

    void UnregisterListeners() {
        if (tapFormatListenerRegistered_ && tapID_ != kAudioObjectUnknown) {
            AudioObjectPropertyAddress address = {
                kAudioTapPropertyFormat,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain,
            };
            AudioObjectRemovePropertyListener(
                tapID_,
                &address,
                &CaptureEngine::PropertyChanged,
                this
            );
            tapFormatListenerRegistered_ = false;
        }
        if (aggregateAliveListenerRegistered_ && aggregateDeviceID_ != kAudioObjectUnknown) {
            AudioObjectPropertyAddress address = {
                kAudioDevicePropertyDeviceIsAlive,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain,
            };
            AudioObjectRemovePropertyListener(
                aggregateDeviceID_,
                &address,
                &CaptureEngine::PropertyChanged,
                this
            );
            aggregateAliveListenerRegistered_ = false;
        }
        if (serviceRestartListenerRegistered_) {
            AudioObjectPropertyAddress address = {
                kAudioHardwarePropertyServiceRestarted,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain,
            };
            AudioObjectRemovePropertyListener(
                kAudioObjectSystemObject,
                &address,
                &CaptureEngine::PropertyChanged,
                this
            );
            serviceRestartListenerRegistered_ = false;
        }
    }

    static OSStatus PropertyChanged(
        AudioObjectID objectID,
        UInt32 addressCount,
        const AudioObjectPropertyAddress *addresses,
        void *clientData
    ) {
        auto *engine = static_cast<CaptureEngine *>(clientData);
        if (engine == nullptr || addresses == nullptr) {
            return noErr;
        }
        for (UInt32 index = 0; index < addressCount; ++index) {
            const AudioObjectPropertySelector selector = addresses[index].mSelector;
            if (objectID == engine->tapID_ && selector == kAudioTapPropertyFormat) {
                engine->ReportAsyncFailure(kAsyncFailureTapFormatChanged);
            } else if (objectID == engine->aggregateDeviceID_
                && selector == kAudioDevicePropertyDeviceIsAlive) {
                UInt32 alive = 0;
                UInt32 size = sizeof(alive);
                AudioObjectPropertyAddress address = addresses[index];
                const OSStatus status = AudioObjectGetPropertyData(
                    objectID,
                    &address,
                    0,
                    nullptr,
                    &size,
                    &alive
                );
                if (status != noErr || alive == 0) {
                    engine->ReportAsyncFailure(kAsyncFailureAggregateDeviceStopped);
                }
            } else if (objectID == kAudioObjectSystemObject
                && selector == kAudioHardwarePropertyServiceRestarted) {
                engine->ReportAsyncFailure(kAsyncFailureAudioServiceRestarted);
            }
        }
        return noErr;
    }

    void ReportAsyncFailure(AsyncFailure failure) {
        int expected = kAsyncFailureNone;
        if (asyncFailure_.compare_exchange_strong(
            expected,
            failure,
            std::memory_order_acq_rel,
            std::memory_order_relaxed
        )) {
            producerEnabled_.store(false, std::memory_order_release);
        }
    }

    static OSStatus IOProc(
        AudioObjectID,
        const AudioTimeStamp *inNow,
        const AudioBufferList *inputData,
        const AudioTimeStamp *inputTime,
        AudioBufferList *,
        const AudioTimeStamp *,
        void *clientData
    ) {
        auto *engine = static_cast<CaptureEngine *>(clientData);
        if (engine != nullptr) {
            engine->Offer(inputData, inputTime, inNow);
        }
        return noErr;
    }

    void Offer(
        const AudioBufferList *inputData,
        const AudioTimeStamp *inputTime,
        const AudioTimeStamp *now
    ) {
        if (!producerEnabled_.load(std::memory_order_acquire)
            || inputData == nullptr || inputData->mNumberBuffers == 0) {
            return;
        }

        uint32_t totalFrames = FrameCount(inputData);
        if (totalFrames == 0) {
            return;
        }
        uint64_t hostTime = 0;
        if (inputTime != nullptr
            && (inputTime->mFlags & kAudioTimeStampHostTimeValid) != 0) {
            hostTime = inputTime->mHostTime;
        } else if (now != nullptr && (now->mFlags & kAudioTimeStampHostTimeValid) != 0) {
            hostTime = now->mHostTime;
        }

        uint32_t sourceOffset = 0;
        while (sourceOffset < totalFrames) {
            const uint32_t count = std::min(kFramesPerPacket, totalFrames - sourceOffset);
            const uint64_t write = writeIndex_.load(std::memory_order_relaxed);
            const uint64_t read = readIndex_.load(std::memory_order_acquire);
            if (write - read >= capacity_) {
                droppedPackets_.fetch_add(1, std::memory_order_relaxed);
                return;
            }

            Packet &packet = packets_[write % capacity_];
            if (!CopyInterleavedStereo(inputData, sourceOffset, count, packet.samples)) {
                droppedPackets_.fetch_add(1, std::memory_order_relaxed);
                ReportAsyncFailure(kAsyncFailureUnexpectedBufferLayout);
                return;
            }
            packet.frameCount = count;
            packet.hostTime = hostTime == 0
                ? 0
                : hostTime + HostTicksForFrames(sourceOffset);
            writeIndex_.store(write + 1, std::memory_order_release);
            sourceOffset += count;
        }
    }

    uint32_t FrameCount(const AudioBufferList *inputData) const {
        if (inputData->mNumberBuffers == 0) {
            return 0;
        }
        const AudioBuffer &first = inputData->mBuffers[0];
        const uint32_t bytesPerFrame = nonInterleaved_
            ? sizeof(float)
            : sizeof(float) * kChannelCount;
        return bytesPerFrame == 0 ? 0 : first.mDataByteSize / bytesPerFrame;
    }

    bool CopyInterleavedStereo(
        const AudioBufferList *inputData,
        uint32_t sourceOffset,
        uint32_t frameCount,
        float *destination
    ) const {
        if (!nonInterleaved_) {
            const AudioBuffer &buffer = inputData->mBuffers[0];
            if (buffer.mData == nullptr || buffer.mNumberChannels < kChannelCount) {
                return false;
            }
            const float *source = static_cast<const float *>(buffer.mData)
                + static_cast<size_t>(sourceOffset) * kChannelCount;
            std::memcpy(
                destination,
                source,
                static_cast<size_t>(frameCount) * kChannelCount * sizeof(float)
            );
            return true;
        }

        if (inputData->mNumberBuffers < kChannelCount
            || inputData->mBuffers[0].mData == nullptr
            || inputData->mBuffers[1].mData == nullptr) {
            return false;
        }
        const float *left = static_cast<const float *>(inputData->mBuffers[0].mData) + sourceOffset;
        const float *right = static_cast<const float *>(inputData->mBuffers[1].mData) + sourceOffset;
        for (uint32_t frame = 0; frame < frameCount; ++frame) {
            destination[frame * kChannelCount] = left[frame];
            destination[frame * kChannelCount + 1] = right[frame];
        }
        return true;
    }

    uint64_t HostTicksForFrames(uint32_t frameCount) const {
        if (frameCount == 0 || format_.mSampleRate <= 0) {
            return 0;
        }
        const double nanoseconds = (static_cast<double>(frameCount) / format_.mSampleRate)
            * 1'000'000'000.0;
        return AudioConvertNanosToHostTime(static_cast<uint64_t>(nanoseconds));
    }

    void DeliveryLoop() {
        while (true) {
            const int asyncFailure = asyncFailure_.load(std::memory_order_acquire);
            if (!asyncFailureReported_ && asyncFailure != kAsyncFailureNone) {
                asyncFailureReported_ = true;
                if (errorCallback_ != nullptr) {
                    const CallyaAudioTapResult result = asyncFailure
                            == kAsyncFailureUnexpectedBufferLayout
                        ? CallyaAudioTapResultUnsupported
                        : CallyaAudioTapResultCoreAudioFailure;
                    const char *message = "Core Audio capture stopped unexpectedly";
                    switch (asyncFailure) {
                    case kAsyncFailureUnexpectedBufferLayout:
                        message = "Core Audio delivered an unexpected stereo PCM buffer layout";
                        break;
                    case kAsyncFailureTapFormatChanged:
                        message = "The system-audio stream format changed during capture";
                        break;
                    case kAsyncFailureAggregateDeviceStopped:
                        message = "The private system-audio device became unavailable";
                        break;
                    case kAsyncFailureAudioServiceRestarted:
                        message = "The Core Audio service restarted during capture";
                        break;
                    default:
                        break;
                    }
                    errorCallback_(
                        result,
                        message,
                        context_
                    );
                }
            }
            bool delivered = false;
            uint64_t read = readIndex_.load(std::memory_order_relaxed);
            const uint64_t write = writeIndex_.load(std::memory_order_acquire);
            while (read < write) {
                Packet &packet = packets_[read % capacity_];
                if (framesCallback_ != nullptr) {
                    @autoreleasepool {
                        framesCallback_(
                            packet.samples,
                            packet.frameCount,
                            packet.hostTime,
                            format_.mSampleRate,
                            kChannelCount,
                            context_
                        );
                    }
                }
                ++read;
                readIndex_.store(read, std::memory_order_release);
                delivered = true;
            }
            if (workerShouldStop_.load(std::memory_order_acquire)) {
                // All packets published before stop are delivered before the thread exits.
                if (readIndex_.load(std::memory_order_relaxed)
                    >= writeIndex_.load(std::memory_order_acquire)) {
                    break;
                }
            }
            if (!delivered) {
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
        }
    }

    void StopWorker() {
        workerShouldStop_.store(true, std::memory_order_release);
        if (worker_.joinable()) {
            if (worker_.get_id() == std::this_thread::get_id()) {
                // Calling stop/destroy from a frames callback is unsupported; detach is safer than
                // terminating. The Swift wrapper prevents this reentrant lifecycle operation.
                worker_.detach();
            } else {
                worker_.join();
            }
        }
    }

    const CallyaAudioTapScope scope_;
    const std::vector<int32_t> processIdentifiers_;
    const uint32_t capacity_;
    const std::unique_ptr<Packet[]> packets_;
    const CallyaAudioTapFramesCallback framesCallback_;
    const CallyaAudioTapErrorCallback errorCallback_;
    void *const context_;

    std::mutex lifecycleMutex_;
    bool running_ = false;
    AudioObjectID tapID_ = kAudioObjectUnknown;
    AudioObjectID aggregateDeviceID_ = kAudioObjectUnknown;
    AudioDeviceIOProcID ioProcID_ = nullptr;
    AudioStreamBasicDescription format_ = {};
    bool nonInterleaved_ = false;
    bool tapFormatListenerRegistered_ = false;
    bool aggregateAliveListenerRegistered_ = false;
    bool serviceRestartListenerRegistered_ = false;

    std::atomic<bool> producerEnabled_{false};
    std::atomic<bool> workerShouldStop_{false};
    std::atomic<uint64_t> readIndex_{0};
    std::atomic<uint64_t> writeIndex_{0};
    std::atomic<uint64_t> droppedPackets_{0};
    std::atomic<int> asyncFailure_{kAsyncFailureNone};
    bool asyncFailureReported_ = false;
    std::thread worker_;
};

static void IgnoreFrames(
    const float *,
    uint32_t,
    uint64_t,
    double,
    uint32_t,
    void *
) {}

} // namespace

struct CallyaAudioTapOpaque {
    std::unique_ptr<CaptureEngine> engine;
};

CallyaAudioTapResult CallyaAudioTapCreate(
    const CallyaAudioTapConfiguration *configuration,
    CallyaAudioTapFramesCallback framesCallback,
    CallyaAudioTapErrorCallback errorCallback,
    void *context,
    CallyaAudioTapRef *outTap,
    char **outErrorMessage
) {
    if (outErrorMessage != nullptr) {
        *outErrorMessage = nullptr;
    }
    if (configuration == nullptr || framesCallback == nullptr || outTap == nullptr) {
        SetError(outErrorMessage, "A configuration, frames callback and output tap are required");
        return CallyaAudioTapResultInvalidArgument;
    }
    *outTap = nullptr;
    if (configuration->scope != CallyaAudioTapScopeGlobalExcludingProcesses
        && configuration->scope != CallyaAudioTapScopeIncludedProcesses) {
        SetError(outErrorMessage, "Unknown Core Audio tap scope");
        return CallyaAudioTapResultInvalidArgument;
    }
    if (configuration->processIdentifierCount > 0
        && configuration->processIdentifiers == nullptr) {
        SetError(outErrorMessage, "Process identifier storage is missing");
        return CallyaAudioTapResultInvalidArgument;
    }
    if (configuration->scope == CallyaAudioTapScopeIncludedProcesses
        && configuration->processIdentifierCount == 0) {
        SetError(outErrorMessage, "An included-process tap requires at least one PID");
        return CallyaAudioTapResultInvalidArgument;
    }

    std::vector<int32_t> processIdentifiers;
    if (configuration->processIdentifierCount > 0) {
        processIdentifiers.assign(
            configuration->processIdentifiers,
            configuration->processIdentifiers + configuration->processIdentifierCount
        );
    }
    auto opaque = std::make_unique<CallyaAudioTapOpaque>();
    opaque->engine = std::make_unique<CaptureEngine>(
        configuration->scope,
        std::move(processIdentifiers),
        configuration->ringPacketCapacity,
        framesCallback,
        errorCallback,
        context
    );
    *outTap = opaque.release();
    return CallyaAudioTapResultOK;
}

CallyaAudioTapResult CallyaAudioTapStart(
    CallyaAudioTapRef tap,
    char **outErrorMessage
) {
    if (outErrorMessage != nullptr) {
        *outErrorMessage = nullptr;
    }
    if (tap == nullptr || tap->engine == nullptr) {
        SetError(outErrorMessage, "Core Audio tap is missing");
        return CallyaAudioTapResultInvalidArgument;
    }
    std::string error;
    const CallyaAudioTapResult result = tap->engine->Start(error);
    if (result != CallyaAudioTapResultOK) {
        SetError(outErrorMessage, error);
    }
    return result;
}

CallyaAudioTapResult CallyaAudioTapStop(
    CallyaAudioTapRef tap,
    char **outErrorMessage
) {
    if (outErrorMessage != nullptr) {
        *outErrorMessage = nullptr;
    }
    if (tap == nullptr || tap->engine == nullptr) {
        SetError(outErrorMessage, "Core Audio tap is missing");
        return CallyaAudioTapResultInvalidArgument;
    }
    std::string error;
    const CallyaAudioTapResult result = tap->engine->Stop(error);
    if (result != CallyaAudioTapResultOK) {
        SetError(outErrorMessage, error);
    }
    return result;
}

void CallyaAudioTapDestroy(CallyaAudioTapRef tap) {
    delete tap;
}

uint64_t CallyaAudioTapDroppedPacketCount(CallyaAudioTapRef tap) {
    if (tap == nullptr || tap->engine == nullptr) {
        return 0;
    }
    return tap->engine->droppedPacketCount();
}

CallyaAudioTapResult CallyaAudioTapProbePermission(char **outErrorMessage) {
    if (outErrorMessage != nullptr) {
        *outErrorMessage = nullptr;
    }
    // Apple prompts when IO starts on an aggregate device containing a tap, not when the tap
    // object is merely created. Run the complete start/stop path with a minimal ring and no-op
    // consumer so this probe reflects the permission used by real capture.
    CaptureEngine probe(
        CallyaAudioTapScopeGlobalExcludingProcesses,
        {},
        kMinimumPacketCapacity,
        &IgnoreFrames,
        nullptr,
        nullptr
    );
    std::string startError;
    const CallyaAudioTapResult startResult = probe.Start(startError);
    if (startResult != CallyaAudioTapResultOK) {
        SetError(outErrorMessage, startError);
        return startResult;
    }
    std::string stopError;
    const CallyaAudioTapResult stopResult = probe.Stop(stopError);
    if (stopResult != CallyaAudioTapResultOK) {
        SetError(outErrorMessage, stopError);
        return stopResult;
    }
    return CallyaAudioTapResultOK;
}

void CallyaAudioTapFreeString(char *string) {
    std::free(string);
}
