#import "TJMotionArtworkResolver.h"
#import "TJModelUtils.h"
#import <objc/runtime.h>
#import <objc/message.h>

static NSString * const kTJMotionDiskCacheKeyLegacy = @"TJMotionVideoDiskCache";
static NSString * const kTJMotionDiskCacheKey = @"TJMotionVideoDiskCache.v2";
static const NSUInteger kTJMotionCacheMaxEntries = 300;
static NSMutableDictionary<NSString *, NSURL *> *sMotionVideoCache = nil;
static NSMutableArray<NSString *> *sMotionVideoCacheOrder = nil;
static NSMutableDictionary<NSString *, NSDate *> *sNoMotionVideoCache = nil;
static const NSTimeInterval kTJNoMotionTTL = 30 * 60;
static dispatch_queue_t sDiskSyncQueue = nil;
static dispatch_once_t sMotionCacheOnceToken;
static NSURL *sLatestActiveAlbumMotionVideoURL = nil;
static NSString *sLatestActiveAlbumAdamID = nil;
static NSString *sLatestActiveAlbumTitle = nil;

void tj_initMotionCacheIfNeeded(void) {
    dispatch_once(&sMotionCacheOnceToken, ^{
        sMotionVideoCache = [NSMutableDictionary dictionary];
        sMotionVideoCacheOrder = [NSMutableArray array];
        sNoMotionVideoCache = [NSMutableDictionary dictionary];
        sDiskSyncQueue = dispatch_queue_create("com.twentyone.motiondiskqueue", DISPATCH_QUEUE_SERIAL);
        NSDictionary *disk = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kTJMotionDiskCacheKey];
        if (disk && [disk isKindOfClass:[NSDictionary class]]) {
            for (NSString *key in disk) {
                NSString *val = disk[key];
                if ([val isKindOfClass:[NSString class]] && val.length > 0) {
                    sMotionVideoCache[key] = [NSURL URLWithString:val];
                    [sMotionVideoCacheOrder addObject:key];
                }
            }
        }
        if ([[NSUserDefaults standardUserDefaults] objectForKey:kTJMotionDiskCacheKeyLegacy]) {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:kTJMotionDiskCacheKeyLegacy];
        }
    });
}

void tj_recordAlbumMotionVideoURL(NSString *albumKey, NSURL *videoURL) {
    if (!albumKey || !videoURL) return;
    tj_initMotionCacheIfNeeded();
    @synchronized (sMotionVideoCache) {
        if (!sMotionVideoCache[albumKey]) [sMotionVideoCacheOrder addObject:albumKey];
        sMotionVideoCache[albumKey] = videoURL;
        while (sMotionVideoCache.count > kTJMotionCacheMaxEntries && sMotionVideoCacheOrder.count > 0) {
            NSString *oldest = sMotionVideoCacheOrder.firstObject;
            [sMotionVideoCacheOrder removeObjectAtIndex:0];
            [sMotionVideoCache removeObjectForKey:oldest];
        }
    }
    @synchronized (sNoMotionVideoCache) {
        [sNoMotionVideoCache removeObjectForKey:albumKey];
    }
    dispatch_async(sDiskSyncQueue, ^{
        static uint64_t sDiskGen = 0;
        uint64_t currentGen = ++sDiskGen;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), sDiskSyncQueue, ^{
            if (currentGen != sDiskGen) return;
            NSMutableDictionary *toSave = [NSMutableDictionary dictionary];
            @synchronized (sMotionVideoCache) {
                for (NSString *k in sMotionVideoCache) {
                    NSURL *u = sMotionVideoCache[k];
                    if (u.absoluteString) toSave[k] = u.absoluteString;
                }
            }
            [[NSUserDefaults standardUserDefaults] setObject:toSave forKey:kTJMotionDiskCacheKey];
        });
    });
}

BOOL tj_isKnownNoMotionKey(NSString *key) {
    if (!key) return NO;
    tj_initMotionCacheIfNeeded();
    @synchronized (sNoMotionVideoCache) {
        NSDate *when = sNoMotionVideoCache[key];
        if (!when) return NO;
        if (-[when timeIntervalSinceNow] > kTJNoMotionTTL) {
            [sNoMotionVideoCache removeObjectForKey:key];
            return NO;
        }
        return YES;
    }
}

