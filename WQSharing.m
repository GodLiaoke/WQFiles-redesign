//
//  WQSharing.m
//  黑猫游戏工具箱 temporary exports and share sheets
//  GPL-3.0-or-later.
//

#import "WQSharing.h"
#import "WQUI.h"
#import "WQAccess.h"
#import <objc/runtime.h>
#import <sys/stat.h>

@interface WQSharePreparation : NSObject
@property (nonatomic, weak) UIViewController *host;
@property (nonatomic, weak) UIAlertController *hud;
@property (nonatomic, copy) NSString *exportDir;
@property (atomic, getter=isCancelled) BOOL cancelled;
@end

@implementation WQSharePreparation
@end

static char kWQSharePreparationKey;
static char kWQShareInFlightKey;

static NSString *wq_unique_export_directory(void)
{
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                     [@"WQShare-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSError *error = nil;
    return [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES
                                                   attributes:nil error:&error] ? dir : nil;
}

static void wq_remove_export(NSString *exportDir)
{
    if (exportDir.length) [NSFileManager.defaultManager removeItemAtPath:exportDir error:nil];
}

static BOOL wq_share_host_is_active(UIViewController *host)
{
    if (!host || !host.isViewLoaded || !host.view.window) return NO;
    UIWindowScene *scene = host.view.window.windowScene;
    if (scene && scene.activationState != UISceneActivationStateForegroundActive) return NO;
    UINavigationController *nav = host.navigationController;
    if (nav && nav.topViewController != host) return NO;
    if (host.presentedViewController && !host.presentedViewController.isBeingDismissed) return NO;
    return YES;
}

static BOOL wq_shareable_regular_file(NSString *path)
{
    if (!path.length) return NO;
    struct stat st;
    // Do not follow a final symlink: wq_copy_to_local uses O_NOFOLLOW too.
    if (lstat(path.fileSystemRepresentation, &st) == 0) return S_ISREG(st.st_mode);
    if (wq_grant(path) && lstat(path.fileSystemRepresentation, &st) == 0) return S_ISREG(st.st_mode);
    return NO;
}

static void wq_clear_preparation(UIViewController *host, WQSharePreparation *preparation)
{
    if (!host) return;
    if (objc_getAssociatedObject(host, &kWQSharePreparationKey) == preparation) {
        objc_setAssociatedObject(host, &kWQSharePreparationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static BOOL wq_share_in_flight(UIViewController *host)
{
    return host && (objc_getAssociatedObject(host, &kWQSharePreparationKey) ||
                    objc_getAssociatedObject(host, &kWQShareInFlightKey));
}

static void wq_clear_in_flight(UIViewController *host)
{
    if (!host) return;
    objc_setAssociatedObject(host, &kWQShareInFlightKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL wq_present_share(UIViewController *host, NSString *file, NSString *exportDir, UIView *source)
{
    if (!wq_share_host_is_active(host)) {
        wq_remove_export(exportDir);
        return NO;
    }
    UIActivityViewController *share = [[UIActivityViewController alloc]
        initWithActivityItems:@[[NSURL fileURLWithPath:file]] applicationActivities:nil];
    UIView *anchor = source.window ? source : host.view;
    share.popoverPresentationController.sourceView = anchor;
    share.popoverPresentationController.sourceRect = anchor.bounds;
    share.completionWithItemsHandler = ^(UIActivityType __unused activityType, BOOL __unused completed,
                                         NSArray *__unused returnedItems, NSError *__unused activityError) {
        wq_remove_export(exportDir);
    };
    [host presentViewController:share animated:YES completion:^{
        // A presentation rejected after the visibility check must not strand the export.
        if (!share.presentingViewController) wq_remove_export(exportDir);
    }];
    return YES;
}

// Cancel folder preparation when its browser is popped or otherwise abandoned.
// The export is removed by the worker's completion, after any in-progress copy has stopped.
void wq_share_cancel(UIViewController *host)
{
    if (!host) return;
    wq_clear_in_flight(host);
    WQSharePreparation *preparation = objc_getAssociatedObject(host, &kWQSharePreparationKey);
    preparation.cancelled = YES;
    if (host) objc_setAssociatedObject(host, &kWQSharePreparationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIAlertController *hud = preparation.hud;
    if (hud && host.presentedViewController == hud) {
        [host dismissViewControllerAnimated:NO completion:nil];
    }
}

// Copies a file into a unique temporary directory so concurrent shares cannot
// overwrite one another. The export is removed when the share sheet finishes.
void wq_share(UIViewController *host, NSString *path, UIView *source)
{
    if (!host) return;
    if (wq_share_in_flight(host)) {
        wq_alert(host, @"正在分享", @"Wait for the current share to finish before starting another.");
        return;
    }
    objc_setAssociatedObject(host, &kWQShareInFlightKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIViewController *weakHost = host;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = nil;
        NSString *outDir = nil;
        NSString *tmp = nil;
        BOOL ok = NO;
        if (!wq_shareable_regular_file(path)) {
            error = @"只能分享普通文件。";
        } else {
            outDir = wq_unique_export_directory();
            tmp = outDir ? [outDir stringByAppendingPathComponent:path.lastPathComponent] : nil;
            ok = tmp && wq_copy_to_local(path, tmp, &error);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *strongHost = weakHost;
            if (!ok) {
                wq_remove_export(outDir);
                wq_clear_in_flight(strongHost);
                if (wq_share_host_is_active(strongHost)) {
                    wq_alert(strongHost, @"Cannot share", error ?: @"Could not create a temporary export folder");
                }
                return;
            }
            if (!wq_share_host_is_active(strongHost) ||
                !wq_present_share(strongHost, tmp, outDir, source)) {
                wq_remove_export(outDir);
            }
            wq_clear_in_flight(strongHost);
        });
    });
}

static NSString *wq_zip_name(NSString *dir);

// Zips a folder (the system's own zipper via NSFileCoordinator) and opens the
// share sheet, so a backup can go out over AirDrop, Files, Mail…
void wq_share_folder(UIViewController *host, NSString *dir, NSString *zipName, UIView *source)
{
    if (!wq_share_host_is_active(host)) return;
    if (wq_share_in_flight(host)) {
        wq_alert(host, @"正在分享", @"Wait for the current share to finish before starting another.");
        return;
    }
    WQSharePreparation *preparation = [WQSharePreparation new];
    preparation.host = host;
    UIAlertController *hud = [UIAlertController alertControllerWithTitle:@"Preparing…"
        message:@"Compressing the folder" preferredStyle:UIAlertControllerStyleAlert];
    [hud addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *__unused action) {
        preparation.cancelled = YES;
        objc_setAssociatedObject(host, &kWQSharePreparationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [host dismissViewControllerAnimated:YES completion:nil];
    }]];
    preparation.hud = hud;
    objc_setAssociatedObject(host, &kWQSharePreparationKey, preparation, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [host presentViewController:hud animated:YES completion:nil];
    dispatch_async(wq_io(), ^{
        if (preparation.isCancelled) return;
        NSString *resolvedName = zipName ?: wq_zip_name(dir);
        NSString *safe = [[resolvedName componentsSeparatedByCharactersInSet:
                           [NSCharacterSet characterSetWithCharactersInString:@"/:"]] componentsJoinedByString:@"-"];
        NSString *outDir = wq_unique_export_directory();
        preparation.exportDir = outDir;
        NSString *zip = outDir ? [outDir stringByAppendingPathComponent:[safe stringByAppendingPathExtension:@"zip"]] : nil;
        NSFileManager *fm = NSFileManager.defaultManager;
        wq_grant(dir);
        __block NSError *copyError = nil;
        NSError *coordError = nil;
        if (zip && !preparation.isCancelled) {
            [[NSFileCoordinator new] coordinateReadingItemAtURL:[NSURL fileURLWithPath:dir]
                                                        options:NSFileCoordinatorReadingForUploading
                                                          error:&coordError byAccessor:^(NSURL *zipped) {
                if (!preparation.isCancelled) [fm copyItemAtURL:zipped toURL:[NSURL fileURLWithPath:zip] error:&copyError];
            }];
        }
        BOOL ok = zip && !preparation.isCancelled && [fm fileExistsAtPath:zip];
        NSString *why = (coordError ?: copyError).localizedDescription ?: @"Could not create the ZIP";
        wq_log(@"share zip: %@ -> %@ %@", dir, zip.lastPathComponent, ok ? @"OK" : why);
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *strongHost = preparation.host;
            BOOL hudPresented = strongHost && strongHost.presentedViewController == hud;
            void (^finish)(void) = ^{
                BOOL stale = preparation.isCancelled || !wq_share_host_is_active(strongHost);
                wq_clear_preparation(strongHost, preparation);
                if (!ok || stale) {
                    wq_remove_export(outDir);
                    if (!stale && wq_share_host_is_active(strongHost)) {
                        wq_alert(strongHost, @"Cannot share", why);
                    }
                    return;
                }
                if (!wq_present_share(strongHost, zip, outDir, source)) wq_remove_export(outDir);
            };
            if (hudPresented) [strongHost dismissViewControllerAnimated:YES completion:finish];
            else finish();
        });
    });
}

// "Santander 2026-11-09 14.02.11" for AppBackups/<bundle id>/<date>, else the folder name.
static NSString *wq_zip_name(NSString *dir)
{
    NSArray *parts = dir.pathComponents;
    NSUInteger i = [parts indexOfObject:@"AppBackups"];
    if (i != NSNotFound && i + 2 == parts.count - 1) {
        NSString *bid = parts[i + 1];
        return [NSString stringWithFormat:@"%@ %@", wq_display_name(bid) ?: bid, parts.lastObject];
    }
    if (i != NSNotFound && i + 1 == parts.count - 1) {
        NSString *bid = parts.lastObject;
        return [NSString stringWithFormat:@"%@ backups", wq_display_name(bid) ?: bid];
    }
    return dir.lastPathComponent;
}


#pragma mark - Multi-selection ZIP export

// A unique destination name keeps two files with the same leaf name (possible
// when the list was filtered or built from different folders) both in the ZIP.
static NSString *WQExportUniquePath(NSFileManager *fm, NSString *dir, NSString *name)
{
    NSString *dest = [dir stringByAppendingPathComponent:name];
    if (![fm fileExistsAtPath:dest]) return dest;
    NSString *base = name.stringByDeletingPathExtension;
    NSString *ext = name.pathExtension;
    for (NSUInteger i = 2; i < 1000; i++) {
        NSString *candidate = ext.length
            ? [NSString stringWithFormat:@"%@-%lu.%@", base, (unsigned long)i, ext]
            : [NSString stringWithFormat:@"%@-%lu", name, (unsigned long)i];
        NSString *path = [dir stringByAppendingPathComponent:candidate];
        if (![fm fileExistsAtPath:path]) return path;
    }
    return [dir stringByAppendingPathComponent:
        [NSUUID.UUID.UUIDString stringByAppendingPathExtension:(ext.length ? ext : @"dat")]];
}

static void WQExportHUD(WQSharePreparation *preparation, NSString *text)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!preparation.isCancelled) preparation.hud.message = text;
    });
}

