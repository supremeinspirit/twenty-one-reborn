
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <notify.h>
#import <CommonCrypto/CommonDigest.h>
#import "TJPrefsStore.h"
#import "TJModelUtils.h"
#import "TJMotionArtworkResolver.h"
#import "TJCanvasShare.h"

@interface MRUArtworkView : UIControl
@end

@interface TJLMBackgroundView : UIView
@end
@interface TJLMBackgroundVC : UIViewController
@end

static void *kTJLMMotionViewKey = &kTJLMMotionViewKey;
static NSString *const kTJLMBackgroundViewClassName = @"MediaRemoteUI.CoverSheetBackgroundView";

static BOOL sTJLMMusicPlaying = YES;
static BOOL sTJLMScreenBlanked = NO;
static NSHashTable *sTJLMMotionViews = nil;

static BOOL tj_lmEnabled(void) {
    return prefBool(@"enabled", YES) && prefBool(@"lockScreenMotionArtwork", YES);
}

static id tj_lmKVC(id obj, NSString *key) {
    if (!obj) return nil;
    @try { return [obj valueForKeyPath:key]; } @catch (__unused id e) { return nil; }
}

static NSString *tj_lmString(id v) {
    if ([v isKindOfClass:[NSString class]] && [v length] > 0) return v;
    if ([v isKindOfClass:[NSNumber class]] && [v longLongValue] > 0) return [v stringValue];
    return nil;
}

#pragma mark - Telling SpringBoard (clock layout)

static NSString *const kTJLMFullscreenNotification = @"com.pisknk.twentyone.lockmotion.fullscreen";

static void tj_lmPublishFullscreen(BOOL on) {
    static int token = -1;
    static int last = -1;
    if (token == -1 && notify_register_check(kTJLMFullscreenNotification.UTF8String, &token) != NOTIFY_STATUS_OK) {
        token = -1;
        return;
    }
    if (last == (int)on) return;
    last = on;
    notify_set_state(token, on ? 1 : 0);
    notify_post(kTJLMFullscreenNotification.UTF8String);
}

static void tj_lmRecomputeFullscreen(void);

#pragma mark - Local video cache

static NSString *tj_lmCacheDir(void);

// A short trace of the third-party (Spotify) path, kept next to the video cache.
static void tj_lmLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void tj_lmLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.pisknk.twentyone.lockmotion.log", DISPATCH_QUEUE_SERIAL); });
    NSDate *now = [NSDate date];
    dispatch_async(q, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = tj_lmCacheDir();
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *path = [dir stringByAppendingPathComponent:@"lockmotion.log"];
        if ([[fm attributesOfItemAtPath:path error:nil] fileSize] > 128 * 1024) [fm removeItemAtPath:path error:nil];
        if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!h) return;
        @try {
            [h seekToEndOfFile];
            [h writeData:[[NSString stringWithFormat:@"%.3f %@\n", now.timeIntervalSince1970, msg] dataUsingEncoding:NSUTF8StringEncoding]];
        } @catch (__unused id e) {}
        [h closeFile];
    });
}


static NSString *tj_lmCacheDir(void) {
    NSString *base = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    return [base stringByAppendingPathComponent:@"TwentyOneMotion"];
}

static NSString *tj_lmCachePathForURL(NSURL *url) {
    NSData *d = [url.absoluteString dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(d.bytes, (CC_LONG)d.length, digest);
    NSMutableString *hex = [NSMutableString string];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return [tj_lmCacheDir() stringByAppendingPathComponent:[hex stringByAppendingPathExtension:@"mp4"]];
}

static void tj_lmTrimCache(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSURL *> *files = [fm contentsOfDirectoryAtURL:[NSURL fileURLWithPath:tj_lmCacheDir()]
                                includingPropertiesForKeys:@[NSURLContentModificationDateKey] options:0 error:nil];
    if (files.count <= 12) return;
    files = [files sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSDate *da = nil, *db = nil;
        [a getResourceValue:&da forKey:NSURLContentModificationDateKey error:nil];
        [b getResourceValue:&db forKey:NSURLContentModificationDateKey error:nil];
        return [db compare:da];
    }];
    for (NSUInteger i = 12; i < files.count; i++) [fm removeItemAtURL:files[i] error:nil];
}

static NSData *tj_lmFetchSync(NSURL *url, NSError **outErr) {
    __block NSData *result = nil;
    __block NSError *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 15.0;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSInteger st = [r isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)r).statusCode : 0;
        if (!e && st == 200) result = d;
        else err = e ?: [NSError errorWithDomain:@"TJLockMotion" code:st userInfo:nil];
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)));
    if (outErr) *outErr = err;
    return result;
}