void tj_recordNoMotionKey(NSString *key) {
    if (!key) return;
    tj_initMotionCacheIfNeeded();
    @synchronized (sNoMotionVideoCache) {
        sNoMotionVideoCache[key] = [NSDate date];
    }
}

NSURL * _Nullable tj_cachedAlbumMotionVideoURL(NSString *albumKey) {
    if (!albumKey) return nil;
    tj_initMotionCacheIfNeeded();
    @synchronized (sMotionVideoCache) {
        return sMotionVideoCache[albumKey];
    }
}

NSURL * _Nullable tj_latestActiveAlbumMotionVideoURL(void) {
    return sLatestActiveAlbumMotionVideoURL;
}

void tj_setLatestActiveAlbumMotionVideoURL(NSURL * _Nullable url) {
    sLatestActiveAlbumMotionVideoURL = url;
}

NSString * _Nullable tj_latestActiveAlbumAdamID(void) {
    return sLatestActiveAlbumAdamID;
}

void tj_setLatestActiveAlbumAdamID(NSString * _Nullable aid) {
    sLatestActiveAlbumAdamID = aid;
}

NSString * _Nullable tj_latestActiveAlbumTitle(void) {
    return sLatestActiveAlbumTitle;
}

void tj_setLatestActiveAlbumTitle(NSString * _Nullable title) {
    sLatestActiveAlbumTitle = title;
}

NSURL * _Nullable tj_extractVideoURLFromObject(id _Nullable obj) {
    if (!obj) return nil;
    if ([obj isKindOfClass:[NSURL class]]) return (NSURL *)obj;
    if ([obj isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)obj;
        if ([s containsString:@".m3u8"] || [s containsString:@".mp4"]) {
            return [NSURL URLWithString:s];
        }
    }
    for (NSString *selName in @[@"videoURL", @"url", @"URL", @"streamingURL", @"assetURL", @"hlsURL"]) {
        SEL sel = NSSelectorFromString(selName);
        if ([obj respondsToSelector:sel]) {
            id res = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
            if ([res isKindOfClass:[NSURL class]]) return (NSURL *)res;
            if ([res isKindOfClass:[NSString class]]) return [NSURL URLWithString:(NSString *)res];
        }
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)obj;
        for (NSString *k in @[@"tallVideoArtwork", @"motionDetailTall", @"videoArtwork", @"motionDetailSquare", @"editorialVideo"]) {
            id sub = d[k];
            NSURL *u = tj_extractVideoURLFromObject(sub);
            if (u) return u;
        }
        id v = d[@"video"] ?: d[@"url"] ?: d[@"hls_url"] ?: d[@"tall_hls_url"];
        if ([v isKindOfClass:[NSString class]]) return [NSURL URLWithString:(NSString *)v];
        if ([v isKindOfClass:[NSURL class]]) return (NSURL *)v;
    }
    return nil;
}

void tj_inspectAndCacheComponentMotionVideo(id _Nullable component) {
    if (!component) return;
    for (NSString *key in @[@"tallVideoArtwork", @"videoArtwork", @"_internalVideoCatalog", @"videoBackgroundArtworkCatalog", @"editorialVideo", @"videoCatalog", @"videoLooper"]) {
        id val = nil;
        @try { val = [component valueForKey:key]; } @catch (__unused id e) {}
        if (val) {
            NSURL *u = tj_extractVideoURLFromObject(val);
            if (u) {
                sLatestActiveAlbumMotionVideoURL = u;

                id cat = nil;
                @try { cat = [component valueForKey:@"_internalImageCatalog"]; } @catch (__unused id e) {}
                if (cat && [cat respondsToSelector:@selector(token)]) {
                    id tok = ((id (*)(id, SEL))objc_msgSend)(cat, @selector(token));
                    if ([tok isKindOfClass:[NSString class]]) {
                        tj_recordAlbumMotionVideoURL((NSString *)tok, u);
                    }
                }

                NSString *aid = tj_extractAdamID(component);
                if (aid) {
                    sLatestActiveAlbumAdamID = aid;
                    tj_recordAlbumMotionVideoURL(aid, u);
                }
                break;
            }
        }
    }
}

