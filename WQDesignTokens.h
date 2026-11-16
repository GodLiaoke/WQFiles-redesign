//
//  WQDesignTokens.h
//  黑猫游戏工具箱 — 界面设计变量
//  GPL-3.0-or-later.
//
//  系统液态玻璃由 WQGlass.h 提供，全局应用由 WQAppearance.h 负责。
//  配色使用系统动态中性色：浅色/深色/高对比自动适配。
//  字体与行高跟随 Dynamic Type；间距与圆角仍走固定档位。
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import "WQGlass.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 间距档位（4 / 8 / 12 / 16 / 24 / 32 / 48）

#define WQSpace1  4.0
#define WQSpace2  8.0
#define WQSpace3  12.0
#define WQSpace4  16.0
#define WQSpace6  24.0
#define WQSpace8  32.0
#define WQSpace12 48.0

#pragma mark - 圆角档位（0 / 4 / 8 / 12 / 20）

#define WQRadius0 0.0
#define WQRadius1 4.0
#define WQRadius2 8.0
#define WQRadius3 12.0
#define WQRadius4 20.0

#pragma mark - 结构尺寸

#define WQGutter    16.0
#define WQIconSize  20.0
#define WQIconSlot  24.0
#define WQTextLeft  52.0
#define WQControlH  44.0
#define WQHintSpace 18.0

#define WQ_INLINE static inline __attribute__((unused))

#pragma mark - 中性色（系统动态色）

WQ_INLINE UIColor *WQColorBackground(void)  { return UIColor.systemGroupedBackgroundColor; }
WQ_INLINE UIColor *WQColorSurface(void)     { return UIColor.secondarySystemGroupedBackgroundColor; }
WQ_INLINE UIColor *WQColorSurface2(void)    { return UIColor.tertiarySystemGroupedBackgroundColor; }
WQ_INLINE UIColor *WQColorLine(void)        { return UIColor.separatorColor; }
WQ_INLINE UIColor *WQColorText(void)        { return UIColor.labelColor; }
WQ_INLINE UIColor *WQColorText2(void)       { return UIColor.secondaryLabelColor; }
WQ_INLINE UIColor *WQColorText3(void)       { return UIColor.tertiaryLabelColor; }
WQ_INLINE UIColor *WQColorStrong(void)      { return UIColor.labelColor; }
WQ_INLINE UIColor *WQColorOnStrong(void)    { return UIColor.labelColor; }

#pragma mark - 字体（Dynamic Type）

WQ_INLINE UIFont *WQScaledFont(CGFloat size, UIFontWeight weight)
{
    UIFont *base = [UIFont systemFontOfSize:size weight:weight];
    return [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledFontForFont:base];
}

WQ_INLINE UIFont *WQFontTitle(void)    { return WQScaledFont(20.0, UIFontWeightSemibold); }
WQ_INLINE UIFont *WQFontHeadline(void) { return WQScaledFont(17.0, UIFontWeightSemibold); }
WQ_INLINE UIFont *WQFontBody(void)     { return WQScaledFont(15.0, UIFontWeightRegular); }
WQ_INLINE UIFont *WQFontGroup(void)    { return WQScaledFont(12.0, UIFontWeightMedium); }
WQ_INLINE UIFont *WQFontCaption(void)  { return WQScaledFont(12.0, UIFontWeightRegular); }
WQ_INLINE UIFont *WQFontValue(void)    { return WQScaledFont(13.0, UIFontWeightRegular); }

#pragma mark - 行高（Dynamic Type 自适应）

WQ_INLINE CGFloat WQAdaptiveRowHeight(void)
{
    UIContentSizeCategory category = UIApplication.sharedApplication.preferredContentSizeCategory;
    if (!category) return 44.0;
    NSArray<UIContentSizeCategory> *small = @[UIContentSizeCategoryExtraSmall, UIContentSizeCategorySmall];
    NSArray<UIContentSizeCategory> *large = @[UIContentSizeCategoryExtraLarge,
        UIContentSizeCategoryExtraExtraLarge, UIContentSizeCategoryExtraExtraExtraLarge];
    NSArray<UIContentSizeCategory> *a11y = @[UIContentSizeCategoryAccessibilityMedium,
        UIContentSizeCategoryAccessibilityLarge, UIContentSizeCategoryAccessibilityExtraLarge,
        UIContentSizeCategoryAccessibilityExtraExtraLarge,
        UIContentSizeCategoryAccessibilityExtraExtraExtraLarge];
    if ([small containsObject:category]) return 40.0;
    if ([large containsObject:category]) return 52.0;
    if ([a11y containsObject:category]) return 64.0;
    return 44.0;
}

#define WQRowHeight WQAdaptiveRowHeight()

#pragma mark - 统一线性图标

WQ_INLINE UIImage *WQLinearIcon(NSString * _Nullable name)
{
    if (!name.length) name = @"folder";
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:WQIconSize
                                                        weight:UIImageSymbolWeightRegular
                                                         scale:UIImageSymbolScaleMedium];
    UIImage *image = [UIImage systemImageNamed:name withConfiguration:cfg];
    if (!image) image = [UIImage systemImageNamed:@"folder" withConfiguration:cfg];
    return [image imageWithTintColor:WQColorText2() renderingMode:UIImageRenderingModeAlwaysOriginal];
}

#pragma mark - 样式应用（系统材质，无自绘 shadow / gradient）

WQ_INLINE void WQStyleControl(UIView *view)
{
    WQGlassAttach(view, NO, WQRadius2);
}

WQ_INLINE void WQStylePrimaryButton(UIButton *button)
{
    WQGlassAttach(button, YES, WQRadius2);
    [button setTitleColor:WQColorText() forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
}

#pragma mark - 全局设置键

#define WQSettingShowAllDataKey     @"WQSettingShowAllData"
#define WQSettingLegacyScopeKey     @"WQSettingLegacyScope"
#define WQSettingDeleteTreeKey      @"WQSettingDeleteTree"
#define WQSettingFastDirKey         @"WQSettingFastDir"
#define WQSettingParallelWriteKey   @"WQSettingParallelWrite"
#define WQSettingDetectCacheKey     @"WQSettingDetectCache"
#define WQSettingCompactRowsKey     @"WQSettingCompactRows"
#define WQSettingReloadAgeIdxKey    @"WQSettingReloadAgeIdx"

WQ_INLINE BOOL WQSettingGet(NSString *key, BOOL fallback)
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    return [d objectForKey:key] ? [d boolForKey:key] : fallback;
}

WQ_INLINE void WQSettingPut(NSString *key, BOOL value)
{
    [NSUserDefaults.standardUserDefaults setBool:value forKey:key];
}

WQ_INLINE NSTimeInterval WQSettingReloadAge(void)
{
    NSInteger idx = [NSUserDefaults.standardUserDefaults integerForKey:WQSettingReloadAgeIdxKey];
    if (idx == 0) return 15.0;
    if (idx == 2) return 300.0;
    return 60.0;
}

WQ_INLINE NSString *WQSettingReloadAgeText(void)
{
    NSInteger idx = [NSUserDefaults.standardUserDefaults integerForKey:WQSettingReloadAgeIdxKey];
    return idx == 0 ? @"15 秒" : (idx == 2 ? @"5 分钟" : @"1 分钟");
}

NS_ASSUME_NONNULL_END
