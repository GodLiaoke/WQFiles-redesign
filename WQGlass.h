//
//  WQGlass.h
//  WQ Files — 系统液态玻璃材质层
//  GPL-3.0-or-later.
//
//  Liquid Glass is a SYSTEM material, not a hand-drawn gradient or glow. This
//  layer only puts it on the chrome: primary entries, buttons, input fields,
//  floating controls and the credit panel. Content rows stay flat, following
//  Apple's HIG ("glass belongs to the navigation/control layer").
//
//  UIGlassEffect is iOS 26+. It is resolved at runtime so the same binary also
//  builds with older SDKs and degrades on devices where the class is absent.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#define WQ_GLASS_INLINE static inline __attribute__((unused))
#define WQGlassBackgroundTag 0x474C4153   /* "GLAS" */

// The user can turn the material off in Settings; a plain neutral surface is
// then used instead. Reduce Transparency is honoured automatically.
#define WQGlassEnabledKey @"WQSettingGlass"

WQ_GLASS_INLINE BOOL WQGlassEnabled(void)
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if ([d objectForKey:WQGlassEnabledKey]) return [d boolForKey:WQGlassEnabledKey];
    return !UIAccessibilityIsReduceTransparencyEnabled();
}

WQ_GLASS_INLINE BOOL WQGlassClassAvailable(void)
{
    return NSClassFromString(@"UIGlassEffect") != Nil;
}

// Returns nil when the user disabled glass or Reduce Transparency is on.
// Callers then use a plain neutral fill; no blur is layered on top.
WQ_GLASS_INLINE UIVisualEffect *_Nullable WQGlassEffect(BOOL prominent)
{
    if (!WQGlassEnabled()) return nil;
    Class cls = NSClassFromString(@"UIGlassEffect");
    if (cls) {
        // UIGlassEffect() defaults to .regular. Style is deliberately not
        // forced: .clear is for media, .regular is correct over our neutral UI.
        id effect = [[cls alloc] init];
        if (!effect) return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
        // Tint only the one primary action, and keep it neutral — never blue.
        if (prominent && [effect respondsToSelector:NSSelectorFromString(@"setTintColor:")])
            [effect setValue:[UIColor colorWithWhite:0.32 alpha:0.16] forKey:@"tintColor"];
        if ([effect respondsToSelector:NSSelectorFromString(@"setIsInteractive:")])
            [effect setValue:@YES forKey:@"isInteractive"];
        return (UIVisualEffect *)effect;
    }
    // Older iOS: a system material, still neutral, still no custom gradient.
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
}

// Attach glass as the bottom-most subview of any control. Idempotent, pinned
// by constraints so it stays correct under Auto Layout, and never eats touches.
WQ_GLASS_INLINE void WQGlassAttach(UIView *host, BOOL prominent, CGFloat radius)
{
    if ([host viewWithTag:WQGlassBackgroundTag]) return;
    UIVisualEffect *effect = WQGlassEffect(prominent);
    UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:effect];
    glass.tag = WQGlassBackgroundTag;
    glass.userInteractionEnabled = NO;
    glass.translatesAutoresizingMaskIntoConstraints = NO;
    glass.layer.cornerRadius = radius;
    glass.clipsToBounds = YES;
    if (!effect) {
        glass.backgroundColor = prominent
            ? [UIColor colorWithWhite:0.90 alpha:1.0]
            : [UIColor colorWithWhite:0.97 alpha:1.0];
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
}

// A glass panel used for the credit block and the primary home entry.
WQ_GLASS_INLINE UIView *WQGlassPanel(CGFloat radius)
{
    UIView *panel = [UIView new];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    WQGlassAttach(panel, NO, radius);
    return panel;
}

NS_ASSUME_NONNULL_END
