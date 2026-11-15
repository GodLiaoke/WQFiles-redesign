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

static NSString *const WQGameAppRoot = @"/private/var/mobile/Containers/Data/Application";
static NSString *const WQGamePathsKey = @"WQGameSavedPathsV1";
static NSString *const WQGameRiskNote =
    @"仅用于本机调试或补齐缺失资源。写入前请先完全退出游戏、写入期间不要启动它；"
    @"写入不是快照，游戏仍在运行可能损坏存档。同名文件会被替换，替换前在「备份」中保留副本。"
    @"改动游戏文件可能违反游戏条款或导致账号受限，请勿用于在线对局或影响他人。";

@interface WQGamePathPickerViewController : UITableViewController <UITextFieldDelegate>
- (instancetype)initWithGame:(NSString *)game container:(NSString *)container
                    relative:(NSString *)relative suggest:(NSString *)suggest;
@end

@interface WQGameAddPathViewController : UITableViewController <UITextFieldDelegate>
@end

@interface WQGameInjectViewController : UITableViewController <UIDocumentPickerDelegate>
- (instancetype)initWithEntry:(NSDictionary *)entry;
@end

#pragma mark - Built-in game catalogue

// Identification is a hint, not a promise: bundle-id keywords are primary, and
// a few common directories are tried as a secondary signal. Exact resource
// paths differ per device and version, so the suggested path is only a starting
// value the user can edit while browsing the real container.
static NSArray<NSDictionary *> *WQGameProfiles(void)
{
    return @[
        @{@"name": @"三角洲行动", @"hints": @[@"deltaforce", @"projectd", @"dfm"],
          @"marks": @[@"Documents/DeltaForce/Saved", @"Documents/DeltaForce"],
          @"suggest": @"Documents/DeltaForce/Saved/LuaDebug/LuaSource/DFM/BusinessEntrance"},
        @{@"name": @"暗区突围", @"hints": @[@"arenabreakout", @"arena", @"abreakout", @"tmgp.ab"],
          @"marks": @[@"Documents/ArenaBreakout", @"Documents/ABreakout", @"Documents/AB"],
          @"suggest": @"Documents"},
        @{@"name": @"无畏契约", @"hints": @[@"valorant", @"valomobile", @"riot", @"tmgp.val"],
          @"marks": @[@"Documents/VALORANT", @"Documents/ShooterGame"],
          @"suggest": @"Documents"},
        @{@"name": @"和平精英", @"hints": @[@"pubgmhd", @"pubg", @"gameforpeace", @"tmgp.pubgm"],
          @"marks": @[@"Documents/PUBG", @"Documents/ShadowTrackerExtra"],
          @"suggest": @"Documents"},
        @{@"name": @"王者荣耀", @"hints": @[@"sgame", @"honorofkings", @"hok", @"tmgp.sgame"],
          @"marks": @[@"Documents/SGame", @"Documents/HOK"],
          @"suggest": @"Documents"},
        @{@"name": @"穿越火线", @"hints": @[@"crossfire", @"cfm", @"tmgp.cf", @"tmgp.cfm"],
          @"marks": @[@"Documents/CF", @"Documents/CFM"],
          @"suggest": @"Documents"},
    ];
}

#pragma mark - Shared helpers

static BOOL WQGameIsDir(NSString *path)
{
    struct stat st;
    if (wq_stat(path, &st)) return S_ISDIR(st.st_mode);
    struct stat target;
    return stat(path.fileSystemRepresentation, &target) == 0 && S_ISDIR(target.st_mode);
}

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

// Containers come from the system app database first; a plain directory
// listing is a fallback. No full inode scan is ever started here.
static NSArray<NSString *> *WQGameCandidateContainers(void)
{
    NSMutableArray<NSString *> *out = [NSMutableArray new];
    for (NSString *p in wq_ls_container_paths(nil) ?: @[]) {
        NSString *full = [p hasPrefix:@"/"] ? p : [WQGameAppRoot stringByAppendingPathComponent:p];
        if (![full containsString:@"/Containers/Data/Application/"]) continue;
        if (![out containsObject:full]) [out addObject:full];
    }
    for (NSString *name in wq_list(WQGameAppRoot, nil) ?: @[]) {
        NSString *full = [WQGameAppRoot stringByAppendingPathComponent:name];
        if (![out containsObject:full]) [out addObject:full];
    }
    return out;
}

