//
//  WQLuaDeploy.h
//  WQ Files — debug script deployment
//  GPL-3.0-or-later.
//
//  A narrow, user-driven tool: locate an app container, make sure a relative
//  directory chain exists, then install one Lua file the user supplied. It uses
//  only the ordinary file APIs already in WQAccess (create / overwrite with a
//  backup). Nothing is hidden, disguised or written without a confirmation.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WQLuaDeployViewController : UITableViewController
@end

NS_ASSUME_NONNULL_END
