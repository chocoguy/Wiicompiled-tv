// tvOS platform services that need Objective-C (AVKit, AVFAudio). Built on tvOS only, with ARC.
#include "platform/tvos_platform.h"
#include "platform/tvos_persistence.h"

#import <AVFAudio/AVFAudio.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <CoreMedia/CoreMedia.h>
#import <UIKit/UIKit.h>

#include <SDL3/SDL_events.h>
#include <SDL3/SDL_properties.h>
#include <SDL3/SDL_video.h>

#include <chrono>
#include <cstdio>
#include <thread>

namespace TvosPlatform {

void RequestDisplayRefreshRate(SDL_Window* window, float refreshRate) noexcept {
    if (window == nullptr) {
        return;
    }
    @autoreleasepool {
        UIWindow* uiWindow = (__bridge UIWindow*)SDL_GetPointerProperty(
            SDL_GetWindowProperties(window), SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, nullptr);
        if (uiWindow == nil) {
            return;
        }
        // An SDR format description: the game is never HDR, so only the refresh rate matters.
        CMVideoFormatDescriptionRef format = nullptr;
        const CGSize size = uiWindow.windowScene.screen.nativeBounds.size;
        if (CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCMVideoCodecType_H264,
                                           static_cast<int32_t>(size.width), static_cast<int32_t>(size.height),
                                           nullptr, &format) != noErr) {
            return;
        }
        AVDisplayManager* manager = uiWindow.avDisplayManager;
        manager.preferredDisplayCriteria = [[AVDisplayCriteria alloc] initWithRefreshRate:refreshRate
                                                                         formatDescription:format];
        CFRelease(format);
        std::fprintf(stderr, "[tvos] display: asked for %.2f Hz (Match Frame Rate %s)\n", refreshRate,
                     manager.displayCriteriaMatchingEnabled ? "on" : "off; the TV keeps its mode");
    }
}

bool OtherAudioWantsSilence() noexcept {
    @autoreleasepool {
        return AVAudioSession.sharedInstance.secondaryAudioShouldBeSilencedHint;
    }
}

int ThermalState() noexcept {
    return static_cast<int>(NSProcessInfo.processInfo.thermalState);
}

namespace {
bool SDLCALL OnAppEvent(void*, SDL_Event* event) {
    switch (event->type) {
    case SDL_EVENT_WILL_ENTER_BACKGROUND:
    case SDL_EVENT_TERMINATING:
        // SDL calls watchers as the event is sent, here from UIKit's scene callbacks on the main
        // thread, so the copies are stored before tvOS suspends the app.
        TvosPersistence::Flush();
        std::fprintf(stderr, "[tvos] persistence: flushed (%s)\n",
                     event->type == SDL_EVENT_TERMINATING ? "terminating" : "leaving the screen");
        break;
    default:
        break;
    }
    return true;
}
} // namespace

void WatchAppLifecycle() noexcept {
    SDL_AddEventWatch(OnAppEvent, nullptr);
    std::thread([] {
        for (;;) {
            std::this_thread::sleep_for(std::chrono::seconds(30));
            TvosPersistence::KeepChangedSettings();
        }
    }).detach();
}

} // namespace TvosPlatform
