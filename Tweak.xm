// LockScreenRestore — iOS 15 lock screen look on iOS 16 (rootless):
// thin white clock, date below it as "Sunday, September 27", focus pill under the date, big
// padlock that stays open after Face ID, notifications listed top-down under the clock, no
// vibrancy tint, no depth effect, no widgets, iOS 15 music player, live wallpapers.
//
// Sizes and positions adapt to the device: they come from the per-device values SpringBoard
// still carries from iOS 15 (SBFLockScreenMetrics) plus ratios measured against Apple's iOS 15
// lock screen, and are converted with the real font metrics at runtime.
//
// Independently switchable groups (Settings > LockScreenRestore, all on by default), applied at
// SpringBoard launch — the settings page has a respring button. The music player part runs in
// MediaRemoteUI, which restarts with SpringBoard.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreText/CoreText.h>
#import <AVFoundation/AVFoundation.h>
#import "LSRBokeh.h"

// Read straight from disk: NSUserDefaults in SpringBoard's constructor didn't see the values
// (cfprefsd). The settings page flushes to disk before its respring. Rootless jailbreaks
// (Dopamine) redirect tweak preferences under /var/jb, so look there first.
static NSString *const kLSRPrefsPaths[] = {
    @"/var/jb/var/mobile/Library/Preferences/com.aronsz26.lockscreenrestore.plist",
    @"/var/mobile/Library/Preferences/com.aronsz26.lockscreenrestore.plist",
};
static BOOL sLSRClockEnabled = YES;

