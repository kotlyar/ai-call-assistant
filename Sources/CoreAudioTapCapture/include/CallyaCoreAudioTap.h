#ifndef CALLYA_CORE_AUDIO_TAP_H
#define CALLYA_CORE_AUDIO_TAP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CallyaAudioTapOpaque *CallyaAudioTapRef;

typedef enum CallyaAudioTapScope {
    /// Capture every audible process except the supplied process identifiers.
    CallyaAudioTapScopeGlobalExcludingProcesses = 0,
    /// Capture only the supplied process identifiers.
    CallyaAudioTapScopeIncludedProcesses = 1,
} CallyaAudioTapScope;

typedef enum CallyaAudioTapResult {
    CallyaAudioTapResultOK = 0,
    CallyaAudioTapResultInvalidArgument = 1,
    CallyaAudioTapResultAlreadyRunning = 2,
    CallyaAudioTapResultNotRunning = 3,
    CallyaAudioTapResultProcessNotFound = 4,
    CallyaAudioTapResultPermissionDenied = 5,
    CallyaAudioTapResultUnsupported = 6,
    CallyaAudioTapResultCoreAudioFailure = 7,
} CallyaAudioTapResult;

typedef struct CallyaAudioTapConfiguration {
    CallyaAudioTapScope scope;
    /// BSD process identifiers. They are translated to HAL process objects at start time.
    const int32_t *processIdentifiers;
    size_t processIdentifierCount;
    /// Number of fixed-size packets in the real-time SPSC ring. Zero selects the default.
    uint32_t ringPacketCapacity;
} CallyaAudioTapConfiguration;

/// Interleaved stereo Float32 frames. The pointer is valid only for the duration of the callback.
/// This callback is invoked from a dedicated delivery thread, never from Core Audio's IO thread.
typedef void (*CallyaAudioTapFramesCallback)(
    const float *interleavedFrames,
    uint32_t frameCount,
    uint64_t hostTime,
    double sampleRate,
    uint32_t channelCount,
    void *context
);

/// Asynchronous runtime failures are delivered from the same non-real-time delivery thread.
typedef void (*CallyaAudioTapErrorCallback)(
    CallyaAudioTapResult result,
    const char *message,
    void *context
);

/// Creates an idle capture object. The configuration and callbacks are copied.
CallyaAudioTapResult CallyaAudioTapCreate(
    const CallyaAudioTapConfiguration *configuration,
    CallyaAudioTapFramesCallback framesCallback,
    CallyaAudioTapErrorCallback errorCallback,
    void *context,
    CallyaAudioTapRef *outTap,
    char **outErrorMessage
);

/// Creates the private/unmuted process tap, private aggregate device and IOProc, then starts IO.
CallyaAudioTapResult CallyaAudioTapStart(
    CallyaAudioTapRef tap,
    char **outErrorMessage
);

/// Stops IO and synchronously destroys IOProc, aggregate device and process tap.
/// It is idempotent: stopping an already stopped object succeeds.
CallyaAudioTapResult CallyaAudioTapStop(
    CallyaAudioTapRef tap,
    char **outErrorMessage
);

/// Stops capture if necessary and releases the object. Passing NULL is safe.
void CallyaAudioTapDestroy(CallyaAudioTapRef tap);

/// Number of packets dropped because the delivery thread could not keep up.
uint64_t CallyaAudioTapDroppedPacketCount(CallyaAudioTapRef tap);

/// TCC probe: briefly starts and stops a private aggregate device backed by a private/unmuted
/// global tap that excludes the calling process. Starting aggregate IO is the operation that can
/// trigger the macOS system-audio permission prompt; merely creating a tap is not sufficient.
CallyaAudioTapResult CallyaAudioTapProbePermission(char **outErrorMessage);

/// Frees an error string returned by this API.
void CallyaAudioTapFreeString(char *string);

#ifdef __cplusplus
}
#endif

#endif