static NSString *tj_lmAttr(NSString *line, NSString *name) {
    NSRange r = [line rangeOfString:[name stringByAppendingString:@"=\""]];
    if (r.location == NSNotFound) return nil;
    NSUInteger start = NSMaxRange(r);
    NSRange end = [line rangeOfString:@"\"" options:0 range:NSMakeRange(start, line.length - start)];
    return end.location == NSNotFound ? nil : [line substringWithRange:NSMakeRange(start, end.location - start)];
}

static NSURL *tj_lmDownloadFileSync(NSURL *fileURL) {
    NSError *err = nil;
    NSData *data = tj_lmFetchSync(fileURL, &err);
    if (data.length < 1024 || data.length > 80ull * 1024 * 1024) return nil;
    NSString *finalPath = tj_lmCachePathForURL(fileURL);
    [[NSFileManager defaultManager] createDirectoryAtPath:tj_lmCacheDir() withIntermediateDirectories:YES attributes:nil error:nil];
    if (![data writeToFile:finalPath atomically:YES]) return nil;
    tj_lmTrimCache();
    return [NSURL fileURLWithPath:finalPath];
}

static NSURL *tj_lmDownloadVariantSync(NSURL *playlistURL) {
    if ([playlistURL.pathExtension.lowercaseString isEqualToString:@"mp4"]) return tj_lmDownloadFileSync(playlistURL);
    NSError *err = nil;
    NSData *pd = tj_lmFetchSync(playlistURL, &err);
    NSString *playlist = pd ? [[NSString alloc] initWithData:pd encoding:NSUTF8StringEncoding] : nil;
    if (!playlist) return nil;
    if ([playlist containsString:@"#EXT-X-STREAM-INF"]) return nil;
    if ([playlist containsString:@"#EXT-X-KEY"] && ![playlist containsString:@"METHOD=NONE"]) return nil;

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    BOOL byteRanges = [playlist containsString:@"#EXT-X-BYTERANGE"] || [playlist containsString:@"BYTERANGE="];
    for (NSString *raw in [playlist componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (line.length == 0) continue;
        if ([line hasPrefix:@"#EXT-X-MAP"]) {
            NSString *uri = tj_lmAttr(line, @"URI");
            if (uri) [parts addObject:uri];
        } else if (![line hasPrefix:@"#"]) {
            [parts addObject:line];
        }
    }
    if (parts.count == 0) return nil;
    for (NSString *part in parts) {
        if ([part.lowercaseString hasSuffix:@".ts"]) return nil;
    }
    if (byteRanges) {
        NSSet *unique = [NSSet setWithArray:parts];
        if (unique.count != 1) return nil;
        parts = [NSMutableArray arrayWithObject:parts.firstObject];
    }

    NSString *finalPath = tj_lmCachePathForURL(playlistURL);
    NSString *tmpPath = [finalPath stringByAppendingString:@".part"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:tj_lmCacheDir() withIntermediateDirectories:YES attributes:nil error:nil];
    [fm removeItemAtPath:tmpPath error:nil];
    if (![fm createFileAtPath:tmpPath contents:nil attributes:nil]) return nil;
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:tmpPath];
    unsigned long long total = 0;
    for (NSString *part in parts) {
        NSURL *u = [NSURL URLWithString:part relativeToURL:playlistURL].absoluteURL;
        NSData *d = u ? tj_lmFetchSync(u, &err) : nil;
        if (!d) { [fh closeFile]; [fm removeItemAtPath:tmpPath error:nil]; return nil; }
        [fh writeData:d];
        total += d.length;
        if (total > 80ull * 1024 * 1024) { [fh closeFile]; [fm removeItemAtPath:tmpPath error:nil]; return nil; }
    }
    [fh closeFile];
    [fm removeItemAtPath:finalPath error:nil];
    if (![fm moveItemAtPath:tmpPath toPath:finalPath error:&err]) return nil;
    tj_lmTrimCache();
    return [NSURL fileURLWithPath:finalPath];
}

static dispatch_queue_t tj_lmCacheQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.pisknk.twentyone.lockmotion.cache", DISPATCH_QUEUE_SERIAL); });
    return q;
}

