//
//  WQGameFeatures.m
//  WQ Files — game resource tools
//  GPL-3.0-or-later.
//

#import "WQGameFeatures.h"
#import "WQDesignTokens.h"
#import "WQAccess.h"
#import "WQLaunchServices.h"
#import "WQUI.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <dirent.h>

static NSString *const WQGameAppRoot = @"/private/var/mobile/Containers/Data/Application";
static NSString *const WQGamePathsKey = @"WQGameSavedPathsV1";
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

#pragma mark - Game catalogue

// Only Delta Force has a user-verified path. For every other game the app
// shows the real container identifier and lets the user pick: guessing a
// resource directory from a bundle-id keyword produced misleading results.
static NSString *const WQGameExactMark = @"Documents/DeltaForce/Saved";
static NSString *const WQGameExactChain =
    @"Documents/DeltaForce/Saved/LuaDebug/LuaSource/DFM/BusinessEntrance";
static NSString *const WQGameExactName = @"三角洲行动";

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
static void WQGameAddPath(NSDictionary *entry)
{
    NSMutableArray *all = [WQGameLoadPaths() mutableCopy];
    [all addObject:entry];
    WQGameSavePaths(all);
}
static NSString *WQGameFullPath(NSDictionary *entry)
{
    return [entry[@"container"] stringByAppendingPathComponent:entry[@"relative"]];
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
    wq_log(@"game: %lu containers via %@", (unsigned long)candidates.count, source ?: @"未找到");
    return apps;
}

void WQGameClearDetectionCache(void)
{
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
    c.backgroundColor = WQColorSurface();
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

// Plain-text credit view: no badge, no border, no colour.
static UIView *WQGameCreditFooter(void)
{
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 74)];
    UILabel *by = [UILabel new];
    by.text = @"by 淮季";
    by.font = WQFontCaption();
    by.textColor = WQColorText2();
    by.textAlignment = NSTextAlignmentLeft;
    by.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:by];
    UILabel *channel = [UILabel new];
    channel.text = @"公益频道@HeiMaoClub";
    channel.font = WQFontCaption();
    channel.textColor = WQColorText3();
    channel.textAlignment = NSTextAlignmentLeft;
    channel.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:channel];
    [NSLayoutConstraint activateConstraints:@[
        [by.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:WQGutter],
        [by.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-WQGutter],
        [by.topAnchor constraintEqualToAnchor:v.topAnchor constant:WQSpace6],
        [channel.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:WQGutter],
        [channel.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-WQGutter],
        [channel.topAnchor constraintEqualToAnchor:by.bottomAnchor constant:WQSpace1],
    ]];
    return v;
}

#pragma mark - Game centre

@interface WQGameCenterViewController ()
@end

@implementation WQGameCenterViewController {
    NSArray<NSDictionary *> *_apps;
    NSArray<NSDictionary *> *_paths;
    BOOL _detecting;
    BOOL _showAllApps;
    NSString *_statusText;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"游戏资源注入";
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    self.tableView.backgroundColor = WQColorBackground();
    self.tableView.separatorColor = WQColorLine();
    self.tableView.tableFooterView = WQGameCreditFooter();
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"重新检测" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(redetect)];
    _paths = WQGameLoadPaths();
    [self redetect];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    _paths = WQGameLoadPaths();
    [self.tableView reloadData];
}

