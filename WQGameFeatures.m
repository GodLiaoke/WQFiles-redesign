//
//  WQGameFeatures.m
//  黑猫游戏工具箱 — game resource tools
//  GPL-3.0-or-later.
//

#import "WQGameFeatures.h"
#import "WQDesignTokens.h"
#import "WQAppearance.h"
#import "WQExtras.h"
#import "WQAccess.h"
#import "WQLaunchServices.h"
#import "WQUI.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <dirent.h>

static NSString *const WQGameAppRoot = @"/private/var/mobile/Containers/Data/Application";
static NSString *const WQGamePathsKey = @"WQGameSavedPathsV1";
static NSString *const WQGameLastAppsKey = @"WQGameLastAppsV1";
static NSString *const WQGameRiskNote =
    @"仅用于本机调试或补齐缺失资源。写入前请先完全退出游戏、写入期间不要启动它；"
    @"写入不是快照，游戏仍在运行可能损坏存档。同名文件会被替换，替换前在「备份」中保留副本。"
    @"改动游戏文件可能违反游戏条款或导致账号受限，请勿用于在线对局或影响他人。";

// Defined in main.m and linked into the same binary; the log screen is shared
// with the Tools section and is offered when container discovery fails.
@interface WQLogViewController : UIViewController
@end


@interface WQGamePathPickerViewController : UITableViewController <UITextFieldDelegate>
- (instancetype)initWithGame:(NSString *)game container:(NSString *)container
                    relative:(NSString *)relative suggest:(NSString *)suggest;
@end
@interface WQGameAddPathViewController : UITableViewController <UITextFieldDelegate>
@end
@interface WQGameInjectViewController : UITableViewController <UIDocumentPickerDelegate>
- (instancetype)initWithEntry:(NSDictionary *)entry;
@end
@interface WQGameLuaViewController : UITableViewController <UIDocumentPickerDelegate, NSURLSessionDownloadDelegate>
- (instancetype)initWithContainer:(NSString *)container relative:(NSString *)relative
                            alias:(NSString *_Nullable)alias;
@end

#pragma mark - Game catalogue

// Only Delta Force has a user-verified path. For every other game the app
// shows the real container identifier and lets the user pick: guessing a
// resource directory from a bundle-id keyword produced misleading results.
static NSString *const WQGameExactMark = @"Documents/DeltaForce/Saved";
static NSString *const WQGameExactChain =
    @"Documents/DeltaForce/Saved/LuaDebug/LuaSource/DFM/BusinessEntrance";
static NSString *const WQGameExactName = @"三角洲行动";
static NSString *const WQGameLuaDebugChain = @"Documents/DeltaForce/Saved/LuaDebug";
static NSString *const WQGameLuaThirdPartyURL = @"https://ios.ouovo.cc/dl/EntranceFlow.lua";
static NSString *const WQGameLuaThirdPartyName = @"EntranceFlow.lua";
static NSString *const WQGameLuaThirdPartyNote =
    @"第三方版为淮季在社区中寻找到较为稳定的lua 并不是黑猫社区官方版！";
static NSString *const WQGameLuaOfficialNotice =
    @"官方版正在开发完善防封机制中 请等待版本迭代";
static const unsigned long long WQGameLuaMaxBytes = 20ULL * 1024ULL * 1024ULL;

static NSArray<NSDictionary *> *WQGameProfiles(void)
{
    return @[
        @{@"name": @"暗区突围", @"hints": @[@"arenabreakout", @"arena", @"abreakout", @"tmgp.ab"]},
        @{@"name": @"无畏契约", @"hints": @[@"valorant", @"valomobile", @"riot", @"tmgp.val"]},
        @{@"name": @"和平精英", @"hints": @[@"pubgmhd", @"pubg", @"gameforpeace", @"tmgp.pubgm"]},
        @{@"name": @"王者荣耀", @"hints": @[@"sgame", @"honorofkings", @"hok", @"tmgp.sgame"]},
        @{@"name": @"穿越火线", @"hints": @[@"crossfire", @"cfm", @"tmgp.cf", @"tmgp.cfm"]},
    ];
}

#pragma mark - Saved paths

static BOOL WQGameSafeRelative(NSString *rel)
{
    if (!rel.length || [rel hasPrefix:@"/"] || [rel rangeOfString:@"\0"].location != NSNotFound) return NO;
    for (NSString *part in [rel componentsSeparatedByString:@"/"]) {
        if ([part isEqualToString:@"."] || [part isEqualToString:@".."]) return NO;
    }
    return YES;
}

static NSString *_Nullable WQGameSafeFileName(NSString *name)
{
    NSString *n = name.lastPathComponent;
    if (!n.length || [n isEqualToString:@"."] || [n isEqualToString:@".."] ||
        [n rangeOfString:@"\0"].location != NSNotFound) return nil;
    return n;
}

static NSArray<NSDictionary *> *WQGameLoadPaths(void)
{
    NSArray *raw = [NSUserDefaults.standardUserDefaults arrayForKey:WQGamePathsKey] ?: @[];
    NSMutableArray<NSDictionary *> *out = [NSMutableArray new];
    for (id item in raw) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *d = item;
        NSString *container = d[@"container"], *rel = d[@"relative"];
        if (![container isKindOfClass:NSString.class] || ![rel isKindOfClass:NSString.class]) continue;
        if (![container hasPrefix:@"/"] || !WQGameSafeRelative(rel)) continue;
        NSMutableDictionary *clean = [NSMutableDictionary new];
        for (NSString *key in @[@"id", @"game", @"alias", @"container", @"relative"])
            if ([d[key] isKindOfClass:NSString.class]) clean[key] = d[key];
        if (!clean[@"id"]) clean[@"id"] = NSUUID.UUID.UUIDString;
        if (!clean[@"game"]) clean[@"game"] = @"自定义";
        if (!clean[@"alias"]) clean[@"alias"] = rel.lastPathComponent;
        [out addObject:clean];
    }
    return out;
}

static void WQGameSavePaths(NSArray<NSDictionary *> *paths)
{
    [NSUserDefaults.standardUserDefaults setObject:paths forKey:WQGamePathsKey];
}
// Re-deploying the same chain must refresh the entry, not pile up duplicates.
static void WQGameAddPath(NSDictionary *entry)
{
    NSMutableArray *all = [WQGameLoadPaths() mutableCopy];
    NSString *container = entry[@"container"], *relative = entry[@"relative"];
    for (NSDictionary *item in [all copy])
        if ([item[@"container"] isEqualToString:container] &&
            [item[@"relative"] isEqualToString:relative]) [all removeObject:item];
    [all addObject:entry];
    WQGameSavePaths(all);
}
static NSString *WQGameFullPath(NSDictionary *entry)
{
    return [entry[@"container"] stringByAppendingPathComponent:entry[@"relative"]];
}

NSArray<NSDictionary *> *WQGameSavedEntries(void) { return WQGameLoadPaths(); }

// Config import only accepts well-formed entries; WQGameAddPath deduplicates
// by container + relative path, so an existing setup is never duplicated.
void WQGameImportEntries(NSArray<NSDictionary *> *entries)
{
    for (id raw in entries) {
        if (![raw isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *d = raw;
        NSString *container = d[@"container"], *rel = d[@"relative"];
        if (![container isKindOfClass:NSString.class] || ![container hasPrefix:@"/"] ||
            ![rel isKindOfClass:NSString.class] || !WQGameSafeRelative(rel)) continue;
        NSDictionary *clean = @{@"id": NSUUID.UUID.UUIDString,
            @"game": [d[@"game"] isKindOfClass:NSString.class] ? d[@"game"] : @"自定义",
            @"alias": [d[@"alias"] isKindOfClass:NSString.class] ? d[@"alias"] : rel.lastPathComponent,
            @"container": container, @"relative": rel};
        WQGameAddPath(clean);
    }
}

// A slim, validated snapshot of the last successful detection. On a cold start
// it renders immediately (stale-while-revalidate) while the real scan runs in
// the background, so the page never opens empty or frozen.
static NSArray<NSDictionary *> *WQGameLoadCachedApps(void)
{
    NSArray *raw = [NSUserDefaults.standardUserDefaults arrayForKey:WQGameLastAppsKey] ?: @[];
    NSMutableArray<NSDictionary *> *out = [NSMutableArray new];
    for (id item in raw) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *d = item;
        NSString *path = d[@"path"];
        if (![path isKindOfClass:NSString.class] || ![path hasPrefix:@"/"]) continue;
        NSMutableDictionary *clean = [NSMutableDictionary new];
        for (NSString *key in @[@"path", @"bid", @"name", @"game", @"exact", @"sort"])
            if (d[key]) clean[key] = d[key];
        if (!clean[@"name"]) clean[@"name"] = path.lastPathComponent;
        if (!clean[@"bid"]) clean[@"bid"] = @"";
        if (!clean[@"game"]) clean[@"game"] = @"";
        if (!clean[@"exact"]) clean[@"exact"] = @(NO);
        if (!clean[@"sort"]) clean[@"sort"] = @(2);
        [out addObject:clean];
    }
    return out;
}

static void WQGameSaveCachedApps(NSArray<NSDictionary *> *apps)
{
    if (!apps.count) return;   // never persist an empty/failed detection
    NSMutableArray<NSDictionary *> *slim = [NSMutableArray arrayWithCapacity:apps.count];
    for (NSDictionary *a in apps)
        [slim addObject:@{@"path": a[@"path"] ?: @"", @"bid": a[@"bid"] ?: @"",
                          @"name": a[@"name"] ?: @"", @"game": a[@"game"] ?: @"",
                          @"exact": @([a[@"exact"] boolValue]),
                          @"sort": a[@"sort"] ?: @(2)}];
    [NSUserDefaults.standardUserDefaults setObject:slim forKey:WQGameLastAppsKey];
}

NSUInteger WQGameSavedPathCount(void) { return WQGameLoadPaths().count; }
void WQGameClearSavedPaths(void) { WQGameSavePaths(@[]); }

#pragma mark - Staging (exposed to the settings page)

NSString *WQGameStagingDir(void)
{
    NSString *d = [NSTemporaryDirectory() stringByAppendingPathComponent:@"WQGameStaging"];
    [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

static NSArray<NSString *> *WQGameStagingFiles(void)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = WQGameStagingDir();
    NSMutableArray<NSString *> *out = [NSMutableArray new];
    for (NSString *n in [fm contentsOfDirectoryAtPath:dir error:nil] ?: @[])
        [out addObject:[dir stringByAppendingPathComponent:n]];
    return out;
}

unsigned long long WQGameStagingBytes(void)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    unsigned long long total = 0;
    for (NSString *p in WQGameStagingFiles()) {
        NSDictionary *a = [fm attributesOfItemAtPath:p error:nil];
        total += [a[NSFileSize] unsignedLongLongValue];
    }
    return total;
}

NSUInteger WQGameStagingFileCount(void) { return WQGameStagingFiles().count; }

void WQGameClearStaging(void)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *p in WQGameStagingFiles()) [fm removeItemAtPath:p error:nil];
    wq_log(@"game: cleared injection staging");
}

#pragma mark - Filesystem helpers

// A plain lstat answers "missing" for almost every path. Only a real sandbox
// refusal goes through wq_stat, which may request a token — avoiding hundreds
// of grants when scanning containers for a marker directory.
static BOOL WQGameStatFast(NSString *path, struct stat *st)
{
    if (lstat(path.fileSystemRepresentation, st) == 0) return YES;
    int e = errno;
    if (e != EPERM && e != EACCES) return NO;
    return wq_stat(path, st);
}

static BOOL WQGameIsDir(NSString *path)
{
    struct stat st;
    if (wq_stat(path, &st)) return S_ISDIR(st.st_mode);
    struct stat target;
    return stat(path.fileSystemRepresentation, &target) == 0 && S_ISDIR(target.st_mode);
}