// Debug builds log to LockScreenRestoreDebug.log.
#ifdef DEBUG
static void LSRDebugLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void LSRDebugLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *line = [NSString stringWithFormat:@"%.2f %@\n", CACurrentMediaTime(), [[NSString alloc] initWithFormat:format arguments:args]];
    va_end(args);
    // MediaRemoteUI is sandboxed: its log goes to its own tmp folder.
    BOOL springBoard = [[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"];
    NSString *path = [springBoard ? @"/var/mobile/Documents" : NSTemporaryDirectory()
        stringByAppendingPathComponent:@"LockScreenRestoreDebug.log"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}
#else
#define LSRDebugLog(...) do {} while (0)
#endif

@interface SBFLockScreenDateView : UIView
+ (UIFont *)timeFont;
- (void)setCustomTimeFont:(UIFont *)font;
- (UIFont *)customTimeFont;
@end

@interface BSUIVibrancyEffectView : UIView
@property (nonatomic) BOOL isEnabled;
@end

@interface CSProminentTextElementView : UIView
@property (nonatomic, strong) NSDate *date;
@property (readonly, nonatomic) UILabel *textLabel;
@end

@interface CSProminentTimeView : CSProminentTextElementView
@end

@interface CSProminentSubtitleDateView : CSProminentTextElementView
@end

@interface CSProminentDisplayView : UIView
@property (readonly, nonatomic) BSUIVibrancyEffectView *vibrancyEffectView;
@property (nonatomic, strong) CSProminentTimeView *timeView;
@property (nonatomic, strong) CSProminentTextElementView *transientSubtitleView;
@property (nonatomic, strong) CSProminentTextElementView *customSubtitleView;
@end

@interface _UIAnimatingLabel : UILabel
@end

@interface SBUIProudLockIconView : UIView
@end

@interface PBUIPosterFloatingLayerReplica : UIView
@end

#pragma mark - Per-device layout

static const CGFloat kIOS15ClockScale = 0.8;
static CGFloat sLSRClockSizeFactor = 1.0;
static const CGFloat kIOS15ClockWeightAxis = 170.0;
static const CGFloat kIOS15DateWeightAxis = 400.0;
static const CGFloat kIOS15DateBaseFontSize = 22.0;
static const uint32_t kFontAxisWeight = 'wght';
static const CGFloat kIOS15TimeBaselineAboveDate = 0.441;
static const CGFloat kSFDigitHeight = 0.717;
static const CGFloat kIOS15PadlockCenterAboveDigits = 0.531;
static const CGFloat kSFDescender = 0.21;
static const CGFloat kIOS15FaceIDTimeBaselineMin = 175.0;
static const CGFloat kIOS15PlusTimeBaselineMin = 154.0;
static const CGFloat kIOS15HomeButtonTimeBaselineMin = 140.0;
static const CGFloat kIOS15FaceIDStatusArea = 92.0;
static const CGFloat kIOS15HomeButtonStatusArea = 68.0;
static const CGFloat kIOS15TimeToDate = 36.0;
static const CGFloat kIOS15FaceIDPadlockCenter = 76.0;
static const CGFloat kIOS15DateBaselineToList = 29.0;

static CGFloat LSRIOS15ClockSize(CGFloat screenHeight) {
    if (screenHeight == 568.0 || screenHeight == 667.0) return 70.0;
    if (screenHeight == 736.0) return 86.0;
    if (screenHeight == 812.0 || screenHeight == 844.0) return 80.0;
    if (screenHeight == 896.0 || screenHeight == 926.0) return 90.0;
    return 0;
}

typedef struct {
    CGFloat clockFontSize;
    CGFloat dateFontSize;
    CGFloat timeBaselineY;
    CGFloat dateBaselineY;
    CGFloat padlockScale;
    CGFloat padlockDrop;
} LSRLayout;

static CGFloat LSRClassMetric(NSString *className, NSString *selectorName, CGFloat fallback) {
    Class cls = NSClassFromString(className);
    SEL sel = NSSelectorFromString(selectorName);
    if (!cls || ![cls respondsToSelector:sel]) return fallback;
    CGFloat value = ((CGFloat (*)(id, SEL))objc_msgSend)(cls, sel);
    return value > 0 ? value : fallback;
}

static LSRLayout LSRCurrentLayout(void) {
    static LSRLayout layout;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class dateViewClass = NSClassFromString(@"SBFLockScreenDateView");
        UIFont *iOS16TimeFont = [dateViewClass respondsToSelector:@selector(timeFont)] ? [dateViewClass timeFont] : nil;
        CGFloat iOS16TimeSize = iOS16TimeFont.pointSize > 0 ? iOS16TimeFont.pointSize : 100.0;

        CGSize screen = [UIScreen mainScreen].bounds.size;
        CGFloat screenHeight = MAX(screen.width, screen.height);
        BOOL phone = [UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPhone;
        BOOL faceID = phone && screenHeight >= 812.0;
        CGFloat iOS15Size = phone ? LSRIOS15ClockSize(screenHeight) : 0;
        layout.clockFontSize = round((iOS15Size > 0 ? iOS15Size : iOS16TimeSize * kIOS15ClockScale) * sLSRClockSizeFactor);
        layout.dateFontSize = kIOS15DateBaseFontSize;
        layout.padlockScale = 1.0 / LSRClassMetric(@"SBFLockScreenMetrics", @"proudLockScaleFactor", 0.5);

        CGFloat digitsTop, padlockCenter;
        if (phone) {
            CGFloat minimum = faceID ? kIOS15FaceIDTimeBaselineMin
                : (screenHeight >= 736.0 ? kIOS15PlusTimeBaselineMin : kIOS15HomeButtonTimeBaselineMin);
            CGFloat statusArea = faceID ? kIOS15FaceIDStatusArea : kIOS15HomeButtonStatusArea;
            layout.timeBaselineY = MAX(minimum, statusArea + layout.clockFontSize);
            layout.dateBaselineY = layout.timeBaselineY + kIOS15TimeToDate * sLSRClockSizeFactor;
            digitsTop = layout.timeBaselineY - kSFDigitHeight * layout.clockFontSize;
            padlockCenter = faceID ? kIOS15FaceIDPadlockCenter
                : digitsTop - kIOS15PadlockCenterAboveDigits * layout.clockFontSize;
        } else {
            layout.dateBaselineY = LSRClassMetric(@"SBFLockScreenMetrics", @"subtitleBaselineOffsetFromTopOfScreen", 211.0);
            layout.timeBaselineY = layout.dateBaselineY - kIOS15TimeBaselineAboveDate * layout.clockFontSize;
            digitsTop = layout.timeBaselineY - kSFDigitHeight * layout.clockFontSize;
            padlockCenter = digitsTop - kIOS15PadlockCenterAboveDigits * layout.clockFontSize;
        }
        CGFloat iOS16PadlockCenter = LSRClassMetric(@"SBFLockScreenMetrics", @"proudLockCenterFromTopOfScreen", 64.5);
        layout.padlockDrop = padlockCenter - iOS16PadlockCenter;
    });
    return layout;
}

static UIFont *LSRSystemFont(CGFloat size, CGFloat weightAxis) {
    UIFont *base = [UIFont systemFontOfSize:size weight:UIFontWeightRegular];
    UIFontDescriptor *descriptor = [base.fontDescriptor fontDescriptorByAddingAttributes:@{
        (__bridge NSString *)kCTFontVariationAttribute: @{ @(kFontAxisWeight): @(weightAxis) },
    }];
    return [UIFont fontWithDescriptor:descriptor size:size];
}

static UIFont *LSRClockFont(void) {
    static UIFont *font;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ font = LSRSystemFont(LSRCurrentLayout().clockFontSize, kIOS15ClockWeightAxis); });
    return font;
}

