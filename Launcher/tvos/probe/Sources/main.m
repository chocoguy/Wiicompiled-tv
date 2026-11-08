// WiiCompiled tvOS feasibility probe (M0 of docs/tvos-porting-plan.md).
// Runs at launch, prints every result to stderr as "PROBE <line>" (devicectl --console relays it),
// writes Library/Caches/tvprobe-report.txt and shows the report on screen. PROBE_EXIT=1 in the
// launch environment quits when done, so run-probe.sh can capture a whole run unattended.
//
// Phases, in the order the real runtime would meet them:
//   pre-uikit   before UIApplicationMain: VA layout and fixed 4 GiB base availability
//   launch      didFinishLaunching, before any Metal: alias tests, capacity, signals, storage, CPU
//   metal       with the preferred guest base held: Metal device, buffers, a GPU blit, MetalFX,
//               then the layout and base availability again after Metal has mapped its memory
#import <AVKit/AVKit.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <UIKit/UIKit.h>
#include <os/proc.h>
#include <pthread.h>
#include <stdarg.h>
#include <sys/sysctl.h>

#include "probe.h"

static NSMutableString* g_report;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static UILabel* g_label;
static size_t g_mainStack;   // measured in main(): pthread_main_thread_np is not in the tvOS SDK

static void* stack_of_self(void* out) {
    *(size_t*)out = pthread_get_stacksize_np(pthread_self());
    return NULL;
}
static size_t default_thread_stack(void) {
    size_t size = 0;
    pthread_t t;
    if (pthread_create(&t, NULL, stack_of_self, &size) == 0) pthread_join(t, NULL);
    return size;
}

void probe_log(const char* fmt, ...) {
    char line[2048];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    fprintf(stderr, "PROBE %s\n", line);
    pthread_mutex_lock(&g_lock);
    [g_report appendFormat:@"%s\n", line];
    pthread_mutex_unlock(&g_lock);
}

static NSString* caches_dir(void) {
    return NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
}

// ---- System ----

static void probe_system(void) {
    char machine[64] = "";
    size_t len = sizeof machine;
    sysctlbyname("hw.machine", machine, &len, NULL, 0);
    NSProcessInfo* pi = NSProcessInfo.processInfo;
    NSString* variant = [NSBundle.mainBundle objectForInfoDictionaryKey:@"ProbeVariant"] ?: @"?";
    probe_log("[system] variant=%s model=%s os=\"%s\" cores=%lu physical_memory=%.0f MiB available_memory=%.0f MiB thermal=%ld",
              variant.UTF8String, machine, pi.operatingSystemVersionString.UTF8String, (unsigned long)pi.activeProcessorCount,
              (double)pi.physicalMemory / (1 << 20), (double)os_proc_available_memory() / (1 << 20), (long)pi.thermalState);
    probe_log("[system] main thread stack %zu KiB; a default secondary pthread gets %zu KiB", g_mainStack >> 10,
              default_thread_stack() >> 10);

    // CPU features, to compare against the Mac that builds with -mcpu=native today.
    static const char* features[] = {"FEAT_LSE", "FEAT_LSE2", "FEAT_FP16", "FEAT_DotProd", "FEAT_FHM", "FEAT_RDM",
                                     "FEAT_JSCVT", "FEAT_FCMA", "FEAT_LRCPC", "FEAT_LRCPC2", "FEAT_FRINTTS", "FEAT_BF16",
                                     "FEAT_I8MM", "FEAT_SHA3", "FEAT_SHA512", "FEAT_PAuth", "FEAT_BTI", "FEAT_SME",
                                     "FEAT_SME2", "FEAT_CSSC", "FEAT_HBC", "FEAT_FPAC", "FEAT_AFP", "FEAT_RPRES",
                                     "FEAT_WFxT", "FEAT_ECV", "FEAT_SB", "FEAT_SSBS", "FEAT_DPB", "FEAT_DPB2"};
    NSMutableArray* yes = [NSMutableArray array];
    NSMutableArray* no = [NSMutableArray array];
    for (size_t i = 0; i < sizeof features / sizeof features[0]; ++i) {
        char name[96];
        snprintf(name, sizeof name, "hw.optional.arm.%s", features[i]);
        int v = 0;
        size_t vl = sizeof v;
        if (sysctlbyname(name, &v, &vl, NULL, 0) == 0 && v) [yes addObject:@(features[i])];
        else [no addObject:@(features[i])];
    }
    probe_log("[cpu] present: %s", [yes componentsJoinedByString:@" "].UTF8String);
    probe_log("[cpu] absent: %s", [no componentsJoinedByString:@" "].UTF8String);
}

// ---- Storage ----