// Marker probing checks a folder inside every container. Most of those paths
// do not exist, so a plain lstat (no sandbox grant) is the right fast answer.
static BOOL WQGameHasExactMarker(NSString *container)
{
    struct stat st;
    NSString *path = [container stringByAppendingPathComponent:WQGameExactMark];
    if (WQGameStatFast(path, &st)) return S_ISDIR(st.st_mode);
    struct stat target;
    return stat(path.fileSystemRepresentation, &target) == 0 && S_ISDIR(target.st_mode);
}

static NSString *_Nullable WQGameEnsureChain(NSString *container, NSString *rel,
                                             NSUInteger *created, NSString **errorText)
{
    if (!WQGameSafeRelative(rel)) { if (errorText) *errorText = @"相对路径不合法"; return nil; }
    NSString *current = container;
    *created = 0;
    for (NSString *part in [rel componentsSeparatedByString:@"/"]) {
        if (!part.length) continue;
        current = [current stringByAppendingPathComponent:part];
        struct stat st;
        if (wq_stat(current, &st)) {
            if (!S_ISDIR(st.st_mode)) {
                if (errorText) *errorText = [NSString stringWithFormat:@"%@ 已存在但不是目录", part];
                return nil;
            }
            continue;
        }
        NSString *err = nil;
        if (!wq_create_dir(current, &err)) {
            if (errorText) *errorText = [NSString stringWithFormat:@"创建 %@ 失败：%@", part, err ?: @"未知错误"];
            return nil;
        }
        (*created)++;
    }
    return current;
}

// Detect once and reuse. Container discovery MUST follow the same chain as
// the official Apps screen: on iOS 27.0.1 the parent folder gives no token,
// so wq_list() returns nil, and wq_ls_container_paths(nil) returns nil until
// the LaunchServices store path has been remembered. wq_enumerate owns the
// real fallback (container manager -> LaunchServices API -> store -> full
// inode scan with user confirmation, shared 10-minute cache and weekly full
// scan). Do not "optimize" that fallback away again.
static NSArray<NSString *> *WQGameDiscoverContainers(NSString *_Nullable *_Nullable sourceOut)
{
    NSMutableArray<NSString *> *out = [NSMutableArray new];
    void (^add)(NSString *) = ^(NSString *raw) {
        NSString *full = [raw hasPrefix:@"/"] ? raw
            : [WQGameAppRoot stringByAppendingPathComponent:raw];
        if (![full containsString:@"/Containers/Data/Application/"]) return;
        if (![out containsObject:full]) [out addObject:full];
    };

    // Step 1: find and remember the LaunchServices database. This is what the
    // home screen normally does before any app list is shown. Without it a
    // cold start straight into this page always sees an empty store hint.
    wq_display_names_reset_miss();
    wq_load_display_names();
    for (NSString *p in wq_ls_container_paths(nil) ?: @[]) add(p);
    if (out.count) { if (sourceOut) *sourceOut = @"应用数据库"; return out; }

    // Step 2: a plain listing, when the build does hand out a parent token.
    for (NSString *name in wq_list(WQGameAppRoot, nil) ?: @[]) add(name);
    if (out.count) { if (sourceOut) *sourceOut = @"目录列举"; return out; }

    // Step 3: the official fallback. A non-nil progress block gives the scan
    // foreground priority; the global full-scan confirmation and progress
    // window (wq_set_full_scan_ui) still appear when an inode scan is needed.
    NSArray<NSString *> *enumerated = wq_enumerate(WQGameAppRoot, 0, nil,
        ^(int64_t __unused done, int64_t __unused total, NSUInteger __unused found) {});
    for (NSString *p in enumerated ?: @[]) add(p);
    if (out.count) { if (sourceOut) *sourceOut = @"容器扫描"; return out; }

    if (sourceOut) *sourceOut = wq_full_scan_was_declined() ? @"扫描已取消" : @"未找到";
    return out;
}

static NSArray<NSDictionary *> *_Nullable gWQAppCache;
static NSTimeInterval gWQAppCacheTime;
static NSString *_Nullable gWQAppCacheSource;

static NSArray<NSDictionary *> *WQGameScanApps(BOOL force, NSString *_Nullable *_Nullable sourceOut)
{
    BOOL cacheOn = WQSettingGet(WQSettingDetectCacheKey, YES);
    @synchronized (WQGameCenterViewController.class) {
        if (!force && cacheOn && gWQAppCache.count &&
            (CFAbsoluteTimeGetCurrent() - gWQAppCacheTime) < 300.0) {
            if (sourceOut) *sourceOut = gWQAppCacheSource ?: @"缓存";
            return gWQAppCache;
        }
    }
    NSString *source = nil;
    NSArray<NSString *> *candidates = WQGameDiscoverContainers(&source);
    NSMutableArray<NSDictionary *> *apps = [NSMutableArray new];
    for (NSString *dir in candidates) {
        NSString *bid = (wq_bundle_id_for_container(dir) ?: wq_container_label(dir) ?: @"").lowercaseString;
        NSString *name = wq_display_name(bid) ?: (bid.length ? bid : dir.lastPathComponent);
        BOOL exact = WQGameHasExactMarker(dir);
        NSString *game = exact ? WQGameExactName : @"";
        if (!exact) {
            for (NSDictionary *p in WQGameProfiles())
                for (NSString *h in p[@"hints"])
                    if ([bid containsString:h]) { game = p[@"name"]; break; }
        }
        [apps addObject:@{@"path": dir, @"bid": bid ?: @"", @"name": name ?: dir.lastPathComponent,
                          @"exact": @(exact), @"game": game,
                          @"sort": @(exact ? 0 : (game.length ? 1 : 2))}];
    }
    [apps sortUsingDescriptors:@[
        [NSSortDescriptor sortDescriptorWithKey:@"sort" ascending:YES],
        [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES
                                      selector:@selector(localizedCaseInsensitiveCompare:)],
    ]];
    // Never cache an empty result: a cold-start failure used to stick for five
    // minutes and made "重新检测" look broken.
    @synchronized (WQGameCenterViewController.class) {
        gWQAppCache = (cacheOn && apps.count) ? apps : nil;
        gWQAppCacheSource = source;
        gWQAppCacheTime = CFAbsoluteTimeGetCurrent();
    }
    if (sourceOut) *sourceOut = source ?: @"未找到";
    if (apps.count) WQGameSaveCachedApps(apps);
    wq_log(@"game: %lu containers via %@", (unsigned long)candidates.count, source ?: @"未找到");
    return apps;
}

void WQGameClearDetectionCache(void)
{
    [NSUserDefaults.standardUserDefaults removeObjectForKey:WQGameLastAppsKey];
    @synchronized (WQGameCenterViewController.class) {
        gWQAppCache = nil;
        gWQAppCacheSource = nil;
        gWQAppCacheTime = 0;
    }
    wq_log(@"game: detection cache cleared");
}

static void WQGamePopToCenter(UINavigationController *nav)
{
    for (UIViewController *vc in nav.viewControllers.reverseObjectEnumerator)
        if ([vc isKindOfClass:WQGameCenterViewController.class]) { [nav popToViewController:vc animated:YES]; return; }
    [nav popViewControllerAnimated:YES];
}

// Lightweight, decoration-free feedback: the system navigation prompt.
static void WQGameCopyPath(UIViewController *host, NSString *path)
{
    UIPasteboard.generalPasteboard.string = path;
    host.navigationItem.prompt = @"路径已复制";
    __weak UIViewController *weakHost = host;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *h = weakHost;
        if (h && [h.navigationItem.prompt isEqualToString:@"路径已复制"]) h.navigationItem.prompt = nil;
    });
}

static CGFloat WQGameRowH(void) { return WQSettingGet(WQSettingCompactRowsKey, NO) ? 38.0 : WQRowHeight; }

#pragma mark - Reusable cell factories

static UITableViewCell *WQGamePlainCell(void)
{
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    WQStyleCell(c);
    c.textLabel.font = WQFontBody();
    c.textLabel.textColor = WQColorText();
    c.detailTextLabel.font = WQFontCaption();
    c.detailTextLabel.textColor = WQColorText2();
    c.detailTextLabel.numberOfLines = 2;
    return c;
}

static UILabel *WQGameHintLabel(NSString *text)
{
    UILabel *l = [UILabel new];
    l.text = text;
    l.font = WQFontCaption();
    l.textColor = WQColorText3();
    l.textAlignment = NSTextAlignmentLeft;
    l.numberOfLines = 1;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    return l;
}

static UITextField *WQGameField(NSString *text, NSString *placeholder)
{
    UITextField *f = [UITextField new];
    f.text = text;
    f.placeholder = placeholder;
    f.font = WQFontBody();
    f.textColor = WQColorText();
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.spellCheckingType = UITextSpellCheckingTypeNo;
    f.clearButtonMode = UITextFieldViewModeWhileEditing;
    f.borderStyle = UITextBorderStyleNone;
    WQStyleControl(f);
    f.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, WQSpace3, 0)];
    f.leftViewMode = UITextFieldViewModeAlways;
    f.rightView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, WQSpace3, 0)];
    f.rightViewMode = UITextFieldViewModeAlways;
    return f;
}

static UITableViewCell *WQGameFormCell(NSString *title, UIView *control, UILabel *hint)
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = WQColorSurface();
    UILabel *label = [UILabel new];
    label.text = title;
    label.font = WQFontGroup();
    label.textColor = WQColorText2();
    label.textAlignment = NSTextAlignmentLeft;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:label];
    control.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:control];
    [cell.contentView addSubview:hint];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:WQGutter],
        [label.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-WQGutter],
        [label.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:WQSpace3],
        [control.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:WQGutter],
        [control.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-WQGutter],
        [control.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:WQSpace2],
        [control.heightAnchor constraintEqualToConstant:WQControlH],
        [hint.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:WQGutter],
        [hint.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-WQGutter],
        [hint.topAnchor constraintEqualToAnchor:control.bottomAnchor constant:WQSpace1],
        [hint.heightAnchor constraintEqualToConstant:WQHintSpace],
    ]];
    return cell;
}

static UITableViewCell *WQGameButtonCell(NSString *title, id target, SEL action, BOOL primary)
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = WQColorSurface();
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    if (primary) WQStylePrimaryButton(b);
    else { [b setTitleColor:WQColorText() forState:UIControlStateNormal]; WQStyleControl(b); }
    b.titleLabel.font = WQFontBody();
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    [cell.contentView addSubview:b];
    [NSLayoutConstraint activateConstraints:@[
        [b.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:WQGutter],
        [b.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-WQGutter],
        [b.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:WQSpace2],
        [b.heightAnchor constraintEqualToConstant:WQControlH],
    ]];
    return cell;
}

static CGFloat WQGameFormHeight(void)
{
    return WQSpace3 + 18.0 + WQSpace2 + WQControlH + WQSpace1 + WQHintSpace + WQSpace3;
}

// Plain left-aligned credit text at the top of the game page. No card, no
// badge, no capsule, no coloured emblem; width follows the table view.

static UIView *WQGameCreditHeader(CGFloat width)
{
    // Pure text header. A fixed 360pt frame and a rounded panel caused the
    // credit block to sit off-centre on narrow and wide screens.
    UIView *outer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 76)];
    outer.backgroundColor = UIColor.clearColor;
    outer.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UILabel *by = [UILabel new];
    by.text = @"by 淮季";
    by.font = WQFontHeadline();
    by.textColor = WQColorText();
    by.textAlignment = NSTextAlignmentLeft;
    UILabel *channel = [UILabel new];
    channel.text = @"公益频道@HeiMaoClub";
    channel.font = WQFontBody();
    channel.textColor = WQColorText2();
    channel.textAlignment = NSTextAlignmentLeft;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[by, channel]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentLeading;
    stack.spacing = WQSpace1;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [outer addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:outer.leadingAnchor constant:WQGutter],
        [stack.trailingAnchor constraintEqualToAnchor:outer.trailingAnchor constant:-WQGutter],
        [stack.centerYAnchor constraintEqualToAnchor:outer.centerYAnchor],
    ]];
    return outer;
}
#pragma mark - Search helpers

// How many app containers the list shows before the user expands it. Searching
// always sees the complete result set, never just the preview.
static NSUInteger const WQGamePreviewCount = 5;

