//
//  WQLuaDeploy.m
//  WQ Files — debug script deployment
//  GPL-3.0-or-later.
//

#import "WQLuaDeploy.h"
#import "WQDesignTokens.h"
#import "WQAccess.h"
#import "WQLaunchServices.h"
#import "WQUI.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// The feature directory that identifies the target game container. Automatic
// discovery never trusts a hard-coded UUID: a reinstall or another device gets
// a different Application/<UUID> folder.
static NSString *const WQLuaAppRoot = @"/private/var/mobile/Containers/Data/Application";
static NSString *const WQLuaBaseRel = @"Documents/DeltaForce/Saved";
static NSString *const WQLuaDefaultChain = @"LuaDebug/LuaSource/DFM/BusinessEntrance";
static NSString *const WQLuaDefaultName = @"debug.lua";

// Reserved slot for the script the user said they will provide later. Paste its
// contents here to make "Use built-in script" available; while empty, the page
// takes content from the file picker or the text area.
static NSString *const WQLuaBuiltInScript = @"";

#pragma mark - Filesystem helpers (all calls go through WQAccess)

static BOOL WQLuaIsDirectory(NSString *path)
{
    struct stat st;
    if (wq_stat(path, &st)) return S_ISDIR(st.st_mode);
    // wq_stat uses lstat; a linked Saved folder still points at a real dir.
    struct stat target;
    return stat(path.fileSystemRepresentation, &target) == 0 && S_ISDIR(target.st_mode);
}

// Returns the Application/<UUID> container that owns Documents/DeltaForce/Saved.
// `manual` may be a UUID or an absolute container path; it is tried first.
static NSString *_Nullable WQLuaFindContainer(NSString *_Nullable manual, NSString *_Nullable *_Nullable errorText)
{
    NSMutableArray<NSString *> *candidates = [NSMutableArray new];
    NSString *trimmed = [manual stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length) {
        NSString *m = trimmed;
        if ([m hasPrefix:@"/private/var/"] || [m hasPrefix:@"/var/"]) [candidates addObject:m];
        else [candidates addObject:[WQLuaAppRoot stringByAppendingPathComponent:m]];
    }
    // LaunchServices' own store lists installed containers without a full scan.
    for (NSString *p in wq_ls_container_paths(nil) ?: @[]) {
        NSString *full = [p hasPrefix:@"/"] ? p : [WQLuaAppRoot stringByAppendingPathComponent:p];
        if (![full containsString:@"/Containers/Data/Application/"]) continue;
        if (![candidates containsObject:full]) [candidates addObject:full];
    }
    // A plain listing may work on some builds; ignore it when the parent gives
    // no token. Never start a full inode scan from here.
    for (NSString *name in wq_list(WQLuaAppRoot, nil) ?: @[]) {
        NSString *full = [WQLuaAppRoot stringByAppendingPathComponent:name];
        if (![candidates containsObject:full]) [candidates addObject:full];
    }

    for (NSString *dir in candidates) {
        if (WQLuaIsDirectory([dir stringByAppendingPathComponent:WQLuaBaseRel])) return dir;
    }
    if (errorText) *errorText = @"未找到包含 Documents/DeltaForce/Saved 的应用容器。请确认游戏已安装，或在「容器 UUID」中手动填写。";
    return nil;
}

@interface WQLuaDeployViewController () <UIDocumentPickerDelegate, UITextFieldDelegate>
- (void)locateTapped;
- (void)importTapped;
- (void)builtInTapped;
- (void)copyPathTapped;
- (void)deployTapped;
- (void)updateScriptValue;
- (void)performDeployWithChain:(NSArray<NSString *> *)parts name:(NSString *)name
                          data:(NSData *)data manual:(NSString *_Nullable)manual;
- (void)finish:(BOOL)ok message:(NSString *)message path:(NSString *_Nullable)path;
@end

@implementation WQLuaDeployViewController {
    NSArray<NSArray<UITableViewCell *> *> *_cells;
    NSArray<NSArray<NSNumber *> *> *_heights;

    UILabel *_containerValue;
    UILabel *_baseValue;
    UILabel *_modeValue;
    UILabel *_resultValue;
    UILabel *_scriptValue;
    UILabel *_chainHint;
    UILabel *_uuidHint;
    UILabel *_nameHint;
    UILabel *_contentHint;

    UITextField *_chainField;
    UITextField *_uuidField;
    UITextField *_nameField;
    UITextView *_contentView;

    NSData *_importedData;
    NSString *_importedName;
    NSString *_lastTargetPath;
    NSString *_foundContainer;
}