void tj_resolveOptimalVariantURL(NSURL *masterURL, void (^completion)(NSURL * _Nullable resolvedURL)) {
    if (!masterURL) {
        if (completion) completion(nil);
        return;
    }
    NSString *urlStr = masterURL.absoluteString;

    if (![urlStr containsString:@"_default.m3u8"] && ![urlStr containsString:@"master.m3u8"]) {
        if (completion) completion(masterURL);
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:masterURL];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.2 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];
    [req setTimeoutInterval:2.5];
    req.cachePolicy = NSURLRequestReturnCacheDataElseLoad;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable resp, NSError * _Nullable err) {
        if (data && !err) {
            NSString *playlist = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (playlist && playlist.length > 0) {
                NSArray<NSString *> *lines = [playlist componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
                NSString *currentInf = nil;
                NSURL *bestVariantURL = nil;
                NSInteger bestBandwidth = 0;
                NSInteger bestWidth = 0;

                for (NSString *rawLine in lines) {
                    NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    if ([line hasPrefix:@"#EXT-X-STREAM-INF:"]) {
                        currentInf = line;
                    } else if (currentInf && (line.length > 0 && ![line hasPrefix:@"#"])) {
                        NSInteger width = 0;
                        NSInteger height = 0;
                        NSInteger bw = 0;

                        NSRange resRange = [currentInf rangeOfString:@"RESOLUTION="];
                        if (resRange.location != NSNotFound) {
                            NSString *resSub = [currentInf substringFromIndex:resRange.location + resRange.length];
                            NSScanner *scanner = [NSScanner scannerWithString:resSub];
                            [scanner scanInteger:&width];
                            [scanner scanString:@"x" intoString:nil];
                            [scanner scanInteger:&height];
                        }

                        NSRange bwRange = [currentInf rangeOfString:@"BANDWIDTH="];
                        if (bwRange.location != NSNotFound) {
                            NSString *bwSub = [currentInf substringFromIndex:bwRange.location + bwRange.length];
                            NSScanner *scanner = [NSScanner scannerWithString:bwSub];
                            [scanner scanInteger:&bw];
                        }

                        NSURL *candURL = [NSURL URLWithString:line relativeToURL:masterURL].absoluteURL;
                        if (candURL) {

                            if (width <= 1080 && height <= 1440 && bw <= 5500000 && width >= 480) {
                                if (!bestVariantURL || width > bestWidth || (width == bestWidth && bw < bestBandwidth)) {
                                    bestVariantURL = candURL;
                                    bestBandwidth = bw;
                                    bestWidth = width;
                                }
                            } else if (!bestVariantURL && width <= 1080 && height <= 1440) {
                                bestVariantURL = candURL;
                                bestBandwidth = bw;
                                bestWidth = width;
                            }
                        }
                        currentInf = nil;
                    }
                }

                if (bestVariantURL) {
                    if (completion) {
                        dispatch_async(dispatch_get_main_queue(), ^{ completion(bestVariantURL); });
                    }
                    return;
                }
            }
        }
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(masterURL); });
        }
    }];
    [task resume];
}