// Whitespace-separated terms are ANDed, so "com.tencent delta" narrows the
// list instead of matching everything. Ranks: exact field == 0, prefix == 1,
// substring == 2. Exact hits sort first, which is what "精确搜索" means here.
static NSArray<NSString *> *WQGameQueryTokens(NSString *text)
{
    NSMutableArray<NSString *> *out = [NSMutableArray new];
    for (NSString *part in [text componentsSeparatedByCharactersInSet:
                            NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        NSString *token = [part stringByTrimmingCharactersInSet:
                           NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
        if (token.length) [out addObject:token];
    }
    return out;
}

static NSArray<NSString *> *WQGameAppFields(NSDictionary *app)
{
    NSString *path = app[@"path"] ?: @"";
    return @[app[@"name"] ?: @"", app[@"game"] ?: @"", app[@"bid"] ?: @"",
             path.lastPathComponent ?: @"", path,
             [app[@"exact"] boolValue] ? @"三角洲行动 已验证路径" : @""];
}

static NSArray<NSString *> *WQGamePathFields(NSDictionary *entry)
{
    return @[entry[@"alias"] ?: @"", entry[@"game"] ?: @"",
             entry[@"relative"] ?: @"", entry[@"container"] ?: @"",
             WQGameFullPath(entry)];
}

static NSInteger WQGameMatchRank(NSArray<NSString *> *fields, NSArray<NSString *> *tokens)
{
    NSInteger total = 0;
    for (NSString *token in tokens) {
        NSInteger best = 3;   // 3 = this term matched nothing
        for (NSString *raw in fields) {
            NSString *f = raw.lowercaseString;
            if (!f.length) continue;
            if ([f isEqualToString:token]) { best = 0; break; }
            if ([f hasPrefix:token]) best = MIN(best, 1);
            else if ([f rangeOfString:token].location != NSNotFound) best = MIN(best, 2);
        }
        if (best == 3) return -1;
        total += best;
    }
    return total;
}

// Ranked, stable sort of arbitrary item dictionaries by rank then name.
static NSArray<NSDictionary *> *WQGameRanked(NSArray<NSDictionary *> *items,
                                             NSArray<NSString *> *tokens,
                                             NSArray<NSString *> * (^fields)(NSDictionary *),
                                             NSString *nameKey)
{
    NSMutableArray<NSDictionary *> *ranked = [NSMutableArray new];
    for (NSDictionary *item in items) {
        NSInteger rank = WQGameMatchRank(fields(item), tokens);
        if (rank >= 0) [ranked addObject:@{@"item": item, @"rank": @(rank)}];
    }
    // An explicit comparator avoids KVC key paths ("item.name") on plain
    // dictionaries and never sends a compare selector to a nil value.
    [ranked sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSInteger ra = [a[@"rank"] integerValue], rb = [b[@"rank"] integerValue];
        if (ra != rb) return ra < rb ? NSOrderedAscending : NSOrderedDescending;
        NSString *na = a[@"item"][nameKey] ?: @"", *nb = b[@"item"][nameKey] ?: @"";
        return [na localizedCaseInsensitiveCompare:nb];
    }];
    NSMutableArray<NSDictionary *> *result = [NSMutableArray arrayWithCapacity:ranked.count];
    for (NSDictionary *box in ranked) [result addObject:box[@"item"]];
    return result;
}

// Bold-only emphasis: same neutral text colour, no highlight fill or accent.
// It keeps the design language while making the matched terms scannable.
static void WQGameEmphasize(UILabel *label, NSString *text, NSArray<NSString *> *tokens,
                            UIFont *font, UIColor *color)
{
    label.text = text;
    if (!tokens.count || !text.length) return;
    NSMutableAttributedString *a = [[NSMutableAttributedString alloc]
        initWithString:text attributes:@{NSFontAttributeName: font,
                                         NSForegroundColorAttributeName: color}];
    UIFontDescriptor *descriptor = [font.fontDescriptor fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold];
    UIFont *bold = descriptor ? [UIFont fontWithDescriptor:descriptor size:0] : font;
    for (NSString *token in tokens) {
        NSRange remaining = NSMakeRange(0, text.length);
        while (remaining.location < text.length) {
            NSRange hit = [text rangeOfString:token options:NSCaseInsensitiveSearch range:remaining];
            if (hit.location == NSNotFound) break;
            [a addAttribute:NSFontAttributeName value:bold range:hit];
            NSUInteger next = NSMaxRange(hit);
            remaining = NSMakeRange(next, text.length - next);
        }
    }
    label.attributedText = a;
}

#pragma mark - Game centre

@interface WQGameCenterViewController () <UISearchResultsUpdating>
@end

@implementation WQGameCenterViewController {
    NSArray<NSDictionary *> *_apps;          // full detection result
    NSArray<NSDictionary *> *_paths;         // all saved entries
    NSArray<NSDictionary *> *_visibleApps;   // filtered, or the preview slice
    NSArray<NSDictionary *> *_visiblePaths;
    NSArray<NSString *> *_queryTokens;
    NSDictionary<NSString *, NSNumber *> *_pathCounts;   // container -> saved path count
    BOOL _searching;
    BOOL _detecting;
    BOOL _showAllApps;
    NSString *_statusText;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"游戏资源注入";
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    WQStyleTableView(self.tableView);
    self.tableView.separatorColor = WQColorLine();
    self.tableView.tableHeaderView = WQGameCreditHeader(CGRectGetWidth(self.tableView.bounds));
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"重新检测" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(redetect)];

    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"搜索应用名 / 标识 / 容器 UUID";
    search.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    search.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    search.searchBar.spellCheckingType = UITextSpellCheckingTypeNo;
    search.searchBar.returnKeyType = UIReturnKeyDone;
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;   // always visible
    self.definesPresentationContext = YES;

    _visibleApps = @[];
    _visiblePaths = @[];
    _queryTokens = @[];
    _pathCounts = @{};
    _paths = WQGameLoadPaths();
    // Stale-while-revalidate: show the last good detection instantly, then
    // refresh in the background. The user can act on it while it refreshes.
    _apps = WQGameLoadCachedApps();
    _statusText = _apps.count ? @"上次检测" : nil;
    [self recomputeVisible];
    [self redetect];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    NSArray<NSDictionary *> *fresh = WQGameLoadPaths();
    if ([fresh isEqualToArray:_paths]) return;   // keep scroll position otherwise
    _paths = fresh;
    [self recomputeVisible];
    [self.tableView reloadData];
}

// Single source of truth for what the table shows. Every mutation of _apps or
// _paths goes through here, so cell indexes, menus and actions can never read
// a stale or differently-filtered array.
- (void)recomputeVisible
{
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary new];
    for (NSDictionary *entry in _paths ?: @[]) {
        NSString *container = entry[@"container"] ?: @"";
        counts[container] = @([counts[container] unsignedIntegerValue] + 1);
    }
    _pathCounts = counts;

    BOOL searching = _queryTokens.count > 0;
    _searching = searching;
    if (searching) {
        _visibleApps = WQGameRanked(_apps ?: @[], _queryTokens,
            ^NSArray<NSString *> *(NSDictionary *app) { return WQGameAppFields(app); }, @"name");
        _visiblePaths = WQGameRanked(_paths ?: @[], _queryTokens,
            ^NSArray<NSString *> *(NSDictionary *p) { return WQGamePathFields(p); }, @"alias");
    } else {
        NSUInteger limit = _showAllApps ? (_apps ?: @[]).count
                                        : MIN((_apps ?: @[]).count, WQGamePreviewCount);
        _visibleApps = [(_apps ?: @[]) subarrayWithRange:NSMakeRange(0, limit)];
        _visiblePaths = _paths ?: @[];
    }
}

- (BOOL)hasMoreRow
{
    return !_searching && !_showAllApps && _apps.count > WQGamePreviewCount;
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    _queryTokens = WQGameQueryTokens(searchController.searchBar.text ?: @"");
    [self recomputeVisible];
    [self.tableView reloadData];
}

