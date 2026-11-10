//
//  WQDesignTokens.h
//  WQ Files — 界面设计变量
//  GPL-3.0-or-later.
//
//  规范：中性色、固定档位间距与圆角、统一线性图标、无渐变无发光、无装饰徽章。
//  所有视图只引用这里的常量，不写死数值。
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

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

#pragma mark - 圆角档位（0 / 4 / 8 / 12）

#define WQRadius0 0.0
#define WQRadius1 4.0
#define WQRadius2 8.0   /* 控件统一圆角 */
#define WQRadius3 12.0

#pragma mark - 结构尺寸（左边缘对齐的基准）

#define WQGutter    16.0  /* 分组标题、设置项标签、输入框左边缘 */
#define WQIconSize  20.0  /* 统一线性图标 */
#define WQIconSlot  24.0  /* 图标占位宽度 */
#define WQTextLeft  52.0  /* 列表行文字左边缘 = 16 + 24 + 12 */
#define WQRowHeight 44.0  /* 设置项 / 列表行单行高度 */
#define WQControlH  44.0  /* 输入框、主按钮高度 */
#define WQHintSpace 18.0  /* 表单错误提示固定占位高度 */

/* This header is shared by several translation units. Mark helpers unused so
   -Wall -Wextra -Werror builds do not fail in files that use only a subset. */
#define WQ_INLINE static inline __attribute__((unused))

#pragma mark - 中性色（仅靠明暗对比，禁止渐变、发光、彩色强调）

// 页面底色
WQ_INLINE UIColor *WQColorBackground(void) { return [UIColor colorWithRed:0.969 green:0.969 blue:0.965 alpha:1.0]; }
// 控件底色
WQ_INLINE UIColor *WQColorSurface(void)   { return UIColor.whiteColor; }
WQ_INLINE UIColor *WQColorSurface2(void)  { return [UIColor colorWithRed:0.941 green:0.941 blue:0.933 alpha:1.0]; }
// 1px 结构分隔线，不用于外层卡片边框
WQ_INLINE UIColor *WQColorLine(void)      { return [UIColor colorWithRed:0.890 green:0.890 blue:0.878 alpha:1.0]; }
// 文字三级
WQ_INLINE UIColor *WQColorText(void)      { return [UIColor colorWithRed:0.114 green:0.114 blue:0.106 alpha:1.0]; }
WQ_INLINE UIColor *WQColorText2(void)     { return [UIColor colorWithRed:0.424 green:0.424 blue:0.408 alpha:1.0]; }
WQ_INLINE UIColor *WQColorText3(void)     { return [UIColor colorWithRed:0.604 green:0.604 blue:0.580 alpha:1.0]; }
// 主要操作与危险操作：同一个深中性色，不用红色、不用蓝色
WQ_INLINE UIColor *WQColorStrong(void)    { return [UIColor colorWithRed:0.173 green:0.173 blue:0.165 alpha:1.0]; }
WQ_INLINE UIColor *WQColorOnStrong(void)  { return UIColor.whiteColor; }

#pragma mark - 字体

WQ_INLINE UIFont *WQFontTitle(void)  { return [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold]; }
WQ_INLINE UIFont *WQFontBody(void)   { return [UIFont systemFontOfSize:15 weight:UIFontWeightRegular]; }
WQ_INLINE UIFont *WQFontGroup(void)  { return [UIFont systemFontOfSize:12 weight:UIFontWeightMedium]; }
WQ_INLINE UIFont *WQFontCaption(void){ return [UIFont systemFontOfSize:12 weight:UIFontWeightRegular]; }
WQ_INLINE UIFont *WQFontValue(void)  { return [UIFont systemFontOfSize:13 weight:UIFontWeightRegular]; }

#pragma mark - 统一线性图标

// 只用描边型 SF Symbol（非 .fill 变体），统一线宽与点尺寸，统一中性色。
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

#pragma mark - 样式应用（禁止 shadow / gradient / blur）

WQ_INLINE void WQStyleControl(UIView *view)
{
    view.layer.cornerRadius = WQRadius2;
    view.layer.masksToBounds = YES;
    view.layer.shadowOpacity = 0;            // 无发光
    view.layer.shadowRadius = 0;
    view.layer.borderWidth = 1.0;
    view.layer.borderColor = WQColorLine().CGColor;
    view.backgroundColor = WQColorSurface();
}

WQ_INLINE void WQStylePrimaryButton(UIButton *button)
{
    button.layer.cornerRadius = WQRadius2;
    button.layer.masksToBounds = YES;
    button.layer.shadowOpacity = 0;
    button.backgroundColor = WQColorStrong();
    [button setTitleColor:WQColorOnStrong() forState:UIControlStateNormal];
    button.titleLabel.font = WQFontBody();
}

NS_ASSUME_NONNULL_END