static CGFloat LSRIOS15DateFontSize(void) {
    CGSize screen = [UIScreen mainScreen].bounds.size;
    UIContentSizeCategory maximum = MAX(screen.width, screen.height) > 568.0
        ? UIContentSizeCategoryAccessibilityExtraExtraLarge : UIContentSizeCategoryAccessibilityExtraLarge;
    Class subtitleClass = NSClassFromString(@"SBFLockScreenDateSubtitleView");
    SEL scaled = NSSelectorFromString(@"scaledFontSize:withMaximumFontSizeCategory:");
    if ([subtitleClass respondsToSelector:scaled]) {
        CGFloat size = ((CGFloat (*)(id, SEL, CGFloat, NSString *))objc_msgSend)(subtitleClass, scaled, kIOS15DateBaseFontSize, maximum);
        if (size > 0) return size;
    }
    UIContentSizeCategory category = UIApplication.sharedApplication.preferredContentSizeCategory;
    if (UIContentSizeCategoryCompareToCategory(category, maximum) == NSOrderedDescending) category = maximum;
    UITraitCollection *traits = [UITraitCollection traitCollectionWithPreferredContentSizeCategory:category];
    return round([[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledValueForValue:kIOS15DateBaseFontSize
        compatibleWithTraitCollection:traits] * 2.0) / 2.0;
}

static UIFont *LSRDateFont(void) {
    static UIFont *font;
    static UIContentSizeCategory fontCategory;
    UIContentSizeCategory category = UIApplication.sharedApplication.preferredContentSizeCategory;
    if (!font || ![category isEqualToString:fontCategory]) {
        font = LSRSystemFont(LSRIOS15DateFontSize(), kIOS15DateWeightAxis);
        fontCategory = category;
    }
    return font;
}

static UIView *LSRFindSubview(UIView *root, Class cls) {
    if (!cls) return nil;
    for (UIView *sub in root.subviews) {
        if ([sub isKindOfClass:cls]) return sub;
        UIView *found = LSRFindSubview(sub, cls);
        if (found) return found;
    }
    return nil;
}

#pragma mark - Group: iOS 15 clock

%group LSRClock

%hook SBFLockScreenDateView
- (void)layoutSubviews {
    if (fabs(self.customTimeFont.pointSize - LSRCurrentLayout().clockFontSize) > 0.5) {
        [self setCustomTimeFont:LSRClockFont()];
    }
    %orig;
}
%end

static BOOL sLSRApplying = NO;
static __weak UIView *sLSRDisplayView = nil;

static BOOL LSRTargetTopForBaseline(UIView *view, CGFloat baselineY, UIFont *font, CGFloat height, CGFloat *outTop) {
    UIView *container = view.superview;
    UIView *display = container;
    Class displayClass = NSClassFromString(@"CSProminentDisplayView");
    while (display && ![display isKindOfClass:displayClass]) display = display.superview;
    if (!container || !display || !font) return NO;

    CGFloat containerY = [container convertPoint:CGPointZero toView:display].y;
    *outTop = baselineY - containerY - ((height - font.lineHeight) / 2.0 + font.ascender);
    return YES;
}

static BOOL LSRTargetTop(UIView *view, BOOL isTime, CGFloat height, CGFloat *outTop) {
    LSRLayout layout = LSRCurrentLayout();
    return LSRTargetTopForBaseline(view, isTime ? layout.timeBaselineY : layout.dateBaselineY,
                                   isTime ? LSRClockFont() : LSRDateFont(), height, outTop);
}

static void LSRMoveTop(UIView *view, CGFloat top) {
    CGFloat currentTop = view.center.y - view.bounds.size.height / 2.0;
    if (fabs(currentTop - top) < 0.25) return;
    CGPoint center = view.center;
    center.y = top + view.bounds.size.height / 2.0;
    sLSRApplying = YES;
    view.center = center;
    sLSRApplying = NO;
}

static void LSRPlaceView(UIView *view, BOOL isTime) {
    CGFloat top;
    if (view && LSRTargetTop(view, isTime, view.bounds.size.height, &top)) LSRMoveTop(view, top);
}

static CGRect LSRAdjustedFrame(UIView *view, BOOL isTime, CGRect frame) {
    CGFloat top;
    if (LSRTargetTop(view, isTime, frame.size.height, &top)) frame.origin.y = top;
    return frame;
}

static CGPoint LSRAdjustedCenter(UIView *view, BOOL isTime, CGPoint center) {
    CGFloat height = view.bounds.size.height;
    CGFloat top;
    if (LSRTargetTop(view, isTime, height, &top)) center.y = top + height / 2.0;
    return center;
}

%hook CSProminentTimeView
- (void)layoutSubviews {
    %orig;
    UILabel *label = self.textLabel;
    UIFont *font = LSRClockFont();
    if (label && ![label.font isEqual:font]) label.font = font;
}

- (void)setFrame:(CGRect)frame {
    if (sLSRApplying) {
        %orig;
        return;
    }
    sLSRApplying = YES;
    %orig(LSRAdjustedFrame(self, YES, frame));
    sLSRApplying = NO;
}

- (void)setCenter:(CGPoint)center {
    if (sLSRApplying) {
        %orig;
        return;
    }
    sLSRApplying = YES;
    %orig(LSRAdjustedCenter(self, YES, center));
    sLSRApplying = NO;
}
%end

static NSDateFormatter *LSRLongDateFormatter(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale autoupdatingCurrentLocale];
        formatter.dateFormat = @"EEEE, MMMM d";
    });
    return formatter;
}

