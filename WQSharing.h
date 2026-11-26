//
//  WQSharing.h
//  黑猫游戏工具箱 temporary exports and share sheets
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

void wq_share(UIViewController *host, NSString *path, UIView *_Nullable source);
void wq_share_folder(UIViewController *host, NSString *dir, NSString *_Nullable zipName, UIView *_Nullable source);
// Multi-selection export: copies the chosen items into one temporary folder,
// zips that folder with the system zipper, then opens the share sheet.
void wq_share_paths(UIViewController *host, NSArray<NSString *> *paths, NSString *zipName, UIView *_Nullable source);
void wq_share_cancel(UIViewController *host);

NS_ASSUME_NONNULL_END
