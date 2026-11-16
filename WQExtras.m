//
//  WQExtras.m
//  黑猫游戏工具箱 — 收藏、注入记录、校验、配置与关于
//  GPL-3.0-or-later.
//

#import "WQExtras.h"
#import "WQAppearance.h"
#import "WQDesignTokens.h"
#import "WQAccess.h"
#import "WQUI.h"
#import "WQGameFeatures.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <CommonCrypto/CommonDigest.h>

static NSString *const WQBookmarksKey       = @"WQBookmarksV1";
static NSString *const WQInjectionHistoryKey = @"WQInjectionHistoryV1";

#pragma mark - Small helpers

static NSArray<NSDictionary *> *WQLoadArray(NSString *key)
{
    NSArray *raw = [NSUserDefaults.standardUserDefaults arrayForKey:key] ?: @[];
    NSMutableArray<NSDictionary *> *out = [NSMutableArray new];
    for (id item in raw) if ([item isKindOfClass:NSDictionary.class]) [out addObject:item];
    return out;
}

static void WQSaveArray(NSString *key, NSArray<NSDictionary *> *items)
{
    [NSUserDefaults.standardUserDefaults setObject:items forKey:key];
}

static NSString *WQDateText(NSTimeInterval interval)
{
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:interval];
    return [NSDateFormatter localizedStringFromDate:date
                                          dateStyle:NSDateFormatterMediumStyle
                                          timeStyle:NSDateFormatterShortStyle];
}

static UITableViewCell *WQExtrasCell(UITableViewCellStyle style)
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:style reuseIdentifier:nil];
    WQStyleCell(cell);
    cell.textLabel.font = WQFontBody();
    cell.textLabel.textColor = WQColorText();
    cell.textLabel.numberOfLines = 2;
    cell.detailTextLabel.font = WQFontCaption();
    cell.detailTextLabel.textColor = WQColorText2();
    cell.detailTextLabel.numberOfLines = 3;
    return cell;
}

static void WQCopy(UIViewController *host, NSString *text)
{
    UIPasteboard.generalPasteboard.string = text;
    host.navigationItem.prompt = @"已复制";
    __weak UIViewController *weakHost = host;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *h = weakHost;
        if (h && [h.navigationItem.prompt isEqualToString:@"已复制"]) h.navigationItem.prompt = nil;
    });
}

static UILabel *WQStatLabel(NSString *text, UIFont *font, UIColor *color)
{
    UILabel *l = [UILabel new];
    l.text = text;
    l.font = font;
    l.textColor = color;
    l.textAlignment = NSTextAlignmentLeft;
    l.numberOfLines = 1;
    l.adjustsFontForContentSizeCategory = YES;
    return l;
}

#pragma mark - Overview

UIView *WQOverviewHeader(void)
{
    UIView *outer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 360, 124)];
    outer.backgroundColor = UIColor.clearColor;
    UIView *panel = WQGlassPanel(WQRadius4);
    [outer addSubview:panel];
    [NSLayoutConstraint activateConstraints:@[
        [panel.leadingAnchor constraintEqualToAnchor:outer.leadingAnchor constant:WQGutter],
        [panel.trailingAnchor constraintEqualToAnchor:outer.trailingAnchor constant:-WQGutter],
        [panel.topAnchor constraintEqualToAnchor:outer.topAnchor constant:WQSpace3],
        [panel.bottomAnchor constraintEqualToAnchor:outer.bottomAnchor constant:-WQSpace3],
    ]];

    NSString *line1 = [NSString stringWithFormat:@"已保存路径 %lu  ·  收藏 %lu  ·  注入记录 %lu",
        (unsigned long)WQGameSavedPathCount(), (unsigned long)WQBookmarkCount(),
        (unsigned long)WQInjectionHistoryCount()];
    NSString *line2 = [NSString stringWithFormat:@"暂存占用 %@  ·  %@",
        wq_size_text(WQGameStagingBytes()), WQAppearanceModeText()];
    UILabel *a = WQStatLabel(@"工作台", WQFontCaption(), WQColorText3());
    UILabel *b = WQStatLabel(line1, WQFontHeadline(), WQColorText());
    UILabel *c = WQStatLabel(line2, WQFontCaption(), WQColorText2());
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[a, b, c]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentLeading;
    stack.spacing = WQSpace1;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [panel addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:WQSpace4],
        [stack.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-WQSpace4],
        [stack.centerYAnchor constraintEqualToAnchor:panel.centerYAnchor],
    ]];
    return outer;
}

#pragma mark - Bookmark store