#pragma mark - Cell factories (built once; no reuse, no lost input)

- (UITableViewCell *)plainCell
{
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    c.backgroundColor = WQColorSurface();
    return c;
}

// Settings-style row: label on the left, value/control on the right.
- (UITableViewCell *)rowCellWithTitle:(NSString *)title value:(UILabel *_Nullable *_Nullable)valueOut
                                button:(NSString *_Nullable)buttonTitle action:(SEL _Nullable)action
{
    UITableViewCell *cell = [self plainCell];
    UILabel *label = [UILabel new];
    label.text = title;
    label.font = WQFontBody();
    label.textColor = WQColorText();
    label.textAlignment = NSTextAlignmentLeft;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:label];

    UIView *right;
    if (buttonTitle.length) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:buttonTitle forState:UIControlStateNormal];
        [b setTitleColor:WQColorText() forState:UIControlStateNormal];
        b.titleLabel.font = WQFontValue();
        WQStyleControl(b);
        b.translatesAutoresizingMaskIntoConstraints = NO;
        [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
        right = b;
    } else {
        UILabel *v = [UILabel new];
        v.text = @"—";
        v.font = WQFontValue();
        v.textColor = WQColorText2();
        v.textAlignment = NSTextAlignmentRight;
        v.lineBreakMode = NSLineBreakByTruncatingMiddle;
        v.translatesAutoresizingMaskIntoConstraints = NO;
        if (valueOut) *valueOut = v;
        right = v;
    }
    [cell.contentView addSubview:right];

    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:WQGutter],
        [label.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:right.leadingAnchor constant:-WQSpace2],
        [right.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-WQGutter],
        [right.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [right.heightAnchor constraintEqualToConstant:32],
    ]];
    return cell;
}

// Sequential form row: label above a full-width control, fixed hint slot below.
- (UITableViewCell *)formCellWithLabel:(NSString *)title control:(UIView *)control
                                  hint:(NSString *)hint hintOut:(UILabel *_Nullable *_Nullable)hintOut
                                height:(CGFloat)height
{
    UITableViewCell *cell = [self plainCell];
    UILabel *label = [UILabel new];
    label.text = title;
    label.font = WQFontGroup();
    label.textColor = WQColorText2();
    label.textAlignment = NSTextAlignmentLeft;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:label];

    control.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:control];

    UILabel *hintLabel = [UILabel new];
    hintLabel.text = hint;
    hintLabel.font = WQFontCaption();
    hintLabel.textColor = WQColorText3();
    hintLabel.textAlignment = NSTextAlignmentLeft;
    hintLabel.numberOfLines = 1;
    hintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:hintLabel];
    if (hintOut) *hintOut = hintLabel;

    CGFloat controlH = [control isKindOfClass:UITextView.class] ? 120.0 : WQControlH;
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:WQGutter],
        [label.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-WQGutter],
        [label.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:WQSpace3],
        [control.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:WQGutter],
        [control.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-WQGutter],
        [control.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:WQSpace2],
        [control.heightAnchor constraintEqualToConstant:controlH],
        [hintLabel.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:WQGutter],
        [hintLabel.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-WQGutter],
        [hintLabel.topAnchor constraintEqualToAnchor:control.bottomAnchor constant:WQSpace1],
        [hintLabel.heightAnchor constraintEqualToConstant:WQHintSpace],
    ]];
    (void)height;
    return cell;
}

- (UITableViewCell *)primaryCellWithTitle:(NSString *)title action:(SEL)action
{
    UITableViewCell *cell = [self plainCell];
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    WQStylePrimaryButton(b);
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [cell.contentView addSubview:b];
    [NSLayoutConstraint activateConstraints:@[
        [b.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:WQGutter],
        [b.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-WQGutter],
        [b.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:WQSpace2],
        [b.heightAnchor constraintEqualToConstant:WQControlH],
    ]];
    return cell;
}

- (UITextField *)textFieldWithText:(NSString *)text placeholder:(NSString *)placeholder
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
    f.delegate = self;
    WQStyleControl(f);
    f.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, WQSpace3, 0)];
    f.leftViewMode = UITextFieldViewModeAlways;
    f.rightView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, WQSpace3, 0)];
    f.rightViewMode = UITextFieldViewModeAlways;
    return f;
}