- (void)redetect
{
    _detecting = YES;
    // Keep the cached list rendered; header/footer show "refreshing" instead
    // of blanking the whole screen. Only a cold start with no cache shows a
    // single loading row.
    _statusText = @"正在查找应用容器…";
    [self recomputeVisible];
    [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    dispatch_async(wq_io(), ^{
        NSString *source = nil;
        NSArray *found = WQGameScanApps(YES, &source);
        dispatch_async(dispatch_get_main_queue(), ^{
            WQGameCenterViewController *s = weakSelf;
            if (!s) return;
            s->_detecting = NO;
            s->_apps = found;
            s->_statusText = source;
            [s recomputeVisible];
            [s.tableView reloadData];
        });
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 2) return 3;   // 快捷操作
    if (section == 1) return (NSInteger)_visiblePaths.count + 1;   // + add-path row
    if (_detecting && !_apps.count) return 1;
    if (!_apps.count) return 3;   // status + 查看日志 + 手动填写
    if (_searching && !_visibleApps.count) return 1;   // no-match row
    return (NSInteger)_visibleApps.count + ([self hasMoreRow] ? 1 : 0);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) {
        if (_searching && !_detecting && _apps.count)
            return [NSString stringWithFormat:@"已安装应用 · %lu 项匹配", (unsigned long)_visibleApps.count];
        if (_detecting && _apps.count) return @"已安装应用 · 正在刷新…";
        return @"已安装应用 · 选择容器";
    }
    if (section == 2) return @"快捷操作";
    if (_searching)
        return [NSString stringWithFormat:@"保存的注入路径 · %lu 项", (unsigned long)_visiblePaths.count];
    return @"保存的注入路径";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 0) {
        NSString *count = _detecting
            ? (_apps.count ? @"上次检测结果 · 正在后台刷新" : @"正在检测…")
            : (_searching
                ? [NSString stringWithFormat:@"共 %lu 个应用 · %lu 项匹配",
                    (unsigned long)_apps.count, (unsigned long)_visibleApps.count]
                : [NSString stringWithFormat:@"共 %lu 个应用 · 默认显示前 %lu 个",
                    (unsigned long)_apps.count, (unsigned long)WQGamePreviewCount]);
        NSString *how = @"搜索支持名称、应用标识、容器 UUID 与完整路径；多个关键词用空格分隔，完全相等的结果排最前。搜索时不限 5 个，点「显示全部」可展开完整列表。";
        return [NSString stringWithFormat:@"%@。%@\n\n三角洲行动按已验证的特征目录识别；其余游戏只按应用标识排序推荐，不猜测资源目录。长按任意行可复制容器路径。", count, how];
    }
    if (section == 2) return @"三角洲行动的两个动作在应用行右侧；记录、校验与配置都不改动游戏文件。";
    return @"搜索会同时过滤已保存路径。点按快捷放入资源文件，长按可复制完整路径；左滑只删除本应用的记录，不删除游戏里的文件。";
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    // Two-line subtitles need real space; 44pt clipped the second line into
    // the next row on every device.
    return WQSettingGet(WQSettingCompactRowsKey, NO) ? 52.0 : 60.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = WQGamePlainCell();
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    NSArray<NSString *> *tokens = _queryTokens;

    if (indexPath.section == 2) {
        NSUInteger idx = (NSUInteger)indexPath.row;
        NSArray *titles = @[@"注入记录", @"文件校验", @"配置导入 / 导出"];
        NSArray *subtitles = @[@"查看最近写入结果，最多 200 条", @"流式计算 SHA-256 与文件大小",
                               @"导出或合并注入路径与路径收藏"];
        NSArray *icons = @[@"clock", @"number", @"arrow.up.arrow.down"];
        cell.textLabel.text = titles[idx];
        cell.detailTextLabel.text = subtitles[idx];
        cell.imageView.image = WQLinearIcon(icons[idx]);
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    if (indexPath.section == 0) {
        NSUInteger idx = (NSUInteger)indexPath.row;
        if (_detecting && !_apps.count) {
            cell.textLabel.text = @"正在读取已安装应用…";
            cell.detailTextLabel.text = @"首次读取名称数据库需要几秒";
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (!_apps.count) {
            if (idx == 0) {
                cell.textLabel.text = @"未读取到应用容器";
                cell.detailTextLabel.text = [NSString stringWithFormat:@"来源：%@ · 点右上角重新检测，或先看日志确认原因",
                                             _statusText ?: @"未找到"];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
            } else {
                cell.textLabel.text = idx == 1 ? @"查看日志" : @"手动填写容器 UUID";
                cell.detailTextLabel.text = idx == 1 ? @"看是 No App Group、NO TOKEN 还是扫描被取消"
                                                     : @"不依赖检测结果，直接填写已知容器路径";
                cell.imageView.image = WQLinearIcon(idx == 1 ? @"doc.plaintext" : @"square.and.pencil");
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            }
        } else if (_searching && !_visibleApps.count) {
            cell.textLabel.text = @"没有匹配的应用";
            cell.detailTextLabel.text = @"换个关键词，或用下方「添加自定义路径」手动指定";
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if ([self hasMoreRow] && idx == _visibleApps.count) {
            cell.textLabel.text = [NSString stringWithFormat:@"显示全部 %lu 个应用", (unsigned long)_apps.count];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"当前显示前 %lu 个，也可直接用搜索精确定位",
                                         (unsigned long)WQGamePreviewCount];
            cell.imageView.image = WQLinearIcon(@"chevron.down");
        } else {
            if (idx >= _visibleApps.count) return cell;   // defensive: never index a stale row
            NSDictionary *a = _visibleApps[idx];
            BOOL exact = [a[@"exact"] boolValue];
            NSString *title = exact ? [NSString stringWithFormat:@"%@ · 已验证路径", a[@"name"]]
                                    : ([(NSString *)a[@"game"] length] ? a[@"game"] : a[@"name"]);
            NSString *bid = a[@"bid"];
            NSString *subtitle = [NSString stringWithFormat:@"%@ · %@",
                bid.length ? bid : @"标识未知",
                exact ? @"Documents/DeltaForce/Saved" :
                    ([(NSString *)a[@"game"] length] ? @"标识匹配，仅供参考" : a[@"name"])];
            NSUInteger configured = [_pathCounts[a[@"path"]] unsignedIntegerValue];
            if (configured)
                subtitle = [subtitle stringByAppendingFormat:@" · 已配置 %lu 条路径",
                            (unsigned long)configured];
            WQGameEmphasize(cell.textLabel, title, tokens, WQFontBody(), WQColorText());
            WQGameEmphasize(cell.detailTextLabel, subtitle, tokens, WQFontCaption(), WQColorText2());
            cell.imageView.image = WQLinearIcon(exact ? @"checkmark.square" : @"app.dashed");
            cell.detailTextLabel.numberOfLines = 2;
            if (exact) {
                // Both actions sit on the right of the verified Delta row, like
                // the previous build, but in a 140pt stack instead of 200pt.
                // 60pt rows + 2-line subtitles leave enough room on narrow
                // screens, so nothing overlaps.
                UIButton *deploy = [UIButton buttonWithType:UIButtonTypeSystem];
                [deploy setTitle:@"一键部署" forState:UIControlStateNormal];
                WQStylePrimaryButton(deploy);
                deploy.titleLabel.font = WQFontCaption();
                deploy.titleLabel.adjustsFontSizeToFitWidth = YES;
                deploy.titleLabel.minimumScaleFactor = 0.8;
                deploy.tag = (NSInteger)idx;
                [deploy addTarget:self action:@selector(quickDeployTapped:)
                 forControlEvents:UIControlEventTouchUpInside];

                UIButton *lua = [UIButton buttonWithType:UIButtonTypeSystem];
                [lua setTitle:@"注入 Lua" forState:UIControlStateNormal];
                WQStyleControl(lua);
                [lua setTitleColor:WQColorText() forState:UIControlStateNormal];
                lua.titleLabel.font = WQFontCaption();
                lua.titleLabel.adjustsFontSizeToFitWidth = YES;
                lua.titleLabel.minimumScaleFactor = 0.8;
                lua.tag = (NSInteger)idx;
                [lua addTarget:self action:@selector(luaInjectedTapped:)
                 forControlEvents:UIControlEventTouchUpInside];

                UIStackView *actions = [[UIStackView alloc] initWithFrame:CGRectMake(0, 0, 140, 30)];
                actions.axis = UILayoutConstraintAxisHorizontal;
                actions.alignment = UIStackViewAlignmentFill;
                actions.distribution = UIStackViewDistributionFillEqually;
                actions.spacing = WQSpace1;
                [actions addArrangedSubview:deploy];
                [actions addArrangedSubview:lua];
                cell.accessoryView = actions;
            } else {
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            }
        }
    } else {
        NSUInteger idx = (NSUInteger)indexPath.row;
        if (idx < _visiblePaths.count) {
            NSDictionary *p = _visiblePaths[idx];
            NSString *title = p[@"alias"];
            NSString *subtitle = [NSString stringWithFormat:@"%@ · %@", p[@"game"], p[@"relative"]];
            WQGameEmphasize(cell.textLabel, title, tokens, WQFontBody(), WQColorText());
            WQGameEmphasize(cell.detailTextLabel, subtitle, tokens, WQFontCaption(), WQColorText2());
            cell.imageView.image = WQLinearIcon(@"folder");
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.textLabel.text = @"添加自定义路径";
            cell.detailTextLabel.text = @"手动填写容器 UUID 与相对路径，不依赖检测";
            cell.imageView.image = WQLinearIcon(@"plus");
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    }
    return cell;
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point
{
    NSString *path = nil;
    if (indexPath.section == 0 && (NSUInteger)indexPath.row < _visibleApps.count)
        path = _visibleApps[(NSUInteger)indexPath.row][@"path"];
    else if (indexPath.section == 1 && (NSUInteger)indexPath.row < _visiblePaths.count)
        path = WQGameFullPath(_visiblePaths[(NSUInteger)indexPath.row]);
    if (!path) return nil;
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
        actionProvider:^UIMenu *(NSArray<UIMenuElement *> * __unused suggested) {
            UIAction *copy = [UIAction actionWithTitle:@"复制完整路径" image:[UIImage systemImageNamed:@"doc.on.doc"]
                identifier:nil handler:^(UIAction *__unused a) {
                    WQGameCenterViewController *vc = weakSelf;
                    if (vc) WQGameCopyPath(vc, path);
                }];
            return [UIMenu menuWithTitle:@"" children:@[copy]];
        }];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 2) {
        [self.view endEditing:YES];
        NSUInteger idx = (NSUInteger)indexPath.row;
        UIViewController *vc = nil;
        if (idx == 0) vc = [WQInjectionHistoryViewController new];
        else if (idx == 1) vc = [WQFileInspectorViewController new];
        else vc = [WQConfigViewController new];
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }
    if (indexPath.section == 0) {
        NSUInteger idx = (NSUInteger)indexPath.row;
        if (_detecting) return;
        if (!_apps.count) {
            if (idx == 1) [self.navigationController pushViewController:[WQLogViewController new] animated:YES];
            else if (idx == 2) [self.navigationController pushViewController:[WQGameAddPathViewController new] animated:YES];
            return;
        }
        if (_searching && !_visibleApps.count) return;
        if ([self hasMoreRow] && idx == _visibleApps.count) {
            _showAllApps = YES;
            [self recomputeVisible];
            [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0]
                          withRowAnimation:UITableViewRowAnimationAutomatic];
            return;
        }
        if (idx >= _visibleApps.count) return;
        [self.view endEditing:YES];   // dismiss the keyboard before pushing
        NSDictionary *a = _visibleApps[idx];
        BOOL exact = [a[@"exact"] boolValue];
        NSString *suggest = exact ? WQGameExactChain : @"Documents";
        WQGamePathPickerViewController *picker = [[WQGamePathPickerViewController alloc]
            initWithGame:(exact ? WQGameExactName : ([(NSString *)a[@"game"] length] ? a[@"game"] : a[@"name"]))
              container:a[@"path"] relative:@"" suggest:suggest];
        [self.navigationController pushViewController:picker animated:YES];
    } else {
        NSUInteger idx = (NSUInteger)indexPath.row;
        [self.view endEditing:YES];
        if (idx < _visiblePaths.count) {
            WQGameInjectViewController *inject =
                [[WQGameInjectViewController alloc] initWithEntry:_visiblePaths[idx]];
            [self.navigationController pushViewController:inject animated:YES];
        } else {
            [self.navigationController pushViewController:[WQGameAddPathViewController new] animated:YES];
        }
    }
}

- (void)quickDeployTapped:(UIButton *)sender
{
    if (!sender || (NSUInteger)sender.tag >= _visibleApps.count) return;
    NSDictionary *a = _visibleApps[(NSUInteger)sender.tag];
    if (![a[@"exact"] boolValue]) return;
    NSString *container = a[@"path"];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"一键部署默认路径"
        message:[NSString stringWithFormat:@"目标：\n%@/%@\n\n逐级检测目录，已存在保留、缺失才新建，并保存为注入路径。\n\n%@",
            container, WQGameExactChain, WQGameRiskNote]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"部署" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *__unused x) {
            WQGameCenterViewController *s = weakSelf;
            if (!s) return;
            dispatch_async(wq_io(), ^{
                NSString *error = nil;
                NSUInteger created = 0;
                NSString *final = WQGameEnsureChain(container, WQGameExactChain, &created, &error);
                dispatch_async(dispatch_get_main_queue(), ^{
                    WQGameCenterViewController *inner = weakSelf;
                    if (!inner) return;
                    if (!final) { wq_alert(inner, @"部署失败", error ?: @"未知错误"); return; }
                    NSDictionary *entry = @{@"id": NSUUID.UUID.UUIDString, @"game": WQGameExactName,
                                            @"alias": @"默认注入路径", @"container": container,
                                            @"relative": WQGameExactChain};
                    WQGameAddPath(entry);
                    wq_log(@"game: quick deploy created %lu dirs -> %@", (unsigned long)created, final);
                    inner->_paths = WQGameLoadPaths();
                    [inner recomputeVisible];
                    [inner.tableView reloadData];
                    UIAlertController *done = [UIAlertController alertControllerWithTitle:@"已保存"
                        message:[NSString stringWithFormat:@"新建 %lu 个目录\n%@\n\n现在可以放入 lua、pak、sig 等资源文件。",
                                 (unsigned long)created, final]
                        preferredStyle:UIAlertControllerStyleAlert];
                    [done addAction:[UIAlertAction actionWithTitle:@"稍后" style:UIAlertActionStyleCancel handler:nil]];
                    [done addAction:[UIAlertAction actionWithTitle:@"去放入资源" style:UIAlertActionStyleDefault
                        handler:^(UIAlertAction *__unused z) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                [inner.navigationController pushViewController:
                                    [[WQGameInjectViewController alloc] initWithEntry:entry] animated:YES];
                            });
                        }]];
                    [done addAction:[UIAlertAction actionWithTitle:@"注入 Lua" style:UIAlertActionStyleDefault
                        handler:^(UIAlertAction *__unused z) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                WQGameLuaViewController *vc = [[WQGameLuaViewController alloc]
                                    initWithContainer:container relative:WQGameExactChain alias:@"默认注入路径"];
                                [inner.navigationController pushViewController:vc animated:YES];
                            });
                        }]];
                    [inner presentViewController:done animated:YES completion:nil];
                });
            });
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)luaInjectedTapped:(UIButton *)sender
{
    if (!sender || (NSUInteger)sender.tag >= _visibleApps.count) return;
    NSDictionary *a = _visibleApps[(NSUInteger)sender.tag];
    if (![a[@"exact"] boolValue]) return;
    [self.view endEditing:YES];
    WQGameLuaViewController *vc = [[WQGameLuaViewController alloc]
        initWithContainer:a[@"path"] relative:WQGameExactChain alias:@"默认注入路径"];
    [self.navigationController pushViewController:vc animated:YES];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return indexPath.section == 1 && (NSUInteger)indexPath.row < _visiblePaths.count;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
 forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete || indexPath.section != 1 ||
        (NSUInteger)indexPath.row >= _visiblePaths.count) return;
    NSString *identifier = _visiblePaths[(NSUInteger)indexPath.row][@"id"];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"删除这条保存项？"
        message:@"只从本应用移除记录，不会删除游戏目录里的任何文件。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *__unused a) {
            WQGameCenterViewController *s = weakSelf;
            if (!s) return;
            NSMutableArray *all = [WQGameLoadPaths() mutableCopy];
            for (NSDictionary *item in [all copy])
                if ([item[@"id"] isEqualToString:identifier]) [all removeObject:item];
            WQGameSavePaths(all);
            s->_paths = all;
            [s recomputeVisible];
            [s.tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
                        withRowAnimation:UITableViewRowAnimationAutomatic];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Path picker