static __weak CSProminentSubtitleDateView *sLSRDateView;

static void LSRApplyIOS15Date(CSProminentSubtitleDateView *view) {
    UILabel *label = view.textLabel;
    if (!label) return;
    sLSRDateView = view;
    NSString *wanted = [LSRLongDateFormatter() stringFromDate:view.date ?: [NSDate date]];
    if (![label.text isEqualToString:wanted]) label.text = wanted;
    UIFont *font = LSRDateFont();
    if (![label.font isEqual:font]) label.font = font;
}

static NSString *LSRIOS15DateTextForLabel(UILabel *label, NSString *incoming) {
    Class dateViewClass = NSClassFromString(@"CSProminentSubtitleDateView");
    if (!incoming.length || ![label.superview isKindOfClass:dateViewClass]) return incoming;
    CSProminentSubtitleDateView *dateView = (CSProminentSubtitleDateView *)label.superview;
    return [LSRLongDateFormatter() stringFromDate:dateView.date ?: [NSDate date]];
}

%hook _UIAnimatingLabel
- (void)setText:(NSString *)text {
    %orig(LSRIOS15DateTextForLabel(self, text));
}

- (void)setFont:(UIFont *)font {
    if ([self.superview isKindOfClass:NSClassFromString(@"CSProminentTimeView")]) font = LSRClockFont();
    else if ([self.superview isKindOfClass:NSClassFromString(@"CSProminentSubtitleDateView")]) font = LSRDateFont();
    %orig(font);
}