static void probe_storage(void) {
    NSFileManager* fm = NSFileManager.defaultManager;
    NSData* blob = [NSMutableData dataWithLength:1 << 20];
    for (NSString* rel in @[ @"Documents", @"Library/Application Support", @"Library/Caches", @"Library/Preferences",
                             @"Library", @"tmp" ]) {
        NSString* dir = [NSHomeDirectory() stringByAppendingPathComponent:rel];
        NSError* err = nil;
        BOOL existed = [fm fileExistsAtPath:dir];
        BOOL made = existed || [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&err];
        NSString* file = [dir stringByAppendingPathComponent:@"probe-write-test.bin"];
        NSError* werr = nil;
        BOOL wrote = made && [blob writeToFile:file options:NSDataWritingAtomic error:&werr];
        BOOL readBack = wrote && [[NSData dataWithContentsOfFile:file] isEqualToData:blob];
        [fm removeItemAtPath:file error:nil];
        probe_log("[storage] %-28s exists=%d create=%s write=%s read=%s%s%s", rel.UTF8String, existed,
                  made ? "ok" : "FAILED", wrote ? "ok" : "FAILED", readBack ? "ok" : "-",
                  err ? " create-error: " : (werr ? " write-error: " : ""),
                  err ? err.localizedDescription.UTF8String : (werr ? werr.localizedDescription.UTF8String : ""));
    }
    // TVPort keeps saves in the preferences (they survive cache purges); NSUserDefaults aborts the
    // app near 1 MB in total, so this stays at 512 KiB.
    NSUserDefaults* d = NSUserDefaults.standardUserDefaults;
    NSMutableData* pref = [NSMutableData dataWithLength:512 << 10];
    memset(pref.mutableBytes, 0x5A, pref.length);
    [d setObject:pref forKey:@"probe.blob"];
    BOOL synced = [d synchronize];
    BOOL same = [[d dataForKey:@"probe.blob"] isEqualToData:pref];
    [d removeObjectForKey:@"probe.blob"];
    [d synchronize];
    probe_log("[storage] NSUserDefaults 512 KiB blob: synchronize=%s read-back=%s", synced ? "ok" : "FAILED",
              same ? "ok" : "FAILED");
}

// ---- Metal ----

static void probe_metal(uint64_t heldBase) {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) {
        probe_log("[metal] MTLCreateSystemDefaultDevice returned nil");
        return;
    }
    NSMutableArray* families = [NSMutableArray array];
    static const struct { long value; const char* name; } kFamilies[] = {
        {1001, "Apple1"}, {1002, "Apple2"}, {1003, "Apple3"}, {1004, "Apple4"}, {1005, "Apple5"}, {1006, "Apple6"},
        {1007, "Apple7"}, {1008, "Apple8"}, {1009, "Apple9"}, {1010, "Apple10"}, {2002, "Mac2"}, {3001, "Common1"},
        {3002, "Common2"}, {3003, "Common3"}, {5001, "Metal3"}, {5002, "Metal4"},
    };
    for (size_t i = 0; i < sizeof kFamilies / sizeof kFamilies[0]; ++i) {
        if ([dev supportsFamily:(MTLGPUFamily)kFamilies[i].value]) [families addObject:@(kFamilies[i].name)];
    }
    probe_log("[metal] device \"%s\" families: %s", dev.name.UTF8String, [families componentsJoinedByString:@" "].UTF8String);
    probe_log("[metal] BC=%d unified=%d recommendedMaxWorkingSetSize=%.0f MiB maxBufferLength=%.0f MiB "
              "maxThreadgroupMemory=%lu argumentBuffersTier=%ld",
              dev.supportsBCTextureCompression, dev.hasUnifiedMemory, (double)dev.recommendedMaxWorkingSetSize / (1 << 20),
              (double)dev.maxBufferLength / (1 << 20), (unsigned long)dev.maxThreadgroupMemoryLength,
              (long)dev.argumentBuffersSupport);
    if (@available(tvOS 27.1, *)) {
        probe_log("[metal] MetalFX spatial=%d temporal=%d", [MTLFXSpatialScalerDescriptor supportsDevice:dev],
                  [MTLFXTemporalScalerDescriptor supportsDevice:dev]);
    } else {
        probe_log("[metal] MetalFX: needs tvOS 27.1");
    }

    // 1 GiB of shared buffers while the guest space is held: where do they land, and does the GPU work?
    NSMutableArray<id<MTLBuffer>>* buffers = [NSMutableArray array];
    const NSUInteger chunk = 32u << 20;
    uint64_t lowest = UINT64_MAX, highest = 0, lowestGpu = UINT64_MAX, highestGpu = 0;
    int overlaps = 0;
    for (int i = 0; i < 32; ++i) {
        id<MTLBuffer> b = [dev newBufferWithLength:chunk options:MTLResourceStorageModeShared];
        if (!b) break;
        [buffers addObject:b];
        uint64_t cpu = (uint64_t)(uintptr_t)b.contents, gpu = b.gpuAddress;
        if (cpu < lowest) lowest = cpu;
        if (cpu + chunk > highest) highest = cpu + chunk;
        if (gpu < lowestGpu) lowestGpu = gpu;
        if (gpu + chunk > highestGpu) highestGpu = gpu + chunk;
        if (heldBase && cpu < heldBase + (4ull << 30) && cpu + chunk > heldBase) ++overlaps;
    }
    probe_log("[metal] %lu x 32 MiB shared buffers: CPU 0x%llx-0x%llx, GPU 0x%llx-0x%llx, inside held guest space: %d",
              (unsigned long)buffers.count, lowest, highest, lowestGpu, highestGpu, overlaps);

    id<MTLCommandQueue> queue = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    for (id<MTLBuffer> b in buffers) [blit fillBuffer:b range:NSMakeRange(0, b.length) value:0x7E];
    [blit endEncoding];
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    [cb commit];
    [cb waitUntilCompleted];
    double ms = (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6;
    int good = 0;
    for (id<MTLBuffer> b in buffers) {
        const uint8_t* p = b.contents;
        if (p[0] == 0x7E && p[b.length / 2] == 0x7E && p[b.length - 1] == 0x7E) ++good;
    }
    probe_log("[metal] GPU blit fill of 1 GiB: status=%ld error=%s, %.1f ms, %d/%lu buffers verified", (long)cb.status,
              cb.error ? cb.error.localizedDescription.UTF8String : "none", ms, good, (unsigned long)buffers.count);

    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                 width:4096
                                                                                height:4096
                                                                             mipmapped:YES];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    probe_log("[metal] 4096x4096 RGBA8 mipmapped private texture: %s", [dev newTextureWithDescriptor:td] ? "ok" : "FAILED");
}