@implementation WQGamePathPickerViewController {
    NSString *_game, *_container, *_relative, *_suggest;
    NSArray<NSString *> *_subdirs;
    BOOL _loading;
    UITextField *_aliasField, *_chainField;
    UILabel *_aliasHint, *_chainHint;
    UITableViewCell *_locationCell, *_saveFormCell, *_saveButtonCell, *_chainFormCell, *_chainButtonCell;
}

- (instancetype)initWithGame:(NSString *)game container:(NSString *)container
                    relative:(NSString *)relative suggest:(NSString *)suggest
{
    if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
        _game = game; _container = container; _relative = relative ?: @""; _suggest = suggest ?: @"Documents";
        _subdirs = @[];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = _relative.length ? _relative.lastPathComponent : @"数据根目录";
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    WQStyleTableView(self.tableView);
    self.tableView.separatorColor = WQColorLine();
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"复制路径" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(copyPathTapped)];

    _aliasField = WQGameField(_relative.length ? _relative.lastPathComponent : @"资源目录", @"给快捷路径起个名字");
    _aliasHint = WQGameHintLabel(@"保存后出现在「保存的注入路径」");
    _chainField = WQGameField(_relative.length ? _relative : _suggest, @"相对数据根目录，可修改");
    _chainHint = WQGameHintLabel(@"已存在的层级保留，只新建缺失层级");
    _aliasField.delegate = self;
    _chainField.delegate = self;

    _locationCell = WQGamePlainCell();
    _locationCell.selectionStyle = UITableViewCellSelectionStyleNone;
    _locationCell.textLabel.text = _relative.length ? _relative : @"（根目录）";
    _locationCell.detailTextLabel.text = [self currentPath];
    _locationCell.imageView.image = WQLinearIcon(@"folder");
    _saveFormCell = WQGameFormCell(@"路径别名", _aliasField, _aliasHint);
    _saveButtonCell = WQGameButtonCell(@"保存当前目录", self, @selector(saveCurrentTapped), NO);
    _chainFormCell = WQGameFormCell(@"相对目录链", _chainField, _chainHint);
    _chainButtonCell = WQGameButtonCell(@"检测并创建", self, @selector(createChainTapped), YES);
    [self reloadSubdirs];
}

- (NSString *)currentPath
{
    return _relative.length ? [_container stringByAppendingPathComponent:_relative] : _container;
}

- (void)copyPathTapped { WQGameCopyPath(self, [self currentPath]); }

- (void)reloadSubdirs
{
    _loading = YES;
    [self.tableView reloadData];
    NSString *path = [self currentPath];
    BOOL fast = WQSettingGet(WQSettingFastDirKey, YES);
    __weak typeof(self) weakSelf = self;
    dispatch_async(wq_io(), ^{
        NSArray<NSString *> *dirs = fast ? wq_list_child_dirs(path, nil) : nil;
        if (!dirs) {   // nil = unreadable; fall back, never pretend it is empty
            NSMutableArray<NSString *> *collected = [NSMutableArray new];
            for (NSString *n in wq_list(path, nil) ?: @[])
                if (WQGameIsDir([path stringByAppendingPathComponent:n])) [collected addObject:n];
            [collected sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
            dirs = collected;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            WQGamePathPickerViewController *s = weakSelf;
            if (!s) return;
            s->_loading = NO;
            s->_subdirs = dirs;
            [s.tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
                        withRowAnimation:UITableViewRowAnimationAutomatic];
        });
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return 1;
    if (section == 1) return MAX((NSInteger)_subdirs.count, 1);
    return 2;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return @[@"当前位置", @"子目录", @"保存快捷路径", @"按路径逐级检测并创建"][section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 1) return @"点按目录继续进入；只列目录。点右上角「复制路径」可复制当前绝对路径。";
    if (section == 2) return @"只记录路径，不写入任何文件。";
    if (section == 3) return [NSString stringWithFormat:@"三角洲行动的默认目录链已预填，可修改。%@", WQGameRiskNote];
    return nil;
}
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) return 64.0;
    if (indexPath.section >= 2 && indexPath.row == 0) return WQGameFormHeight();
    if (indexPath.section >= 2) return WQControlH + WQSpace4;
    return WQGameRowH();
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) return _locationCell;
    if (indexPath.section == 1) {
        UITableViewCell *cell = WQGamePlainCell();
        if (_loading) {
            cell.textLabel.text = @"正在读取目录…";
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (!_subdirs.count) {
            cell.textLabel.text = @"没有子目录";
            cell.detailTextLabel.text = @"可保存当前目录，或用「按路径逐级检测并创建」";
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            cell.textLabel.text = _subdirs[(NSUInteger)indexPath.row];
            cell.imageView.image = WQLinearIcon(@"folder");
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        return cell;
    }
    if (indexPath.row == 0) return indexPath.section == 2 ? _saveFormCell : _chainFormCell;
    return indexPath.section == 2 ? _saveButtonCell : _chainButtonCell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1 || _loading || (NSUInteger)indexPath.row >= _subdirs.count) return;
    NSString *next = _relative.length
        ? [_relative stringByAppendingPathComponent:_subdirs[(NSUInteger)indexPath.row]]
        : _subdirs[(NSUInteger)indexPath.row];
    WQGamePathPickerViewController *picker = [[WQGamePathPickerViewController alloc]
        initWithGame:_game container:_container relative:next suggest:_suggest];
    [self.navigationController pushViewController:picker animated:YES];
}

- (void)saveCurrentTapped
{
    [self.view endEditing:YES];
    if (!_relative.length) { _aliasHint.text = @"请先进入子目录，或用下方按路径创建"; return; }
    NSString *alias = [_aliasField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!alias.length) { _aliasHint.text = @"请填写别名"; return; }
    NSDictionary *entry = @{@"id": NSUUID.UUID.UUIDString, @"game": _game,
                            @"alias": alias, @"container": _container, @"relative": _relative};
    WQGameAddPath(entry);
    wq_log(@"game: saved injection path %@ -> %@", alias, WQGameFullPath(entry));
    wq_alert(self, @"已保存", WQGameFullPath(entry));
    WQGamePopToCenter(self.navigationController);
}

- (void)createChainTapped
{
    [self.view endEditing:YES];
    NSString *rel = [_chainField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!WQGameSafeRelative(rel)) { _chainHint.text = @"请填写不含 .. 的相对路径"; return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"检测并创建目录"
        message:[NSString stringWithFormat:@"目标：%@/%@\n\n已存在的层级保留，缺失的层级会新建，并保存为注入路径。\n\n%@",
            _container, rel, WQGameRiskNote]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"创建" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *__unused a) {
            [weakSelf performCreateChain:rel];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)performCreateChain:(NSString *)rel
{
    _chainHint.text = @"正在检测并创建…";
    NSString *container = _container, *game = _game;
    __weak typeof(self) weakSelf = self;
    dispatch_async(wq_io(), ^{
        NSString *error = nil;
        NSUInteger created = 0;
        NSString *final = WQGameEnsureChain(container, rel, &created, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            WQGamePathPickerViewController *s = weakSelf;
            if (!s) return;
            if (!final) { s->_chainHint.text = error ?: @"创建失败"; wq_alert(s, @"创建失败", error ?: @"未知错误"); return; }
            NSDictionary *entry = @{@"id": NSUUID.UUID.UUIDString, @"game": game,
                                    @"alias": rel.lastPathComponent, @"container": container, @"relative": rel};
            WQGameAddPath(entry);
            wq_log(@"game: created %lu dirs, saved %@", (unsigned long)created, final);
            wq_alert(s, @"已保存", [NSString stringWithFormat:@"新建 %lu 个目录\n%@", (unsigned long)created, final]);
            WQGamePopToCenter(s.navigationController);
        });
    });
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField { [textField resignFirstResponder]; return YES; }

@end

#pragma mark - Custom path form

@implementation WQGameAddPathViewController {
    UITextField *_gameField, *_containerField, *_relField, *_aliasField;
    UILabel *_gameHint, *_containerHint, *_relHint, *_aliasHint;
    NSArray<UITableViewCell *> *_cells;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"添加注入路径";
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    WQStyleTableView(self.tableView);
    self.tableView.separatorColor = WQColorLine();
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;

    _gameField = WQGameField(@"", @"游戏名称，可留空");
    _containerField = WQGameField(@"", @"容器 UUID 或完整路径");
    _relField = WQGameField(@"Documents", @"相对容器根，如 Documents/Paks");
    _aliasField = WQGameField(@"", @"快捷路径别名");
    _gameHint = WQGameHintLabel(@"仅用于显示，不影响写入");
    _containerHint = WQGameHintLabel(@"可从「应用数据」复制 UUID，或点下方按钮选择");
    _relHint = WQGameHintLabel(@"必填，以 Documents 开头更安全");
    _aliasHint = WQGameHintLabel(@"留空则使用相对路径最后一级");
    for (UITextField *f in @[_gameField, _containerField, _relField, _aliasField]) f.delegate = self;
    _cells = @[
        WQGameFormCell(@"游戏名称", _gameField, _gameHint),
        WQGameFormCell(@"容器 UUID / 路径", _containerField, _containerHint),
        WQGameFormCell(@"相对路径", _relField, _relHint),
        WQGameFormCell(@"别名", _aliasField, _aliasHint),
        WQGameButtonCell(@"从已安装应用选择容器", self, @selector(pickDetectedTapped), NO),
        WQGameButtonCell(@"保存路径", self, @selector(saveTapped), YES),
    ];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return section == 0 ? 4 : 2;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return section == 0 ? @"路径信息" : @"完成";
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return section == 1 ? WQGameRiskNote : nil;
}
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return indexPath.section == 0 ? WQGameFormHeight() : WQControlH + WQSpace4;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return _cells[(NSUInteger)(indexPath.section == 0 ? indexPath.row : 4 + indexPath.row)];
}

- (void)pickDetectedTapped
{
    [self.view endEditing:YES];
    __weak typeof(self) weakSelf = self;
    dispatch_async(wq_io(), ^{
        NSArray *found = WQGameScanApps(YES, NULL);
        dispatch_async(dispatch_get_main_queue(), ^{
            WQGameAddPathViewController *s = weakSelf;
            if (!s) return;
            UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择应用容器"
                message:@"显示真实应用标识，按需要确认" preferredStyle:UIAlertControllerStyleAlert];
            NSUInteger limit = MIN(found.count, (NSUInteger)12);
            if (!limit) [sheet addAction:[UIAlertAction actionWithTitle:@"未读取到应用" style:UIAlertActionStyleDefault handler:nil]];
            for (NSUInteger i = 0; i < limit; i++) {
                NSDictionary *a = found[i];
                NSString *title = [NSString stringWithFormat:@"%@ · %@", a[@"name"],
                                   [(NSString *)a[@"bid"] length] ? a[@"bid"] : @"标识未知"];
                [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *__unused x) {
                        s->_containerField.text = a[@"path"];
                        if (!s->_gameField.text.length) s->_gameField.text = [(NSString *)a[@"game"] length] ? a[@"game"] : a[@"name"];
                        s->_containerHint.text = @"已填入容器路径";
                    }]];
            }
            [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            [s presentViewController:sheet animated:YES completion:nil];
        });
    });
}