- (void)setAttributedText:(NSAttributedString *)attributedText {
    if (attributedText.length && [self.superview isKindOfClass:NSClassFromString(@"CSProminentSubtitleDateView")]) {
        NSMutableDictionary *attributes = [[attributedText attributesAtIndex:0 effectiveRange:NULL] mutableCopy];
        attributes[NSFontAttributeName] = LSRDateFont();
        attributedText = [[NSAttributedString alloc] initWithString:LSRIOS15DateTextForLabel(self, attributedText.string)
            attributes:attributes];
    }
    %orig(attributedText);
}
%end

%hook CSProminentSubtitleDateView
- (void)setFrame:(CGRect)frame {
    if (sLSRApplying) {
        %orig;
        return;
    }
    sLSRApplying = YES;
    %orig(LSRAdjustedFrame(self, NO, frame));
    sLSRApplying = NO;
}

- (void)setCenter:(CGPoint)center {
    if (sLSRApplying) {
        %orig;
        return;
    }
    sLSRApplying = YES;
    %orig(LSRAdjustedCenter(self, NO, center));
    sLSRApplying = NO;
}

- (void)setDate:(NSDate *)date {
    %orig;
    LSRApplyIOS15Date(self);
}

- (void)_updateLabel {
    %orig;
    LSRApplyIOS15Date(self);
}

- (void)layoutSubviews {
    %orig;
    LSRApplyIOS15Date(self);
}

- (void)didMoveToWindow {
    %orig;
    LSRApplyIOS15Date(self);
}
%end

%hook CSProminentDisplayView
- (void)layoutSubviews {
    %orig;
    sLSRDisplayView = self;
    BSUIVibrancyEffectView *vibrancy = self.vibrancyEffectView;
    if (vibrancy.isEnabled) vibrancy.isEnabled = NO;
    LSRPlaceView(self.timeView, YES);
    LSRPlaceView(LSRFindSubview(self, NSClassFromString(@"CSProminentSubtitleDateView")), NO);

    CGFloat dateBaselineY = LSRCurrentLayout().dateBaselineY;
    for (CSProminentTextElementView *subtitle in @[self.transientSubtitleView ?: [NSNull null],
                                                   self.customSubtitleView ?: [NSNull null]]) {
        if (![subtitle isKindOfClass:[UIView class]]) continue;
        CGFloat top;
        if (LSRTargetTopForBaseline(subtitle, dateBaselineY, subtitle.textLabel.font, subtitle.bounds.size.height, &top)) {
            LSRMoveTop(subtitle, top);
        }
    }
}
%end

%hook CSProminentDisplayViewController
- (void)setTextColor:(UIColor *)color {
    %orig([UIColor whiteColor]);
}

- (UIColor *)effectiveTextColor {
    return [UIColor whiteColor];
}
%end

%hook CSCombinedListViewController
- (UIEdgeInsets)_listViewDefaultContentInsets {
    UIEdgeInsets insets = %orig;
    if ([UIDevice currentDevice].userInterfaceIdiom != UIUserInterfaceIdiomPhone) return insets;
    CGFloat listTop = round(LSRCurrentLayout().dateBaselineY + kIOS15DateBaselineToList);
    if (insets.top < listTop) insets.top = listTop;
    return insets;
}
%end

%hook SBUIProudLockIconView
- (void)layoutSubviews {
    %orig;
    UIView *glyph = LSRFindSubview(self, NSClassFromString(@"BSUICAPackageView"));
    LSRLayout layout = LSRCurrentLayout();
    CGAffineTransform t = CGAffineTransformMake(layout.padlockScale, 0, 0, layout.padlockScale, 0, layout.padlockDrop);
    if (glyph && !CGAffineTransformEqualToTransform(glyph.transform, t)) glyph.transform = t;
}

