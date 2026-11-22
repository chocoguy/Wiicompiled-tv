#pragma once

// tvOS-only platform services (src/platform/tvos/tvos_platform.mm).
struct SDL_Window;

namespace TvosPlatform {

// Asks the TV for a display mode at the game's frame rate. tvOS honors it only when the user has
// Match Frame Rate on (Settings > Video and Audio); otherwise the TV keeps its current mode.
void RequestDisplayRefreshRate(SDL_Window* window, float refreshRate) noexcept;

// True while another app's audio (music, a video) asks secondary audio such as game music to go
// quiet: AVAudioSession.secondaryAudioShouldBeSilencedHint. Drives the music ducking.
bool OtherAudioWantsSilence() noexcept;

// NSProcessInfo.thermalState: 0 nominal, 1 fair, 2 serious (tvOS lowers clocks), 3 critical.
int ThermalState() noexcept;

// Once SDL is running: store every pending save and settings copy when the app leaves the screen
// (tvOS may end a background app without warning), and check the settings files every 30 s.
void WatchAppLifecycle() noexcept;

} // namespace TvosPlatform