void tj_fetchMotionVideoForSongAndAlbum(NSString * _Nullable songID,
                                       NSString * _Nullable albumID,
                                       NSString * _Nullable albumTitle,
                                       NSString * _Nullable artistName,
                                       NSString * _Nullable songTitle,
                                       void (^completion)(NSURL * _Nullable videoURL)) {
    NSString *artistKey = tj_normalizedKey(artistName);
    NSString *albumCompoundKey = (artistKey && tj_normalizedKey(albumTitle)) ?
        [NSString stringWithFormat:@"album:%@|%@", artistKey, tj_normalizedKey(albumTitle)] : nil;
    NSString *songCompoundKey = (artistKey && tj_normalizedKey(songTitle)) ?
        [NSString stringWithFormat:@"song:%@|%@", artistKey, tj_normalizedKey(songTitle)] : nil;

    if (albumID) {
        NSURL *cached = tj_cachedAlbumMotionVideoURL(albumID);
        if (cached) { if (completion) completion(cached); return; }
    }
    if (songID) {
        NSURL *cached = tj_cachedAlbumMotionVideoURL(songID);
        if (cached) { if (completion) completion(cached); return; }
    }
    if (albumCompoundKey) {
        NSURL *cached = tj_cachedAlbumMotionVideoURL(albumCompoundKey);
        if (cached) { if (completion) completion(cached); return; }
    }
    if (songCompoundKey) {
        NSURL *cached = tj_cachedAlbumMotionVideoURL(songCompoundKey);
        if (cached) { if (completion) completion(cached); return; }
    }

    if ((albumID && tj_isKnownNoMotionKey(albumID)) ||
        (songID && tj_isKnownNoMotionKey(songID)) ||
        (albumCompoundKey && tj_isKnownNoMotionKey(albumCompoundKey)) ||
        (songCompoundKey && tj_isKnownNoMotionKey(songCompoundKey))) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }

    void (^recordNoMotionAndFinish)(void) = ^{
        if (albumID) tj_recordNoMotionKey(albumID);
        if (songID) tj_recordNoMotionKey(songID);
        if (albumCompoundKey) tj_recordNoMotionKey(albumCompoundKey);
        if (songCompoundKey) tj_recordNoMotionKey(songCompoundKey);
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
    };

    void (^finishWithoutCaching)(void) = ^{
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
    };

    __block void (^fetchAlbumHTMLDirectly)(NSString *) = nil;
    __block void (^performITunesSearchFallback)(void) = nil;

    __block BOOL triedSongPage = NO;
    __block void (^fetchSongPage)(void) = nil;

    void (^extractAndFinish)(NSString *, NSString *) = ^(NSString *albumHtml, NSString *resolvedAlbumID) {
        NSURL *foundMasterURL = nil;

        NSRegularExpression *tallRegex = [NSRegularExpression regularExpressionWithPattern:@"\"tallVideoArtwork\"[\\s\\S]*?\"video\"\\s*:\\s*\"(https://[^\"]+\\.m3u8)\"" options:0 error:nil];
        NSTextCheckingResult *tallMatch = [tallRegex firstMatchInString:albumHtml options:0 range:NSMakeRange(0, albumHtml.length)];
        if (tallMatch && tallMatch.numberOfRanges > 1) {
            NSString *tallStr = [albumHtml substringWithRange:[tallMatch rangeAtIndex:1]];
            foundMasterURL = [NSURL URLWithString:tallStr];
        }

        if (!foundMasterURL) {
            for (NSString *key in @[@"motionDetailTall", @"motionTallVideo3x4", @"videoArtwork",
                                    @"squareVideoArtwork", @"motionDetailSquare", @"motionSquareVideo1x1"]) {
                NSString *pattern = [NSString stringWithFormat:@"\"%@\"\\s*:\\s*\\{(?:[^{}]|\\{[^{}]*\\})*?\"video\"\\s*:\\s*\"(https://[^\"]+\\.m3u8)\"", key];
                NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
                NSTextCheckingResult *m = [re firstMatchInString:albumHtml options:0 range:NSMakeRange(0, albumHtml.length)];
                if (m && m.numberOfRanges > 1) {
                    foundMasterURL = [NSURL URLWithString:[albumHtml substringWithRange:[m rangeAtIndex:1]]];
                    if (foundMasterURL) break;
                }
            }
        }
        if (!foundMasterURL && fetchSongPage && !triedSongPage) {
            triedSongPage = YES;
            fetchSongPage();
            return;
        }


        if (foundMasterURL) {
            tj_resolveOptimalVariantURL(foundMasterURL, ^(NSURL * _Nullable optimalURL) {
                NSURL *finalURL = optimalURL ?: foundMasterURL;
                if (songID) tj_recordAlbumMotionVideoURL(songID, finalURL);
                if (albumID) tj_recordAlbumMotionVideoURL(albumID, finalURL);
                if (resolvedAlbumID) tj_recordAlbumMotionVideoURL(resolvedAlbumID, finalURL);
                if (albumCompoundKey) tj_recordAlbumMotionVideoURL(albumCompoundKey, finalURL);
                if (songCompoundKey) tj_recordAlbumMotionVideoURL(songCompoundKey, finalURL);

                if (completion) {
                    dispatch_async(dispatch_get_main_queue(), ^{ completion(finalURL); });
                }
            });
            return;
        }

        recordNoMotionAndFinish();
    };

    if (songID.length > 0 && tj_isNumericAdamID(songID)) {
        fetchSongPage = ^{
            NSString *country = [[[NSLocale currentLocale] countryCode] lowercaseString] ?: @"us";
            NSString *songURLStr = [NSString stringWithFormat:@"https://music.apple.com/%@/song/a/%@", country, songID];
            NSMutableURLRequest *songReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:songURLStr]];
            [songReq setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.2 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];
            [songReq setTimeoutInterval:6.0];
            NSURLSessionDataTask *songTask = [[NSURLSession sharedSession] dataTaskWithRequest:songReq completionHandler:^(NSData * _Nullable sd, NSURLResponse * _Nullable sr, NSError * _Nullable se) {
                NSInteger st = [sr isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)sr).statusCode : 0;
                NSString *html = (sd && !se && st == 200) ? [[NSString alloc] initWithData:sd encoding:NSUTF8StringEncoding] : nil;
                fetchSongPage = nil;
                if (html) {
                    extractAndFinish(html, songID);
                } else {
                    recordNoMotionAndFinish();
                }
            }];
            [songTask resume];
        };
    }

    fetchAlbumHTMLDirectly = ^(NSString *targetAlbumID) {
        NSString *country = [[[NSLocale currentLocale] countryCode] lowercaseString] ?: @"us";
        NSString *albURLStr = [NSString stringWithFormat:@"https://music.apple.com/%@/album/a/%@", country, targetAlbumID];
        NSMutableURLRequest *albReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:albURLStr]];
        [albReq setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.2 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];
        [albReq setTimeoutInterval:4.0];
        albReq.cachePolicy = NSURLRequestReturnCacheDataElseLoad;

        NSURLSessionDataTask *albTask = [[NSURLSession sharedSession] dataTaskWithRequest:albReq completionHandler:^(NSData * _Nullable aData, NSURLResponse * _Nullable aResp, NSError * _Nullable aErr) {
            NSInteger aStatus = [aResp isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)aResp).statusCode : 0;
            if (aData && !aErr && aStatus == 200) {
                NSString *aHtml = [[NSString alloc] initWithData:aData encoding:NSUTF8StringEncoding];
                if (aHtml) {
                    extractAndFinish(aHtml, targetAlbumID);
                    return;
                }
            }

            NSString *fallbackStr = [NSString stringWithFormat:@"https://music.apple.com/album/%@", targetAlbumID];
            NSMutableURLRequest *fbReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:fallbackStr]];
            [fbReq setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.2 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];
            [fbReq setTimeoutInterval:4.0];
            NSURLSessionDataTask *fbTask = [[NSURLSession sharedSession] dataTaskWithRequest:fbReq completionHandler:^(NSData * _Nullable fbData, NSURLResponse * _Nullable fbResp, NSError * _Nullable fbErr) {
                NSInteger fbStatus = [fbResp isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)fbResp).statusCode : 0;
                if (fbData && !fbErr && fbStatus == 200) {
                    NSString *fbHtml = [[NSString alloc] initWithData:fbData encoding:NSUTF8StringEncoding];
                    if (fbHtml) {
                        extractAndFinish(fbHtml, targetAlbumID);
                        return;
                    }
                }
                finishWithoutCaching();
            }];
            [fbTask resume];
        }];
        [albTask resume];
    };

    performITunesSearchFallback = ^{
        NSString *searchQuery = nil;
        NSString *entityType = @"album";
        if (albumTitle && albumTitle.length > 0) {
            searchQuery = (artistName && artistName.length > 0) ? [NSString stringWithFormat:@"%@ %@", albumTitle, artistName] : albumTitle;
            entityType = @"album";
        } else if (songTitle && songTitle.length > 0) {
            searchQuery = (artistName && artistName.length > 0) ? [NSString stringWithFormat:@"%@ %@", songTitle, artistName] : songTitle;
            entityType = @"song";
        }

        if (!searchQuery || searchQuery.length == 0) {
            recordNoMotionAndFinish();
            return;
        }

        NSString *encodedQuery = [searchQuery stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
        NSString *searchURLStr = [NSString stringWithFormat:@"https://itunes.apple.com/search?term=%@&entity=%@&limit=1", encodedQuery, entityType];
        NSMutableURLRequest *searchReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:searchURLStr]];
        [searchReq setTimeoutInterval:3.0];
        [searchReq setValue:@"iTunes/12.0" forHTTPHeaderField:@"User-Agent"];

        NSURLSessionDataTask *searchTask = [[NSURLSession sharedSession] dataTaskWithRequest:searchReq completionHandler:^(NSData * _Nullable sData, NSURLResponse * _Nullable sResp, NSError * _Nullable sErr) {
            NSString *foundColId = nil;
            if (sData && !sErr) {
                @try {
                    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:sData options:0 error:nil];
                    NSArray *results = [json isKindOfClass:[NSDictionary class]] ? json[@"results"] : nil;
                    if ([results isKindOfClass:[NSArray class]] && results.count > 0) {
                        NSDictionary *first = [results firstObject];
                        BOOL artistOK = !artistKey || [tj_normalizedKey(first[@"artistName"]) isEqualToString:artistKey];
                        NSString *expectedTitle = albumTitle.length > 0 ? albumTitle : songTitle;
                        NSString *returnedTitle = [entityType isEqualToString:@"album"] ? first[@"collectionName"] : first[@"trackName"];
                        BOOL titleOK = tj_albumTitlesMatch(expectedTitle, returnedTitle);
                        id col = first[@"collectionId"];
                        if (col && artistOK && titleOK) {
                            foundColId = [NSString stringWithFormat:@"%@", col];
                        }
                    }
                } @catch (__unused id e) {}
            }

            if (foundColId && foundColId.length > 0) {
                fetchAlbumHTMLDirectly(foundColId);
            } else if (!sData || sErr) {
                finishWithoutCaching();
            } else {
                recordNoMotionAndFinish();
            }
        }];
        [searchTask resume];
    };

    if (albumID && albumID.length > 0 && tj_isNumericAdamID(albumID)) {
        fetchAlbumHTMLDirectly(albumID);
        return;
    }

    if (songID && songID.length > 0 && tj_isNumericAdamID(songID)) {
        NSString *lookupURLStr = [NSString stringWithFormat:@"https://itunes.apple.com/lookup?id=%@", songID];
        NSMutableURLRequest *lookupReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:lookupURLStr]];
        [lookupReq setTimeoutInterval:3.0];

        NSURLSessionDataTask *lookupTask = [[NSURLSession sharedSession] dataTaskWithRequest:lookupReq completionHandler:^(NSData * _Nullable lData, NSURLResponse * _Nullable lResp, NSError * _Nullable lErr) {
            NSString *foundColId = nil;
            if (lData && !lErr) {
                @try {
                    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:lData options:0 error:nil];
                    NSArray *results = [json isKindOfClass:[NSDictionary class]] ? json[@"results"] : nil;
                    if ([results isKindOfClass:[NSArray class]] && results.count > 0) {
                        NSDictionary *first = [results firstObject];
                        id col = first[@"collectionId"];
                        if (col) {
                            foundColId = [NSString stringWithFormat:@"%@", col];
                        }
                    }
                } @catch (__unused id e) {}
            }

            if (foundColId && foundColId.length > 0) {
                fetchAlbumHTMLDirectly(foundColId);
                return;
            }

            performITunesSearchFallback();
        }];
        [lookupTask resume];
        return;
    }

    performITunesSearchFallback();
}

