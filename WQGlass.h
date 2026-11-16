//
//  WQGlass.h
//  黑猫游戏工具箱 — 平面材质兼容层
//  GPL-3.0-or-later.
//
//  液态玻璃已整体回退。本文件只保留旧调用点的 API，让全部实现变成纯平面
//  中性色：不创建任何系统特效视图、不插子视图、不加约束、不交换任何方法。
//  这样不会白屏，也不会因为材质层与分隔线/圆角叠在一起造成错位。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#define WQ_GLASS_INLINE static inline __attribute__((unused))
#define WQGlassBackgroundTag      0x474C4153   /* "GLAS" */
#define WQGlassProminentTag       (WQGlassBackgroundTag + 1)
#define WQGlassCellPanelTag       0x474C4350   /* "GLCP" */
// Kept so old NSUserDefaults values and Settings code still compile. They are
// never read for rendering: this build is always flat.
#define WQGlassEnabledKey        @"WQSettingGlass"
#define WQGlassRowsEnabledKey    @"WQSettingGlassRows"

WQ_GLASS_INLINE BOOL WQGlassEnabled(void)      { return NO; }
WQ_GLASS_INLINE BOOL WQGlassRowsEnabled(void)  { return NO; }
WQ_GLASS_INLINE BOOL WQGlassClassAvailable(void) { return NO; }
WQ_GLASS_INLINE UIVisualEffect *_Nullable WQGlassEffect(BOOL prominent)
{
    (void)prominent;
    return nil;
}

// Flat, opaque fills. No subview is inserted, so a panel can never cover a
// label, a separator or an accessory.
WQ_GLASS_INLINE UIColor *WQGlassFlatColor(BOOL prominent)
{
    return prominent
        ? [UIColor colorWithRed:0.173 green:0.173 blue:0.165 alpha:1.0]
        : [UIColor colorWithRed:1.0 green:1.0 blue:1.0 alpha:1.0];
}

WQ_GLASS_INLINE void WQGlassAttach(UIView *host, BOOL prominent, CGFloat radius)
{
    (void)prominent;
    host.backgroundColor = WQGlassFlatColor(prominent);
    host.layer.cornerRadius = radius;
    host.clipsToBounds = YES;
    host.layer.shadowOpacity = 0;
    host.layer.shadowRadius = 0;
    host.layer.borderWidth = 0;
}

WQ_GLASS_INLINE UIView *WQGlassPanel(CGFloat radius)
{
    UIView *panel = [UIView new];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    WQGlassAttach(panel, NO, radius);
    return panel;
}

WQ_GLASS_INLINE UIView *WQGlassCellPanel(CGFloat radius)
{
    UIView *panel = [[UIView alloc] initWithFrame:CGRectZero];
    panel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    panel.tag = WQGlassCellPanelTag;
    WQGlassAttach(panel, NO, radius);
    return panel;
}

// No effect views exist any more; refresh is intentionally a no-op.
WQ_GLASS_INLINE void WQGlassRefreshIn(UIView *root)
{
    (void)root;
}

NS_ASSUME_NONNULL_END