// Copies a selected directory into the staging tree. Symbolic links and
// special files are skipped, never followed; every source folder is listed
// through wq_list so sandbox tokens are obtained when needed.
static BOOL WQExportCopyTree(NSString *src, NSString *dst, NSUInteger depth,
                             WQSharePreparation *preparation,
                             NSUInteger *files, unsigned long long *bytes,
                             NSUInteger *skipped, NSUInteger *failed, NSUInteger *truncated,
                             NSString **firstError)
{
    if (preparation.isCancelled) return NO;
    if (depth > 12) { (*truncated)++; return YES; }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *dirError = nil;
    if (![fm createDirectoryAtPath:dst withIntermediateDirectories:YES attributes:nil error:&dirError]) {
        (*failed)++;
        if (firstError && !*firstError) *firstError = dirError.localizedDescription ?: @"无法创建临时目录";
        return NO;
    }
    NSArray<NSString *> *names = wq_list(src, nil);
    if (!names) {
        (*skipped)++;   // unreadable folder is skipped, not a whole-export failure
        return YES;
    }
    for (NSString *name in names) {
        if (preparation.isCancelled) return NO;
        if (!name.length || [name isEqualToString:@"."] || [name isEqualToString:@".."]) continue;
        NSString *full = [src stringByAppendingPathComponent:name];
        NSString *dest = [dst stringByAppendingPathComponent:name];
        struct stat st = {0};
        if (lstat(full.fileSystemRepresentation, &st) != 0 && !wq_stat(full, &st)) { (*skipped)++; continue; }
        if (S_ISLNK(st.st_mode)) { (*skipped)++; continue; }
        if (S_ISDIR(st.st_mode)) {
            if (!WQExportCopyTree(full, dest, depth + 1, preparation, files, bytes,
                                  skipped, failed, truncated, firstError)) return NO;
            continue;
        }
        if (!S_ISREG(st.st_mode)) { (*skipped)++; continue; }
        if (*files >= 2000 || *bytes >= 512ULL * 1024 * 1024) {
            (*truncated)++;
            return NO;
        }
        NSString *why = nil;
        if (!wq_copy_to_local(full, dest, &why)) {
            // Fall back to a plain copy after an explicit grant; some folders
            // hand out tokens only for the child path.
            wq_grant(full);
            NSError *copyError = nil;
            if (![fm copyItemAtPath:full toPath:dest error:&copyError]) {
                (*failed)++;
                if (firstError && !*firstError) *firstError = why ?: (copyError.localizedDescription ?: @"复制失败");
                continue;
            }
        }
        (*files)++;
        *bytes += (unsigned long long)st.st_size;
    }
    return YES;
}

