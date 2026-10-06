#import "TJCanvasShare.h"
#import <notify.h>

NSString *const TJCanvasShareChangedNotification = @"com.pisknk.twentyone.canvas.changed";

enum { kTJCanvasPieces = 40, kTJCanvasMaxLength = kTJCanvasPieces * 8 };

typedef NS_ENUM(int, TJCanvasSlot) { TJCanvasSlotSeq = 0, TJCanvasSlotHash, TJCanvasSlotLength, TJCanvasSlotFirstPiece };

static int tj_csToken(int slot) {
    static int tokens[TJCanvasSlotFirstPiece + kTJCanvasPieces];
    static BOOL ready[TJCanvasSlotFirstPiece + kTJCanvasPieces];
    if (slot < 0 || slot >= TJCanvasSlotFirstPiece + kTJCanvasPieces) return -1;
    if (!ready[slot]) {
        char name[64];
        snprintf(name, sizeof(name), "com.pisknk.twentyone.canvas.s%d", slot);
        int token = 0;
        if (notify_register_check(name, &token) != NOTIFY_STATUS_OK) return -1;
        tokens[slot] = token;
        ready[slot] = YES;
    }
    return tokens[slot];
}

static BOOL tj_csSet(int slot, uint64_t value) {
    int token = tj_csToken(slot);
    return token != -1 && notify_set_state(token, value) == NOTIFY_STATUS_OK;
}

static BOOL tj_csGet(int slot, uint64_t *value) {
    int token = tj_csToken(slot);
    return token != -1 && notify_get_state(token, value) == NOTIFY_STATUS_OK;
}

uint64_t TJCanvasTitleHash(NSString *title) {
    if (title.length == 0) return 0;
    NSString *folded = [title stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch
                                                  locale:nil];
    NSString *joined = [[folded componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]]
                        componentsJoinedByString:@""];
    NSData *bytes = [(joined.length > 0 ? joined : folded) dataUsingEncoding:NSUTF8StringEncoding];
    uint64_t hash = 1469598103934665603ULL;
    const uint8_t *p = bytes.bytes;
    for (NSUInteger i = 0; i < bytes.length; i++) { hash ^= p[i]; hash *= 1099511628211ULL; }
    return hash ?: 1;
}

void TJCanvasSharePublish(NSString *title, NSString *address) {
    static uint64_t seq = 0;
    NSData *bytes = [address dataUsingEncoding:NSUTF8StringEncoding];
    if (bytes.length > kTJCanvasMaxLength) bytes = nil;
    @synchronized ([NSNotificationCenter defaultCenter]) {
        uint64_t current = 0;
        if (tj_csGet(TJCanvasSlotSeq, &current) && current > seq) seq = current;
        seq = (seq | 1ULL) + 2;                 // odd: a write is under way
        if (!tj_csSet(TJCanvasSlotSeq, seq)) return;
        tj_csSet(TJCanvasSlotHash, TJCanvasTitleHash(title));
        tj_csSet(TJCanvasSlotLength, bytes.length);
        const uint8_t *p = bytes.bytes;
        for (NSUInteger piece = 0; piece * 8 < bytes.length; piece++) {
            uint64_t value = 0;
            NSUInteger count = MIN((NSUInteger)8, bytes.length - piece * 8);
            memcpy(&value, p + piece * 8, count);
            tj_csSet(TJCanvasSlotFirstPiece + (int)piece, value);
        }
        seq += 1;                               // even: complete
        tj_csSet(TJCanvasSlotSeq, seq);
    }
    notify_post(TJCanvasShareChangedNotification.UTF8String);
}

BOOL TJCanvasShareRead(NSString *title, NSURL **address) {
    *address = nil;
    uint64_t wanted = TJCanvasTitleHash(title);
    if (wanted == 0) return NO;
    for (int attempt = 0; attempt < 3; attempt++) {
        uint64_t before = 0, after = 0, hash = 0, length = 0;
        if (!tj_csGet(TJCanvasSlotSeq, &before) || before == 0 || (before & 1ULL)) continue;
        if (!tj_csGet(TJCanvasSlotHash, &hash) || !tj_csGet(TJCanvasSlotLength, &length)) continue;
        if (length > kTJCanvasMaxLength) return NO;
        NSMutableData *bytes = [NSMutableData dataWithLength:(NSUInteger)length];
        uint8_t *p = bytes.mutableBytes;
        BOOL complete = YES;
        for (NSUInteger piece = 0; piece * 8 < length; piece++) {
            uint64_t value = 0;
            if (!tj_csGet(TJCanvasSlotFirstPiece + (int)piece, &value)) { complete = NO; break; }
            memcpy(p + piece * 8, &value, MIN((NSUInteger)8, (NSUInteger)length - piece * 8));
        }
        if (!complete || !tj_csGet(TJCanvasSlotSeq, &after) || after != before) continue;
        if (hash != wanted) return NO;
        if (length > 0) {
            NSString *s = [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
            NSURL *url = s.length ? [NSURL URLWithString:s] : nil;
            if ([url.scheme isEqualToString:@"https"]) *address = url;
        }
        return YES;
    }
    return NO;
}