static NSArray<NSDictionary *> *WQGameDetectInstalled(void)
{
    NSArray<NSDictionary *> *profiles = WQGameProfiles();
    NSMutableArray<NSDictionary *> *found = [NSMutableArray new];
    NSMutableSet<NSString *> *seen = [NSMutableSet new];
    for (NSString *dir in WQGameCandidateContainers()) {
        NSString *bid = (wq_container_label(dir) ?: @"").lowercaseString;
        for (NSDictionary *p in profiles) {
            BOOL hit = NO;
            for (NSString *h in p[@"hints"]) if ([bid containsString:h]) { hit = YES; break; }
            if (!hit) {
                for (NSString *m in p[@"marks"])
                    if (WQGameIsDir([dir stringByAppendingPathComponent:m])) { hit = YES; break; }
            }
            if (!hit || [seen containsObject:dir]) continue;
            [seen addObject:dir];
            [found addObject:@{@"name": p[@"name"], @"container": dir,
                               @"bundle": bid ?: @"", @"suggest": p[@"suggest"] ?: @"Documents"}];
            break;
        }
    }
    [found sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] compare:b[@"name"]];
    }];
    return found;
}

// Checks each level, creates only the missing ones, and refuses a level that
// already exists but is not a directory. Returns the final absolute path.
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