- (void)saveTapped
{
    [self.view endEditing:YES];
    NSString *container = [_containerField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *rel = [_relField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *alias = [_aliasField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *game = [_gameField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!container.length) { _containerHint.text = @"请填写容器 UUID 或完整路径"; return; }
    if (![container hasPrefix:@"/"]) container = [WQGameAppRoot stringByAppendingPathComponent:container];
    if (!WQGameIsDir(container)) { _containerHint.text = @"容器目录不存在，请检查 UUID"; return; }
    if (!WQGameSafeRelative(rel)) { _relHint.text = @"请填写不含 .. 的相对路径"; return; }
    if (!alias.length) alias = rel.lastPathComponent;
    NSDictionary *entry = @{@"id": NSUUID.UUID.UUIDString, @"game": game.length ? game : @"自定义",
                            @"alias": alias, @"container": container, @"relative": rel};
    WQGameAddPath(entry);
    wq_log(@"game: added custom path %@", WQGameFullPath(entry));
    [self.navigationController popViewControllerAnimated:YES];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField { [textField resignFirstResponder]; return YES; }

@end

#pragma mark - Quick injection

@implementation WQGameInjectViewController {
    NSDictionary *_entry;
    NSMutableArray<NSDictionary *> *_files;
    UILabel *_result;
    NSString *_targetPath;
}

- (instancetype)initWithEntry:(NSDictionary *)entry
{
    if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
        _entry = entry;
        _files = [NSMutableArray new];
        _targetPath = WQGameFullPath(entry);
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"放入资源文件";
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    WQStyleTableView(self.tableView);
    self.tableView.separatorColor = WQColorLine();
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"选择文件" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(importTapped)];
    if ([_entry[@"relative"] isEqualToString:WQGameExactChain]) {
        UIBarButtonItem *lua = [[UIBarButtonItem alloc] initWithTitle:@"Lua 注入"
            style:UIBarButtonItemStylePlain target:self action:@selector(openLuaTapped)];
        self.navigationItem.rightBarButtonItems = @[self.navigationItem.rightBarButtonItem, lua];
    }
    _result = WQGameHintLabel(@"尚未写入");
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return 2;
    if (section == 1) return (NSInteger)_files.count + 2;
    return 3;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return @[@"目标路径", @"待放入的资源文件", @"写入"][section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 1) return @"支持 pak、sig、lua 及任意文件，可多选。同名文件会被替换并自动备份；失败的文件会留在列表里便于重试。";
    return section == 2 ? WQGameRiskNote : nil;
}
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) return 60.0;
    if (indexPath.section == 1 && (NSUInteger)indexPath.row >= _files.count + 1) return WQControlH + WQSpace4;
    if (indexPath.section == 2 && indexPath.row >= 1) return WQControlH + WQSpace4;
    return WQGameRowH();
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = WQGamePlainCell();
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryType = UITableViewCellAccessoryNone;
    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            cell.textLabel.text = _entry[@"alias"];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", _entry[@"game"], _entry[@"relative"]];
        } else {
            cell.textLabel.text = @"完整路径（长按复制）";
            cell.detailTextLabel.text = _targetPath;
        }
        cell.imageView.image = WQLinearIcon(@"folder");
        return cell;
    }
    if (indexPath.section == 1) {
        NSUInteger idx = (NSUInteger)indexPath.row;
        if (idx < _files.count) {
            NSDictionary *f = _files[idx];
            cell.textLabel.text = f[@"name"];
            cell.detailTextLabel.text = wq_size_text((unsigned long long)[f[@"size"] unsignedLongLongValue]);
            cell.imageView.image = WQLinearIcon(@"doc");
            return cell;
        }
        if (idx == _files.count) {
            unsigned long long total = 0;
            for (NSDictionary *f in _files) total += [f[@"size"] unsignedLongLongValue];
            cell.textLabel.text = _files.count
                ? [NSString stringWithFormat:@"已选择 %lu 个文件 · %@", (unsigned long)_files.count, wq_size_text(total)]
                : @"尚未选择文件";
            cell.detailTextLabel.text = _files.count ? @"左滑可移除单个文件" : @"点右上角「选择文件」或下方按钮";
            return cell;
        }
        return WQGameButtonCell(@"从「文件」选择", self, @selector(importTapped), NO);
    }
    if (indexPath.row == 0) {
        cell.textLabel.text = @"写入结果";
        cell.detailTextLabel.text = _result.text;
        cell.imageView.image = WQLinearIcon(@"info.circle");
        return cell;
    }
    if (indexPath.row == 1) return WQGameButtonCell(@"复制目标路径", self, @selector(copyPathTapped), NO);
    return WQGameButtonCell([NSString stringWithFormat:@"写入 %lu 个文件", (unsigned long)_files.count],
                            self, @selector(writeTapped), YES);
}

- (void)copyPathTapped { WQGameCopyPath(self, _targetPath); }

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point
{
    if (indexPath.section != 0 || indexPath.row != 1) return nil;
    NSString *path = _targetPath;
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
        actionProvider:^UIMenu *(NSArray<UIMenuElement *> * __unused suggested) {
            UIAction *copy = [UIAction actionWithTitle:@"复制完整路径" image:[UIImage systemImageNamed:@"doc.on.doc"]
                identifier:nil handler:^(UIAction *__unused a) {
                    WQGameInjectViewController *s = weakSelf;
                    if (s) WQGameCopyPath(s, path);
                }];
            return [UIMenu menuWithTitle:@"" children:@[copy]];
        }];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return indexPath.section == 1 && (NSUInteger)indexPath.row < _files.count;
}
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
 forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete || indexPath.section != 1 ||
        (NSUInteger)indexPath.row >= _files.count) return;
    NSDictionary *f = _files[(NSUInteger)indexPath.row];
    [NSFileManager.defaultManager removeItemAtPath:f[@"local"] error:nil];
    [_files removeObjectAtIndex:(NSUInteger)indexPath.row];
    [self.tableView reloadData];
}

- (void)openLuaTapped
{
    WQGameLuaViewController *vc = [[WQGameLuaViewController alloc]
        initWithContainer:_entry[@"container"] relative:_entry[@"relative"]
                    alias:_entry[@"alias"]];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)importTapped
{
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem]];
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller { (void)controller; }

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    (void)controller;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *staging = WQGameStagingDir();
    for (NSURL *url in urls) {
        NSString *name = WQGameSafeFileName(url.lastPathComponent);
        if (!name) continue;
        BOOL scoped = [url startAccessingSecurityScopedResource];
        NSString *local = [staging stringByAppendingPathComponent:name];
        NSUInteger suffix = 1;
        while ([fm fileExistsAtPath:local])
            local = [staging stringByAppendingPathComponent:
                [NSString stringWithFormat:@"%lu-%@", (unsigned long)suffix++, name]];
        NSError *err = nil;
        BOOL ok = [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:local] error:&err];
        if (scoped) [url stopAccessingSecurityScopedResource];
        if (!ok) { wq_log(@"game: stage failed %@ (%@)", name, err.localizedDescription); continue; }
        unsigned long long size = [[fm attributesOfItemAtPath:local error:nil][NSFileSize] unsignedLongLongValue];
        [_files addObject:@{@"name": name, @"local": local, @"size": @(size)}];
    }
    [self.tableView reloadData];
}

- (void)writeTapped
{
    if (!_files.count) { wq_alert(self, @"没有文件", @"请先从「文件」选择要放入的资源文件。"); return; }
    NSString *target = _targetPath;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认写入"
        message:[NSString stringWithFormat:@"目标目录：%@\n\n将写入 %lu 个文件。同名文件会被替换，替换前在「备份」中保留副本。\n\n%@",
            target, (unsigned long)_files.count, WQGameRiskNote]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"写入" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *__unused a) { [weakSelf performWrite]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)performWrite
{
    _result.text = @"正在写入…";
    [self.tableView reloadData];
    NSArray<NSDictionary *> *files = [_files copy];
    NSString *target = _targetPath;
    BOOL parallel = WQSettingGet(WQSettingParallelWriteKey, YES) && files.count > 1;
    __weak typeof(self) weakSelf = self;
    dispatch_async(wq_io(), ^{
        if (!WQGameIsDir(target)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                WQGameInjectViewController *s = weakSelf;
                if (!s) return;
                s->_result.text = @"目标目录不存在";
                [s.tableView reloadData];
                wq_alert(s, @"目标目录不存在", @"请回到「游戏功能」重新检测并创建目录链，或重新保存这条路径。");
            });
            return;
        }
        NSMutableArray<NSDictionary *> *results = [NSMutableArray arrayWithCapacity:files.count];
        for (NSUInteger i = 0; i < files.count; i++) [results addObject:@{}];
        dispatch_queue_t queue = dispatch_queue_create("wq.game.write",
            parallel ? DISPATCH_QUEUE_CONCURRENT : DISPATCH_QUEUE_SERIAL);
        // Cap concurrency: wide parallel writes can starve the target app's
        // own filesystem work and the advisory-lock bookkeeping.
        dispatch_semaphore_t limit = dispatch_semaphore_create(parallel ? 3 : 1);
        dispatch_apply(files.count, queue, ^(size_t i) {
            dispatch_semaphore_wait(limit, DISPATCH_TIME_FOREVER);
            NSDictionary *f = files[i];
            NSString *dest = [target stringByAppendingPathComponent:f[@"name"]];
            struct stat st;
            BOOL exists = wq_stat(dest, &st) && S_ISREG(st.st_mode);
            NSString *err = nil;
            BOOL ok = exists ? wq_write_from_file(dest, f[@"local"], &err)
                             : wq_create_file_from(dest, f[@"local"], &err);
            NSString *failure = nil;
            if (!ok) failure = err ?: @"写入失败";
            else {
                struct stat after;
                unsigned long long want = [f[@"size"] unsignedLongLongValue];
                if (!wq_stat(dest, &after) || !S_ISREG(after.st_mode) || (unsigned long long)after.st_size != want)
                    failure = @"写入后校验不一致";
            }
            NSDictionary *r = failure ? @{@"name": f[@"name"], @"error": failure}
                                      : @{@"name": f[@"name"], @"replaced": @(exists),
                                          @"bytes": f[@"size"]};
            @synchronized (results) { results[i] = r; }
            wq_log(@"game: %@ %@ (%llu bytes, replaced=%d)", failure ? @"FAILED" : @"wrote",
                   dest, [f[@"size"] unsignedLongLongValue], exists ? 1 : 0);
            dispatch_semaphore_signal(limit);
        });

        NSUInteger okCount = 0, replaced = 0;
        NSMutableArray<NSString *> *failures = [NSMutableArray new];
        NSMutableSet<NSString *> *succeeded = [NSMutableSet new];
        for (NSDictionary *r in results) {
            if (r[@"error"]) [failures addObject:[NSString stringWithFormat:@"%@：%@", r[@"name"], r[@"error"]]];
            else {
                okCount++;
                if ([r[@"replaced"] boolValue]) replaced++;
                [succeeded addObject:r[@"name"]];
            }
        }
        NSFileManager *fm = NSFileManager.defaultManager;
        NSMutableArray<NSDictionary *> *remaining = [NSMutableArray new];
        for (NSDictionary *f in files) {
            if ([succeeded containsObject:f[@"name"]]) [fm removeItemAtPath:f[@"local"] error:nil];
            else [remaining addObject:f];   // keep failed files for a retry
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            WQGameInjectViewController *s = weakSelf;
            if (!s) return;
            NSString *summary = [NSString stringWithFormat:@"成功 %lu / %lu · 替换 %lu%@",
                (unsigned long)okCount, (unsigned long)files.count, (unsigned long)replaced,
                parallel ? @" · 并行" : @""];
            s->_result.text = summary;
            [s->_files setArray:remaining];
            [s.tableView reloadData];
            NSString *msg = failures.count
                ? [NSString stringWithFormat:@"%@\n\n失败（已留在列表）：\n%@", summary,
                                             [failures componentsJoinedByString:@"\n"]]
                : [NSString stringWithFormat:@"%@\n\n目标：%@", summary, target];
            NSArray *names = [files valueForKey:@"name"] ?: @[];
            WQRecordInjection(@{@"target": target,
                                @"game": s->_entry[@"game"] ?: @"",
                                @"alias": s->_entry[@"alias"] ?: @"",
                                @"ok": @(okCount), @"replaced": @(replaced),
                                @"failed": @(failures.count),
                                @"files": [names componentsJoinedByString:@"、"] ?: @""});
            wq_alert(s, failures.count ? @"部分完成" : @"写入完成", msg);
        });
    });
}

