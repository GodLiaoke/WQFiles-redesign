//
//  WQAppearance.h
//  黑猫游戏工具箱 — 全局外观（平面回归）
//  GPL-3.0-or-later.
//

#import <UIKit/UIKit.h>
#import "WQDesignTokens.h"
#import "WQGlass.h"

NS_ASSUME_NONNULL_BEGIN

// Kept for compatibility with saved preferences; this build is always light.
#define WQSettingAppearanceModeKey @"WQSettingAppearanceMode"
#define WQAppearanceModeFollow 0
#define WQAppearanceModeLight 1
#define WQAppearanceModeDark 2

extern NSString *const WQAppearanceDidChangeNotification;

void WQApplyAppearanceMode(void);
void WQApplyGlobalAppearance(void);
void WQRegisterAppearanceNotifications(void);
void WQRefreshAllWindows(void);

// Unified flat styling. Called when a screen is pushed; there is NO runtime
// method swizzling, so every cell keeps UIKit's own layout.
void WQStyleTableView(UITableView *tableView);
void WQStyleView(UIView *view);
void WQStyleCell(UITableViewCell *cell);

NSString *WQAppearanceModeText(void);
NSString *WQAppearanceStateText(void);

NS_ASSUME_NONNULL_END
