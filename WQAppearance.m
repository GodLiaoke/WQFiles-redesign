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
    // Hard type guard: this must never receive a UIView/UIWindow.
    if (![cell isKindOfClass:UITableViewCell.class]) return;
    @try {
        cell.backgroundColor = UIColor.clearColor;
        cell.contentView.backgroundColor = UIColor.clearColor;
        if ([cell respondsToSelector:@selector(setBackgroundConfiguration:)])
            cell.backgroundConfiguration = [UIBackgroundConfiguration clearConfiguration];

        UIView *existing = cell.backgroundView;
        if (existing) {
            // Ours is already installed, or the screen has a deliberate custom
            // background. Never replace a custom one.
            if (existing.tag == WQGlassCellPanelTag || existing.tag == WQGlassBackgroundTag) {
                cell.textLabel.adjustsFontForContentSizeCategory = YES;
                cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
            }
            return;
        }
        cell.backgroundView = WQGlassCellPanel(WQRadius3);
        cell.textLabel.adjustsFontForContentSizeCategory = YES;
        cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    } @catch (NSException *__unused exception) {
        // Any cell-styling failure degrades to plain UIKit, not a blank screen.
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:WQGlassRowsEnabledKey];
        cell.backgroundView = nil;
    }
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

// Swizzle ONLY initWithStyle:reuseIdentifier:, which UITableViewCell declares
// itself. class_getInstanceMethod therefore returns a Method owned by
// UITableViewCell, never UIView's layoutSubviews. Swizzling layoutSubviews
// here was the white-screen bug: UIView's implementation got replaced for
// every view, so UIWindow's first layout raised an exception.
static void WQInstallCellGlass(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = UITableViewCell.class;
        SEL originalSEL = @selector(initWithStyle:reuseIdentifier:);
        SEL hookSEL = @selector(wq_appearance_initWithStyle:reuseIdentifier:);
        Method original = class_getInstanceMethod(cls, originalSEL);
        Method hook = class_getInstanceMethod(cls, hookSEL);
        if (original && hook && original != hook)
            method_exchangeImplementations(original, hook);
    });
}

void WQApplyGlobalAppearance(void)
{
    @try {
        // System bars keep their native Liquid Glass; only colours are unified.
        UINavigationBar.appearance.tintColor = WQColorText();
        UIToolbar.appearance.tintColor = WQColorText();
        UISearchBar.appearance.tintColor = WQColorText();
        UISwitch.appearance.onTintColor = WQColorStrong();
        WQInstallCellGlass();
        // Probe once at launch. If the device's material throws, the guarded
        // factory persists flat mode and every later call becomes a no-op.
        (void)WQGlassEffect(NO);
    } @catch (NSException *__unused exception) {
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        [d setBool:NO forKey:WQGlassEnabledKey];
        [d setBool:NO forKey:WQGlassRowsEnabledKey];
    }
}

#pragma mark - Runtime adaptation

void WQRefreshAllWindows(void)
{
    @try {
        UIApplication *app = UIApplication.sharedApplication;
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                WQGlassRefreshIn(window);
                [window setNeedsLayout];
            }
        }
    } @catch (NSException *__unused exception) {
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        [d setBool:NO forKey:WQGlassEnabledKey];
        [d setBool:NO forKey:WQGlassRowsEnabledKey];
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

#pragma mark - Safe runtime cell styling

// The hook is installed from didFinishLaunching (not +load), only swaps a
// method UITableViewCell declares itself, checks the returned object's class,
// and is gated by the opt-in switch. Any failure falls back to plain cells.
@implementation UITableViewCell (WQAppearanceGlass)

- (instancetype)wq_appearance_initWithStyle:(UITableViewCellStyle)style
                            reuseIdentifier:(NSString *)identifier
{
    // After the exchange this calls the ORIGINAL initializer.
    UITableViewCell *cell = [self wq_appearance_initWithStyle:style reuseIdentifier:identifier];
    if (![cell isKindOfClass:UITableViewCell.class]) return cell;
    @try {
        if (WQGlassRowsEnabled()) WQStyleCell(cell);
    } @catch (NSException *__unused exception) {
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:WQGlassRowsEnabledKey];
        cell.backgroundView = nil;
    }
    return cell;
}

@end