NSUInteger WQBookmarkCount(void) { return WQLoadArray(WQBookmarksKey).count; }
NSArray<NSDictionary *> *WQBookmarkEntries(void) { return WQLoadArray(WQBookmarksKey); }

void WQBookmarkClear(void)
{
    WQSaveArray(WQBookmarksKey, @[]);
}

// Only well-formed, absolute paths are ever imported.
void WQBookmarkImportEntries(NSArray<NSDictionary *> *entries)
{
    NSMutableArray<NSDictionary *> *all = [WQLoadArray(WQBookmarksKey) mutableCopy];
    for (NSDictionary *item in entries) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *path = item[@"path"], *alias = item[@"alias"];
        if (![path isKindOfClass:NSString.class] || ![path hasPrefix:@"/"] ||
            ![alias isKindOfClass:NSString.class]) continue;
        for (NSDictionary *old in [all copy])
            if ([old[@"path"] isEqualToString:path]) [all removeObject:old];
        [all addObject:@{@"id": NSUUID.UUID.UUIDString, @"alias": alias,
                         @"path": path, @"added": @(NSDate.date.timeIntervalSince1970)}];
    }
    WQSaveArray(WQBookmarksKey, all);
}

#pragma mark - Bookmarks screen

@interface WQBookmarksViewController () <UISearchResultsUpdating>
@end

@implementation WQBookmarksViewController {
    NSArray<NSDictionary *> *_items;
    NSArray<NSDictionary *> *_shown;
    NSString *_query;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"路径收藏";
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    WQStyleTableView(self.tableView);
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"添加" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(addTapped)];
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"搜索别名或路径";
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    [self reload];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self reload];
}

- (void)reload
{
    _items = WQBookmarkEntries();
    [self applyFilter];
    [self.tableView reloadData];
}

- (void)applyFilter
{
    if (!_query.length) { _shown = _items; return; }
    NSMutableArray<NSDictionary *> *out = [NSMutableArray new];
    for (NSDictionary *item in _items) {
        NSString *hay = [NSString stringWithFormat:@"%@ %@", item[@"alias"] ?: @"", item[@"path"] ?: @""];
        if ([hay rangeOfString:_query options:NSCaseInsensitiveSearch].location != NSNotFound)
            [out addObject:item];
    }
    _shown = out;
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    _query = searchController.searchBar.text ?: @"";
    [self applyFilter];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)_shown.count + 1;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return [NSString stringWithFormat:@"共 %lu 条", (unsigned long)_items.count];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return @"点按打开目录或文件，长按复制路径，左滑删除记录。收藏只保存本机路径，不会改动目标文件。";
}
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return WQRowHeight + 12.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = WQExtrasCell(UITableViewCellStyleSubtitle);
    if ((NSUInteger)indexPath.row < _shown.count) {
        NSDictionary *item = _shown[(NSUInteger)indexPath.row];
        cell.textLabel.text = item[@"alias"] ?: @"未命名";
        cell.detailTextLabel.text = item[@"path"];
        cell.imageView.image = WQLinearIcon(@"bookmark");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        cell.textLabel.text = _shown.count ? @"添加当前想到的路径" : @"暂无收藏";
        cell.detailTextLabel.text = _shown.count ? @"点右上角「添加」也可" : @"保存常用容器、注入目录或备份位置";
        cell.imageView.image = WQLinearIcon(@"plus");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point
{
    if ((NSUInteger)indexPath.row >= _shown.count) return nil;
    NSString *path = _shown[(NSUInteger)indexPath.row][@"path"] ?: @"";
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
        actionProvider:^UIMenu *(NSArray<UIMenuElement *> *__unused suggested) {
            UIAction *copy = [UIAction actionWithTitle:@"复制路径" image:[UIImage systemImageNamed:@"doc.on.doc"]
                identifier:nil handler:^(UIAction *__unused a) {
                    WQBookmarksViewController *s = weakSelf;
                    if (s) WQCopy(s, path);
                }];
            return [UIMenu menuWithTitle:@"" children:@[copy]];
        }];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ((NSUInteger)indexPath.row < _shown.count)
        WQOpenPathFromExtras(self.navigationController, _shown[(NSUInteger)indexPath.row][@"path"]);
    else
        [self addTapped];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return (NSUInteger)indexPath.row < _shown.count;
}
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
 forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete || (NSUInteger)indexPath.row >= _shown.count) return;
    NSString *identifier = _shown[(NSUInteger)indexPath.row][@"id"];
    NSMutableArray<NSDictionary *> *all = [WQBookmarkEntries() mutableCopy];
    for (NSDictionary *item in [all copy])
        if ([item[@"id"] isEqualToString:identifier]) [all removeObject:item];
    WQSaveArray(WQBookmarksKey, all);
    [self reload];
}