#pragma mark - Metadata-only lookup (third-party players)

static NSString *tj_matchStrip(NSString *s) {
    if (s.length == 0) return s;
    NSString *t = [s stringByReplacingOccurrencesOfString:@"\\s*[\\(\\[][^\\)\\]]*[\\)\\]]" withString:@""
                                                  options:NSRegularExpressionSearch range:NSMakeRange(0, s.length)];
    NSRange dash = [t rangeOfString:@" - "];
    if (dash.location != NSNotFound && dash.location > 0) t = [t substringToIndex:dash.location];
    t = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return t.length > 0 ? t : s;
}

static NSArray<NSString *> *tj_matchTokens(NSString *s) {
    if (s.length == 0) return @[];
    NSString *folded = [s stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch
                                              locale:nil];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *tok in [folded componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]]) {
        if (tok.length > 0) [out addObject:tok];
    }
    return out;
}

static NSString *tj_matchFold(NSString *s) {
    return [tj_matchTokens(s) componentsJoinedByString:@" "];
}

static BOOL tj_matchTitles(NSString *a, NSString *b) {
    NSString *fa = tj_matchFold(a), *fb = tj_matchFold(b);
    if (fa.length == 0 || fb.length == 0) return NO;
    if ([fa isEqualToString:fb]) return YES;
    return [tj_matchFold(tj_matchStrip(a)) isEqualToString:tj_matchFold(tj_matchStrip(b))];
}