#pragma mark - Layout

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Lua 调试脚本";
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    self.tableView.backgroundColor = WQColorBackground();
    self.tableView.separatorColor = WQColorLine();
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;

    _chainField = [self textFieldWithText:WQLuaDefaultChain placeholder:@"LuaDebug/LuaSource/DFM/BusinessEntrance"];
    _uuidField  = [self textFieldWithText:@"" placeholder:@"留空则自动定位，可填 UUID 或完整路径"];
    _nameField  = [self textFieldWithText:WQLuaDefaultName placeholder:@"debug.lua"];

    _contentView = [UITextView new];
    _contentView.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    _contentView.textColor = WQColorText();
    _contentView.backgroundColor = WQColorSurface();
    _contentView.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _contentView.autocorrectionType = UITextAutocorrectionTypeNo;
    _contentView.textContainerInset = UIEdgeInsetsMake(WQSpace2, WQSpace2, WQSpace2, WQSpace2);
    WQStyleControl(_contentView);
    _contentView.layer.borderColor = WQColorLine().CGColor;

    UITableViewCell *c0 = [self rowCellWithTitle:@"容器" value:&_containerValue button:nil action:NULL];
    UITableViewCell *c1 = [self rowCellWithTitle:@"基线目录" value:&_baseValue button:nil action:NULL];
    UITableViewCell *c2 = [self rowCellWithTitle:@"定位方式" value:&_modeValue button:nil action:NULL];
    UITableViewCell *c3 = [self rowCellWithTitle:@"重新自动定位" value:nil button:@"定位" action:@selector(locateTapped)];

    UITableViewCell *f0 = [self formCellWithLabel:@"相对目录链" control:_chainField
        hint:@"相对 Saved，缺失层级才会新建" hintOut:&_chainHint height:0];
    UITableViewCell *f1 = [self formCellWithLabel:@"容器 UUID（可选）" control:_uuidField
        hint:@"留空则自动定位" hintOut:&_uuidHint height:0];

    UITableViewCell *g0 = [self formCellWithLabel:@"文件名" control:_nameField
        hint:@"不含路径分隔符，自动补 .lua" hintOut:&_nameHint height:0];
    UITableViewCell *g1 = [self formCellWithLabel:@"脚本内容" control:_contentView
        hint:@"可粘贴，或从「文件」导入" hintOut:&_contentHint height:0];
    UITableViewCell *g2 = [self rowCellWithTitle:@"从文件导入" value:nil button:@"选择 .lua" action:@selector(importTapped)];
    UITableViewCell *g3 = [self rowCellWithTitle:@"当前脚本" value:&_scriptValue button:nil action:NULL];
    UITableViewCell *g4 = [self rowCellWithTitle:@"使用内置脚本" value:nil button:@"填入" action:@selector(builtInTapped)];

    UITableViewCell *h0 = [self rowCellWithTitle:@"最近结果" value:&_resultValue button:nil action:NULL];
    UITableViewCell *h1 = [self primaryCellWithTitle:@"检查并部署" action:@selector(deployTapped)];
    UITableViewCell *h2 = [self rowCellWithTitle:@"复制目标路径" value:nil button:@"复制" action:@selector(copyPathTapped)];

    CGFloat formH = WQSpace3 + 18.0 + WQSpace2 + WQControlH + WQSpace1 + WQHintSpace + WQSpace3;
    CGFloat textH = WQSpace3 + 18.0 + WQSpace2 + 120.0 + WQSpace1 + WQHintSpace + WQSpace3;
    _cells = @[@[c0, c1, c2, c3], @[f0, f1], @[g0, g1, g2, g3, g4], @[h0, h1, h2]];
    _heights = @[
        @[@(WQRowHeight), @(WQRowHeight), @(WQRowHeight), @(WQRowHeight)],
        @[@(formH), @(formH)],
        @[@(formH), @(textH), @(WQRowHeight), @(WQRowHeight), @(WQRowHeight)],
        @[@(WQRowHeight), @(WQControlH + WQSpace4), @(WQRowHeight)],
    ];

    _resultValue.text = @"尚未部署";
    _scriptValue.text = @"未选择";
    [self updateScriptValue];
    [self locateTapped];
}

- (NSArray<NSString *> *)sectionTitles { return @[@"目标定位", @"目录链", @"Lua 脚本", @"部署"]; }

