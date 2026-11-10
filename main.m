//
//  iPhoneMirror touchd — TrollStore HID 注入守护
//
//  在 app 自身进程内用 IOHIDEventSystemClient 派发系统级触摸事件，
//  并实现与 WebDriverAgent 相同的 HTTP 协议，供 PC 侧 bridge 直接复用。
//
//  需要 entitlement: com.apple.private.hid.client.event-dispatch
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <mach/mach_time.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <sys/socket.h>
#include <unistd.h>

#pragma mark - IOKit 私有接口

static void TDLog(NSString *fmt, ...);

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef double IOHIDFloat;
typedef uint64_t AbsoluteTime;

// 这些是 IOKit 私有符号，SDK 的 tbd 里未必导出，因此运行时 dlsym 解析。
typedef IOHIDEventSystemClientRef (*FnClientCreate)(CFAllocatorRef);
typedef void (*FnDispatch)(IOHIDEventSystemClientRef, IOHIDEventRef);
typedef IOHIDEventRef (*FnCreateDigitizerEvent)(
    CFAllocatorRef, AbsoluteTime, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
    IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, bool, bool, uint32_t);
typedef IOHIDEventRef (*FnCreateFingerEvent)(
    CFAllocatorRef, AbsoluteTime, uint32_t, uint32_t, uint32_t,
    IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, bool, bool);
typedef void (*FnAppendEvent)(IOHIDEventRef, IOHIDEventRef);

static FnClientCreate pClientCreate = NULL;
static FnDispatch pDispatch = NULL;
static FnCreateDigitizerEvent pCreateDigitizer = NULL;
static FnCreateFingerEvent pCreateFinger = NULL;
static FnAppendEvent pAppend = NULL;

static BOOL TDLoadIOKit(void) {
    void *handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!handle) handle = dlopen("/System/Library/PrivateFrameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!handle) {
        TDLog(@"dlopen IOKit failed: %s", dlerror());
        return NO;
    }
    pClientCreate = (FnClientCreate)dlsym(handle, "IOHIDEventSystemClientCreate");
    pDispatch = (FnDispatch)dlsym(handle, "IOHIDEventSystemClientDispatchEvent");
    pCreateDigitizer = (FnCreateDigitizerEvent)dlsym(handle, "IOHIDEventCreateDigitizerEvent");
    pCreateFinger = (FnCreateFingerEvent)dlsym(handle, "IOHIDEventCreateDigitizerFingerEvent");
    pAppend = (FnAppendEvent)dlsym(handle, "IOHIDEventAppendEvent");
    TDLog(@"symbols create=%p dispatch=%p hand=%p finger=%p append=%p",
          pClientCreate, pDispatch, pCreateDigitizer, pCreateFinger, pAppend);
    return pClientCreate && pDispatch && pCreateDigitizer && pCreateFinger && pAppend;
}

enum {
    kTransducerHand = 3,
    kTransducerFinger = 2,
    kDigitizerEventRange = 0x01,
    kDigitizerEventTouch = 0x02,
    kDigitizerEventPosition = 0x04,
    kDigitizerEventStop = 0x08,
    kDigitizerEventIdentity = 0x20,
};

#pragma mark - 日志

static NSMutableArray<NSString *> *gLogLines;
static pthread_mutex_t gLogLock = PTHREAD_MUTEX_INITIALIZER;

static void TDLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *stamped = [NSString stringWithFormat:@"%.3f %@",
                         [NSDate date].timeIntervalSince1970, line];
    pthread_mutex_lock(&gLogLock);
    [gLogLines addObject:stamped];
    while (gLogLines.count > 300) [gLogLines removeObjectAtIndex:0];
    pthread_mutex_unlock(&gLogLock);
    NSLog(@"[touchd] %@", line);
}

#pragma mark - 触摸引擎

static IOHIDEventSystemClientRef gClient = NULL;
static pthread_mutex_t gTouchLock = PTHREAD_MUTEX_INITIALIZER;

static AbsoluteTime TDNow(void) {
    return (AbsoluteTime)(mach_absolute_time());
}