static BOOL tj_matchArtists(NSString *a, NSString *b) {
    NSSet *stop = [NSSet setWithArray:@[@"and", @"feat", @"ft", @"featuring", @"with"]];
    NSMutableSet *sa = [NSMutableSet setWithArray:tj_matchTokens(a)];
    NSMutableSet *sb = [NSMutableSet setWithArray:tj_matchTokens(b)];
    [sa minusSet:stop];
    [sb minusSet:stop];
    if (sa.count == 0 || sb.count == 0) return NO;
    return [sa isSubsetOfSet:sb] || [sb isSubsetOfSet:sa];
}

static NSInteger tj_matchAlbumScore(NSString *wanted, NSString *candidate) {
    NSString *fw = tj_matchFold(wanted), *fc = tj_matchFold(candidate);
    if (fw.length == 0) return 1;
    if (fc.length == 0) return 0;
    if ([fw isEqualToString:fc]) return 3;
    NSString *sw = tj_matchFold(tj_matchStrip(wanted)), *sc = tj_matchFold(tj_matchStrip(candidate));
    if ([sw isEqualToString:sc]) return 2;
    if ([fc hasPrefix:[sw stringByAppendingString:@" "]] || [fw hasPrefix:[sc stringByAppendingString:@" "]]) return 1;
    return 0;
}