static void tj_lmLocalVideo(NSURL *remoteURL, void (^completion)(NSURL *localURL)) {
    NSString *path = tj_lmCachePathForURL(remoteURL);
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate: [NSDate date]} ofItemAtPath:path error:nil];
        completion([NSURL fileURLWithPath:path]);
        return;
    }
    dispatch_async(tj_lmCacheQueue(), ^{
        NSURL *local = [[NSFileManager defaultManager] fileExistsAtPath:path] ? [NSURL fileURLWithPath:path] : nil;
        if (!local) {
            @try { local = tj_lmDownloadVariantSync(remoteURL); } @catch (__unused id e) { local = nil; }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(local); });
    });
}

#pragma mark - Motion view

static void tj_lmConfigureAudioSessionOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient
                                         withOptions:AVAudioSessionCategoryOptionMixWithOthers
                                               error:nil];
    });
}


@interface TJLockMotionView : UIView
@property (nonatomic, strong) AVQueuePlayer *player;
@property (nonatomic, strong) AVPlayerLooper *looper;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, strong) NSURL *videoURL;
@property (nonatomic, copy) NSString *trackKey;
@property (nonatomic, assign) BOOL appeared;
@property (nonatomic, assign) BOOL observing;
@property (nonatomic, assign) CFTimeInterval lastInfoQuery;
@property (nonatomic, assign) CFTimeInterval retryAfter;
@property (nonatomic, weak) UIView *coverView;
@property (nonatomic, assign) BOOL showingVideo;
@property (nonatomic, assign) BOOL coverHidden;
@property (nonatomic, strong) CAGradientLayer *fadeMask;
@property (nonatomic, assign) BOOL artworkVisible;
@property (nonatomic, assign) BOOL handledReady;
- (void)applyCoverVisibilityAnimated:(BOOL)animated;
- (void)loadVideoURL:(NSURL *)url;
- (void)startPlayerWithURL:(NSURL *)playURL remote:(NSURL *)url;
- (void)teardown;
- (void)updatePlayback;
@end

@implementation TJLockMotionView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        self.clipsToBounds = YES;
        self.appeared = YES;
        self.artworkVisible = YES;
        self.alpha = 0.0f;
        CAGradientLayer *mask = [CAGradientLayer layer];
        mask.colors = @[(id)[UIColor whiteColor].CGColor, (id)[UIColor whiteColor].CGColor,
                        (id)[[UIColor whiteColor] colorWithAlphaComponent:0.5f].CGColor, (id)[UIColor clearColor].CGColor];
        mask.locations = @[@0.0f, @0.72f, @0.90f, @1.0f];
        mask.startPoint = CGPointMake(0.5f, 0.0f);
        mask.endPoint = CGPointMake(0.5f, 1.0f);
        mask.frame = self.bounds;
        self.layer.mask = mask;
        self.fadeMask = mask;
    }
    return self;
}

- (void)loadVideoURL:(NSURL *)url {
    if (!url) { [self teardown]; return; }
    if ([self.videoURL isEqual:url]) { [self updatePlayback]; return; }
    [self teardown];
    self.videoURL = url;
    tj_lmConfigureAudioSessionOnce();

    __weak TJLockMotionView *weakSelf = self;
    tj_lmLocalVideo(url, ^(NSURL *localURL) {
        TJLockMotionView *s = weakSelf;
        if (!s || ![s.videoURL isEqual:url] || s.player) return;
        [s startPlayerWithURL:localURL ?: url remote:url];
    });
}

- (void)startPlayerWithURL:(NSURL *)playURL remote:(NSURL *)url {
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:playURL];
    if ([item respondsToSelector:@selector(setPreferredMaximumResolution:)])
        item.preferredMaximumResolution = CGSizeMake(1080.0f, 1080.0f);
    AVQueuePlayer *player = [AVQueuePlayer queuePlayerWithItems:@[]];
    AVPlayerLooper *looper = nil;
    @try { looper = [AVPlayerLooper playerLooperWithPlayer:player templateItem:item]; } @catch (__unused id e) {}
    if (!looper) [player insertItem:item afterItem:nil];
    player.muted = YES;
    player.volume = 0.0f;
    player.preventsDisplaySleepDuringVideoPlayback = NO;
    player.automaticallyWaitsToMinimizeStalling = NO;

    AVPlayerLayer *layer = [AVPlayerLayer playerLayerWithPlayer:player];
    layer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    layer.frame = self.bounds;
    layer.opacity = 0.0f;
    [self.layer addSublayer:layer];

    self.player = player;
    self.looper = looper;
    self.playerLayer = layer;

    @try {
        [layer addObserver:self forKeyPath:@"readyForDisplay" options:NSKeyValueObservingOptionNew context:NULL];
        self.observing = YES;
    } @catch (__unused id e) {}

    self.handledReady = NO;
    [self updatePlayback];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (object == self.playerLayer && [keyPath isEqualToString:@"readyForDisplay"] && self.playerLayer.isReadyForDisplay) {
            if (self.handledReady) return;
            self.handledReady = YES;
            self.playerLayer.opacity = 1.0f;
            self.showingVideo = YES;
            [self applyCoverVisibilityAnimated:YES];
            [self updatePlayback];
        }
    });
}

