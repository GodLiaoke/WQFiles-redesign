//
//  WQGlass.h
//  黑猫游戏工具箱 — 系统液态玻璃材质层
//  GPL-3.0-or-later.
//
//  Liquid Glass is a SYSTEM material, not a hand-drawn gradient or glow. It is
//  applied globally to chrome AND content rows (the product requirement here),
//  with a single switch to fall back to flat neutral surfaces. Reduce
//  Transparency, Dark Mode, Increase Contrast and Dynamic Type are honoured by
//  WQAppearance.h.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#define WQ_GLASS_INLINE static inline __attribute__((unused))
#define WQGlassBackgroundTag      0x474C4153   /* "GLAS" */
#define WQGlassProminentTag       (WQGlassBackgroundTag + 1)
/* Distinct from the glass subview tags: viewWithTag: returns self when
   the host has the same tag, which would make WQGlassAttach skip itself. */
#define WQGlassCellPanelTag       0x474C4350   /* "GLCP" */
#define WQGlassEnabledKey        @"WQSettingGlass"
#define WQGlassRowsEnabledKey    @"WQSettingGlassRows"

WQ_GLASS_INLINE BOOL WQGlassEnabled(void)
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if ([d objectForKey:WQGlassEnabledKey]) return [d boolForKey:WQGlassEnabledKey];
    return !UIAccessibilityIsReduceTransparencyEnabled();
}

WQ_GLASS_INLINE BOOL WQGlassRowsEnabled(void)
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if ([d objectForKey:WQGlassRowsEnabledKey]) return [d boolForKey:WQGlassRowsEnabledKey];
    // Safe default. The row-level hook is opt-in from Settings; if anything in
    // the system material misbehaves on a device, launch still stays flat.
    return NO;
}

WQ_GLASS_INLINE BOOL WQGlassClassAvailable(void)
{
    return NSClassFromString(@"UIGlassEffect") != Nil;
}

// Returns nil when the user disabled glass or Reduce Transparency is on.
// Callers then use a plain neutral fill; no blur is layered on top.
// A system material must NEVER be able to break app launch. Everything that
// touches UIKit's private class surface is guarded; on any exception we persist
// a flat-mode fallback so the rest of the process never retries the material.
WQ_GLASS_INLINE UIVisualEffect *_Nullable WQGlassEffect(BOOL prominent)
{
    if (!WQGlassEnabled()) return nil;
    @try {
        Class cls = NSClassFromString(@"UIGlassEffect");
        if (cls) {
            id effect = [[cls alloc] init];   // defaults to .regular
            if ([effect isKindOfClass:UIVisualEffect.class]) {
                if (prominent && [effect respondsToSelector:NSSelectorFromString(@"setTintColor:")])
                    [effect setValue:[UIColor colorWithWhite:0.32 alpha:0.16] forKey:@"tintColor"];
                if ([effect respondsToSelector:NSSelectorFromString(@"setIsInteractive:")])
                    [effect setValue:@YES forKey:@"isInteractive"];
                return (UIVisualEffect *)effect;
            }
        }
    } @catch (NSException *__unused exception) {
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:WQGlassEnabledKey];
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:WQGlassRowsEnabledKey];
        return nil;
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
}

WQ_GLASS_INLINE UIView *_Nullable WQGlassSubview(UIView *host)
{
    UIView *v = [host viewWithTag:WQGlassBackgroundTag];
    if (!v) v = [host viewWithTag:WQGlassProminentTag];
    return v;
}

// Attach glass as the bottom-most subview of any view. Idempotent, pinned by
// constraints so it stays correct under Auto Layout, and never eats touches.
WQ_GLASS_INLINE void WQGlassAttach(UIView *host, BOOL prominent, CGFloat radius)
{
    if (WQGlassSubview(host)) return;
    @try {
        NSInteger tag = prominent ? WQGlassProminentTag : WQGlassBackgroundTag;
        UIVisualEffect *effect = WQGlassEffect(prominent);
        UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:effect];
        glass.tag = tag;
        glass.userInteractionEnabled = NO;
        glass.translatesAutoresizingMaskIntoConstraints = NO;
        glass.layer.cornerRadius = radius;
        glass.clipsToBounds = YES;
        if (!effect) {
            glass.backgroundColor = prominent
                ? [UIColor colorWithWhite:0.90 alpha:1.0]
                : UIColor.secondarySystemGroupedBackgroundColor;
        }
        [host insertSubview:glass atIndex:0];
        [NSLayoutConstraint activateConstraints:@[
            [glass.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
            [glass.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
            [glass.topAnchor constraintEqualToAnchor:host.topAnchor],
            [glass.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
        ]];
        host.backgroundColor = UIColor.clearColor;
        host.layer.cornerRadius = radius;
        host.clipsToBounds = YES;
        host.layer.shadowOpacity = 0;
        host.layer.shadowRadius = 0;
        host.layer.borderWidth = 0;
    } @catch (NSException *__unused exception) {
        // Panels are built in viewDidLoad; an exception there would leave the
        // window blank. Degrade to a plain surface instead.
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        [d setBool:NO forKey:WQGlassEnabledKey];
        [d setBool:NO forKey:WQGlassRowsEnabledKey];
        host.backgroundColor = prominent
            ? [UIColor colorWithWhite:0.90 alpha:1.0]
            : UIColor.secondarySystemGroupedBackgroundColor;
        host.layer.cornerRadius = radius;
        host.clipsToBounds = YES;
    }
}

// A glass panel used for the credit blocks, the overview and the primary entry.
WQ_GLASS_INLINE UIView *WQGlassPanel(CGFloat radius)
{
    UIView *panel = [UIView new];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    WQGlassAttach(panel, NO, radius);
    return panel;
}

// A glass background for a table cell. It is installed as backgroundView so
// the cell itself is never clipped (swipe actions and accessories stay intact).
WQ_GLASS_INLINE UIView *WQGlassCellPanel(CGFloat radius)
{
    UIView *panel = [[UIView alloc] initWithFrame:CGRectZero];
    panel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    panel.tag = WQGlassCellPanelTag;
    WQGlassAttach(panel, NO, radius);
    return panel;
}

// Called when traits change: refresh the effect of every attached glass view.
// Stored tags tell us whether the view was the prominent variant.
WQ_GLASS_INLINE void WQGlassRefreshIn(UIView *root)
{
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if ([v isKindOfClass:UIVisualEffectView.class] &&
            (v.tag == WQGlassBackgroundTag || v.tag == WQGlassProminentTag)) {
            BOOL prominent = v.tag == WQGlassProminentTag;
            UIVisualEffectView *effectView = (UIVisualEffectView *)v;
            @try {
                effectView.effect = WQGlassEffect(prominent);
                effectView.backgroundColor = WQGlassEnabled() ? UIColor.clearColor
                    : (prominent ? [UIColor colorWithWhite:0.90 alpha:1.0]
                                 : UIColor.secondarySystemGroupedBackgroundColor);
            } @catch (NSException *__unused exception) {
                effectView.effect = nil;
                effectView.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
            }
        }
        for (UIView *child in v.subviews) [stack addObject:child];
    }
}

NS_ASSUME_NONNULL_END