@end


// Runs on the shared IO queue. wq_list / wq_stat obtain sandbox tokens
// when needed, so this works on iOS 26 and iOS 27 alike.
static NSArray<NSDictionary *> *WQLuaListItems(NSString *dir)
{
    NSMutableArray<NSDictionary *> *out = [NSMutableArray new];
    for (NSString *name in wq_list(dir, nil) ?: @[]) {
        if ([name isEqualToString:@"."] || [name isEqualToString:@".."] || !name.length) continue;
        NSString *path = [dir stringByAppendingPathComponent:name];
        struct stat st;
        if (!wq_stat(path, &st)) continue;
        [out addObject:@{@"name": name, @"path": path,
                         @"dir": @(S_ISDIR(st.st_mode)),
                         @"size": @((unsigned long long)st.st_size)}];
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL da = [a[@"dir"] boolValue], db = [b[@"dir"] boolValue];
        if (da != db) return da ? NSOrderedAscending : NSOrderedDescending;
        return [a[@"name"] compare:b[@"name"] options:NSCaseInsensitiveSearch];
    }];
    return out;
}

#pragma mark - Delta Force default Lua injection

// Three explicit, user-driven sources for the verified LuaDebug chain. None of
// them hide, disguise, auto-run or defeat any integrity check: this is the same
// plain file write used by the general resource importer, with an extra network
// source and a development notice. The "official" option writes nothing.

@implementation WQGameLuaViewController {
    NSString *_container, *_relative, *_target, *_alias, *_luaDebug;
    NSString *_chainStatus, *_status, *_downloadText;
    NSArray<NSDictionary *> *_items;
    NSURLSession *_session;
    NSURLSessionDownloadTask *_downloadTask;
    NSString *_stageLocal, *_stageError;   // delegate queue only
    double _downloadProgress;
    BOOL _chainReady, _checked, _downloading;
}

- (instancetype)initWithContainer:(NSString *)container relative:(NSString *)relative
                            alias:(NSString *)alias
{
    if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
        _container = container ?: @"";
        _relative = relative ?: WQGameExactChain;
        _alias = alias ?: @"默认注入路径";
        _target = [_container stringByAppendingPathComponent:_relative];
        _luaDebug = [_container stringByAppendingPathComponent:WQGameLuaDebugChain];
        _status = @"尚未注入";
        _chainStatus = @"正在检测目录…";
        _downloadText = @"";
        _items = @[];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"三角洲行动 · Lua 注入";
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    WQStyleTableView(self.tableView);
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"刷新" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(refreshTapped)];
    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.defaultSessionConfiguration;
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    // A serial background delegate queue: file staging happens off the main
    // thread, UI updates are dispatched back explicitly.
    _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    // First entry: detect every level and create only the missing ones.
    if (!_checked) { _checked = YES; [self ensureChainAndRefresh]; }
    else [self refreshItems];
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    if (self.isMovingFromParentViewController || self.isBeingDismissed) {
        // NSURLSession retains its delegate; invalidate to break the cycle.
        [_downloadTask cancel];
        [_session invalidateAndCancel];
    }
}

- (void)setStatus:(NSString *)text
{
    _status = text ?: @"";
    [self.tableView reloadData];
}
- (void)setChainStatus:(NSString *)text ready:(BOOL)ready
{
    _chainStatus = text ?: @"";
    _chainReady = ready;
    [self.tableView reloadData];
}
- (void)copyText:(NSString *)text
{
    UIPasteboard.generalPasteboard.string = text;
    self.navigationItem.prompt = @"已复制";
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WQGameLuaViewController *v = weakSelf;
        if (v && [v.navigationItem.prompt isEqualToString:@"已复制"]) v.navigationItem.prompt = nil;
    });
}

#pragma mark - Directory chain

// Runs on the shared IO queue. wq_list / wq_stat obtain sandbox tokens when
// needed, so this works on iOS 26 and iOS 27 alike.
- (void)ensureChainAndRefresh
{
    [self setChainStatus:@"正在检测目录…" ready:NO];
    NSString *container = _container, *relative = _relative, *target = _target;
    __weak typeof(self) weakSelf = self;
    dispatch_async(wq_io(), ^{
        NSString *error = nil;
        NSUInteger created = 0;
        NSString *final = WQGameEnsureChain(container, relative, &created, &error);
        NSArray<NSDictionary *> *items = final ? WQLuaListItems(target) : @[];
        dispatch_async(dispatch_get_main_queue(), ^{
            WQGameLuaViewController *v = weakSelf;
            if (!v) return;
            v->_items = items;
            if (!final) {
                [v setChainStatus:[@"创建失败：" stringByAppendingString:(error ?: @"未知错误")] ready:NO];
                return;
            }
            [v setChainStatus:(created
                ? [NSString stringWithFormat:@"已就绪 · 自动新建 %lu 层目录", (unsigned long)created]
                : @"已就绪 · 全部目录已存在") ready:YES];
            wq_log(@"game: lua chain ready, created %lu levels, %lu items",
                   (unsigned long)created, (unsigned long)items.count);
        });
    });
}

- (void)refreshItems
{
    NSString *target = _target;
    __weak typeof(self) weakSelf = self;
    dispatch_async(wq_io(), ^{
        NSArray<NSDictionary *> *items = WQLuaListItems(target);
        dispatch_async(dispatch_get_main_queue(), ^{
            WQGameLuaViewController *v = weakSelf;
            if (!v) return;
            v->_items = items;
            [v.tableView reloadData];
        });
    });
}

- (void)refreshTapped
{
    [self.view endEditing:YES];
    if (_downloading) {
        [_downloadTask cancel];
        _downloading = NO;
        _downloadTask = nil;
        _downloadText = @"已取消下载";
    }
    [_session invalidateAndCancel];
    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.defaultSessionConfiguration;
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    [self ensureChainAndRefresh];
    [self setStatus:@"已刷新目录"];
}

#pragma mark - Table: four clear sections

- (NSArray<NSString *> *)sectionTitles
{
    return @[@"注入方式", @"目录", @"LuaDebug 内容", @"危险操作"];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return (NSInteger)[self sectionTitles].count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return 3;
    if (section == 1) return 4;
    if (section == 2) return (NSInteger)_items.count + 1;   // + refresh row
    return 1;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return [self sectionTitles][(NSUInteger)section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 0)
        return [NSString stringWithFormat:
            @"自定义：从「文件」App 选 lua，按原文件名写入。官方版：只显示开发进度提示，不下载、不写入。第三方版：下载后写入，本行显示进度条与百分比。\n\n%@\n\n当前状态：%@\n\n%@",
            WQGameLuaThirdPartyNote, _status, WQGameRiskNote];
    if (section == 1)
        return @"首次进入自动逐级检测并补建缺失目录。点「目录链」重新检测，点目标路径复制；两个入口都走共享文件浏览器。写入前仍会再次校验目录链。";
    if (section == 2)
        return @"左滑删除单条：文件在「备份」留副本，目录连同内容一起移除。点「刷新列表」重新读取。";
    return @"删除 LuaDebug 整棵目录及其全部内容，不保留副本、无法撤销。删除后本页不立刻重建，下次进入自动补建目录链。";
}
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSUInteger section = (NSUInteger)indexPath.section;
    if (section == 0) return 60.0;
    if (section == 1) return indexPath.row == 1 ? 92.0 : 56.0;   // 3-line path
    if (section == 2) return 56.0;
    return 56.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = WQGamePlainCell();
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    NSUInteger section = (NSUInteger)indexPath.section;
    NSUInteger row = (NSUInteger)indexPath.row;

    if (section == 0) {
        NSArray<NSString *> *titles = @[@"自定义导入", @"官方版", @"第三方版"];
        NSArray<NSString *> *subs = @[
            @"从「文件」App 选择 lua，按原文件名写入",
            @"查看开发进度提示，不写入任何文件",
            @"写入社区寻找到的较稳定 lua",
        ];
        NSArray<NSString *> *icons = @[@"square.and.arrow.down", @"info.circle", @"arrow.down.circle"];
        cell.textLabel.text = titles[row];
        cell.imageView.image = WQLinearIcon(icons[row]);
        if (row == 2 && _downloading) {
            UIProgressView *progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
            progress.frame = CGRectMake(0, 0, 92, 4);
            progress.progressTintColor = WQColorStrong();
            progress.trackTintColor = WQColorLine();
            progress.progress = (float)_downloadProgress;
            cell.accessoryView = progress;
            cell.detailTextLabel.text = _downloadText.length ? _downloadText : @"正在下载…";
            cell.detailTextLabel.numberOfLines = 2;
        } else {
            cell.detailTextLabel.text = (row == 2 && _downloadText.length)
                ? _downloadText : subs[row];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else if (section == 1) {
        if (row == 0) {
            cell.textLabel.text = @"目录链";
            cell.detailTextLabel.text = _chainStatus;
            cell.imageView.image = WQLinearIcon(_chainReady ? @"checkmark.circle" : @"clock");
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (row == 1) {
            cell.textLabel.text = _target;
            cell.textLabel.font = WQFontValue();
            cell.textLabel.numberOfLines = 3;
            cell.detailTextLabel.text = @"点按复制完整路径";
            cell.imageView.image = WQLinearIcon(@"folder");
        } else {
            cell.textLabel.text = row == 2 ? @"打开 LuaDebug 根目录" : @"打开注入目录";
            cell.detailTextLabel.text = row == 2 ? _luaDebug : _target;
            cell.detailTextLabel.numberOfLines = 2;
            cell.imageView.image = WQLinearIcon(row == 2 ? @"folder" : @"folder.badge.plus");
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else if (section == 2) {
        if (row >= _items.count) {
            cell.textLabel.text = @"刷新列表";
            cell.detailTextLabel.text = _items.count
                ? [NSString stringWithFormat:@"当前 %lu 项", (unsigned long)_items.count] : @"目录为空";
            cell.imageView.image = WQLinearIcon(@"arrow.clockwise");
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            NSDictionary *item = _items[row];
            BOOL dir = [item[@"dir"] boolValue];
            cell.textLabel.text = item[@"name"];
            cell.textLabel.numberOfLines = 2;
            cell.detailTextLabel.text = dir
                ? @"目录 · 左滑可连同内容删除"
                : [NSString stringWithFormat:@"文件 · %@", wq_size_text([item[@"size"] unsignedLongLongValue])];
            cell.imageView.image = WQLinearIcon(dir ? @"folder" : @"doc");
        }
    } else {
        cell.textLabel.text = @"清空 LuaDebug 整棵目录";
        cell.detailTextLabel.text = @"删除全部子目录与文件，不保留副本";
        cell.imageView.image = WQLinearIcon(@"trash");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSUInteger section = (NSUInteger)indexPath.section;
    NSUInteger row = (NSUInteger)indexPath.row;
    if (section == 0) {
        if (row == 0) [self importTapped];
        else if (row == 1) [self officialTapped];
        else [self thirdPartyTapped];
        return;
    }
    if (section == 1) {
        if (row == 0) [self ensureChainAndRefresh];
        else if (row == 1) [self copyText:_target];
        else {
            [self.view endEditing:YES];
            WQOpenPathFromExtras(self.navigationController, row == 2 ? _luaDebug : _target);
        }
        return;
    }
    if (section == 2) { if (row >= _items.count) [self refreshItems]; return; }
    [self purgeLuaDebugTapped];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return indexPath.section == 2 && (NSUInteger)indexPath.row < _items.count;
}
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
 forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete || indexPath.section != 2 ||
        (NSUInteger)indexPath.row >= _items.count) return;
    [self deleteItem:_items[(NSUInteger)indexPath.row]];
}

#pragma mark - Deletion

- (void)deleteItem:(NSDictionary *)item
{
    NSString *name = item[@"name"], *path = item[@"path"];
    BOOL dir = [item[@"dir"] boolValue];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:
        [NSString stringWithFormat:@"删除「%@」？", name]
        message:[NSString stringWithFormat:@"%@\n\n%@", path,
            dir ? @"该目录及其全部内容会被移除，不保留副本，且无法撤销。"
                : @"该文件会被移除，并在「备份」中保留一份副本。"]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *__unused a) {
            dispatch_async(wq_io(), ^{
                NSString *error = nil;
                BOOL ok = dir ? wq_delete_tree(path, &error) : wq_delete(path, &error);
                dispatch_async(dispatch_get_main_queue(), ^{
                    WQGameLuaViewController *v = weakSelf;
                    if (!v) return;
                    if (!ok) {
                        [v setStatus:[@"删除失败：" stringByAppendingString:(error ?: @"未知错误")]];
                        wq_alert(v, @"删除失败", error ?: @"未知错误");
                        return;
                    }
                    wq_log(@"game: lua item deleted %@ (dir=%d)", path, dir ? 1 : 0);
                    [v setStatus:[NSString stringWithFormat:@"已删除 %@", name]];
                    [v refreshItems];
                });
            });
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)purgeLuaDebugTapped
{
    NSString *luaDebug = _luaDebug;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清空 LuaDebug？"
        message:[NSString stringWithFormat:@"%@\n\n将删除该目录及其全部子目录与文件（包括 LuaSource、DFM、BusinessEntrance 和所有已注入的 lua）。\n\n不保留副本，无法撤销。删除后本页不会立刻重建，下次重新进入时会自动补建目录链。",
            luaDebug]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *__unused a) {
            dispatch_async(wq_io(), ^{
                NSString *error = nil;
                BOOL ok = wq_delete_tree(luaDebug, &error);
                dispatch_async(dispatch_get_main_queue(), ^{
                    WQGameLuaViewController *v = weakSelf;
                    if (!v) return;
                    if (!ok) {
                        [v setStatus:[@"清空失败：" stringByAppendingString:(error ?: @"未知错误")]];
                        wq_alert(v, @"清空失败", error ?: @"未知错误");
                        return;
                    }
                    wq_log(@"game: LuaDebug tree purged -> %@", luaDebug);
                    v->_items = @[];
                    [v setChainStatus:@"LuaDebug 已清空 · 下次进入自动重建" ready:NO];
                    [v setStatus:@"LuaDebug 已清空"];
                });
            });
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Official (notice only)

- (void)officialTapped
{
    // 只显示开发进度：不下载、不写入、不隐藏、不伪装，也不实现任何绕过逻辑。
    wq_alert(self, @"官方版", [NSString stringWithFormat:@"%@\n\n当前版本不会下载或写入任何文件，也不包含任何防封实现。",
                               WQGameLuaOfficialNotice]);
    [self setStatus:@"官方版：等待版本迭代，未写入文件"];
    wq_log(@"game: official lua notice shown, no file written");
}

#pragma mark - Custom import

- (void)importTapped
{
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem]];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller { (void)controller; }

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    (void)controller;
    NSURL *url = urls.firstObject;
    NSString *name = WQGameSafeFileName(url.lastPathComponent);
    if (!url || !name) { wq_alert(self, @"无法导入", @"请选择普通文件。"); return; }
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *local = [WQGameStagingDir() stringByAppendingPathComponent:name];
    [fm removeItemAtPath:local error:nil];
    NSError *error = nil;
    BOOL ok = [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:local] error:&error];
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!ok) {
        [self setStatus:@"导入失败"];
        wq_alert(self, @"导入失败", error.localizedDescription ?: @"无法读取所选文件");
        return;
    }
    [self confirmWriteLocal:local name:name source:@"自定义导入"];
}

