//
//  WQAppearance.m
//  黑猫游戏工具箱 — 全局外观与自适应
//  GPL-3.0-or-later.
//

#import "WQAppearance.h"
#import <objc/runtime.h>

NSString *const WQAppearanceDidChangeNotification = @"WQAppearanceDidChangeNotification";

#pragma mark - Unified styling

void WQStyleCell(UITableViewCell *cell)
{
    if (!cell) return;
    cell.backgroundColor = UIColor.clearColor;
    cell.contentView.backgroundColor = UIColor.clearColor;
    if ([cell respondsToSelector:@selector(setBackgroundConfiguration:)])
        cell.backgroundConfiguration = [UIBackgroundConfiguration clearConfiguration];

    UIView *existing = cell.backgroundView;
    if (existing) {
        // Ours is already installed, or the screen has a deliberate custom
        // background. Never replace a custom one.
        if (existing.tag == WQGlassBackgroundTag) {
            cell.textLabel.adjustsFontForContentSizeCategory = YES;
            cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
        }
        return;
    }
    cell.backgroundView = WQGlassCellPanel(WQRadius3);
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
}

void WQStyleTableView(UITableView *tableView)
{
    if (!tableView) return;
    tableView.backgroundColor = WQColorBackground();
    tableView.separatorColor = WQColorLine();
    tableView.sectionIndexColor = WQColorText2();
    tableView.sectionIndexBackgroundColor = UIColor.clearColor;
    tableView.sectionIndexTrackingBackgroundColor = UIColor.clearColor;
    // The glass rows need a neutral backdrop to refract; a clear background
    // here would show the raw window and look flat.
    if (!tableView.backgroundView) {
        UIView *backdrop = [UIView new];
        backdrop.backgroundColor = WQColorBackground();
        tableView.backgroundView = backdrop;
    }
}

void WQStyleView(UIView *view)
{
    if (!view) return;
    if ([view isKindOfClass:UITableView.class]) { WQStyleTableView((UITableView *)view); return; }
    view.backgroundColor = WQColorBackground();
}

#pragma mark - Appearance mode

static NSInteger WQAppearanceMode(void)
{
    return [NSUserDefaults.standardUserDefaults integerForKey:WQSettingAppearanceModeKey];
}

NSString *WQAppearanceModeText(void)
{
    NSInteger mode = WQAppearanceMode();
    return mode == WQAppearanceModeLight ? @"浅色"
        : (mode == WQAppearanceModeDark ? @"深色" : @"跟随系统");
}

NSString *WQAppearanceStateText(void)
{
    NSString *glass = !WQGlassEnabled() ? @"平面中性"
        : (WQGlassClassAvailable() ? @"系统液态玻璃" : @"系统材质（降级）");
    NSString *rows = WQGlassRowsEnabled() ? @"全局行玻璃开启" : @"仅控件层玻璃";
    NSString *transparency = UIAccessibilityIsReduceTransparencyEnabled() ? @"已降低透明度" : @"标准透明度";
    NSString *contrast = UITraitCollection.currentTraitCollection.accessibilityContrast == UIAccessibilityContrastHigh
        ? @"高对比" : @"标准对比";
    return [NSString stringWithFormat:@"%@ · %@ · %@ · %@", glass, rows, transparency, contrast];
}

void WQApplyAppearanceMode(void)
{
    NSInteger mode = WQAppearanceMode();
    UIUserInterfaceStyle style = UIUserInterfaceStyleUnspecified;
    if (mode == WQAppearanceModeLight) style = UIUserInterfaceStyleLight;
    else if (mode == WQAppearanceModeDark) style = UIUserInterfaceStyleDark;
    UIApplication *app = UIApplication.sharedApplication;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows)
            window.overrideUserInterfaceStyle = style;
    }
}

void WQApplyGlobalAppearance(void)
{
    // System bars keep their native Liquid Glass; only colours are unified.
    UINavigationBar.appearance.tintColor = WQColorText();
    UIToolbar.appearance.tintColor = WQColorText();
    UISearchBar.appearance.tintColor = WQColorText();
    UISwitch.appearance.onTintColor = WQColorStrong();
}

#pragma mark - Runtime adaptation

void WQRefreshAllWindows(void)
{
    UIApplication *app = UIApplication.sharedApplication;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            WQGlassRefreshIn(window);
            [window setNeedsLayout];
        }
    }
    [NSNotificationCenter.defaultCenter postNotificationName:WQAppearanceDidChangeNotification object:nil];
}

void WQRegisterAppearanceNotifications(void)
{
    static id transparencyObserver, sizeObserver;
    NSOperationQueue *queue = NSOperationQueue.mainQueue;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    transparencyObserver = [center addObserverForName:UIAccessibilityReduceTransparencyStatusDidChangeNotification
        object:nil queue:queue usingBlock:^(NSNotification *__unused note) {
            WQRefreshAllWindows();
        }];
    sizeObserver = [center addObserverForName:UIContentSizeCategoryDidChangeNotification
        object:nil queue:queue usingBlock:^(NSNotification *__unused note) {
            WQRefreshAllWindows();
        }];
    (void)transparencyObserver; (void)sizeObserver;   // retained for process lifetime
}

#pragma mark - Runtime cell styling

// One small, idempotent hook makes EVERY screen in the app use the same glass
// rows, including modules that predate the redesign. Cells with their own
// backgroundView are respected, and the switch in Settings disables it.
@implementation UITableViewCell (WQAppearanceGlass)

+ (void)load
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = UITableViewCell.class;
        Method original = class_getInstanceMethod(cls, @selector(layoutSubviews));
        Method replacement = class_getInstanceMethod(cls, @selector(wq_appearance_layoutSubviews));
        if (original && replacement) method_exchangeImplementations(original, replacement);
    });
}

- (void)wq_appearance_layoutSubviews
{
    [self wq_appearance_layoutSubviews];   // swizzled: calls the original
    if (WQGlassRowsEnabled()) WQStyleCell(self);
}

@end