// ---- Display ----

static void probe_display(UIWindow* window) {
    UIScreen* s = window.windowScene.screen;
    probe_log("[display] nativeBounds=%.0fx%.0f scale=%.1f maximumFramesPerSecond=%ld", s.nativeBounds.size.width,
              s.nativeBounds.size.height, s.nativeScale, (long)s.maximumFramesPerSecond);
    AVDisplayManager* dm = window.avDisplayManager;
    probe_log("[display] AVDisplayManager matching enabled=%d switching=%d", dm.displayCriteriaMatchingEnabled,
              dm.displayModeSwitchInProgress);
}

// ---- Flow ----

static void finish(void) {
    probe_log("[done] report written to Library/Caches/tvprobe-report.txt");
    NSString* text;
    pthread_mutex_lock(&g_lock);
    text = [g_report copy];
    pthread_mutex_unlock(&g_lock);
    [text writeToFile:[caches_dir() stringByAppendingPathComponent:@"tvprobe-report.txt"] atomically:YES
             encoding:NSUTF8StringEncoding error:nil];
    g_label.text = text;
    fprintf(stderr, "PROBE-END\n");
    if (getenv("PROBE_EXIT")) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ exit(0); });
    }
}

@interface ProbeSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(strong, nonatomic) UIWindow* window;
@end

@implementation ProbeSceneDelegate
- (void)scene:(UIScene*)scene willConnectToSession:(UISceneSession*)session options:(UISceneConnectionOptions*)options {
    (void)session;
    (void)options;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];
    UIViewController* vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.blackColor;
    UILabel* label = [[UILabel alloc] initWithFrame:CGRectInset(vc.view.bounds, 60, 40)];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    label.numberOfLines = 0;
    label.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    label.textColor = UIColor.whiteColor;
    label.text = @"WiiCompiled tvOS probe: running…";
    [vc.view addSubview:label];
    g_label = label;
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];

    UIWindow* window = self.window;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        uint64_t base = probe_vm_preferred_base();
        int held = base && probe_vm_hold(base);
        probe_log("[metal] holding the preferred guest space 0x%llx while Metal starts: %s", (unsigned long long)base,
                  held ? "yes" : "no");
        probe_metal(held ? base : 0);
        probe_vm_layout("after-metal");
        probe_vm_fixed_bases("after-metal", 0, NULL);
        if (held) {
            probe_log("[metal] (the held base 0x%llx shows as taken above)", (unsigned long long)base);
            probe_vm_release(base);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            probe_display(window);
            finish();
        });
    });
}
@end

@interface ProbeAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation ProbeAppDelegate
- (BOOL)application:(UIApplication*)app didFinishLaunchingWithOptions:(NSDictionary*)options {
    (void)app;
    (void)options;
    probe_system();
    probe_vm_layout("launch");
    probe_vm_reserve_capacity();
    probe_vm_fixed_bases("launch", 1, caches_dir().fileSystemRepresentation);
    probe_signals();
    probe_storage();
    return YES;
}

- (UISceneConfiguration*)application:(UIApplication*)app
    configurationForConnectingSceneSession:(UISceneSession*)session
                                   options:(UISceneConnectionOptions*)options {
    (void)app;
    (void)options;
    UISceneConfiguration* c = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
    c.delegateClass = ProbeSceneDelegate.class;
    return c;
}
@end

int main(int argc, char* argv[]) {
    setvbuf(stderr, NULL, _IONBF, 0);
    g_mainStack = pthread_get_stacksize_np(pthread_self());
    g_report = [NSMutableString string];
    probe_log("[start] WiiCompiled tvOS probe");
    probe_vm_layout("pre-uikit");
    probe_vm_fixed_bases("pre-uikit", 0, NULL);
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(ProbeAppDelegate.class));
    }
}