- (void)teardown {
    if (self.observing) {
        @try { [self.playerLayer removeObserver:self forKeyPath:@"readyForDisplay"]; } @catch (__unused id e) {}
        self.observing = NO;
    }
    [self.looper disableLooping];
    [self.player pause];
    [self.player removeAllItems];
    [self.playerLayer removeFromSuperlayer];
    self.looper = nil;
    self.player = nil;
    self.playerLayer = nil;
    self.videoURL = nil;
    if (self.showingVideo) {
        self.showingVideo = NO;
        [self applyCoverVisibilityAnimated:YES];
    }
}

- (void)applyCoverVisibilityAnimated:(BOOL)animated {
    UIView *cover = self.coverView;
    UIView *image = tj_lmKVC(cover, @"artworkImageView");
    UIView *shadow = tj_lmKVC(cover, @"artworkShadowView");
    BOOL hideCover = self.showingVideo;
    BOOL wasHidden = self.coverHidden;
    BOOL showVideo = self.showingVideo && self.artworkVisible;
    void (^apply)(void) = ^{
        self.alpha = showVideo ? 1.0f : 0.0f;
        if (hideCover) {
            if ([image isKindOfClass:[UIView class]]) image.alpha = 0.0f;
            if ([shadow isKindOfClass:[UIView class]]) shadow.alpha = 0.0f;
        } else if (wasHidden) {
            if ([image isKindOfClass:[UIView class]]) image.alpha = 1.0f;
            if ([shadow isKindOfClass:[UIView class]]) shadow.alpha = 1.0f;
        }
    };
    self.coverHidden = hideCover;
    if (animated) [UIView animateWithDuration:(self.artworkVisible ? 0.35 : 0.2) animations:apply];
    else apply();
    tj_lmRecomputeFullscreen();
}

- (void)dealloc {
    _showingVideo = NO;
    [self teardown];
    dispatch_async(dispatch_get_main_queue(), ^{ tj_lmRecomputeFullscreen(); });
}

- (BOOL)shouldPlay {
    if (!tj_lmEnabled()) return NO;
    if (!self.appeared || !self.artworkVisible || !self.window || self.hidden || self.superview.hidden) return NO;
    if (sTJLMScreenBlanked || !sTJLMMusicPlaying) return NO;
    if ([NSProcessInfo processInfo].isLowPowerModeEnabled) return NO;
    return YES;
}

- (void)updatePlayback {
    if (!self.player) return;
    if ([self shouldPlay]) {
        if (self.player.rate == 0.0f) [self.player play];
    } else if (self.player.rate != 0.0f) {
        [self.player pause];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.playerLayer && !CGRectEqualToRect(self.playerLayer.frame, self.bounds)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.playerLayer.frame = self.bounds;
        [CATransaction commit];
    }
    if (!CGRectEqualToRect(self.fadeMask.frame, self.bounds)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.fadeMask.frame = self.bounds;
        [CATransaction commit];
    }
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self updatePlayback];
    tj_lmRecomputeFullscreen();
}

@end

static void tj_lmForEachMotionView(void (^block)(TJLockMotionView *v)) {
    for (TJLockMotionView *v in [sTJLMMotionViews allObjects]) block(v);
}

static void tj_lmRecomputeFullscreen(void) {
    BOOL on = NO;
    for (TJLockMotionView *v in [sTJLMMotionViews allObjects]) {
        if (v.showingVideo && v.artworkVisible && v.appeared && v.window && !v.hidden) { on = YES; break; }
    }
    tj_lmPublishFullscreen(on);
}

#pragma mark - Song identity and lookup

typedef void (*TJLMGetInfoFunc)(dispatch_queue_t, void (^)(CFDictionaryRef));

