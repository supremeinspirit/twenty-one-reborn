// The playing Spotify track's Canvas, handed from the Spotify app to the lock screen.
//
// The two processes share no files, so the clip's address travels in notify(3) state: a hash of
// the track title, the address' length and the address itself in eight-byte pieces, guarded by a
// sequence number that is odd while a write is under way.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const TJCanvasShareChangedNotification; // a notify(3) name

uint64_t TJCanvasTitleHash(NSString * _Nullable title);

// Spotify side. A nil address says the track has no video Canvas.
void TJCanvasSharePublish(NSString * _Nullable title, NSString * _Nullable address);

// Lock screen side. Returns YES when what is published belongs to this title; *address is then the
// clip, or nil where the track has none.
BOOL TJCanvasShareRead(NSString * _Nullable title, NSURL * _Nullable * _Nonnull address);

NS_ASSUME_NONNULL_END
