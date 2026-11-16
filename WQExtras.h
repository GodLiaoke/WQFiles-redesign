//
//  WQExtras.h
//  黑猫游戏工具箱 — 收藏、注入记录、校验、配置与关于
//  GPL-3.0-or-later.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WQBookmarksViewController : UITableViewController
@end
@interface WQInjectionHistoryViewController : UITableViewController
@end
@interface WQFileInspectorViewController : UITableViewController
@end
@interface WQConfigViewController : UITableViewController
@end
@interface WQAboutViewController : UITableViewController
@end

// Glass overview panel on the home screen; rebuild on each appearance.
UIView *WQOverviewHeader(CGFloat width);

NSUInteger WQBookmarkCount(void);
void WQBookmarkClear(void);
NSArray<NSDictionary *> *WQBookmarkEntries(void);
void WQBookmarkImportEntries(NSArray<NSDictionary *> *entries);

NSUInteger WQInjectionHistoryCount(void);
void WQInjectionHistoryClear(void);
void WQRecordInjection(NSDictionary *record);

// Implemented in main.m, which owns the private file-open dispatch.
void WQOpenPathFromExtras(UINavigationController *nav, NSString *path);

// Implemented by the game module, used by config import/export.
NSArray<NSDictionary *> *WQGameSavedEntries(void);
void WQGameImportEntries(NSArray<NSDictionary *> *entries);

NS_ASSUME_NONNULL_END
