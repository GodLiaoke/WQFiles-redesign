//
//  WQGameFeatures.h
//  黑猫游戏工具箱 — game resource tools
//  GPL-3.0-or-later.
//
//  A neutral, user-driven file tool: show installed apps with their real
//  identifiers, let the user pick a container and save an injection path,
//  then copy user-supplied resource files (pak / sig / lua / anything) into it.
//  All writes go through WQAccess with an explicit confirmation and the
//  existing overwrite backup. Nothing is hidden, disguised, auto-run or
//  designed to defeat integrity checks.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WQGameCenterViewController : UITableViewController
@end

// Staged files live in a temporary folder so a security-scoped URL stays
// valid and large resources are never held in memory. These are the hooks the
// settings page uses to report and remove leftovers after an interrupted run.
NSString *WQGameStagingDir(void);
unsigned long long WQGameStagingBytes(void);
NSUInteger WQGameStagingFileCount(void);
void WQGameClearStaging(void);

NSUInteger WQGameSavedPathCount(void);
void WQGameClearSavedPaths(void);
void WQGameClearDetectionCache(void);

NS_ASSUME_NONNULL_END
