//
//  WQAppearance.h
//  黑猫游戏工具箱 — 全局外观与自适应
//  GPL-3.0-or-later.
//

#import <UIKit/UIKit.h>
#import "WQDesignTokens.h"

NS_ASSUME_NONNULL_BEGIN

// 0 = 跟随系统, 1 = 浅色, 2 = 深色
#define WQSettingAppearanceModeKey @"WQSettingAppearanceMode"
#define WQAppearanceModeFollow 0
#define WQAppearanceModeLight 1
#define WQAppearanceModeDark 2

extern NSString *const WQAppearanceDidChangeNotification;

// Called once at launch and whenever the mode setting changes. Applies the
// override to every scene window, so all screens adapt together.
void WQApplyAppearanceMode(void);
void WQApplyGlobalAppearance(void);
void WQRegisterAppearanceNotifications(void);
void WQRefreshAllWindows(void);

// Unified styling. WQStyleCell is also injected into every UITableViewCell at
// runtime (see WQAppearance.m), so third-party screens in this app match the
// game module without duplicating code in each controller.
void WQStyleTableView(UITableView *tableView);
void WQStyleView(UIView *view);
void WQStyleCell(UITableViewCell *cell);

NSString *WQAppearanceModeText(void);
NSString *WQAppearanceStateText(void);

NS_ASSUME_NONNULL_END