static NSURL *tj_lmModelVideoURL(id item, id artwork) {
    NSMutableArray *targets = [NSMutableArray array];
    id song = item ? tj_unwrapSongFromPlayingItem(item) : nil;
    id album = item ? tj_unwrapAlbumFromPlayingItem(item) : nil;
    for (id t in @[album ?: [NSNull null], song ?: [NSNull null], tj_lmKVC(item, @"metadataObject") ?: [NSNull null],
                   item ?: [NSNull null], tj_lmKVC(artwork, @"catalog") ?: [NSNull null],
                   tj_lmKVC(album, @"artworkCatalog") ?: [NSNull null], tj_lmKVC(song, @"artworkCatalog") ?: [NSNull null]]) {
        if (t != [NSNull null]) [targets addObject:t];
    }
    for (id target in targets) {
        for (NSString *prop in @[@"tallVideoArtwork", @"videoBackgroundArtworkCatalog", @"_internalVideoCatalog",
                                 @"videoArtwork", @"editorialVideo", @"videoCatalog"]) {
            id cat = tj_lmKVC(target, prop);
            NSURL *u = cat ? tj_extractVideoURLFromObject(cat) : nil;
            if (u) {
                return u;
            }
        }
    }
    return nil;
}

static void tj_lmLoadResolved(TJLockMotionView *mv, NSString *key, NSURL *url) {
    __weak TJLockMotionView *weakMV = mv;
    NSString *s = url.absoluteString;
    if ([s containsString:@"_default.m3u8"] || [s containsString:@"master.m3u8"]) {
        tj_resolveOptimalVariantURL(url, ^(NSURL *variant) {
            TJLockMotionView *m2 = weakMV;
            if (m2 && [m2.trackKey isEqualToString:key]) [m2 loadVideoURL:variant ?: url];
        });
    } else {
        [mv loadVideoURL:url];
    }
}

static void tj_lmGiveUp(TJLockMotionView *mv) {
    [mv teardown];
    mv.trackKey = nil;
    mv.retryAfter = CACurrentMediaTime() + 20.0;
}

#pragma mark - Spotify (matched by metadata)

typedef void (*TJLMGetClientFunc)(dispatch_queue_t, void (^)(id));
typedef CFStringRef (*TJLMClientBundleFunc)(id);

static BOOL tj_lmIsSpotifyBundle(NSString *bundleID) {
    return [bundleID isEqualToString:@"com.spotify.client"];
}

static void tj_lmNowPlayingIsSpotify(void (^completion)(BOOL isSpotify)) {
    TJLMGetClientFunc getClient = (TJLMGetClientFunc)dlsym(RTLD_DEFAULT, "MRMediaRemoteGetNowPlayingClient");
    if (!getClient) { tj_lmLog(@"spotify: MRMediaRemoteGetNowPlayingClient missing"); completion(NO); return; }
    getClient(dispatch_get_main_queue(), ^(id client) {
        BOOL match = NO;
        NSMutableArray *seen = [NSMutableArray array];
        if (client) {
            for (NSString *name in @[@"MRNowPlayingClientGetBundleIdentifier", @"MRNowPlayingClientGetParentAppBundleIdentifier"]) {
                TJLMClientBundleFunc fn = (TJLMClientBundleFunc)dlsym(RTLD_DEFAULT, name.UTF8String);
                NSString *bundleID = fn ? (__bridge NSString *)fn(client) : nil;
                if ([bundleID isKindOfClass:[NSString class]]) [seen addObject:bundleID];
                if ([bundleID isKindOfClass:[NSString class]] && tj_lmIsSpotifyBundle(bundleID)) { match = YES; break; }
            }
        }
        tj_lmLog(@"spotify: now playing client %@ -> %@", client ? [seen componentsJoinedByString:@","] : @"(none)", match ? @"spotify" : @"not spotify");
        completion(match);
    });
}

