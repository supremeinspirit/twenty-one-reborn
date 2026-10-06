// Runs inside Spotify: publishes the playing track's Canvas for the lock screen (TJLockScreenMotion.x).
//
// Spotify's core writes canvas.url and canvas.type into the played track's metadata; the type is
// spelled IMAGE, VIDEO, VIDEO_LOOPING, VIDEO_LOOPING_RANDOM or GIF. Only the video ones are clips.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "TJCanvasShare.h"

static NSString *const kTJSCPlayerClassName = @"_TtC23NowPlaying_PlatformImpl28StatefulPlayerImplementation";

@interface TJSCLock : NSObject
@end
@implementation TJSCLock
@end

static void tj_scLog(NSString *line) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.pisknk.twentyone.canvas.log", DISPATCH_QUEUE_SERIAL); });
    NSDate *now = [NSDate date];
    dispatch_async(q, ^{
        NSString *dir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        if (!dir) return;
        NSString *path = [dir stringByAppendingPathComponent:@"TwentyOneCanvas.log"];
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([[fm attributesOfItemAtPath:path error:nil] fileSize] > 64 * 1024) [fm removeItemAtPath:path error:nil];
        if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!h) return;
        @try {
            [h seekToEndOfFile];
            [h writeData:[[NSString stringWithFormat:@"%.3f %@\n", now.timeIntervalSince1970, line] dataUsingEncoding:NSUTF8StringEncoding]];
        } @catch (__unused id e) {}
        [h closeFile];
    });
}

static id tj_scValue(id object, NSString *key) {
    if (!object) return nil;
    @try { return [object valueForKey:key]; } @catch (__unused id e) { return nil; }
}

static NSString *tj_scString(id value) {
    return [value isKindOfClass:[NSString class]] && [value length] > 0 ? value : nil;
}

static void tj_scPublish(id state) {
    static NSString *last = nil;
    id track = tj_scValue(state, @"track");
    if (!track) return;
    NSDictionary *metadata = tj_scValue(track, @"metadata");
    if (![metadata isKindOfClass:[NSDictionary class]]) metadata = nil;
    NSString *title = tj_scString(tj_scValue(track, @"trackTitle")) ?: tj_scString(metadata[@"title"]);
    if (!title) return;
    NSString *address = tj_scString(metadata[@"canvas.url"]);
    NSString *type = tj_scString(metadata[@"canvas.type"]);
    if (type && ![type hasPrefix:@"VIDEO"]) address = nil;
    if (address && ![address hasPrefix:@"https://"]) address = nil;

    NSString *stamp = [NSString stringWithFormat:@"%@|%@", title, address ?: @""];
    @synchronized ([TJSCLock class]) {
        if ([stamp isEqualToString:last]) return;
        last = stamp;
    }
    TJCanvasSharePublish(title, address);
    tj_scLog([NSString stringWithFormat:@"\"%@\" -> %@", title, address ?: (type ? [@"no video canvas, type " stringByAppendingString:type] : @"no canvas")]);
}

%group SpotifyCanvas

%hook TJSCPlayer

- (void)player:(id)player stateDidChange:(id)state {
    %orig;
    @try { tj_scPublish(state); } @catch (__unused id e) {}
}

%end

%end

%group SpotifyCanvasFromState

%hook TJSCPlayerFromState

- (void)player:(id)player stateDidChange:(id)state fromState:(id)oldState {
    %orig;
    @try { tj_scPublish(state); } @catch (__unused id e) {}
}

%end

%end

%ctor {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.spotify.client"]) return;
        Class player = NSClassFromString(kTJSCPlayerClassName);
        if (!player) { tj_scLog(@"not hooked: player class missing"); return; }
        if (class_getInstanceMethod(player, @selector(player:stateDidChange:))) {
            %init(SpotifyCanvas, TJSCPlayer = player);
            tj_scLog(@"loaded into Spotify (player:stateDidChange:)");
        } else if (class_getInstanceMethod(player, @selector(player:stateDidChange:fromState:))) {
            %init(SpotifyCanvasFromState, TJSCPlayerFromState = player);
            tj_scLog(@"loaded into Spotify (player:stateDidChange:fromState:)");
        } else {
            tj_scLog(@"not hooked: the player takes no state change message");
        }
    }
}