- (void)setAlpha:(CGFloat)alpha {
    %orig(1.0);
}

- (void)setTransform:(CGAffineTransform)transform {
    %orig(CGAffineTransformIdentity);
}
%end

%hook CSProudLockViewController
- (BOOL)_shouldApplyScaleAndBlurForAuthenticated {
    return NO;
}
%end

%hook PBUIPosterFloatingLayerReplica
- (void)didMoveToWindow {
    %orig;
    self.hidden = YES;
}

- (void)setHidden:(BOOL)hidden {
    %orig(YES);
}
%end

@interface CSBatteryChargingView : UIView
@end

@interface _CSSingleBatteryChargingView : CSBatteryChargingView
@end

@interface _CSDoubleBatteryChargingView : CSBatteryChargingView
@end

static const void *kLSRChargingShiftKey = &kLSRChargingShiftKey;

static CGFloat LSRChargingShift(UIView *view) {
    return [objc_getAssociatedObject(view, kLSRChargingShiftKey) doubleValue];
}

static void LSRUpdateChargingShift(UIView *view) {
    CGRect content = CGRectNull;
    for (UIView *sub in view.subviews) {
        if (sub.hidden || CGRectIsEmpty(sub.frame)) continue;
        content = CGRectUnion(content, sub.frame);
    }
    if (CGRectIsNull(content)) return;

    LSRLayout layout = LSRCurrentLayout();
    CGFloat clockTop = layout.timeBaselineY - kSFDigitHeight * layout.clockFontSize;
    CGFloat dateBottom = layout.dateBaselineY + kSFDescender * layout.dateFontSize;
    CGFloat shift = round((clockTop + dateBottom) / 2.0 - CGRectGetMidY(content));
    if (fabs(shift - LSRChargingShift(view)) < 0.5) return;

    CGAffineTransform own = view.transform;
    objc_setAssociatedObject(view, kLSRChargingShiftKey, @(shift), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    view.transform = own;
    LSRDebugLog(@"charging view %@ content %@ shift %.1f", NSStringFromClass([view class]),
        NSStringFromCGRect(content), shift);
}

%hook CSBatteryChargingView
- (void)didMoveToWindow {
    %orig;
    LSRUpdateChargingShift(self);
}

- (void)setTransform:(CGAffineTransform)transform {
    transform.ty += LSRChargingShift(self);
    %orig(transform);
}

- (CGAffineTransform)transform {
    CGAffineTransform t = %orig;
    t.ty -= LSRChargingShift(self);
    return t;
}
%end

%hook _CSSingleBatteryChargingView
- (void)layoutSubviews {
    %orig;
    LSRUpdateChargingShift(self);
}
%end

%hook _CSDoubleBatteryChargingView
- (void)layoutSubviews {
    %orig;
    LSRUpdateChargingShift(self);
}
%end

%end // LSRClock

#pragma mark - Group: iOS 15 focus pill

@interface CSFocusActivityView : UIView
- (UIView *)activityIndicator;
@end

@interface CSAdjunctItemView : UIView
@end

static const CGFloat kIOS15FocusPillLift = 20.0;

static UIView *LSRFocusIndicator(UIView *focusView) {
    UIView *indicator = [focusView respondsToSelector:@selector(activityIndicator)] ? [(CSFocusActivityView *)focusView activityIndicator] : nil;
    return [indicator isKindOfClass:[UIView class]] ? indicator : nil;
}

%group LSRFocus

%hook CSFocusActivityView
- (void)layoutSubviews {
    %orig;
    UIView *indicator = LSRFocusIndicator(self);
    if (!indicator) return;
    indicator.center = CGPointMake(indicator.center.x, indicator.center.y - kIOS15FocusPillLift);
    for (UIView *view = self; view && ![view isKindOfClass:[UIStackView class]]; view = view.superview) {
        if (view.clipsToBounds) view.clipsToBounds = NO;
    }
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    BOOL inside = %orig;
    if (inside) return YES;
    UIView *indicator = LSRFocusIndicator(self);
    return indicator && CGRectContainsPoint(indicator.frame, point);
}
%end

%hook CSAdjunctItemView
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    BOOL inside = %orig;
    if (inside) return YES;
    for (UIView *view in self.subviews) {
        if ([view pointInside:[self convertPoint:point toView:view] withEvent:event]) return YES;
    }
    return NO;
}
%end