- (NSArray<NSString *> *)sectionFooters
{
    return @[
        @"自动定位按特征目录 Documents/DeltaForce/Saved 识别目标应用，不使用固定 UUID。列表来自系统应用数据库；若数据库未就绪，请手动填写容器 UUID。",
        @"逐级检测：已存在的目录原样保留，只有缺失的层级才会新建。基线目录必须已存在，否则说明定位到了错误的容器。",
        @"内容完全由你提供。同名文件会被替换，替换前会在「备份」中保留一份副本，可长按还原。",
        @"仅用于本机调试排查。请先完全退出游戏，写入期间不要启动它；写入不是快照，游戏仍在运行时可能损坏存档。改动游戏文件可能违反游戏条款或导致账号受限，请勿用于在线对局或影响他人。",
    ];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return (NSInteger)_cells.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)_cells[section].count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return [self sectionTitles][section]; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { return [self sectionFooters][section]; }
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return (CGFloat)_heights[indexPath.section][indexPath.row].doubleValue;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return _cells[indexPath.section][indexPath.row];
}

#pragma mark - State

- (void)updateScriptValue
{
    NSUInteger bytes = _importedData.length ?: [_contentView.text dataUsingEncoding:NSUTF8StringEncoding].length;
    if (bytes) _scriptValue.text = [NSString stringWithFormat:@"%lu 字节 · %@", (unsigned long)bytes, _importedName ?: @"粘贴内容"];
    else _scriptValue.text = @"未选择";
}

- (void)locateTapped
{
    [self.view endEditing:YES];
    NSString *manual = _uuidField.text;
    _containerValue.text = @"定位中…";
    _baseValue.text = @"—";
    _modeValue.text = manual.length ? @"手动指定" : @"自动定位";
    __weak typeof(self) weakSelf = self;
    dispatch_async(wq_io(), ^{
        NSString *error = nil;
        NSString *container = WQLuaFindContainer(manual, &error);
        NSString *label = container ? wq_container_label(container) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            WQLuaDeployViewController *self2 = weakSelf;
            if (!self2) return;
            if (container) {
                self2->_foundContainer = container;
                self2->_containerValue.text = label ?: container.lastPathComponent;
                self2->_baseValue.text = @"已找到";
                self2->_uuidHint.text = label ?: container.lastPathComponent;
                wq_log(@"lua: located container %@", container);
            } else {
                self2->_foundContainer = nil;
                self2->_containerValue.text = @"未找到";
                self2->_baseValue.text = @"未找到";
                self2->_uuidHint.text = @"请手动填写 UUID";
                wq_alert(self2, @"未找到目标容器", error ?: @"自动定位失败");
            }
        });
    });
}

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
    if (!url) return;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!data.length) {
        _contentHint.text = @"导入失败：文件为空或无法读取";
        return;
    }
    _importedData = data;
    _importedName = url.lastPathComponent;
    if (!_nameField.text.length || [_nameField.text isEqualToString:WQLuaDefaultName])
        _nameField.text = url.lastPathComponent;
    _contentView.text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    _contentHint.text = [NSString stringWithFormat:@"已从「文件」导入 %lu 字节", (unsigned long)data.length];
    [self updateScriptValue];
}

- (void)builtInTapped
{
    if (!WQLuaBuiltInScript.length) {
        _contentHint.text = @"内置脚本尚未预置；请粘贴内容或从「文件」导入";
        return;
    }
    _importedData = nil;
    _importedName = @"内置脚本";
    _contentView.text = WQLuaBuiltInScript;
    _contentHint.text = @"已填入内置脚本";
    [self updateScriptValue];
}

- (void)copyPathTapped
{
    if (!_lastTargetPath.length) {
        _resultValue.text = @"请先部署一次";
        return;
    }
    UIPasteboard.generalPasteboard.string = _lastTargetPath;
    _resultValue.text = @"路径已复制";
}

#pragma mark - Deploy