void wq_share_paths(UIViewController *host, NSArray<NSString *> *paths,
                    NSString *zipName, UIView *source)
{
    if (!wq_share_host_is_active(host)) return;
    if (wq_share_in_flight(host)) {
        wq_alert(host, @"正在分享", @"Wait for the current share to finish before starting another.");
        return;
    }
    if (paths.count == 0) return;
    WQSharePreparation *preparation = [WQSharePreparation new];
    preparation.host = host;
    UIAlertController *hud = [UIAlertController alertControllerWithTitle:@"正在准备导出"
        message:@"正在复制所选项目…" preferredStyle:UIAlertControllerStyleAlert];
    [hud addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *__unused action) {
        preparation.cancelled = YES;
        objc_setAssociatedObject(host, &kWQSharePreparationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [host dismissViewControllerAnimated:YES completion:nil];
    }]];
    preparation.hud = hud;
    objc_setAssociatedObject(host, &kWQSharePreparationKey, preparation, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [host presentViewController:hud animated:YES completion:nil];

    dispatch_async(wq_io(), ^{
        NSString *safe = [[(zipName ?: @"导出") componentsSeparatedByCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:@"/:"]] componentsJoinedByString:@"-"];
        NSString *outDir = wq_unique_export_directory();
        preparation.exportDir = outDir;
        NSString *staging = outDir ? [outDir stringByAppendingPathComponent:safe] : nil;
        NSString *zip = outDir ? [outDir stringByAppendingPathComponent:
                                  [safe stringByAppendingPathExtension:@"zip"]] : nil;
        NSFileManager *fm = NSFileManager.defaultManager;
        NSUInteger files = 0, skipped = 0, failed = 0, truncated = 0;
        unsigned long long bytes = 0;
        NSString *firstError = nil;
        BOOL ok = NO;
        if (staging && [fm createDirectoryAtPath:staging withIntermediateDirectories:NO
                                     attributes:nil error:nil]) {
            NSUInteger index = 0;
            for (NSString *path in paths) {
                if (preparation.isCancelled) break;
                index++;
                if (index == 1 || index % 5 == 0 || index == paths.count)
                    WQExportHUD(preparation, [NSString stringWithFormat:
                        @"正在复制 %lu / %lu", (unsigned long)index, (unsigned long)paths.count]);
                NSString *dest = WQExportUniquePath(fm, staging, path.lastPathComponent);
                struct stat st = {0};
                if (lstat(path.fileSystemRepresentation, &st) != 0 && !wq_stat(path, &st)) { failed++; continue; }
                if (S_ISLNK(st.st_mode)) { skipped++; continue; }
                if (S_ISDIR(st.st_mode)) {
                    if (!WQExportCopyTree(path, dest, 1, preparation, &files, &bytes,
                                          &skipped, &failed, &truncated, &firstError)) break;
                } else if (S_ISREG(st.st_mode)) {
                    if (files >= 2000 || bytes >= 512ULL * 1024 * 1024) { truncated++; break; }
                    NSString *why = nil;
                    if (!wq_copy_to_local(path, dest, &why)) {
                        wq_grant(path);
                        NSError *copyError = nil;
                        if (![fm copyItemAtPath:path toPath:dest error:&copyError]) {
                            failed++;
                            if (!firstError) firstError = why ?: (copyError.localizedDescription ?: @"复制失败");
                            continue;
                        }
                    }
                    files++;
                    bytes += (unsigned long long)st.st_size;
                } else { skipped++; }
            }
            if (!preparation.isCancelled && files > 0) {
                WQExportHUD(preparation, @"正在压缩成 ZIP…");
                __block NSError *copyError = nil;
                NSError *coordError = nil;
                [[NSFileCoordinator new] coordinateReadingItemAtURL:[NSURL fileURLWithPath:staging]
                    options:NSFileCoordinatorReadingForUploading error:&coordError
                    byAccessor:^(NSURL *zipped) {
                        if (!preparation.isCancelled)
                            [fm copyItemAtURL:zipped toURL:[NSURL fileURLWithPath:zip] error:&copyError];
                    }];
                ok = zip && [fm fileExistsAtPath:zip];
                if (!ok && !firstError)
                    firstError = (coordError ?: copyError).localizedDescription ?: @"无法创建 ZIP";
            } else if (!preparation.isCancelled && !firstError && files == 0) {
                firstError = @"没有可导出的普通文件；所选目录可能为空，或全部是符号链接。";
            }
        }
        [fm removeItemAtPath:staging error:nil];
        NSString *why = firstError ?: @"无法创建 ZIP";
        wq_log(@"export zip: %lu selected -> %@ %@ (files=%lu bytes=%llu skipped=%lu failed=%lu truncated=%lu)",
               (unsigned long)paths.count, zip.lastPathComponent ?: @"(none)", ok ? @"OK" : why,
               (unsigned long)files, bytes, (unsigned long)skipped, (unsigned long)failed,
               (unsigned long)truncated);
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *strongHost = preparation.host;
            BOOL hudPresented = strongHost && strongHost.presentedViewController == hud;
            void (^finish)(void) = ^{
                BOOL stale = preparation.isCancelled || !wq_share_host_is_active(strongHost);
                wq_clear_preparation(strongHost, preparation);
                if (!ok || stale) {
                    wq_remove_export(outDir);
                    if (!stale && wq_share_host_is_active(strongHost))
                        wq_alert(strongHost, @"导出失败", why);
                    return;
                }
                if (skipped || failed || truncated) {
                    UIAlertController *note = [UIAlertController alertControllerWithTitle:@"导出说明"
                        message:[NSString stringWithFormat:
                            @"已打包 %lu 个文件（%@）。跳过 %lu 项，失败 %lu 项，达到上限 %lu 项。\n\n"
                            @"符号链接与非普通文件不会写入 ZIP；目录最深 12 层、最多 2000 个文件或 512 MB。",
                            (unsigned long)files, wq_size_text(bytes), (unsigned long)skipped,
                            (unsigned long)failed, (unsigned long)truncated]
                        preferredStyle:UIAlertControllerStyleAlert];
                    [note addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
                        handler:^(UIAlertAction *__unused a) { wq_remove_export(outDir); }]];
                    [note addAction:[UIAlertAction actionWithTitle:@"继续导出" style:UIAlertActionStyleDefault
                        handler:^(UIAlertAction *__unused a) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                if (!wq_present_share(strongHost, zip, outDir, source)) wq_remove_export(outDir);
                            });
                        }]];
                    [strongHost presentViewController:note animated:YES completion:nil];
                    return;
                }
                if (!wq_present_share(strongHost, zip, outDir, source)) wq_remove_export(outDir);
            };
            if (hudPresented) [strongHost dismissViewControllerAnimated:YES completion:finish];
            else finish();
        });
    });
}
