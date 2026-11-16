//
//  WQAppearance.m
//  黑猫游戏工具箱 — 全局外观（平面回归）
//  GPL-3.0-or-later.
//
//  不再交换任何 UIKit 方法，不再注入单元格背景，不再创建材质视图。
//  所有页面统一固定浅色中性色，导航栏文字色与表视图底色一致。
//

#import "WQAppearance.h"

NSString *const WQAppearanceDidChangeNotification = @"WQAppearanceDidChangeNotification";

#pragma mark - Unified flat styling

void WQStyleCell(UITableViewCell *cell)
{
    if (![cell isKindOfClass:UITableViewCell.class]) return;
    cell.backgroundColor = WQColorSurface();
    cell.contentView.backgroundColor = WQColorSurface();
    cell.backgroundView = nil;
    cell.selectedBackgroundView = nil;
    cell.textLabel.adjustsFontForContentSizeCategory = NO;
    cell.detailTextLabel.adjustsFontForContentSizeCategory = NO;
}

void WQStyleTableView(UITableView *tableView)
{
    if (![tableView isKindOfClass:UITableView.class]) return;
    tableView.backgroundColor = WQColorBackground();
    tableView.separatorColor = WQColorLine();
    tableView.sectionIndexColor = WQColorText2();
    tableView.sectionIndexBackgroundColor = UIColor.clearColor;
    tableView.sectionIndexTrackingBackgroundColor = UIColor.clearColor;
    if ([tableView.backgroundView isKindOfClass:UIView.class] &&
        tableView.backgroundView.tag != WQGlassCellPanelTag)
        tableView.backgroundView.backgroundColor = WQColorBackground();
}

void WQStyleView(UIView *view)
{
    if (!view) return;
    if ([view isKindOfClass:UITableView.class]) { WQStyleTableView((UITableView *)view); return; }
    view.backgroundColor = WQColorBackground();
}

#pragma mark - Appearance mode (fixed light)

NSString *WQAppearanceModeText(void)   { return @"浅色"; }
NSString *WQAppearanceStateText(void)  { return @"平面中性 · 固定档位"; }

void WQApplyAppearanceMode(void)
{
    // The design tokens are fixed light neutral colours. Forcing the light
    // interface style keeps system bars, keyboards and alerts consistent with
    // them; otherwise a Dark Mode device would show dark bars with dark text.
    UIApplication *app = UIApplication.sharedApplication;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows)
            window.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    }
}

void WQApplyGlobalAppearance(void)
{
    UINavigationBar.appearance.tintColor = WQColorText();
    UIToolbar.appearance.tintColor = WQColorText();
    UISearchBar.appearance.tintColor = WQColorText();
    UISwitch.appearance.onTintColor = WQColorStrong();
    WQApplyAppearanceMode();
}

#pragma mark - Refresh

void WQRefreshAllWindows(void)
{
    UIApplication *app = UIApplication.sharedApplication;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            WQGlassRefreshIn(window);   // no-op in the flat build
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
