//
//  WQGameFeatures.h
//  WQ Files — game resource tools
//  GPL-3.0-or-later.
//
//  A neutral, user-driven file tool: detect installed games, browse their data
//  container, save an injection path, then copy user-supplied resource files
//  (pak / sig / lua / anything) into it. All writes go through WQAccess with an
//  explicit confirmation and the existing overwrite backup. Nothing is hidden,
//  disguised, auto-run or designed to defeat integrity checks.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WQGameCenterViewController : UITableViewController
@end

NS_ASSUME_NONNULL_END
