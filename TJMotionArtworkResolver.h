#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

void tj_initMotionCacheIfNeeded(void);
BOOL tj_isKnownNoMotionKey(NSString *key);
void tj_recordNoMotionKey(NSString *key);

void tj_recordAlbumMotionVideoURL(NSString *albumKey, NSURL *videoURL);

NSURL * _Nullable tj_cachedAlbumMotionVideoURL(NSString *albumKey);

NSURL * _Nullable tj_latestActiveAlbumMotionVideoURL(void);
void tj_setLatestActiveAlbumMotionVideoURL(NSURL * _Nullable url);

NSString * _Nullable tj_latestActiveAlbumAdamID(void);
void tj_setLatestActiveAlbumAdamID(NSString * _Nullable aid);

NSString * _Nullable tj_latestActiveAlbumTitle(void);
void tj_setLatestActiveAlbumTitle(NSString * _Nullable title);

void tj_inspectAndCacheComponentMotionVideo(id _Nullable component);

NSURL * _Nullable tj_extractVideoURLFromObject(id _Nullable obj);

void tj_resolveOptimalVariantURL(NSURL *masterURL, void (^completion)(NSURL * _Nullable resolvedURL));

void tj_fetchMotionVideoForSongAndAlbum(NSString * _Nullable songID,
                                       NSString * _Nullable albumID,
                                       NSString * _Nullable albumTitle,
                                       NSString * _Nullable artistName,
                                       NSString * _Nullable songTitle,
                                       void (^completion)(NSURL * _Nullable videoURL));

void tj_fetchMotionVideoForMetadata(NSString * _Nullable songTitle,
                                    NSString * _Nullable artistName,
                                    NSString * _Nullable albumTitle,
                                    void (^completion)(NSURL * _Nullable videoURL));

NS_ASSUME_NONNULL_END