%hook CSFocusActivityManager
- (BOOL)_shouldHideFocusActivityIndicator {
    return NO;
}
%end

%hook NCNotificationListCountIndicatorView
- (void)setTitleString:(NSString *)titleString {
    %orig(nil);
}

- (void)setSymbolImageName:(NSString *)symbolImageName {
    %orig(nil);
}

- (void)layoutSubviews {
    %orig;
    Ivar ivar = class_getInstanceVariable(object_getClass(self), "_symbolImageView");
    UIView *symbolView = ivar ? object_getIvar(self, ivar) : nil;
    if (symbolView && !symbolView.hidden) symbolView.hidden = YES;
}
%end

%end // LSRFocus

#pragma mark - Group: iOS 15 notifications (Listed from the top + Debug Logs)

static const CGFloat kIOS15CardCornerRadius = 13.0;
static const CGFloat kIOS15CardInsetReduction = 4.0;

@interface NCNotificationShortLookView : UIView
- (CGFloat)_continuousCornerRadius;
- (void)_setContinuousCornerRadius:(CGFloat)radius;
@end

@interface NCNotificationSeamlessContentView : UIView
@end

static const CGFloat kIOS15ListInset = 8.0;
static const CGFloat kIOS16ListInset = 10.0;

@interface ACUISSizeDimensionRequest : NSObject
+ (instancetype)fixed:(CGFloat)value;
@property (readonly, nonatomic) CGFloat minimum;
@property (readonly, nonatomic) CGFloat maximum;
@end

@interface ACUISActivityItemMetricsRequest : NSObject <NSCopying>
@property (nonatomic, strong) ACUISSizeDimensionRequest *widthRequest;
@end

@interface ACUISActivityMetricsRequest : NSObject <NSCopying>
@property (nonatomic, copy) ACUISActivityItemMetricsRequest *lockScreenMetrics;
@end

@interface NCNotificationListSectionHeaderView : UIView
@property (nonatomic, weak) id delegate;
@end

@interface NCNotificationListView : UIScrollView
@property (nonatomic, strong) UIView *headerView;
@property (nonatomic) CGFloat revealPercentage;
- (BOOL)isRevealed;
@end

static BOOL LSRIsHistoryHeader(UIView *header) {
    if (![header isKindOfClass:NSClassFromString(@"NCNotificationListSectionHeaderView")]) return NO;
    id section = ((NCNotificationListSectionHeaderView *)header).delegate;
    return [section respondsToSelector:@selector(isHistorySection)]
        && ((BOOL (*)(id, SEL))objc_msgSend)(section, @selector(isHistorySection));
}

static CGFloat LSRHistoryHeaderMaxAlpha(UIView *header) {
    NCNotificationListView *list = (NCNotificationListView *)header.superview;
    if (![list isKindOfClass:NSClassFromString(@"NCNotificationListView")] || list.headerView != header
        || !LSRIsHistoryHeader(header)) return 1.0;
    return list.isRevealed ? 1.0 : MIN(MAX(list.revealPercentage, 0.0), 1.0);
}

static void LSRApplyHistoryHeaderReveal(NCNotificationListView *list) {
    UIView *header = list.headerView;
    if (!LSRIsHistoryHeader(header)) return;
    CGFloat alpha = LSRHistoryHeaderMaxAlpha(header);
    if (fabs(header.alpha - alpha) > 0.001) header.alpha = alpha;
}

%group LSRNotifications

%hook NCNotificationListView
- (BOOL)layoutFromBottom {
    return NO;
}