static NSString *tj_storefrontCountry(void) {
    NSString *cc = [[[NSLocale currentLocale] countryCode] lowercaseString];
    return cc.length == 2 ? cc : @"us";
}

static void tj_storeSearch(NSString *term, NSString *entity, NSInteger limit, void (^completion)(NSArray * _Nullable results)) {
    NSURLComponents *comps = [NSURLComponents componentsWithString:@"https://itunes.apple.com/search"];
    comps.queryItems = @[[NSURLQueryItem queryItemWithName:@"term" value:term],
                         [NSURLQueryItem queryItemWithName:@"media" value:@"music"],
                         [NSURLQueryItem queryItemWithName:@"entity" value:entity],
                         [NSURLQueryItem queryItemWithName:@"limit" value:[NSString stringWithFormat:@"%ld", (long)limit]],
                         [NSURLQueryItem queryItemWithName:@"country" value:tj_storefrontCountry()]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:comps.URL];
    [req setTimeoutInterval:5.0];
    [req setValue:@"iTunes/12.0" forHTTPHeaderField:@"User-Agent"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable resp, NSError * _Nullable err) {
        NSInteger status = [resp isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        NSArray *results = nil;
        if (data && !err && status == 200) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            id r = [json isKindOfClass:[NSDictionary class]] ? json[@"results"] : nil;
            if ([r isKindOfClass:[NSArray class]]) results = r;
        }
        completion(results);
    }] resume];
}

static NSString *tj_storeIDString(id v) {
    return [v isKindOfClass:[NSNumber class]] && [v longLongValue] > 0 ? [v stringValue] : nil;
}