- (void)redetect
{
    _detecting = YES;
    _apps = @[];
    [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    _statusText = @"正在查找应用容器…";
    dispatch_async(wq_io(), ^{
        NSString *source = nil;
        NSArray *found = WQGameScanApps(YES, &source);
        dispatch_async(dispatch_get_main_queue(), ^{
            WQGameCenterViewController *s = weakSelf;
            if (!s) return;
            s->_detecting = NO;
            s->_apps = found;
            s->_statusText = source;
            [s.tableView reloadData];
        });
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) {
        NSInteger base = (NSInteger)MAX(_apps.count, (NSUInteger)1);
        if (!_apps.count && !_detecting) base += 2;   // 查看日志 / 手动填写
        return base + (_apps.count > 3 && !_showAllApps ? 1 : 0);
    }
    return (NSInteger)_paths.count + 1;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return section == 0 ? @"已安装应用 · 选择容器" : @"保存的注入路径";
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 0)
        return @"三角洲行动按已验证的特征目录识别，可一键部署默认目录链。其余游戏只按应用标识排序推荐，不猜测资源目录；显示的是真实标识，请点按确认后再选择路径。长按任意行可复制容器路径。";
    return @"点按快捷放入资源文件，长按可复制完整路径；左滑只删除本应用的记录，不删除游戏里的文件。";
}
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return WQGameRowH();
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = WQGamePlainCell();
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    if (indexPath.section == 0) {
        NSUInteger idx = (NSUInteger)indexPath.row;
        BOOL moreRow = _apps.count > 3 && !_showAllApps && idx == _apps.count;
        if (_detecting) {
            cell.textLabel.text = @"正在读取已安装应用…";
            cell.detailTextLabel.text = @"首次读取名称数据库需要几秒";
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (!_apps.count) {
            cell.textLabel.text = @"未读取到应用容器";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"来源：%@ · 点右上角重新检测，或先看日志确认原因",
                                         _statusText ?: @"未找到"];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (moreRow) {
            cell.textLabel.text = [NSString stringWithFormat:@"显示全部 %lu 个应用", (unsigned long)_apps.count];
            cell.detailTextLabel.text = @"默认只显示前 3 个，其余按需要展开";
            cell.imageView.image = WQLinearIcon(@"chevron.down");
        } else if (!_apps.count && (idx == 1 || idx == 2)) {
            cell.textLabel.text = idx == 1 ? @"查看日志" : @"手动填写容器 UUID";
            cell.detailTextLabel.text = idx == 1 ? @"看是 No App Group、NO TOKEN 还是扫描被取消"
                                                 : @"不依赖检测结果，直接填写已知容器路径";
            cell.imageView.image = WQLinearIcon(idx == 1 ? @"doc.plaintext" : @"square.and.pencil");
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            NSDictionary *a = _apps[idx];
            BOOL exact = [a[@"exact"] boolValue];
            cell.textLabel.text = exact ? [NSString stringWithFormat:@"%@ · 已验证路径", a[@"name"]]
                                        : (a[@"game"] ?: a[@"name"]);
            NSString *bid = a[@"bid"];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@",
                bid.length ? bid : @"标识未知",
                exact ? @"Documents/DeltaForce/Saved" : (a[@"game"] ? @"标识匹配，仅供参考" : a[@"name"])];
            cell.imageView.image = WQLinearIcon(exact ? @"checkmark.square" : @"app.dashed");
            if (exact) {
                UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
                [b setTitle:@"一键部署" forState:UIControlStateNormal];
                WQStylePrimaryButton(b);
                b.titleLabel.font = WQFontValue();
                b.frame = CGRectMake(0, 0, 92, 30);
                b.tag = (NSInteger)idx;
                [b addTarget:self action:@selector(quickDeployTapped:) forControlEvents:UIControlEventTouchUpInside];
                cell.accessoryView = b;
            } else {
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            }
        }
    } else {
        NSUInteger idx = (NSUInteger)indexPath.row;
        if (idx < _paths.count) {
            NSDictionary *p = _paths[idx];
            cell.textLabel.text = p[@"alias"];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", p[@"game"], p[@"relative"]];
            cell.imageView.image = WQLinearIcon(@"folder");
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.textLabel.text = @"添加自定义路径";
            cell.detailTextLabel.text = @"手动填写容器 UUID 与相对路径";
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
    if (indexPath.section == 0 && (NSUInteger)indexPath.row < _apps.count)
        path = _apps[(NSUInteger)indexPath.row][@"path"];
    else if (indexPath.section == 1 && (NSUInteger)indexPath.row < _paths.count)
        path = WQGameFullPath(_paths[(NSUInteger)indexPath.row]);
    if (!path) return nil;
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
        actionProvider:^UIMenu *(NSArray<UIMenuElement *> * __unused suggested) {
            UIAction *copy = [UIAction actionWithTitle:@"复制完整路径" image:[UIImage systemImageNamed:@"doc.on.doc"]
                identifier:nil handler:^(UIAction *__unused a) {
                    WQGameCenterViewController *s = weakSelf;
                    if (s) WQGameCopyPath(s, path);
                }];
            return [UIMenu menuWithTitle:@"" children:@[copy]];
        }];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        NSUInteger idx = (NSUInteger)indexPath.row;
        if (_detecting) return;
        if (!_apps.count) {
            if (idx == 1) [self.navigationController pushViewController:[WQLogViewController new] animated:YES];
            else if (idx == 2) [self.navigationController pushViewController:[WQGameAddPathViewController new] animated:YES];
            return;
        }
        if (_apps.count > 3 && !_showAllApps && idx == _apps.count) {
            _showAllApps = YES;
            [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0]
                          withRowAnimation:UITableViewRowAnimationAutomatic];
            return;
        }
        if (idx >= _apps.count) return;
        NSDictionary *a = _apps[idx];
        NSString *suggest = [a[@"exact"] boolValue] ? WQGameExactChain : @"Documents";
        WQGamePathPickerViewController *picker = [[WQGamePathPickerViewController alloc]
            initWithGame:([a[@"exact"] boolValue] ? WQGameExactName : (a[@"game"] ?: a[@"name"]))
              container:a[@"path"] relative:@"" suggest:suggest];
        [self.navigationController pushViewController:picker animated:YES];
    } else if ((NSUInteger)indexPath.row < _paths.count) {
        WQGameInjectViewController *inject =
            [[WQGameInjectViewController alloc] initWithEntry:_paths[(NSUInteger)indexPath.row]];
        [self.navigationController pushViewController:inject animated:YES];
    } else {
        [self.navigationController pushViewController:[WQGameAddPathViewController new] animated:YES];
    }
}

- (void)quickDeployTapped:(UIButton *)sender
{
    if ((NSUInteger)sender.tag >= _apps.count) return;
    NSDictionary *a = _apps[(NSUInteger)sender.tag];
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
                    [inner.tableView reloadData];
                    wq_alert(inner, @"已保存", [NSString stringWithFormat:@"新建 %lu 个目录\n%@\n\n可在下方「保存的注入路径」中放入 lua 等资源。",
                                               (unsigned long)created, final]);
                });
            });
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return indexPath.section == 1 && (NSUInteger)indexPath.row < _paths.count;
}
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
 forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete || indexPath.section != 1 ||
        (NSUInteger)indexPath.row >= _paths.count) return;
    NSString *identifier = _paths[(NSUInteger)indexPath.row][@"id"];
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
    self.tableView.backgroundColor = WQColorBackground();
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
    self.tableView.backgroundColor = WQColorBackground();
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
    self.tableView.backgroundColor = WQColorBackground();
    self.tableView.separatorColor = WQColorLine();
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"选择文件" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(importTapped)];
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
            wq_alert(s, failures.count ? @"部分完成" : @"写入完成", msg);
        });
    });
}

@end
