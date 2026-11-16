//
//  WQDesignTokens.h
//  WQ Files — 界面设计变量
//  GPL-3.0-or-later.
//
//  玻璃只用于导航与主控件层（WQGlass.h），内容列表保持平面。
//  配色改用系统动态中性色：浅色/深色/高对比自动适配，靠明暗分层而非彩色。
//  间距与圆角仍走固定档位，统一线性图标，无自绘渐变、发光或装饰徽章。
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import "WQGlass.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 间距档位（4 / 8 / 12 / 16 / 24 / 32 / 48）

/* Macros rather than file-scope constants: this header is included by several
   translation units, and unused static constants would break -Werror builds. */
#define WQSpace1  4.0
#define WQSpace2  8.0
#define WQSpace3  12.0
#define WQSpace4  16.0
#define WQSpace6  24.0
#define WQSpace8  32.0   /* 组间留白 */
#define WQSpace12 48.0

#pragma mark - 圆角档位（0 / 4 / 8 / 12 / 20）

#define WQRadius0 0.0
#define WQRadius1 4.0
#define WQRadius2 8.0   /* 控件统一圆角 */
#define WQRadius3 12.0
#define WQRadius4 20.0  /* 玻璃面板 / 主入口 */

#pragma mark - 结构尺寸（左边缘对齐的基准）

#define WQGutter    16.0  /* 分组标题、设置项标签、输入框左边缘 */
#define WQIconSize  20.0  /* 统一线性图标 */
#define WQIconSlot  24.0  /* 图标占位宽度 */
#define WQTextLeft  52.0  /* 列表行文字左边缘 = 16 + 24 + 12 */
#define WQRowHeight 44.0  /* 设置项 / 列表行单行高度 */
#define WQControlH  44.0  /* 输入框、主按钮高度 */
#define WQHintSpace 18.0  /* 表单错误提示固定占位高度 */

#define WQ_INLINE static inline __attribute__((unused))

#pragma mark - 中性色（系统动态色，自动适配浅色/深色/高对比）

WQ_INLINE UIColor *WQColorBackground(void)  { return UIColor.systemGroupedBackgroundColor; }
WQ_INLINE UIColor *WQColorSurface(void)     { return UIColor.secondarySystemGroupedBackgroundColor; }
WQ_INLINE UIColor *WQColorSurface2(void)    { return UIColor.tertiarySystemGroupedBackgroundColor; }
WQ_INLINE UIColor *WQColorLine(void)        { return UIColor.separatorColor; }
WQ_INLINE UIColor *WQColorText(void)        { return UIColor.labelColor; }
WQ_INLINE UIColor *WQColorText2(void)       { return UIColor.secondaryLabelColor; }
WQ_INLINE UIColor *WQColorText3(void)       { return UIColor.tertiaryLabelColor; }
// 主要操作：动态标签色，深色模式下自动反相，不用红/蓝强调
WQ_INLINE UIColor *WQColorStrong(void)      { return UIColor.labelColor; }
WQ_INLINE UIColor *WQColorOnStrong(void)    { return UIColor.labelColor; }

#pragma mark - 字体

WQ_INLINE UIFont *WQFontTitle(void)   { return [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold]; }
WQ_INLINE UIFont *WQFontHeadline(void){ return [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]; }
WQ_INLINE UIFont *WQFontBody(void)    { return [UIFont systemFontOfSize:15 weight:UIFontWeightRegular]; }
WQ_INLINE UIFont *WQFontGroup(void)   { return [UIFont systemFontOfSize:12 weight:UIFontWeightMedium]; }
WQ_INLINE UIFont *WQFontCaption(void) { return [UIFont systemFontOfSize:12 weight:UIFontWeightRegular]; }
WQ_INLINE UIFont *WQFontValue(void)   { return [UIFont systemFontOfSize:13 weight:UIFontWeightRegular]; }

#pragma mark - 统一线性图标

// 只用描边型 SF Symbol（非 .fill 变体），统一线宽与点尺寸。
// 禁止：表情符号、彩色服务方块、圆角徽章、图标底衬、感叹号类符号。
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

// Secondary controls: a light glass surface, no hard 1px border.
WQ_INLINE void WQStyleControl(UIView *view)
{
    WQGlassAttach(view, NO, WQRadius2);
}

// Primary action: tinted-but-neutral glass, never a solid dark block.
WQ_INLINE void WQStylePrimaryButton(UIButton *button)
{
    WQGlassAttach(button, YES, WQRadius2);
    [button setTitleColor:WQColorText() forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
}

#pragma mark - 全局设置（多个视图共用，键只在这里定义一次）

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