static void tj_lmResolveSpotify(TJLockMotionView *mv, NSString *key, NSString *albumTitle, NSString *artist, NSString *title) {
    if (!prefBool(@"lockScreenSpotifyMotion", YES)) { tj_lmLog(@"spotify: switched off in settings"); tj_lmGiveUp(mv); return; }
    __weak TJLockMotionView *weakMV = mv;
    void (^lookup)(NSString *, NSString *, NSString *) = ^(NSString *t, NSString *a, NSString *al) {
        tj_fetchMotionVideoForMetadata(t, a, al, ^(NSURL *url) {
            TJLockMotionView *m = weakMV;
            tj_lmLog(@"spotify: \"%@\" by \"%@\" on \"%@\" -> %@", t, a, al ?: @"", url ? url.absoluteString : @"no animated artwork found");
            if (!m || ![m.trackKey isEqualToString:key]) return;
            if (!url && prefBool(@"lockScreenSpotifyCanvas", YES)) {
                // Second source: the track's own Canvas, as the Spotify app publishes it.
                NSURL *canvas = nil;
                BOOL known = TJCanvasShareRead(t, &canvas);
                tj_lmLog(@"spotify: canvas for \"%@\" -> %@", t, canvas ? canvas.absoluteString : (known ? @"this track has none" : @"nothing published for this track yet"));
                url = canvas;
            }
            if (!url) { tj_lmGiveUp(m); return; }
            tj_lmLoadResolved(m, key, url);
        });
    };
    tj_lmNowPlayingIsSpotify(^(BOOL isSpotify) {
        TJLockMotionView *m = weakMV;
        if (!m || ![m.trackKey isEqualToString:key]) return;
        if (!isSpotify) { tj_lmGiveUp(m); return; }
        if (title.length && artist.length) { lookup(title, artist, albumTitle); return; }
        TJLMGetInfoFunc getInfo = (TJLMGetInfoFunc)dlsym(RTLD_DEFAULT, "MRMediaRemoteGetNowPlayingInfo");
        if (!getInfo) { tj_lmGiveUp(m); return; }
        getInfo(dispatch_get_main_queue(), ^(CFDictionaryRef cfInfo) {
            TJLockMotionView *m2 = weakMV;
            if (!m2 || ![m2.trackKey isEqualToString:key]) return;
            NSDictionary *info = (__bridge NSDictionary *)cfInfo;
            if (![info isKindOfClass:[NSDictionary class]]) { tj_lmGiveUp(m2); return; }
            NSString *t = tj_lmString(info[@"kMRMediaRemoteNowPlayingInfoTitle"]) ?: title;
            NSString *a = tj_lmString(info[@"kMRMediaRemoteNowPlayingInfoArtist"]) ?: artist;
            NSString *al = tj_lmString(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]) ?: albumTitle;
            if (!t.length || !a.length) { tj_lmGiveUp(m2); return; }
            lookup(t, a, al);
        });
    });
}

static void tj_lmResolveAndLoad(TJLockMotionView *mv, NSString *key, NSString *songID, NSString *albumID,
                                NSString *albumTitle, NSString *artist, NSString *title, NSURL *modelURL) {
    if (modelURL) {
        if (albumID.length) tj_recordAlbumMotionVideoURL(albumID, modelURL);
        if (songID.length) tj_recordAlbumMotionVideoURL(songID, modelURL);
        tj_lmLoadResolved(mv, key, modelURL);
        return;
    }
    if (!songID.length && !albumID.length) {
        tj_lmResolveSpotify(mv, key, albumTitle, artist, title);
        return;
    }
    __weak TJLockMotionView *weakMV = mv;
    tj_fetchMotionVideoForSongAndAlbum(songID, albumID, albumTitle, artist, title, ^(NSURL *url) {
        TJLockMotionView *m = weakMV;
        if (!m || ![m.trackKey isEqualToString:key]) return;
        if (!url) {
            [m teardown];
            m.trackKey = nil;
            m.retryAfter = CACurrentMediaTime() + 20.0;
            return;
        }
        tj_lmLoadResolved(m, key, url);
    });
}