#pragma mark - Third-party download with a real progress bar

- (void)thirdPartyTapped
{
    if (_downloading) {
        [_downloadTask cancel];
        _downloading = NO;
        _downloadTask = nil;
        _downloadText = @"已取消下载";
        [self setStatus:@"已取消下载"];
        return;
    }
    _stageLocal = nil;
    _stageError = nil;
    _downloadProgress = 0.0;
    _downloading = YES;
    _downloadText = @"正在下载 0%";
    [self setStatus:@"正在下载…"];
    NSURL *url = [NSURL URLWithString:WQGameLuaThirdPartyURL];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30.0];
    _downloadTask = [_session downloadTaskWithRequest:request];
    [_downloadTask resume];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
 totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
    (void)session; (void)downloadTask; (void)bytesWritten;
    double frac = totalBytesExpectedToWrite > 0
        ? (double)totalBytesWritten / (double)totalBytesExpectedToWrite : 0.0;
    if (frac < 0.0) frac = 0.0;
    if (frac > 1.0) frac = 1.0;
    NSString *text = totalBytesExpectedToWrite > 0
        ? [NSString stringWithFormat:@"正在下载 %d%% · %@ / %@",
            (int)(frac * 100.0), wq_size_text((unsigned long long)totalBytesWritten),
            wq_size_text((unsigned long long)totalBytesExpectedToWrite)]
        : [NSString stringWithFormat:@"正在下载 · 已接收 %@",
            wq_size_text((unsigned long long)totalBytesWritten)];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        WQGameLuaViewController *v = weakSelf;
        if (!v || !v->_downloading) return;
        v->_downloadProgress = frac;
        v->_downloadText = text;
        NSIndexPath *row = [NSIndexPath indexPathForRow:2 inSection:0];
        [v.tableView reloadRowsAtIndexPaths:@[row] withRowAnimation:UITableViewRowAnimationNone];
    });
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didFinishDownloadingToURL:(NSURL *)location
{
    (void)session; (void)downloadTask;
    // location is only valid during this callback: stage it synchronously on
    // the delegate's serial background queue.
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *local = [WQGameStagingDir() stringByAppendingPathComponent:WQGameLuaThirdPartyName];
    [fm removeItemAtPath:local error:nil];
    NSError *error = nil;
    if (![fm copyItemAtPath:location.path toPath:local error:&error]) {
        _stageLocal = nil;
        _stageError = error.localizedDescription ?: @"暂存下载文件失败";
        return;
    }
    unsigned long long size = [[fm attributesOfItemAtPath:local error:nil][NSFileSize] unsignedLongLongValue];
    if (!size || size > WQGameLuaMaxBytes) {
        _stageError = [NSString stringWithFormat:@"文件大小异常（%@）", wq_size_text(size)];
        [fm removeItemAtPath:local error:nil];
        _stageLocal = nil;
        return;
    }
    _stageLocal = local;
    _stageError = nil;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
didCompleteWithError:(NSError * _Nullable)error
{
    (void)session;
    if (error && error.code == NSURLErrorCancelled) return;   // handled by the cancel path
    NSString *failure = error ? (error.localizedDescription ?: @"网络请求失败") : nil;
    if (!failure) failure = _stageError;
    if (!failure && !_stageLocal) failure = @"下载内容为空";
    if (!failure) {
        NSHTTPURLResponse *http = [task.response isKindOfClass:NSHTTPURLResponse.class]
            ? (NSHTTPURLResponse *)task.response : nil;
        if (!http) failure = @"响应不是 HTTP";
        else if (http.statusCode != 200)
            failure = [NSString stringWithFormat:@"源站返回 HTTP %ld", (long)http.statusCode];
        else {
            NSString *type = [(NSString *)(http.allHeaderFields[@"Content-Type"] ?: @"") lowercaseString];
            if ([type containsString:@"json"] || [type containsString:@"html"])
                failure = @"源站返回了非文件内容（错误页）";
        }
    }
    if (failure && _stageLocal) {
        [NSFileManager.defaultManager removeItemAtPath:_stageLocal error:nil];
        _stageLocal = nil;
    }
    NSString *local = _stageLocal;
    NSString *text = failure ? [@"下载失败：" stringByAppendingString:failure]
                             : @"下载完成 100% · 待确认写入";
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        WQGameLuaViewController *v = weakSelf;
        if (!v || !v->_downloading) return;
        v->_downloading = NO;
        v->_downloadTask = nil;
        v->_downloadProgress = failure ? 0.0 : 1.0;
        v->_downloadText = text;
        v->_status = text;
        [v.tableView reloadData];
        if (failure) {
            wq_alert(v, @"下载失败", [NSString stringWithFormat:
                @"%@\n\n可改用「自定义导入」从「文件」App 选择本地 lua。", failure]);
            return;
        }
        wq_log(@"game: lua downloaded -> %@", local);
        [v confirmWriteLocal:local name:WQGameLuaThirdPartyName source:@"第三方版"];
    });
}

#pragma mark - Shared write path

- (void)confirmWriteLocal:(NSString *)local name:(NSString *)name source:(NSString *)source
{
    [self setStatus:[NSString stringWithFormat:@"%@ · 待确认写入", source]];
    NSString *target = _target;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认注入 Lua"
        message:[NSString stringWithFormat:@"方式：%@\n文件：%@\n目标目录：%@\n\n"
                 @"若目标目录缺失会逐级创建；同名文件会被替换，替换前在「备份」中保留副本。\n\n%@",
                 source, name, target, WQGameRiskNote]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
        handler:^(UIAlertAction *__unused a) {
            [self setStatus:@"已取消写入"];
        }]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"写入" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *__unused action) {
            [weakSelf writeLocal:local name:name source:source];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)writeLocal:(NSString *)local name:(NSString *)name source:(NSString *)source
{
    [self setStatus:@"正在写入…"];
    NSString *container = _container, *relative = _relative, *target = _target, *alias = _alias;
    unsigned long long size = [[NSFileManager.defaultManager attributesOfItemAtPath:local
                                                                             error:nil][NSFileSize] unsignedLongLongValue];
    __weak typeof(self) weakSelf = self;
    dispatch_async(wq_io(), ^{
        NSString *chainError = nil;
        NSUInteger created = 0;
        NSString *final = WQGameEnsureChain(container, relative, &created, &chainError);
        NSString *failure = nil;
        BOOL replaced = NO;
        if (!final) failure = chainError ?: @"目标目录创建失败";
        else {
            NSString *dest = [target stringByAppendingPathComponent:name];
            struct stat st;
            replaced = wq_stat(dest, &st) && S_ISREG(st.st_mode);
            NSString *writeError = nil;
            BOOL ok = replaced ? wq_write_from_file(dest, local, &writeError)
                               : wq_create_file_from(dest, local, &writeError);
            if (!ok) failure = writeError ?: @"写入失败";
            else {
                struct stat after;
                if (!wq_stat(dest, &after) || !S_ISREG(after.st_mode) ||
                    (unsigned long long)after.st_size != size) failure = @"写入后校验不一致";
            }
            wq_log(@"game: lua %@ %@ (%llu bytes, replaced=%d, created=%lu)",
                   failure ? @"FAILED" : @"wrote", dest, size, replaced ? 1 : 0,
                   (unsigned long)created);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            WQGameLuaViewController *v = weakSelf;
            if (!v) return;
            if (failure) {
                [v setStatus:[@"失败：" stringByAppendingString:failure]];
                v->_downloadText = @"下载完成 · 写入失败，可重试";
                [v.tableView reloadData];
                wq_alert(v, @"注入失败", failure);
                return;
            }
            [NSFileManager.defaultManager removeItemAtPath:local error:nil];
            v->_downloadText = @"已下载并写入目标目录";
            [v setStatus:[NSString stringWithFormat:@"已写入 %@ · %@ · %@",
                          name, source, wq_size_text(size)]];
            WQRecordInjection(@{@"target": target, @"game": WQGameExactName, @"alias": alias,
                                @"ok": @1, @"replaced": @(replaced), @"failed": @0,
                                @"files": name});
            wq_alert(v, @"注入完成", [NSString stringWithFormat:@"%@\n\n目标：%@/%@\n\n%@",
                                     name, target, name, WQGameRiskNote]);
            [v refreshItems];
        });
    });
}

@end