void tj_fetchMotionVideoForMetadata(NSString * _Nullable songTitle,
                                    NSString * _Nullable artistName,
                                    NSString * _Nullable albumTitle,
                                    void (^completion)(NSURL * _Nullable videoURL)) {
    void (^finish)(NSURL *) = ^(NSURL *url) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(url); });
    };
    NSString *artistKey = tj_normalizedKey(artistName);
    if (!artistKey || (!tj_normalizedKey(songTitle) && !tj_normalizedKey(albumTitle))) { finish(nil); return; }

    NSString *albumKey = tj_normalizedKey(albumTitle) ? [NSString stringWithFormat:@"album:%@|%@", artistKey, tj_normalizedKey(albumTitle)] : nil;
    NSString *songKey = tj_normalizedKey(songTitle) ? [NSString stringWithFormat:@"song:%@|%@", artistKey, tj_normalizedKey(songTitle)] : nil;
    NSURL *cached = (albumKey ? tj_cachedAlbumMotionVideoURL(albumKey) : nil) ?: (songKey ? tj_cachedAlbumMotionVideoURL(songKey) : nil);
    if (cached) { finish(cached); return; }
    if ((albumKey && tj_isKnownNoMotionKey(albumKey)) || (songKey && tj_isKnownNoMotionKey(songKey))) { finish(nil); return; }

    void (^noMatch)(void) = ^{
        if (albumKey) tj_recordNoMotionKey(albumKey);
        if (songKey) tj_recordNoMotionKey(songKey);
        finish(nil);
    };
    void (^resolve)(NSString *, NSString *) = ^(NSString *songID, NSString *albumID) {
        tj_fetchMotionVideoForSongAndAlbum(songID, albumID, albumTitle, artistName, songTitle, completion);
    };

    NSString *leadArtist = [artistName componentsSeparatedByString:@", "].firstObject ?: artistName;

    void (^searchAlbum)(void) = ^{
        if (albumTitle.length == 0) { noMatch(); return; }
        NSString *term = [NSString stringWithFormat:@"%@ %@", tj_matchStrip(albumTitle), artistName];
        tj_storeSearch(term, @"album", 10, ^(NSArray *results) {
            if (!results) { finish(nil); return; }
            NSString *bestID = nil;
            NSInteger bestScore = 1;
            for (NSDictionary *r in results) {
                if (![r isKindOfClass:[NSDictionary class]] || !tj_matchArtists(artistName, r[@"artistName"])) continue;
                NSInteger score = tj_matchAlbumScore(albumTitle, r[@"collectionName"]);
                NSString *cid = tj_storeIDString(r[@"collectionId"]);
                if (cid && score > bestScore) { bestScore = score; bestID = cid; }
            }
            if (bestID) resolve(nil, bestID);
            else noMatch();
        });
    };

    if (songTitle.length == 0) { searchAlbum(); return; }

    NSString *term = [NSString stringWithFormat:@"%@ %@", tj_matchStrip(songTitle), leadArtist];
    tj_storeSearch(term, @"song", 25, ^(NSArray *results) {
        if (!results) { finish(nil); return; }
        NSString *bestSong = nil, *bestAlbum = nil, *sameAlbum = nil;
        NSInteger bestScore = 0;
        for (NSDictionary *r in results) {
            if (![r isKindOfClass:[NSDictionary class]]) continue;
            if (!tj_matchArtists(artistName, r[@"artistName"])) continue;
            NSInteger score = tj_matchAlbumScore(albumTitle, r[@"collectionName"]);
            NSString *cid = tj_storeIDString(r[@"collectionId"]);
            if (!tj_matchTitles(songTitle, r[@"trackName"])) {
                if (cid && !sameAlbum && albumTitle.length > 0 && score >= 2) sameAlbum = cid;
                continue;
            }
            if (cid && score > bestScore) {
                bestScore = score;
                bestAlbum = cid;
                bestSong = tj_storeIDString(r[@"trackId"]);
            }
        }
        if (bestAlbum) resolve(bestSong, bestAlbum);
        else if (sameAlbum) resolve(nil, sameAlbum);
        else searchAlbum();
    });
}