- (void)setLayoutFromBottom:(BOOL)layoutFromBottom {
    %orig(NO);
}

- (void)layoutSubviews {
    %orig;
    LSRApplyHistoryHeaderReveal(self);
}

- (void)setRevealPercentage:(CGFloat)percentage {
    LSRDebugLog(@"[Debug] NCNotificationListView setRevealPercentage: %.2f", percentage);
    %orig;
    LSRApplyHistoryHeaderReveal(self);
}

- (void)setRevealed:(BOOL)revealed {
    LSRDebugLog(@"[Debug] NCNotificationListView setRevealed: %d", revealed);
    %orig(revealed);
    LSRApplyHistoryHeaderReveal(self);
}
%end

%hook NCNotificationListSectionHeaderView
- (void)setAlpha:(CGFloat)alpha {
    %orig(MIN(alpha, LSRHistoryHeaderMaxAlpha(self)));
}
%end

%hook CSCombinedListViewController
- (CGFloat)horizontalInsetMargin {
    return kIOS15ListInset;
}
%end

%hook ACUISActivityHostViewControllerFactory
+ (id)activityHostViewControllerWithDescriptor:(id)descriptor sceneType:(NSInteger)type metricsRequest:(ACUISActivityMetricsRequest *)request {
    ACUISActivityItemMetricsRequest *lockScreen = request.lockScreenMetrics;
    ACUISSizeDimensionRequest *width = lockScreen.widthRequest;
    LSRDebugLog(@"activity metrics request: width %.1f..%.1f", width.minimum, width.maximum);
    if (width && fabs(width.minimum - width.maximum) < 0.01) {
        CGFloat wider = width.maximum + 2.0 * (kIOS16ListInset - kIOS15ListInset);
        ACUISActivityMetricsRequest *adjusted = [request copy];
        ACUISActivityItemMetricsRequest *adjustedLockScreen = [lockScreen copy];
        adjustedLockScreen.widthRequest = [%c(ACUISSizeDimensionRequest) fixed:wider];
        adjusted.lockScreenMetrics = adjustedLockScreen;
        request = adjusted;
    }
    return %orig(descriptor, type, request);
}
%end

%hook NCNotificationSeamlessContentView
- (void)_layoutSubviewInBounds:(CGRect)bounds measuringOnly:(CGSize *)measuredSize {
    CGFloat reduction = kIOS15CardInsetReduction;
    CGRect enlarged = bounds;
    enlarged.size.width += 2.0 * reduction;
    enlarged.size.height += 2.0 * reduction;
    %orig(enlarged, measuredSize);
    if (measuredSize) {
        measuredSize->width = MAX(0.0, measuredSize->width - 2.0 * reduction);
        measuredSize->height = MAX(0.0, measuredSize->height - 2.0 * reduction);
        return;
    }
    CGRect viewBounds = self.bounds;
    if (!CGPointEqualToPoint(viewBounds.origin, CGPointMake(reduction, reduction))) {
        viewBounds.origin = CGPointMake(reduction, reduction);
        self.bounds = viewBounds;
    }
    CGFloat wantedCenterY = CGRectGetMidY(viewBounds);
    for (UIView *subview in self.subviews) {
        if (![NSStringFromClass([subview class]) containsString:@"BadgedIconView"]) continue;
        CGPoint center = subview.center;
        if (fabs(center.y - wantedCenterY) > 0.01) subview.center = CGPointMake(center.x, wantedCenterY);
    }
}
%end

%hook NCNotificationShortLookView
- (void)_setContinuousCornerRadius:(CGFloat)radius {
    %orig(kIOS15CardCornerRadius);
}

- (void)layoutSubviews {
    %orig;
    if (fabs(self._continuousCornerRadius - kIOS15CardCornerRadius) > 0.01) {
        [self _setContinuousCornerRadius:kIOS15CardCornerRadius];
    }
    Ivar ivar = class_getInstanceVariable(object_getClass(self), "_stackDimmingOverlayView");
    UIView *dimming = ivar ? object_getIvar(