static void TDEnsureClient(void) {
    if (gClient == NULL && pClientCreate != NULL) {
        gClient = pClientCreate(kCFAllocatorDefault);
        TDLog(@"IOHIDEventSystemClientCreate -> %p", gClient);
    }
}

// phase: 1=began 2=moved 3=ended
static void TDSendTouch(int phase, double x, double y) {
    if (pCreateDigitizer == NULL || pCreateFinger == NULL || pAppend == NULL || pDispatch == NULL) {
        TDLog(@"touch skipped: IOKit symbols unavailable");
        return;
    }
    if (gClient == NULL) TDEnsureClient();
    if (gClient == NULL) return;

    pthread_mutex_lock(&gTouchLock);
    AbsoluteTime ts = TDNow();
    uint32_t mask = kDigitizerEventPosition;
    bool range = true, touch = true;
    if (phase == 1) mask |= kDigitizerEventRange | kDigitizerEventTouch;
    else if (phase == 3) { range = false; touch = false; mask |= kDigitizerEventStop; }

    IOHIDEventRef hand = pCreateDigitizer(
        kCFAllocatorDefault, ts, kTransducerHand, 0, 1, 0, 0,
        0, 0, 0, 0, 0, true, true, 0);
    IOHIDEventRef finger = pCreateFinger(
        kCFAllocatorDefault, ts, 0, 2, mask, x, y, 0, 0, 0, range, touch);
    if (hand != NULL && finger != NULL) {
        pAppend(hand, finger);
        pDispatch(gClient, hand);
    } else {
        TDLog(@"event create failed hand=%p finger=%p", hand, finger);
    }
    if (finger) CFRelease(finger);
    if (hand) CFRelease(hand);
    pthread_mutex_unlock(&gTouchLock);
}

#pragma mark - HTTP 服务

static int gListenFD = -1;
static NSString *gSessionId = nil;
static CGSize gPlane = {0, 0};
static int gGestureCount = 0;

static CGSize TDPlane(void) {
    if (gPlane.width > 0 && gPlane.height > 0) return gPlane;
    CGRect bounds = [UIScreen mainScreen].bounds;
    gPlane = bounds.size;
    return gPlane;
}

static NSDictionary *TDStatusJSON(void) {
    CGSize plane = TDPlane();
    return @{@"value": @{
                 @"state": @"success",
                 @"ready": @YES,
                 @"build": @{@"version": @"touchd-1.0"},
                 @"device": [UIDevice currentDevice].model ?: @"iPad",
                 @"plane": [NSString stringWithFormat:@"%.0fx%.0f", plane.width, plane.height],
             }};
}

