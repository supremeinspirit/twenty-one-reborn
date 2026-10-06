
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>
#import <math.h>
#import <objc/runtime.h>
#import "TJPrefsStore.h"

@interface CSProminentDisplayView : UIView
@end

static NSString *const kTJLCFullscreenNotification = @"com.pisknk.twentyone.lockmotion.fullscreen";

static BOOL sTJLCFullscreen = NO;
static NSHashTable<UIView *> *sTJLCDisplayViews = nil;

#pragma mark - Small helpers

static void tj_lcCollect(UIView *root, BOOL (^match)(UIView *v), NSMutableArray<UIView *> *out) {
    if (match(root)) [out addObject:root];
    for (UIView *sub in root.subviews) tj_lcCollect(sub, match, out);
}

static UIView *tj_lcFindClassNamed(UIView *root, NSString *name) {
    if ([NSStringFromClass(root.class) isEqualToString:name]) return root;
    for (UIView *sub in root.subviews) {
        UIView *found = tj_lcFindClassNamed(sub, name);
        if (found) return found;
    }
    return nil;
}

#pragma mark - Per-display-view cache

static void *kTJLCFoundKey = &kTJLCFoundKey;
static void *kTJLCSavedAlphaKey = &kTJLCSavedAlphaKey;
static NSHashTable<UIView *> *sTJLCHiddenWidgets = nil;

@interface TJLCFound : NSObject
@property (nonatomic, weak) UIView *timeView;
@property (nonatomic, weak) UIView *timeLabel;
@property (nonatomic, weak) UIView *dateView;
@property (nonatomic, weak) UIView *dateLabel;
@property (nonatomic, strong) NSArray<UIView *> *widgets;
@property (nonatomic, assign) BOOL widgetsAll;
@property (nonatomic, assign) BOOL compactApplied;
@end
@implementation TJLCFound
@end

static BOOL tj_lcIsDescendant(UIView *v, UIView *root) {
    for (UIView *p = v; p; p = p.superview) if (p == root) return YES;
    return NO;
}

static BOOL tj_lcStillAttached(UIView *v, UIView *root) {
    return v && v != root && tj_lcIsDescendant(v, root);
}

static UIView *tj_lcFindDateLabel(UIView *dateView) {
    if (!dateView) return nil;
    if ([dateView isKindOfClass:[UILabel class]]) return dateView;
    NSMutableArray<UIView *> *labels = [NSMutableArray array];
    tj_lcCollect(dateView, ^BOOL(UIView *v) { return [v isKindOfClass:[UILabel class]]; }, labels);
    UIView *best = nil;
    for (UIView *l in labels) {
        if (l.isHidden || l.alpha < 0.01) continue;
        if (!best || l.bounds.size.width > best.bounds.size.width) best = l;
    }
    return best;
}