- (void)addTapped
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"添加收藏"
        message:@"填写别名与已存在的绝对路径" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = @"别名"; }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.placeholder = @"/private/var/mobile/Containers/Data/...";
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *__unused a) {
            WQBookmarksViewController *s = weakSelf;
            if (!s) return;
            NSString *alias = [alert.textFields[0].text stringByTrimmingCharactersInSet:
                               NSCharacterSet.whitespaceAndNewlineCharacterSet];
            NSString *path = [alert.textFields[1].text stringByTrimmingCharactersInSet:
                              NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (!alias.length) alias = path.lastPathComponent;
            if (![path hasPrefix:@"/"] || !alias.length) {
                wq_alert(s, @"未保存", @"请填写别名和以 / 开头的绝对路径。");
                return;
            }
            struct stat st;
            if (!wq_stat(path, &st)) {
                wq_alert(s, @"未保存", @"路径当前无法访问或不存在，请检查后重试。");
                return;
            }
            WQBookmarkImportEntries(@[@{@"alias": alias, @"path": path}]);
            [s reload];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Injection history

NSUInteger WQInjectionHistoryCount(void) { return WQLoadArray(WQInjectionHistoryKey).count; }
void WQInjectionHistoryClear(void) { WQSaveArray(WQInjectionHistoryKey, @[]); }

void WQRecordInjection(NSDictionary *record)
{
    if (![record isKindOfClass:NSDictionary.class]) return;
    NSMutableArray<NSDictionary *> *all = [WQLoadArray(WQInjectionHistoryKey) mutableCopy];
    NSMutableDictionary *clean = [NSMutableDictionary new];
    for (NSString *key in @[@"target", @"game", @"alias", @"ok", @"replaced", @"failed", @"files"])
        if (record[key]) clean[key] = record[key];
    clean[@"at"] = @(NSDate.date.timeIntervalSince1970);
    [all insertObject:clean atIndex:0];
    if (all.count > 200) [all removeObjectsInRange:NSMakeRange(200, all.count - 200)];
    WQSaveArray(WQInjectionHistoryKey, all);
}

@implementation WQInjectionHistoryViewController {
    NSArray<NSDictionary *> *_items;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"注入记录";
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    WQStyleTableView(self.tableView);
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(clearTapped)];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    _items = WQLoadArray(WQInjectionHistoryKey);
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return MAX((NSInteger)_items.count, 1);
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return @"最多保留最近 200 条。记录只包含时间、目标路径与结果，不保存文件内容。清空只删除本机记录。";
}
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return WQRowHeight + 12.0;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = WQExtrasCell(UITableViewCellStyleSubtitle);
    if (!_items.count) {
        cell.textLabel.text = @"暂无注入记录";
        cell.detailTextLabel.text = @"在游戏资源注入页写入文件后会在这里留痕";
        return cell;
    }
    NSDictionary *r = _items[(NSUInteger)indexPath.row];
    cell.textLabel.text = [NSString stringWithFormat:@"%@ · 成功 %@ / 替换 %@",
        r[@"alias"] ?: r[@"game"] ?: @"注入", r[@"ok"] ?: @"0", r[@"replaced"] ?: @"0"];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\n%@",
        WQDateText([r[@"at"] doubleValue]), r[@"target"] ?: @""];
    cell.imageView.image = WQLinearIcon(@"clock");
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!_items.count) return;
    NSDictionary *r = _items[(NSUInteger)indexPath.row];
    NSString *files = r[@"files"] ?: @"（未记录文件名）";
    wq_alert(self, @"注入详情", [NSString stringWithFormat:@"%@\n\n目标：%@\n\n成功 %@ · 替换 %@ · 失败 %@\n\n文件：%@",
        WQDateText([r[@"at"] doubleValue]), r[@"target"] ?: @"",
        r[@"ok"] ?: @"0", r[@"replaced"] ?: @"0", r[@"failed"] ?: @"0", files]);
}