static void tj_lmRefreshTrack(MRUArtworkView *artworkView, TJLockMotionView *mv) {
    if (!tj_lmEnabled()) { [mv teardown]; mv.trackKey = nil; return; }

    id response = tj_lmKVC(artworkView, @"artwork.response");
    id item = tj_lmKVC(response, @"tracklist.playingItem");
    NSString *key = item ? tj_itemTrackKey(item) : nil;
    // a pointer-derived key means the item carries no usable metadata; ask MediaRemote instead
    if ([key hasPrefix:@"0x"]) key = nil;
    if (key.length > 0) {
        if ([key isEqualToString:mv.trackKey]) { [mv updatePlayback]; return; }
        if (!mv.trackKey && CACurrentMediaTime() < mv.retryAfter) return;
        mv.trackKey = key;
        [mv teardown];
        tj_lmLog(@"track from player item: key %@ songID %@ albumID %@", key, tj_extractAdamID(item) ?: @"-", tj_extractAlbumAdamID(item) ?: @"-");
        NSString *title = nil, *artist = nil;
        for (NSString *kp in @[@"title", @"metadataObject.song.title", @"metadataObject.title"]) {
            title = tj_lmString(tj_lmKVC(item, kp)); if (title) break;
        }
        for (NSString *kp in @[@"artistName", @"metadataObject.song.artistName", @"metadataObject.song.artist.name", @"metadataObject.artistName"]) {
            artist = tj_lmString(tj_lmKVC(item, kp)); if (artist) break;
        }
        tj_lmResolveAndLoad(mv, key, tj_extractAdamID(item), tj_extractAlbumAdamID(item),
                            tj_extractAlbumTitle(item), artist, title,
                            tj_lmModelVideoURL(item, tj_lmKVC(artworkView, @"artwork")));
        return;
    }

    TJLMGetInfoFunc getInfo = (TJLMGetInfoFunc)dlsym(RTLD_DEFAULT, "MRMediaRemoteGetNowPlayingInfo");
    if (!getInfo) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - mv.lastInfoQuery < 2.0) { [mv updatePlayback]; return; }
    mv.lastInfoQuery = now;
    __weak TJLockMotionView *weakMV = mv;
    getInfo(dispatch_get_main_queue(), ^(CFDictionaryRef cfInfo) {
        TJLockMotionView *m = weakMV;
        NSDictionary *info = (__bridge NSDictionary *)cfInfo;
        if (!m || ![info isKindOfClass:[NSDictionary class]]) return;
        NSString *title = tj_lmString(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
        NSString *artist = tj_lmString(info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
        NSString *album = tj_lmString(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
        NSString *songID = tj_lmString(info[@"kMRMediaRemoteNowPlayingInfoiTunesStoreIdentifier"]);
        NSString *albumID = tj_lmString(info[@"kMRMediaRemoteNowPlayingInfoAlbumiTunesStoreAdamIdentifier"]);
        NSString *k = songID ?: (title ? [NSString stringWithFormat:@"%@ - %@", title, artist ?: @""] : nil);
        if (!k || [k isEqualToString:m.trackKey]) { [m updatePlayback]; return; }
        if (!m.trackKey && CACurrentMediaTime() < m.retryAfter) return;
        m.trackKey = k;
        [m teardown];
        tj_lmLog(@"track from MediaRemote: key %@ songID %@ albumID %@", k, songID ?: @"-", albumID ?: @"-");
        tj_lmResolveAndLoad(m, k, songID, albumID, album, artist, title, nil);
    });
}

#pragma mark - Attaching to the big cover

static BOOL tj_lmIsBigCover(UIView *artworkView) {
    UIView *sup = artworkView.superview;
    return sup && [NSStringFromClass(sup.class) isEqualToString:kTJLMBackgroundViewClassName];
}

static void tj_lmAttach(MRUArtworkView *artworkView) {
    if (!tj_lmIsBigCover(artworkView)) return;
    TJLockMotionView *mv = objc_getAssociatedObject(artworkView, kTJLMMotionViewKey);
    if (!tj_lmEnabled()) {
        if (mv) { [mv teardown]; mv.hidden = YES; }
        return;
    }
    UIView *background = artworkView.superview;

    CGRect bounds = background.bounds;
    CGRect target = CGRectMake(0, 0, bounds.size.width, ceil(bounds.size.height * 0.68));

    if (!mv) {
        mv = [[TJLockMotionView alloc] initWithFrame:target];
        mv.coverView = artworkView;
        objc_setAssociatedObject(artworkView, kTJLMMotionViewKey, mv, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!sTJLMMotionViews) sTJLMMotionViews = [NSHashTable weakObjectsHashTable];
        [sTJLMMotionViews addObject:mv];
    }
    mv.hidden = NO;
    NSArray *subs = background.subviews;
    NSUInteger coverIdx = [subs indexOfObject:artworkView];
    if (mv.superview != background || [subs indexOfObject:mv] + 1 != coverIdx) {
        [background insertSubview:mv belowSubview:artworkView];
    }
    if (!CGRectEqualToRect(mv.frame, target)) mv.frame = target;

    if (mv.coverHidden) [mv applyCoverVisibilityAnimated:NO];

    tj_lmRefreshTrack(artworkView, mv);
}

static TJLockMotionView *tj_lmMotionViewForVC(UIViewController *vc) {
    if (!vc.isViewLoaded) return nil;
    UIView *artworkView = tj_lmKVC(vc, @"artworkView");
    return artworkView ? objc_getAssociatedObject(artworkView, kTJLMMotionViewKey) : nil;
}

static void tj_lmSetAppeared(UIViewController *vc, BOOL appeared) {
    TJLockMotionView *mv = tj_lmMotionViewForVC(vc);
    if (mv) {
        mv.appeared = appeared;
        [mv updatePlayback];
    }
    tj_lmRecomputeFullscreen();
}

static void tj_lmSetArtworkVisible(UIViewController *vc, BOOL visible) {
    TJLockMotionView *mv = tj_lmMotionViewForVC(vc);
    if (!mv || mv.artworkVisible == visible) return;
    mv.artworkVisible = visible;
    [mv applyCoverVisibilityAnimated:YES];
    [mv updatePlayback];
}

%group LockMotion

%hook MRUArtworkView

- (void)layoutSubviews {
    %orig;
    @try { tj_lmAttach(self); } @catch (__unused id e) {}
}

%end

%hook TJLMBackgroundView

- (void)artworkView:(id)artworkView didChangeArtworkImage:(id)image {
    %orig;
    @try { if (artworkView) tj_lmAttach(artworkView); } @catch (__unused id e) {}
}

%end

%hook TJLMBackgroundVC

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    @try { tj_lmSetAppeared(self, YES); } @catch (__unused id e) {}
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    @try { tj_lmSetAppeared(self, NO); } @catch (__unused id e) {}
}

- (void)setArtworkVisible:(BOOL)visible {
    %orig;
    @try { tj_lmSetArtworkVisible(self, visible); } @catch (__unused id e) {}
}

%end

%end

#pragma mark - Global state (music playing, screen blanked, Low Power Mode)

typedef void (*TJLMRegisterFunc)(dispatch_queue_t);
typedef void (*TJLMGetIsPlayingFunc)(dispatch_queue_t, void (^)(Boolean));

static void tj_lmUpdateAll(void) {
    tj_lmForEachMotionView(^(TJLockMotionView *v) { [v updatePlayback]; });
}

static void tj_lmObserveState(void) {
    TJLMRegisterFunc reg = (TJLMRegisterFunc)dlsym(RTLD_DEFAULT, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (reg) reg(dispatch_get_main_queue());

    TJLMGetIsPlayingFunc getIsPlaying = (TJLMGetIsPlayingFunc)dlsym(RTLD_DEFAULT, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    if (getIsPlaying) {
        getIsPlaying(dispatch_get_main_queue(), ^(Boolean playing) {
            sTJLMMusicPlaying = playing;
            tj_lmUpdateAll();
        });
    }

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserverForName:@"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification" object:nil
                     queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        NSNumber *val = note.userInfo[@"kMRMediaRemoteNowPlayingApplicationIsPlayingUserInfoKey"];
        if (val) sTJLMMusicPlaying = val.boolValue;
        tj_lmUpdateAll();
    }];
    [nc addObserverForName:@"kMRMediaRemoteNowPlayingInfoDidChangeNotification" object:nil
                     queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *note) {
        tj_lmForEachMotionView(^(TJLockMotionView *v) { v.lastInfoQuery = 0; v.retryAfter = 0; [v.superview setNeedsLayout]; });
    }];
    [nc addObserverForName:NSProcessInfoPowerStateDidChangeNotification object:nil
                     queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *note) {
        tj_lmUpdateAll();
    }];
    [nc addObserverForName:TJPrefsStoreChangedNotification object:nil
                     queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *note) {
        tj_lmForEachMotionView(^(TJLockMotionView *v) { [v.superview setNeedsLayout]; });
    }];

    static int blankToken = 0;
    notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &blankToken, dispatch_get_main_queue(), ^(int token) {
        uint64_t state = 0;
        notify_get_state(token, &state);
        sTJLMScreenBlanked = (state != 0);
        tj_lmUpdateAll();
    });

    // Spotify can publish a track's Canvas after the lock screen has already asked for it:
    // a view that is showing nothing asks again.
    static int canvasToken = 0;
    notify_register_dispatch(TJCanvasShareChangedNotification.UTF8String, &canvasToken, dispatch_get_main_queue(), ^(__unused int token) {
        tj_lmForEachMotionView(^(TJLockMotionView *v) {
            if (v.showingVideo || v.videoURL || v.trackKey) return;
            v.lastInfoQuery = 0;
            v.retryAfter = 0;
            [v.superview setNeedsLayout];
        });
    });
}

%ctor {
    @autoreleasepool {
        if (![[NSProcessInfo processInfo].processName isEqualToString:@"MediaRemoteUI"]) return;
        Class bgView = NSClassFromString(kTJLMBackgroundViewClassName);
        Class bgVC = NSClassFromString(@"MediaRemoteUI.CoverSheetBackgroundViewController");
        if (!bgView || !bgVC || !objc_getClass("MRUArtworkView")) {
            return;
        }
        %init(LockMotion, TJLMBackgroundView = bgView, TJLMBackgroundVC = bgVC);
        tj_lmLog(@"loaded into MediaRemoteUI");
        tj_lmPublishFullscreen(NO);
        tj_lmObserveState();
    }
}