static TJLCFound *tj_lcFound(UIView *displayView) {
    TJLCFound *f = objc_getAssociatedObject(displayView, kTJLCFoundKey);
    BOOL needsRefresh = !f || !tj_lcStillAttached(f.timeView, displayView) ||
        (f.dateView && !tj_lcStillAttached(f.dateView, displayView));
    if (!needsRefresh) return f;

    BOOL wasApplied = f.compactApplied;
    f = [TJLCFound new];
    f.compactApplied = wasApplied;
    f.timeView = tj_lcFindClassNamed(displayView, @"CSProminentTimeView");
    f.timeLabel = f.timeView ? tj_lcFindClassNamed(f.timeView, @"_UIAnimatingLabel") : nil;
    f.dateView = tj_lcFindClassNamed(displayView, @"CSProminentSubtitleDateView");
    f.dateLabel = tj_lcFindDateLabel(f.dateView);
    objc_setAssociatedObject(displayView, kTJLCFoundKey, f, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return f;
}

#pragma mark - Geometry (screen coordinates)

static CGRect tj_lcWindowRect(UIView *v) {
    return v ? [v convertRect:v.bounds toView:nil] : CGRectZero;
}

#pragma mark - Widgets

static BOOL tj_lcIsWidgetClass(UIView *v) {
    NSString *cls = NSStringFromClass(v.class);
    return [cls containsString:@"WidgetHost"] || [cls isEqualToString:@"CSProminentEmptyElementView"];
}

// Off: only the widgets beside the date make room for the compact clock row.
// On: every lock screen complication steps aside while the artwork plays.
static BOOL tj_lcHideAllComplications(void) {
    return prefBool(@"lockScreenHideComplications", YES);
}

static NSArray<UIView *> *tj_lcFindWidgets(TJLCFound *f, UIWindow *win, CGRect row, BOOL all) {
    NSMutableArray<UIView *> *all = [NSMutableArray array];
    tj_lcCollect(win, ^BOOL(UIView *v) { return tj_lcIsWidgetClass(v); }, all);
    NSMutableArray<UIView *> *out = [NSMutableArray array];
    for (UIView *v in all) {
        if (f.timeView && tj_lcIsDescendant(f.timeView, v)) continue;
        if (f.dateView && tj_lcIsDescendant(f.dateView, v)) continue;
        if (f.dateLabel && tj_lcIsDescendant(f.dateLabel, v)) continue;
        CGRect r = tj_lcWindowRect(v);
        if (r.size.height < 1) continue;
        if (!all && fabs(CGRectGetMidY(r) - CGRectGetMidY(row)) > MAX(row.size.height, 20)) continue;
        BOOL nested = NO;
        for (UIView *p = v.superview; p; p = p.superview) if ([out containsObject:p]) { nested = YES; break; }
        if (!nested) [out addObject:v];
    }
    return out;
}

static void tj_lcHideWidgets(NSArray<UIView *> *widgets) {
    if (!sTJLCHiddenWidgets) sTJLCHiddenWidgets = [NSHashTable weakObjectsHashTable];
    for (UIView *w in widgets) {
        if (!objc_getAssociatedObject(w, kTJLCSavedAlphaKey))
            objc_setAssociatedObject(w, kTJLCSavedAlphaKey, @(w.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (w.alpha != 0.0) w.alpha = 0.0;
        [sTJLCHiddenWidgets addObject:w];
    }
}

static NSUInteger tj_lcRestoreWidgets(void) {
    NSUInteger n = 0;
    for (UIView *w in sTJLCHiddenWidgets.allObjects) {
        NSNumber *saved = objc_getAssociatedObject(w, kTJLCSavedAlphaKey);
        if (!saved) continue;
        w.alpha = saved.doubleValue;
        objc_setAssociatedObject(w, kTJLCSavedAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        n++;
    }
    [sTJLCHiddenWidgets removeAllObjects];
    return n;
}

#pragma mark - Layout

static BOOL tj_lcShouldCompact(void) {
    return prefBool(@"enabled", YES) && sTJLCFullscreen;
}

@interface TJLCRowLabel : UILabel
@end
@implementation TJLCRowLabel
@end

static void *kTJLCRowLabelKey = &kTJLCRowLabelKey;
static void *kTJLCMaskKey = &kTJLCMaskKey;
static NSHashTable<UIView *> *sTJLCMaskedViews = nil;
static NSTimer *sTJLCTimer = nil;

static void tj_lcMask(UIView *v) {
    if (!v) return;
    CALayer *mask = objc_getAssociatedObject(v, kTJLCMaskKey);
    if (!mask) {
        mask = [CALayer layer];
        objc_setAssociatedObject(v, kTJLCMaskKey, mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (v.layer.mask != mask) v.layer.mask = mask;
    if (!sTJLCMaskedViews) sTJLCMaskedViews = [NSHashTable weakObjectsHashTable];
    [sTJLCMaskedViews addObject:v];
}

static void tj_lcUnmaskAll(void) {
    for (UIView *v in sTJLCMaskedViews.allObjects) {
        CALayer *mask = objc_getAssociatedObject(v, kTJLCMaskKey);
        if (mask && v.layer.mask == mask) v.layer.mask = nil;
    }
    [sTJLCMaskedViews removeAllObjects];
}

static NSString *tj_lcRowText(UIView *timeLabel) {
    static NSDateFormatter *dateFmt = nil, *timeFmt = nil;
    if (!dateFmt) {
        dateFmt = [NSDateFormatter new];
        [dateFmt setLocalizedDateFormatFromTemplate:@"dMMM"];
        timeFmt = [NSDateFormatter new];
        [timeFmt setLocalizedDateFormatFromTemplate:@"jmm"];
        NSString *f = [timeFmt.dateFormat stringByReplacingOccurrencesOfString:@"a" withString:@""];
        timeFmt.dateFormat = [f stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }
    NSDate *now = [NSDate date];
    NSString *time = [timeLabel isKindOfClass:[UILabel class]] ? ((UILabel *)timeLabel).text : nil;
    if (time.length == 0) time = [timeFmt stringFromDate:now];
    return [NSString stringWithFormat:@"%@ - %@", [dateFmt stringFromDate:now], time];
}

static void tj_lcUpdateTimer(void) {
    BOOL want = tj_lcShouldCompact();
    if (want && !sTJLCTimer) {
        sTJLCTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(__unused NSTimer *t) {
            for (UIView *v in [sTJLCDisplayViews.allObjects copy]) {
                TJLCRowLabel *row = objc_getAssociatedObject(v, kTJLCRowLabelKey);
                TJLCFound *f = objc_getAssociatedObject(v, kTJLCFoundKey);
                if (!row || !f) continue;
                NSString *text = tj_lcRowText(f.timeLabel);
                if (![row.text isEqualToString:text]) row.text = text;
            }
        }];
        sTJLCTimer.tolerance = 0.3;
    } else if (!want && sTJLCTimer) {
        [sTJLCTimer invalidate];
        sTJLCTimer = nil;
    }
}

static void tj_lcApply(UIView *displayView, BOOL animated) {
    @try {
        TJLCFound *f = tj_lcFound(displayView);
        UIView *timeLabel = f.timeLabel ?: f.timeView;
        UIView *dateView = f.dateView;
        if (!timeLabel || !dateView) return;

        if (!tj_lcShouldCompact()) {
            if (!f.compactApplied) return;
            f.compactApplied = NO;
            f.widgets = nil;
            TJLCRowLabel *row = objc_getAssociatedObject(displayView, kTJLCRowLabelKey);
            objc_setAssociatedObject(displayView, kTJLCRowLabelKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            tj_lcUnmaskAll();
            void (^reset)(void) = ^{
                row.alpha = 0.0;
                tj_lcRestoreWidgets();
            };
            if (animated) {
                [UIView animateWithDuration:0.3 animations:reset completion:^(__unused BOOL done) { [row removeFromSuperview]; }];
            } else {
                reset();
                [row removeFromSuperview];
            }
            return;
        }

        UIWindow *win = displayView.window;
        UIView *host = dateView.superview;
        if (!win || !host) return;

        BOOL firstApply = !f.compactApplied;
        BOOL all = tj_lcHideAllComplications();
        if (!firstApply && f.widgetsAll != all) {
            tj_lcRestoreWidgets();
            f.widgets = nil;
        }
        // Widgets can join the lock screen after the first pass, so an empty result is looked up again.
        if (firstApply || f.widgets.count == 0) f.widgets = tj_lcFindWidgets(f, win, tj_lcWindowRect(dateView), all);
        f.widgetsAll = all;
        f.compactApplied = YES;

        TJLCRowLabel *row = objc_getAssociatedObject(displayView, kTJLCRowLabelKey);
        BOOL created = NO;
        if (!row) {
            row = [TJLCRowLabel new];
            row.textAlignment = NSTextAlignmentCenter;
            row.adjustsFontSizeToFitWidth = YES;
            row.minimumScaleFactor = 0.6;
            row.userInteractionEnabled = NO;
            row.alpha = 0.0;
            objc_setAssociatedObject(displayView, kTJLCRowLabelKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            created = YES;
        }
        if (row.superview != host) [host addSubview:row];
        if (!CGRectEqualToRect(row.frame, dateView.frame)) row.frame = dateView.frame;
        UILabel *dateLabel = [f.dateLabel isKindOfClass:[UILabel class]] ? (UILabel *)f.dateLabel : nil;
        UIFont *font = dateLabel.font ?: [UIFont systemFontOfSize:22 weight:UIFontWeightSemibold];
        if (![row.font isEqual:font]) row.font = font;
        UIColor *color = dateLabel.textColor ?: [UIColor whiteColor];
        if (![row.textColor isEqual:color]) row.textColor = color;
        NSString *text = tj_lcRowText(timeLabel);
        if (![row.text isEqualToString:text]) row.text = text;

        tj_lcMask(timeLabel);
        if (!dateView.isHidden && dateLabel) tj_lcMask(dateLabel);

        NSArray<UIView *> *widgets = f.widgets;
        void (^apply)(void) = ^{
            row.alpha = 1.0;
            tj_lcHideWidgets(widgets);
        };
        if (animated || created) [UIView animateWithDuration:0.3 animations:apply];
        else apply();
    } @catch (__unused id e) {}
}

static void tj_lcApplyAll(BOOL animated) {
    @try {
        tj_lcUpdateTimer();
        NSArray *views = [sTJLCDisplayViews.allObjects copy];
        for (UIView *v in views) tj_lcApply(v, animated);
    } @catch (__unused id e) {}
}

#pragma mark - Hooks

%group LockClock

%hook CSProminentDisplayView

- (void)layoutSubviews {
    %orig;
    @try {
        if (!sTJLCDisplayViews) sTJLCDisplayViews = [NSHashTable weakObjectsHashTable];
        [sTJLCDisplayViews addObject:self];
        tj_lcApply(self, NO);
    } @catch (__unused id e) {}
}

- (void)didMoveToWindow {
    %orig;
    @try {
        if (!self.window) return;
        if (!sTJLCDisplayViews) sTJLCDisplayViews = [NSHashTable weakObjectsHashTable];
        [sTJLCDisplayViews addObject:self];
        tj_lcApply(self, NO);
    } @catch (__unused id e) {}
}

%end

%end

%ctor {
    @autoreleasepool {
        if (![[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"]) return;
        if (!objc_getClass("CSProminentDisplayView")) return;
        sTJLCDisplayViews = [NSHashTable weakObjectsHashTable];

        %init(LockClock);

        static int token = 0;
        notify_register_dispatch(kTJLCFullscreenNotification.UTF8String, &token, dispatch_get_main_queue(), ^(int t) {
            uint64_t state = 0;
            notify_get_state(t, &state);
            BOOL on = (state != 0);
            if (on == sTJLCFullscreen) return;
            sTJLCFullscreen = on;
            tj_lcApplyAll(YES);
        });

        static int blankToken = 0;
        notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &blankToken, dispatch_get_main_queue(), ^(int t) {
            uint64_t blanked = 0;
            notify_get_state(t, &blanked);
            if (blanked || !sTJLCFullscreen) return;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                tj_lcApplyAll(NO);
            });
        });

        [[NSNotificationCenter defaultCenter] addObserverForName:TJPrefsStoreChangedNotification object:nil
                                                            queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *n) {
            tj_lcApplyAll(YES);
        }];
    }
}