- (void)clearTapped
{
    if (!_items.count) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清空注入记录？"
        message:@"只删除本机记录，不删除已写入游戏目录的文件，也不删除备份。此操作无法撤销。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *__unused a) {
            WQInjectionHistoryClear();
            WQInjectionHistoryViewController *s = weakSelf;
            if (!s) return;
            s->_items = @[];
            [s.tableView reloadData];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - File inspector

@interface WQFileInspectorViewController () <UIDocumentPickerDelegate>
@end

@implementation WQFileInspectorViewController {
    NSString *_name, *_sha, *_bytes;
    NSDate *_date;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"文件校验";
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    WQStyleTableView(self.tableView);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return section == 0 ? 1 : 4;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return section == 0 ? @"选择文件" : @"校验结果";
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return section == 1 ? @"SHA-256 以流式计算，不把大文件读入内存。用于核对 pak / sig / lua 等资源是否完整；本工具不判断文件内容是否适合写入游戏。" : nil;
}
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return WQRowHeight;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = WQExtrasCell(UITableViewCellStyleSubtitle);
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (indexPath.section == 0) {
        cell.textLabel.text = @"从「文件」选择";
        cell.detailTextLabel.text = @"支持任意文件，含 pak / sig / lua";
        cell.imageView.image = WQLinearIcon(@"square.and.arrow.down");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        NSArray<NSString *> *titles = @[@"文件名", @"大小", @"SHA-256", @"校验时间"];
        NSArray<NSString *> *values = @[
            _name ?: @"尚未选择",
            _bytes ?: @"—",
            _sha ?: @"—",
            _date ? WQDateText(_date.timeIntervalSince1970) : @"—",
        ];
        cell.textLabel.text = titles[(NSUInteger)indexPath.row];
        cell.detailTextLabel.text = values[(NSUInteger)indexPath.row];
        cell.imageView.image = WQLinearIcon(indexPath.row == 2 ? @"number" : @"doc");
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) [self pick];
    else if (indexPath.section == 1 && indexPath.row == 2 && _sha) WQCopy(self, _sha);
}

- (void)pick
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
    if (!url) return;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSInputStream *stream = [NSInputStream inputStreamWithURL:url];
    if (!stream) {
        if (scoped) [url stopAccessingSecurityScopedResource];
        wq_alert(self, @"读取失败", @"无法打开所选文件");
        return;
    }
    [stream open];
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    uint8_t buffer[65536];
    unsigned long long total = 0;
    BOOL ok = YES;
    NSInteger read = 0;
    while ((read = [stream read:buffer maxLength:sizeof(buffer)]) > 0) {
        CC_SHA256_Update(&ctx, buffer, (CC_LONG)read);
        total += (unsigned long long)read;
    }
    if (read < 0) ok = NO;
    [stream close];
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!ok) { wq_alert(self, @"读取失败", stream.streamError.localizedDescription ?: @"无法读取该文件"); return; }

    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    _name = url.lastPathComponent ?: @"文件";
    _sha = hex.uppercaseString;
    _bytes = wq_size_text(total);
    _date = NSDate.date;
    wq_log(@"inspect: %@ %llu bytes sha256=%@", _name, total, _sha);
    [self.tableView reloadData];
}

@end

#pragma mark - Config transfer

@interface WQConfigViewController () <UIDocumentPickerDelegate>
@end

@implementation WQConfigViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"配置导入 / 导出";
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    WQStyleTableView(self.tableView);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return section == 0 ? 2 : 1;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return section == 0 ? @"本机配置" : @"统计";
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return section == 0
        ? @"导出为 JSON，包含注入路径与路径收藏；导入会校验格式并按路径去重合并，不覆盖已有条目。配置不含任何游戏资源文件内容。"
        : nil;
}
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return WQRowHeight;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = WQExtrasCell(UITableViewCellStyleSubtitle);
    if (indexPath.section == 0) {
        cell.textLabel.text = indexPath.row == 0 ? @"导出配置" : @"导入配置";
        cell.detailTextLabel.text = indexPath.row == 0 ? @"保存到「文件」App" : @"从 JSON 合并路径与收藏";
        cell.imageView.image = WQLinearIcon(indexPath.row == 0 ? @"square.and.arrow.up" : @"square.and.arrow.down");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        cell.textLabel.text = [NSString stringWithFormat:@"注入路径 %lu  ·  收藏 %lu",
            (unsigned long)WQGameSavedPathCount(), (unsigned long)WQBookmarkCount()];
        cell.detailTextLabel.text = @"导出前可先在这里核对数量";
        cell.imageView.image = WQLinearIcon(@"chart.bar");
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 0) return;
    if (indexPath.row == 0) [self exportConfig];
    else [self importConfig];
}