static NSString *WQGameStagingDir(void)
{
    NSString *d = [NSTemporaryDirectory() stringByAppendingPathComponent:@"WQGameStaging"];
    [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

static void WQGamePopToCenter(UINavigationController *nav)
{
    for (UIViewController *vc in nav.viewControllers.reverseObjectEnumerator)
        if ([vc isKindOfClass:WQGameCenterViewController.class]) { [nav popToViewController:vc animated:YES]; return; }
    [nav popViewControllerAnimated:YES];
}

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

// Label above a full-width control, with a fixed hint slot underneath.
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

#pragma mark - Game centre (the "游戏功能" category)

@interface WQGameCenterViewController ()
@end

@implementation WQGameCenterViewController {
    NSArray<NSDictionary *> *_games;
    NSArray<NSDictionary *> *_paths;
    BOOL _detecting;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"游戏功能";
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    self.tableView.backgroundColor = WQColorBackground();
    self.tableView.separatorColor = WQColorLine();
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
    _games = @[];
    [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    dispatch_async(wq_io(), ^{
        NSArray *found = WQGameDetectInstalled();
        dispatch_async(dispatch_get_main_queue(), ^{
            WQGameCenterViewController *s = weakSelf;
            if (!s) return;
            s->_detecting = NO;
            s->_games = found;
            [s.tableView reloadData];
            wq_log(@"game: detected %lu installed games", (unsigned long)found.count);
        });
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return MAX((NSInteger)_games.count, 1);
    if (section == 1) return MAX((NSInteger)_paths.count + 1, 1);
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return @[@"已检测到的游戏", @"保存的注入路径", @"手动指定"][section];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 0) return @"依据应用标识或常见目录识别，结果仅供参考；未列出的游戏可在下方手动指定容器。识别不会启动全量扫描。";
    if (section == 1) return @"点按一条路径即可快捷放入资源文件。左滑可删除保存项（只删除记录，不删除游戏里的文件）。";
    return WQGameRiskNote;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return WQRowHeight;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = WQGamePlainCell();
    cell.accessoryType = UITableViewCellAccessoryNone;
    if (indexPath.section == 0) {
        if (_detecting) {
            cell.textLabel.text = @"正在检测已安装游戏…";
            cell.detailTextLabel.text = nil;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (!_games.count) {
            cell.textLabel.text = @"未识别到已安装的游戏";
            cell.detailTextLabel.text = @"可在下方手动指定容器路径";
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            NSDictionary *g = _games[(NSUInteger)indexPath.row];
            cell.textLabel.text = g[@"name"];
            NSString *bid = g[@"bundle"];
            cell.detailTextLabel.text = bid.length ? bid : g[@"container"];
            cell.imageView.image = WQLinearIcon(@"gamecontroller");
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else if (indexPath.section == 1) {
        if ((NSUInteger)indexPath.row < _paths.count) {
            NSDictionary *p = _paths[(NSUInteger)indexPath.row];
            cell.textLabel.text = p[@"alias"];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", p[@"game"], p[@"relative"]];
            cell.imageView.image = WQLinearIcon(@"folder");
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.textLabel.text = @"添加注入路径";
            cell.detailTextLabel.text = @"自定义游戏名、容器与相对路径";
            cell.imageView.image = WQLinearIcon(@"plus");
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else {
        cell.textLabel.text = @"手动指定容器并添加路径";
        cell.detailTextLabel.text = @"适合未识别到的游戏或自定义目录";
        cell.imageView.image = WQLinearIcon(@"square.and.pencil");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0 && !_detecting && _games.count) {
        NSDictionary *g = _games[(NSUInteger)indexPath.row];
        WQGamePathPickerViewController *picker =
            [[WQGamePathPickerViewController alloc] initWithGame:g[@"name"]
                                                      container:g[@"container"]
                                                       relative:@""
                                                       suggest:g[@"suggest"]];
        [self.navigationController pushViewController:picker animated:YES];
    } else if (indexPath.section == 1 && (NSUInteger)indexPath.row < _paths.count) {
        WQGameInjectViewController *inject =
            [[WQGameInjectViewController alloc] initWithEntry:_paths[(NSUInteger)indexPath.row]];
        [self.navigationController pushViewController:inject animated:YES];
    } else {
        WQGameAddPathViewController *add = [WQGameAddPathViewController new];
        [self.navigationController pushViewController:add animated:YES];
    }
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
 forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete || indexPath.section != 1 ||
        (NSUInteger)indexPath.row >= _paths.count) return;
    NSDictionary *entry = _paths[(NSUInteger)indexPath.row];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"删除这条保存项？"
        message:@"只从本应用移除记录，不会删除游戏目录里的任何文件。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    NSString *identifier = entry[@"id"];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        NSMutableArray *all = [WQGameLoadPaths() mutableCopy];
        for (NSDictionary *item in [all copy])
            if ([item[@"id"] isEqualToString:identifier]) [all removeObject:item];
        WQGameSavePaths(all);
        WQGameCenterViewController *s = weakSelf;
        if (!s) return;
        s->_paths = all;
        [s.tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
                    withRowAnimation:UITableViewRowAnimationAutomatic];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return indexPath.section == 1 && (NSUInteger)indexPath.row < _paths.count;
}

@end

#pragma mark - Path picker: browse, save, or create the chain

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

    _aliasField = WQGameField(_relative.length ? _relative.lastPathComponent : @"资源目录", @"给这条快捷路径起个名字");
    _aliasHint = WQGameHintLabel(@"保存后会出现在「保存的注入路径」");
    _chainField = WQGameField(_relative.length ? _relative : _suggest, @"相对数据根目录，如 Documents/Paks");
    _chainHint = WQGameHintLabel(@"仅供参考，可修改；以实际目录为准");
    _aliasField.delegate = self;
    _chainField.delegate = self;

    // Build form cells once so the text fields keep their first-responder state
    // and their text across reloads.
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

- (void)reloadSubdirs
{
    _loading = YES;
    [self.tableView reloadData];
    NSString *path = [self currentPath];
    __weak typeof(self) weakSelf = self;
    dispatch_async(wq_io(), ^{
        NSArray<NSString *> *names = wq_list(path, nil) ?: @[];
        NSMutableArray<NSString *> *dirs = [NSMutableArray new];
        for (NSString *n in names) {
            if ([n isEqualToString:@"."] || [n isEqualToString:@".."]) continue;
            if (WQGameIsDir([path stringByAppendingPathComponent:n])) [dirs addObject:n];
        }
        [dirs sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        dispatch_async(dispatch_get_main_queue(), ^{
            WQGamePathPickerViewController *s = weakSelf;
            if (!s) return;
            s->_loading = NO;
            s->_subdirs = dirs;
            [s.tableView reloadData];
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
    if (section == 1) return @"点按目录继续进入。只有目录会显示，文件不会列出。";
    if (section == 2) return @"只记录路径，不写入任何文件。";
    if (section == 3) return [NSString stringWithFormat:@"已存在的层级原样保留，只新建缺失层级。%@", WQGameRiskNote];
    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) return 64.0;
    if (indexPath.section >= 2 && indexPath.row == 0) return WQGameFormHeight();
    if (indexPath.section >= 2) return WQControlH + WQSpace4;
    return WQRowHeight;
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
            NSString *name = _subdirs[(NSUInteger)indexPath.row];
            cell.textLabel.text = name;
            cell.detailTextLabel.text = nil;
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
    wq_alert(self, @"已保存", [NSString stringWithFormat:@"%@\n\n可在「游戏功能 → 保存的注入路径」中快捷放入资源文件。", WQGameFullPath(entry)]);
    WQGamePopToCenter(self.navigationController);
}

- (void)createChainTapped
{
    [self.view endEditing:YES];
    NSString *rel = [_chainField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!WQGameSafeRelative(rel)) { _chainHint.text = @"请填写不含 .. 的相对路径"; return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"检测并创建目录"
        message:[NSString stringWithFormat:@"目标：%@/%@\n\n已存在的层级保留，缺失的层级会新建，并保存为注入路径。\n\n%@", _container, rel, WQGameRiskNote]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"创建" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
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
            wq_alert(s, @"已保存", [NSString stringWithFormat:@"新建 %lu 个目录\n%@\n\n可在「保存的注入路径」中快捷放入资源文件。",
                                    (unsigned long)created, final]);
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
        WQGameButtonCell(@"从已检测游戏选择容器", self, @selector(pickDetectedTapped), NO),
        WQGameButtonCell(@"保存路径", self, @selector(saveTapped), YES),
    ];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return section == 0 ? 4 : 1;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return @[@"路径信息", @"从已检测游戏选择容器", @"保存"][section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return section == 2 ? WQGameRiskNote : nil;
}
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) return WQGameFormHeight();
    return WQControlH + WQSpace4;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) return _cells[(NSUInteger)indexPath.row];
    return _cells[indexPath.section == 1 ? 4 : 5];
}

- (void)pickDetectedTapped
{
    [self.view endEditing:YES];
    __weak typeof(self) weakSelf = self;
    dispatch_async(wq_io(), ^{
        NSArray *found = WQGameDetectInstalled();
        dispatch_async(dispatch_get_main_queue(), ^{
            WQGameAddPathViewController *s = weakSelf;
            if (!s) return;
            UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择已检测到的游戏"
                message:nil preferredStyle:UIAlertControllerStyleAlert];
            if (!found.count) {
                [sheet addAction:[UIAlertAction actionWithTitle:@"未检测到游戏" style:UIAlertActionStyleDefault handler:nil]];
            } else {
                for (NSDictionary *g in found) {
                    [sheet addAction:[UIAlertAction actionWithTitle:g[@"name"] style:UIAlertActionStyleDefault
                        handler:^(UIAlertAction *__unused a) {
                            s->_containerField.text = g[@"container"];
                            if (!s->_gameField.text.length) s->_gameField.text = g[@"name"];
                            s->_containerHint.text = @"已填入容器路径";
                        }]];
                }
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
    if (![container hasPrefix:@"/"]) {
        if (!container.length) { _containerHint.text = @"请填写容器 UUID 或完整路径"; return; }
        container = [WQGameAppRoot stringByAppendingPathComponent:container];
    }
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
    NSMutableArray<NSDictionary *> *_files;   // name, local, size
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
    // Clear stale staged files from an earlier, cancelled injection.
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *n in [fm contentsOfDirectoryAtPath:WQGameStagingDir() error:nil] ?: @[])
        [fm removeItemAtPath:[WQGameStagingDir() stringByAppendingPathComponent:n] error:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return 2;
    if (section == 1) return (NSInteger)_files.count + 2;
    return 2;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return @[@"目标路径", @"待放入的资源文件", @"写入"][section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 1) return @"支持 pak、sig、lua 及任意文件，可多选。同名文件会被替换并自动备份。";
    return section == 2 ? WQGameRiskNote : nil;
}
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) return 60.0;
    if (indexPath.section == 1 && (NSUInteger)indexPath.row >= _files.count + 1) return WQControlH + WQSpace4;
    if (indexPath.section == 2 && indexPath.row == 1) return WQControlH + WQSpace4;
    return WQRowHeight;
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
            cell.textLabel.text = @"完整路径";
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
            cell.textLabel.text = _files.count ? [NSString stringWithFormat:@"已选择 %lu 个文件", (unsigned long)_files.count] : @"尚未选择文件";
            cell.detailTextLabel.text = _files.count ? @"左滑可移除单个文件" : @"点右上角「选择文件」或下方按钮";
            return cell;
        }
        return WQGameButtonCell(@"从「文件」选择", self, @selector(importTapped), NO);
    }
    if (indexPath.row == 0) {
        if (!_result) { _result = [UILabel new]; _result.text = @"尚未写入"; }
        cell.textLabel.text = @"写入结果";
        cell.detailTextLabel.text = _result.text;
        cell.imageView.image = WQLinearIcon(@"info.circle");
        return cell;
    }
    return WQGameButtonCell([NSString stringWithFormat:@"写入 %lu 个文件", (unsigned long)_files.count],
                            self, @selector(writeTapped), YES);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
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
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return indexPath.section == 1 && (NSUInteger)indexPath.row < _files.count;
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
    [alert addAction:[UIAlertAction actionWithTitle:@"写入" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [weakSelf performWrite];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)performWrite
{
    _result.text = @"正在写入…";
    [self.tableView reloadData];
    NSArray<NSDictionary *> *files = [_files copy];
    NSString *target = _targetPath;
    __weak typeof(self) weakSelf = self;
    dispatch_async(wq_io(), ^{
        if (!WQGameIsDir(target)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                WQGameInjectViewController *s = weakSelf;
                if (!s) return;
                s->_result.text = @"目标目录不存在";
                [s.tableView reloadData];
                wq_alert(s, @"目标目录不存在",
                         @"请回到「游戏功能」用「按路径逐级检测并创建」重新建立目录，或重新保存这条路径。");
            });
            return;
        }
        NSUInteger okCount = 0, replaced = 0;
        NSMutableArray<NSString *> *failures = [NSMutableArray new];
        for (NSDictionary *f in files) {
            NSString *dest = [target stringByAppendingPathComponent:f[@"name"]];
            struct stat st;
            BOOL exists = wq_stat(dest, &st) && S_ISREG(st.st_mode);
            NSString *err = nil;
            BOOL ok = exists ? wq_write_from_file(dest, f[@"local"], &err)
                             : wq_create_file_from(dest, f[@"local"], &err);
            if (!ok) { [failures addObject:[NSString stringWithFormat:@"%@：%@", f[@"name"], err ?: @"写入失败"]]; continue; }
            struct stat after;
            unsigned long long want = [f[@"size"] unsignedLongLongValue];
            if (!wq_stat(dest, &after) || !S_ISREG(after.st_mode) || (unsigned long long)after.st_size != want) {
                [failures addObject:[NSString stringWithFormat:@"%@：写入后校验不一致", f[@"name"]]];
                continue;
            }
            okCount++;
            if (exists) replaced++;
            wq_log(@"game: wrote %@ (%llu bytes, replaced=%d)", dest, want, exists ? 1 : 0);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            WQGameInjectViewController *s = weakSelf;
            if (!s) return;
            NSString *summary = [NSString stringWithFormat:@"成功 %lu / %lu · 替换 %lu",
                (unsigned long)okCount, (unsigned long)files.count, (unsigned long)replaced];
            s->_result.text = summary;
            [s.tableView reloadData];
            NSString *msg = failures.count
                ? [NSString stringWithFormat:@"%@\n\n失败：\n%@", summary, [failures componentsJoinedByString:@"\n"]]
                : [NSString stringWithFormat:@"%@\n\n目标：%@", summary, target];
            wq_alert(s, failures.count ? @"部分完成" : @"写入完成", msg);
            NSFileManager *fm = NSFileManager.defaultManager;
            for (NSDictionary *f in files) [fm removeItemAtPath:f[@"local"] error:nil];
            [s->_files removeAllObjects];
            [s.tableView reloadData];
        });
    });
}

@end