static NSData *TDJSONData(id obj) {
    return [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
}

static void TDSendResponse(int fd, int status, NSData *body) {
    NSString *reason = status == 200 ? @"OK" : (status == 404 ? @"Not Found" : @"Error");
    NSString *head = [NSString stringWithFormat:
        @"HTTP/1.1 %d %@\r\nContent-Type: application/json\r\n"
         "Content-Length: %lu\r\nConnection: keep-alive\r\n\r\n",
        status, reason, (unsigned long)body.length];
    NSMutableData *out = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    if (body) [out appendData:body];
    send(fd, out.bytes, out.length, 0);
}

// 把 W3C actions 翻译成 IOHID 触摸序列
static void TDRunActions(NSDictionary *payload) {
    NSArray *actions = payload[@"actions"];
    if (![actions isKindOfClass:[NSArray class]]) return;
    CGSize plane = TDPlane();
    double lastX = 0, lastY = 0;
    BOOL down = NO;

    for (NSDictionary *source in actions) {
        NSArray *steps = source[@"actions"];
        if (![steps isKindOfClass:[NSArray class]]) continue;
        for (NSDictionary *step in steps) {
            NSString *type = step[@"type"];
            if ([type isEqualToString:@"pointerMove"]) {
                double x = [step[@"x"] doubleValue];
                double y = [step[@"y"] doubleValue];
                lastX = x; lastY = y;
                if (down) TDSendTouch(2, x, y);
            } else if ([type isEqualToString:@"pointerDown"]) {
                down = YES;
                TDSendTouch(1, lastX, lastY);
            } else if ([type isEqualToString:@"pointerUp"]) {
                if (down) TDSendTouch(3, lastX, lastY);
                down = NO;
            } else if ([type isEqualToString:@"pause"]) {
                usleep((useconds_t)([step[@"duration"] doubleValue] * 1000));
            }
        }
    }
    if (down) TDSendTouch(3, lastX, lastY);
    gGestureCount++;
    if (gGestureCount <= 3 || gGestureCount % 10 == 0) {
        TDLog(@"gesture #%d at %.0f,%.0f plane %.0fx%.0f",
              gGestureCount, lastX, lastY, plane.width, plane.height);
    }
}

static void TDHandleConnection(int fd) {
    char buf[8192];
    NSMutableData *pending = [NSMutableData data];

    while (1) {
        // 读取完整请求头
        NSRange headerEnd = [pending rangeOfData:
            [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]
            options:0 range:NSMakeRange(0, pending.length)];
        while (headerEnd.location == NSNotFound) {
            ssize_t n = recv(fd, buf, sizeof(buf), 0);
            if (n <= 0) return;
            [pending appendBytes:buf length:(NSUInteger)n];
            if (pending.length > 1024 * 1024) return;
            headerEnd = [pending rangeOfData:
                [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]
                options:0 range:NSMakeRange(0, pending.length)];
        }

        NSData *headData = [pending subdataWithRange:NSMakeRange(0, headerEnd.location)];
        NSString *head = [[NSString alloc] initWithData:headData encoding:NSUTF8StringEncoding];
        NSUInteger bodyStart = headerEnd.location + 4;
        [pending replaceBytesInRange:NSMakeRange(0, bodyStart) withBytes:NULL length:0];

        NSArray *lines = [head componentsSeparatedByString:@"\r\n"];
        NSArray *requestLine = [lines.firstObject componentsSeparatedByString:@" "];
        if (requestLine.count < 2) return;
        NSString *method = requestLine[0];
        NSString *path = requestLine[1];

        NSUInteger contentLength = 0;
        for (NSString *line in lines) {
            if ([line.lowercaseString hasPrefix:@"content-length:"]) {
                contentLength = (NSUInteger)[line substringFromIndex:15].integerValue;
            }
        }
        while (pending.length < contentLength) {
            ssize_t n = recv(fd, buf, sizeof(buf), 0);
            if (n <= 0) return;
            [pending appendBytes:buf length:(NSUInteger)n];
        }
        NSData *bodyData = contentLength > 0
            ? [pending subdataWithRange:NSMakeRange(0, contentLength)] : nil;
        if (contentLength > 0) {
            [pending replaceBytesInRange:NSMakeRange(0, contentLength) withBytes:NULL length:0];
        }

        if ([path isEqualToString:@"/status"]) {
            TDSendResponse(fd, 200, TDJSONData(TDStatusJSON()));
        } else if ([path hasPrefix:@"/session/"] && [path hasSuffix:@"/actions"]) {
            NSDictionary *payload = bodyData
                ? [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil] : nil;
            TDRunActions(payload ?: @{});
            TDSendResponse(fd, 200, TDJSONData(@{@"value": [NSNull null],
                                                 @"sessionId": gSessionId ?: @""}));
        } else if ([path hasPrefix:@"/session/"] && [path hasSuffix:@"/window/size"]) {
            CGSize plane = TDPlane();
            TDSendResponse(fd, 200, TDJSONData(@{@"value": @{
                @"width": @(plane.width), @"height": @(plane.height)}}));
        } else if ([path isEqualToString:@"/session"] && [method isEqualToString:@"POST"]) {
            if (gSessionId == nil) gSessionId = [NSUUID UUID].UUIDString;
            TDSendResponse(fd, 200, TDJSONData(@{@"sessionId": gSessionId,
                                                 @"value": @{@"sessionId": gSessionId}}));
        } else if ([path isEqualToString:@"/log"]) {
            pthread_mutex_lock(&gLogLock);
            NSString *joined = [gLogLines componentsJoinedByString:@"\n"];
            pthread_mutex_unlock(&gLogLock);
            TDSendResponse(fd, 200, [joined dataUsingEncoding:NSUTF8StringEncoding]);
        } else {
            TDSendResponse(fd, 404, TDJSONData(@{@"value": @{@"error": @"unknown command",
                                                             @"message": path}}));
        }
    }
}

static void *TDConnThread(void *arg) {
    int fd = *(int *)arg;
    free(arg);
    TDHandleConnection(fd);
    close(fd);
    return NULL;
}

static void *TDAcceptLoop(void *arg) {
    while (1) {
        struct sockaddr_in addr;
        socklen_t len = sizeof(addr);
        int fd = accept(gListenFD, (struct sockaddr *)&addr, &len);
        if (fd < 0) {
            usleep(200000);
            continue;
        }
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        int *slot = malloc(sizeof(int));
        if (!slot) { close(fd); continue; }
        *slot = fd;
        pthread_t th;
        if (pthread_create(&th, NULL, TDConnThread, slot) != 0) {
            free(slot);
            close(fd);
            continue;
        }
        pthread_detach(th);
    }
    return NULL;
}

static BOOL TDStartServer(void) {
    gListenFD = socket(AF_INET, SOCK_STREAM, 0);
    if (gListenFD < 0) return NO;
    int one = 1;
    setsockopt(gListenFD, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(8100);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(gListenFD, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        TDLog(@"bind 8100 failed errno=%d", errno);
        return NO;
    }
    if (listen(gListenFD, 16) < 0) return NO;

    pthread_t th;
    pthread_create(&th, NULL, TDAcceptLoop, NULL);
    pthread_detach(th);
    TDLog(@"listening on 127.0.0.1:8100");
    return YES;
}

#pragma mark - 后台保活

static AVAudioPlayer *gSilencePlayer = nil;

static NSData *TDSilenceWav(void) {
    // 8kHz / 16bit / mono / 1s 静音
    uint32_t dataSize = 16000;
    NSMutableData *wav = [NSMutableData data];
    [wav appendBytes:"RIFF" length:4];
    uint32_t chunk = 36 + dataSize; [wav appendBytes:&chunk length:4];
    [wav appendBytes:"WAVEfmt " length:8];
    uint32_t fmtLen = 16; [wav appendBytes:&fmtLen length:4];
    uint16_t pcm = 1, channels = 1; [wav appendBytes:&pcm length:2];
    [wav appendBytes:&channels length:2];
    uint32_t rate = 8000; [wav appendBytes:&rate length:4];
    uint32_t byteRate = 16000; [wav appendBytes:&byteRate length:4];
    uint16_t align = 2, bits = 16; [wav appendBytes:&align length:2];
    [wav appendBytes:&bits length:2];
    [wav appendBytes:"data" length:4];
    [wav appendBytes:&dataSize length:4];
    [wav appendData:[NSMutableData dataWithLength:dataSize]];
    return wav;
}

static void TDStartKeepAlive(void) {
    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback error:&error];
    [session setActive:YES error:&error];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"td_silence.wav"];
    [TDSilenceWav() writeToFile:path atomically:YES];
    gSilencePlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:
                      [NSURL fileURLWithPath:path] error:&error];
    gSilencePlayer.numberOfLoops = -1;
    gSilencePlayer.volume = 0.01;
    [gSilencePlayer play];
    TDLog(@"keep-alive audio started (err=%@)", error.localizedDescription ?: @"none");
}

#pragma mark - App

@interface TDAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation TDAppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    gLogLines = [NSMutableArray array];
    TDLog(@"boot, bundle=%@", [NSBundle mainBundle].bundleIdentifier);
    BOOL symbolsReady = TDLoadIOKit();
    TDLog(@"IOKit symbols ready=%d", symbolsReady);
    TDEnsureClient();
    TDStartKeepAlive();
    TDStartServer();

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor systemBackgroundColor];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectInset(vc.view.bounds, 24, 24)];
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
    label.text = [NSString stringWithFormat:
        @"iPhoneMirror touchd\n\n"
         "HID client: %@\n"
         "HTTP: 127.0.0.1:8100\n"
         "Plane: %.0fx%.0f\n\n"
         "此界面可最小化，后台继续工作",
        gClient ? @"ready" : @"failed",
        TDPlane().width, TDPlane().height];
    [vc.view addSubview:label];

    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(TDAppDelegate.class));
    }
}