- (void)exportConfig
{
    NSDictionary *payload = @{
        @"app": @"黑猫游戏工具箱",
        @"format": @"heimaoconfig/1",
        @"exportedAt": @(NSDate.date.timeIntervalSince1970),
        @"paths": WQGameSavedEntries() ?: @[],
        @"bookmarks": WQBookmarkEntries() ?: @[],
    };
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload
                                                   options:NSJSONWritingPrettyPrinted error:&error];
    if (!data) { wq_alert(self, @"导出失败", error.localizedDescription ?: @"无法生成配置"); return; }
    NSString *file = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"黑猫游戏工具箱-配置-%@.json",
            [NSNumber numberWithLongLong:(long long)NSDate.date.timeIntervalSince1970]]];
    if (![data writeToFile:file options:NSDataWritingAtomic error:&error]) {
        wq_alert(self, @"导出失败", error.localizedDescription ?: @"无法写入临时文件");
        return;
    }
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForExportingURLs:@[[NSURL fileURLWithPath:file]] asCopy:NO];
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)importConfig
{
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeJSON]];
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
    if (!url) return;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!data) { wq_alert(self, @"导入失败", @"无法读取所选文件"); return; }
    NSError *error = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![parsed isKindOfClass:NSDictionary.class]) {
        wq_alert(self, @"导入失败", error.localizedDescription ?: @"不是有效的配置 JSON");
        return;
    }
    NSDictionary *root = parsed;
    NSArray *paths = root[@"paths"], *bookmarks = root[@"bookmarks"];
    if (![paths isKindOfClass:NSArray.class] || ![bookmarks isKindOfClass:NSArray.class]) {
        wq_alert(self, @"导入失败", @"配置缺少 paths 或 bookmarks 数组");
        return;
    }
    WQGameImportEntries(paths);
    WQBookmarkImportEntries(bookmarks);
    wq_log(@"config: imported %lu paths, %lu bookmarks",
           (unsigned long)paths.count, (unsigned long)bookmarks.count);
    [self.tableView reloadData];
    wq_alert(self, @"已导入", [NSString stringWithFormat:@"注入路径 %lu 条 · 收藏 %lu 条\n\n现有：注入路径 %lu 条 · 收藏 %lu 条",
        (unsigned long)paths.count, (unsigned long)bookmarks.count,
        (unsigned long)WQGameSavedPathCount(), (unsigned long)WQBookmarkCount()]);
}

@end

#pragma mark - About

@implementation WQAboutViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"关于";
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    WQStyleTableView(self.tableView);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    NSArray<NSNumber *> *counts = @[@4, @2, @3, @2];
    return counts[(NSUInteger)section].integerValue;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return @[@"应用", @"署名", @"运行状态", @"开源"][section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return section == 3 ? @"基于 kolbicz/WQFiles（worse_query）改造，GPL-3.0-or-later。仅供本机调试与补齐缺失资源；改动游戏文件可能违反条款或导致账号受限。" : nil;
}
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return WQRowHeight;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = WQExtrasCell(UITableViewCellStyleValue1);
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *group = wq_app_group() ?: @"No App Group";
    NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
    NSArray<NSArray *> *rows = @[
        @[@[@"名称", @"黑猫游戏工具箱"],
          @[@"版本", [NSString stringWithFormat:@"%@ (%@)", info[@"CFBundleShortVersionString"] ?: @"?",
                                                  info[@"CFBundleVersion"] ?: @"?"]],
          @[@"最低系统", @"iOS 26.0"],
          @[@"Bundle ID", info[@"CFBundleIdentifier"] ?: @"—"]],
        @[@[@"作者", @"by 淮季"],
          @[@"频道", @"公益频道@HeiMaoClub"]],
        @[@[@"外观", WQAppearanceModeText()],
          @[@"材质", WQAppearanceStateText()],
          @[@"App Group", group]],
        @[@[@"系统版本", [NSString stringWithFormat:@"%ld.%ld.%ld", (long)v.majorVersion,
                                                       (long)v.minorVersion, (long)v.patchVersion]],
          @[@"上游项目", @"kolbicz/WQFiles · 点按打开"]],
    ];
    NSArray<NSString *> *pair = rows[indexPath.section][indexPath.row];
    cell.textLabel.text = pair[0];
    cell.detailTextLabel.text = pair[1];
    cell.detailTextLabel.font = WQFontValue();
    cell.detailTextLabel.textColor = WQColorText2();
    cell.detailTextLabel.numberOfLines = 2;
    if (indexPath.section == 3 && indexPath.row == 1) {
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    if (indexPath.section == 1) cell.imageView.image = WQLinearIcon(@"person");
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 3 && indexPath.row == 1)
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"https://github.com/kolbicz/WQFiles"]
                                         options:@{} completionHandler:nil];
}

@end