- (void)deployTapped
{
    [self.view endEditing:YES];
    NSString *chain = [_chainField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *name = [_nameField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSData *lua = _importedData ?: [_contentView.text dataUsingEncoding:NSUTF8StringEncoding];

    NSArray<NSString *> *parts = [chain componentsSeparatedByString:@"/"];
    for (NSString *part in parts) {
        if (!part.length || [part isEqualToString:@"."] || [part isEqualToString:@".."] ||
            [part rangeOfString:@"\0"].location != NSNotFound) {
            _chainHint.text = @"目录链只能是不含 . 或 .. 的相对层级";
            return;
        }
    }
    if (!parts.count) { _chainHint.text = @"请填写目录链"; return; }
    if (!name.length || [name containsString:@"/"] || [name isEqualToString:@"."] || [name isEqualToString:@".."]) {
        _nameHint.text = @"请填写不含路径分隔符的文件名";
        return;
    }
    if (![name.pathExtension.lowercaseString isEqualToString:@"lua"])
        name = [name stringByAppendingPathExtension:@"lua"];
    if (!lua.length) { _contentHint.text = @"脚本内容为空，请粘贴或导入"; return; }

    NSString *manual = _uuidField.text;
    NSString *preview = [NSString stringWithFormat:@"%@/%@/%@", WQLuaBaseRel, chain, name];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认部署"
        message:[NSString stringWithFormat:@"目标：%@\n\n将逐级检测并创建缺失目录；同名文件会被替换，替换前在「备份」中保留副本。\n\n请先完全退出游戏，写入期间不要启动它。此功能仅用于本机调试排查，改动游戏文件可能违反游戏条款或导致账号受限。", preview]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"部署" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [weakSelf performDeployWithChain:parts name:name data:lua manual:manual];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)performDeployWithChain:(NSArray<NSString *> *)parts name:(NSString *)name
                          data:(NSData *)data manual:(NSString *)manual
{
    _resultValue.text = @"正在写入…";
    __weak typeof(self) weakSelf = self;
    dispatch_async(wq_io(), ^{
        NSString *error = nil;
        NSString *container = WQLuaFindContainer(manual, &error);
        if (!container) { [weakSelf finish:NO message:error ?: @"未找到目标容器" path:nil]; return; }

        NSString *current = [container stringByAppendingPathComponent:WQLuaBaseRel];
        if (!WQLuaIsDirectory(current)) {
            [weakSelf finish:NO message:@"基线目录不存在，可能定位到了错误的容器" path:nil];
            return;
        }

        NSUInteger created = 0;
        for (NSString *part in parts) {
            current = [current stringByAppendingPathComponent:part];
            struct stat st;
            if (wq_stat(current, &st)) {
                if (!S_ISDIR(st.st_mode)) {
                    [weakSelf finish:NO message:[NSString stringWithFormat:@"%@ 已存在但不是目录", part] path:nil];
                    return;
                }
                continue;  // 已存在，原样保留
            }
            NSString *dirError = nil;
            if (!wq_create_dir(current, &dirError)) {
                [weakSelf finish:NO message:[NSString stringWithFormat:@"创建 %@ 失败：%@", part, dirError ?: @"未知错误"] path:nil];
                return;
            }
            created++;
        }

        NSString *target = [current stringByAppendingPathComponent:name];
        struct stat st;
        BOOL exists = wq_stat(target, &st) && S_ISREG(st.st_mode);
        NSString *writeError = nil;
        BOOL ok = exists ? wq_write(target, data, &writeError) : wq_create_file(target, data, &writeError);
        if (!ok) {
            [weakSelf finish:NO message:[NSString stringWithFormat:@"写入失败：%@", writeError ?: @"未知错误"] path:target];
            return;
        }
        NSData *check = wq_read(target, data.length + 1, nil);
        if (![check isEqualToData:data]) {
            [weakSelf finish:NO message:@"写入后校验不一致，请检查游戏是否仍在运行" path:target];
            return;
        }
        wq_log(@"lua: deployed %@ (%lu bytes, created %lu dirs, replaced=%d)",
               target, (unsigned long)data.length, (unsigned long)created, exists ? 1 : 0);
        [weakSelf finish:YES message:[NSString stringWithFormat:@"完成 · 新建 %lu 个目录 · %lu 字节 · %@",
            (unsigned long)created, (unsigned long)data.length, exists ? @"已替换（有备份）" : @"新建文件"] path:target];
    });
}

- (void)finish:(BOOL)ok message:(NSString *)message path:(NSString *_Nullable)path
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_resultValue.text = ok ? @"部署完成" : @"部署失败";
        if (path.length) self->_lastTargetPath = path;
        wq_alert(self, ok ? @"部署完成" : @"部署失败", message);
    });
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    [textField resignFirstResponder];
    return YES;
}

@end
