//
//  main.m
//  WQ Files
//
//  Proof-of-concept file browser for iOS 27 that reaches other containers
//  through the worse_query sandbox escape by Taj C (forcequit),
//  https://github.com/forcequitOS/worse_query, GPL-3.0-or-later.
//  This app is GPL-3.0-or-later as well (see LICENSE).
//

#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import "WQAccess.h"
#import "WQLaunchServices.h"
#import "WQUI.h"
#import "WQSharing.h"
#import "WQDir.h"
#import "WQApps.h"
#import "WQCache.h"
#import "WQCore.h"
#import "WQPlistEditor.h"
#import "WQPlistEditorSupport.h"
#import "WQHexViewer.h"
#import "WQSQLiteViewer.h"
#import "WQDesignTokens.h"
#import "WQGameFeatures.h"

// Settings keys live in WQDesignTokens.h so the settings page, the file
// browser and the game module all read the same values. The two helpers are
// defined with the settings controllers below; declare them up front.
static BOOL WQSettingBool(NSString *key, BOOL fallback);
static void WQSettingSetBool(NSString *key, BOOL value);

// NSCache is thread-safe and evicts under memory pressure. Container paths are
// stable for the lifetime of an install, so resolved identifiers are reusable.
static NSCache<NSString *, NSDictionary *> *WQContainerInfoCache(void)
{
    static NSCache<NSString *, NSDictionary *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; cache.countLimit = 2000; });
    return cache;
}

static BOOL wq_looks_like_uuid(NSString *name)
{
    return name.length == 36 && [[NSUUID alloc] initWithUUIDString:name] != nil;
}

static BOOL wq_regular_file_for_ui(NSString *path)
{
    struct stat st;
    if (!wq_stat(path, &st)) return NO;
    // Symbolic links are deliberately not followed: the file APIs use
    // O_NOFOLLOW and the UI must offer the same contract.
    return S_ISREG(st.st_mode);
}

#pragma mark - Item

@interface WQItem : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) NSString *bundleID;  // for the app icon
@property (nonatomic) BOOL isDir;
@property (nonatomic) BOOL isLink;
@property (nonatomic) BOOL isRegular;
@property (nonatomic) unsigned long long size;
@property (nonatomic) mode_t mode;
@property (nonatomic) uid_t uid;
@property (nonatomic, strong) NSDate *modified;
@property (nonatomic, strong) NSDate *created;
@end

@implementation WQItem
@end

#pragma mark - File viewer

typedef NS_ENUM(NSInteger, WQOpenMode) { WQOpenAuto, WQOpenPlist, WQOpenText, WQOpenHex, WQOpenSQLite };
// Opens a file in the fitting viewer (Auto: chosen from its first bytes).
static void wq_open_file(UINavigationController *nav, NSString *path, BOOL readOnly, WQOpenMode mode);

typedef NS_ENUM(NSInteger, WQViewKind) { WQViewText, WQViewPlist, WQViewImage, WQViewHex };

static const NSUInteger kViewLimit = 4 * 1024 * 1024;
static const NSUInteger kHexLimit = 64 * 1024;

// Parsing and image creation happen on the I/O queue; the main thread only
// installs the prepared display.
@interface WQFileDisplay : NSObject
@property (nonatomic) BOOL truncated;
@property (nonatomic, strong) NSString *plistText;
@property (nonatomic) NSPropertyListFormat plistFormat;
@property (nonatomic, strong) UIImage *image;
@property (nonatomic, strong) NSString *text;
@property (nonatomic, strong) NSString *hexText;
@end
@implementation WQFileDisplay
@end

static NSString *wq_file_hex_dump(NSData *data, BOOL truncated)
{
    NSUInteger len = MIN(data.length, kHexLimit);
    const uint8_t *b = data.bytes;
    NSMutableString *out = [NSMutableString stringWithCapacity:len * 4];
    for (NSUInteger off = 0; off < len; off += 16) {
        [out appendFormat:@"%08lx  ", (unsigned long)off];
        NSMutableString *ascii = [NSMutableString new];
        for (NSUInteger i = 0; i < 16; i++) {
            if (off + i < len) {
                uint8_t c = b[off + i];
                [out appendFormat:@"%02x ", c];
                [ascii appendFormat:@"%c", (c >= 0x20 && c < 0x7f) ? c : '.'];
            } else {
                [out appendString:@"   "];
            }
        }
        [out appendFormat:@" %@\n", ascii];
    }
    if (data.length > len || truncated) [out appendString:@"\n… (only the beginning is shown)\n"];
    return out;
}

@interface WQFileViewController : UIViewController <UITextViewDelegate, WQUnsavedEditing>
@property (nonatomic) BOOL readOnly;
- (instancetype)initWithPath:(NSString *)path;
@end

@implementation WQFileViewController {
    NSString *_path;
    UITextView *_textView;
    UIImageView *_imageView;
    UIBarButtonItem *_editButton;
    WQViewKind _kind;
    NSPropertyListFormat _plistFormat;
    BOOL _truncated;
    WQEditState *_editState;
    NSDictionary<NSString *, NSNumber *> *_version;
}


- (instancetype)initWithPath:(NSString *)path
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _path = [path copy];
        _editState = [WQEditState new];
        self.title = path.lastPathComponent;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _textView = [UITextView new];
    _textView.translatesAutoresizingMaskIntoConstraints = NO;
    _textView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    _textView.editable = NO;
    _textView.autocorrectionType = UITextAutocorrectionTypeNo;
    _textView.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _textView.smartQuotesType = UITextSmartQuotesTypeNo;
    _textView.smartDashesType = UITextSmartDashesTypeNo;
    _textView.alwaysBounceVertical = YES;
    _textView.delegate = self;
    [self.view addSubview:_textView];
    __weak typeof(self) weakSelf = self;
    self.navigationItem.backAction = [UIAction actionWithHandler:^(UIAction *__unused a) { [weakSelf leave]; }];
    _imageView = [UIImageView new];
    _imageView.translatesAutoresizingMaskIntoConstraints = NO;
    _imageView.contentMode = UIViewContentModeScaleAspectFit;
    _imageView.hidden = YES;
    [self.view addSubview:_imageView];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    for (UIView *v in @[_textView, _imageView]) {
        [NSLayoutConstraint activateConstraints:@[
            [v.topAnchor constraintEqualToAnchor:g.topAnchor],
            [v.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
            [v.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
            [v.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        ]];
    }
    UIBarButtonItem *share = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                                           target:self action:@selector(share:)];
    UIMenu *openAs = [UIMenu menuWithTitle:@"Open As" children:@[
        [UIAction actionWithTitle:@"Plist Editor" image:[UIImage systemImageNamed:@"list.bullet.indent"] identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf reopenAs:WQOpenPlist]; }],
        [UIAction actionWithTitle:@"十六进制查看器" image:[UIImage systemImageNamed:@"number"] identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf reopenAs:WQOpenHex]; }],
        [UIAction actionWithTitle:@"SQLite Viewer" image:[UIImage systemImageNamed:@"tablecells"] identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf reopenAs:WQOpenSQLite]; }],
    ]];
    UIBarButtonItem *more = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:openAs];
    self.navigationItem.rightBarButtonItems = @[share, more];
    _textView.text = @"Loading…";
    [self load];
}

- (void)load
{
    NSString *path = _path;
    dispatch_async(wq_io(), ^{
        NSString *error = nil;
        struct stat st;
        BOOL exists = wq_stat(path, &st);
        NSDictionary *__unused before = wq_file_version(path);
        NSData *data = wq_read(path, kViewLimit + 1, &error);
        NSDictionary *version = wq_file_version(path);
        if (data && (!before || !version || ![before isEqualToDictionary:version])) {
            data = nil;
            error = version ? @"The file changed while it was being read. Open it again."
                            : @"Could not establish a stable file version. Open it again.";
        }
        WQFileDisplay *display = nil;
        if (data) {
            display = [WQFileDisplay new];
            display.truncated = data.length > kViewLimit;
            NSData *view = display.truncated ? [data subdataWithRange:NSMakeRange(0, kViewLimit)] : data;
            if (!display.truncated) {
                NSPropertyListFormat format = 0;
                id plist = [NSPropertyListSerialization propertyListWithData:view options:0 format:&format error:nil];
                if (plist) {
                    NSData *xml = [NSPropertyListSerialization dataWithPropertyList:plist
                                                                            format:NSPropertyListXMLFormat_v1_0
                                                                           options:0 error:nil];
                    NSString *text = xml ? [[NSString alloc] initWithData:xml encoding:NSUTF8StringEncoding] : nil;
                    if (text) {
                        display.plistFormat = format;
                        display.plistText = text;
                    }
                }
            }
            if (!display.plistText) {
                display.image = [UIImage imageWithData:view];
                if (!display.image) {
                    NSString *text = [[NSString alloc] initWithData:view encoding:NSUTF8StringEncoding];
                    if (text && ![text containsString:@"\0"]) display.text = text;
                    else display.hexText = wq_file_hex_dump(view, display.truncated);
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_version = version;
            if (!display) {
                NSString *hint = wq_permission_hint(path, NO);
                self->_textView.text = [NSString stringWithFormat:@"Cannot read this file.\n\n%@", hint ?: error];
                return;
            }
            NSString *info = exists
                ? [NSString stringWithFormat:@"%@ · mode %o · uid %u", wq_size_text((unsigned long long)st.st_size),
                   st.st_mode & 07777, st.st_uid]
                : @"";
            self.navigationItem.prompt = info.length ? info : nil;
            if (wq_permission_hint(path, YES)) self->_readOnly = YES;   // only the owner may write it
            [self showDisplay:display];
        });
    });
}

- (void)showDisplay:(WQFileDisplay *)display
{
    _truncated = display.truncated;
    if (display.plistText) {
        _kind = WQViewPlist;
        _plistFormat = display.plistFormat;
        _textView.text = display.plistText;
        if (!WQPlistFormatIsWritable(display.plistFormat)) {
            _readOnly = YES;
            NSString *prompt = self.navigationItem.prompt;
            NSString *reason = [NSString stringWithFormat:@"%@ · read only", WQPlistFormatName(display.plistFormat)];
            self.navigationItem.prompt = prompt.length ? [prompt stringByAppendingFormat:@" · %@", reason] : reason;
        }
        if (!_readOnly) [self enableEditing];
        return;
    }
    if (display.image) {
        _kind = WQViewImage;
        _imageView.image = display.image;
        _imageView.hidden = NO;
        _textView.hidden = YES;
        return;
    }
    if (display.text) {
        _kind = WQViewText;
        _textView.text = display.text;
        if (!_truncated && !_readOnly) [self enableEditing];
        return;
    }
    _kind = WQViewHex;
    _textView.text = display.hexText ?: @"";
}

- (void)updateEditButton
{
    _editButton.title = _textView.editable ? @"保存" : @"编辑";
    _editButton.style = _textView.editable ? wq_primary_button_style() : UIBarButtonItemStylePlain;
    _editButton.enabled = !_editState.saving;
}

- (void)enableEditing
{
    if (_editButton) return;
    _editButton = [[UIBarButtonItem alloc] initWithTitle:@"编辑" style:UIBarButtonItemStylePlain
                                                  target:self action:@selector(toggleEdit:)];
    NSArray *items = self.navigationItem.rightBarButtonItems;
    self.navigationItem.rightBarButtonItems = [items arrayByAddingObject:_editButton];
}

- (void)textViewDidChange:(UITextView *)textView
{
    if (_editState.saving) return;
    [_editState noteChange];
}

- (BOOL)blockWhileSaving
{
    if (!_editState.saving) return NO;
    wq_alert(self, @"Save in progress", @"Wait for the current save to finish before leaving or making more changes.");
    return YES;
}

- (BOOL)wq_needsLeaveConfirmation
{
    return _editState.dirty || _editState.saving;
}

- (void)confirmLeaveThen:(void (^)(void))proceed
{
    if ([self blockWhileSaving]) return;
    if (!_editState.dirty) { proceed(); return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Discard changes?"
        message:@"Your text changes have not been saved." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"继续编辑" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"放弃修改" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self->_editState discard];
        self->_textView.editable = NO;
        [self->_textView resignFirstResponder];
        [self updateEditButton];
        proceed();
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)leave
{
    [self confirmLeaveThen:^{ [self.navigationController popViewControllerAnimated:YES]; }];
}

- (void)toggleEdit:(UIBarButtonItem *)sender
{
    if ([self blockWhileSaving]) return;
    if (!_textView.editable) {
        _textView.editable = YES;
        [self updateEditButton];
        [_textView becomeFirstResponder];
        return;
    }
    if (!_editState.dirty) {
        _textView.editable = NO;
        [_textView resignFirstResponder];
        [self updateEditButton];
        return;
    }
    if (!_version) {
        wq_alert(self, @"无法保存", @"The file has no verified version snapshot. Reopen it before saving.");
        return;
    }
    NSData *newData = nil;
    if (_kind == WQViewPlist) {
        NSData *xml = [_textView.text dataUsingEncoding:NSUTF8StringEncoding];
        NSError *error = nil;
        id plist = xml ? [NSPropertyListSerialization propertyListWithData:xml options:0 format:NULL error:&error] : nil;
        if (!plist) {
            wq_alert(self, @"不是有效的属性列表", error.localizedDescription ?: @"Check the XML.");
            return;
        }
        newData = [NSPropertyListSerialization dataWithPropertyList:plist format:_plistFormat options:0 error:&error];
        if (!newData) {
            wq_alert(self, @"无法编码", error.localizedDescription ?: @"");
            return;
        }
    } else {
        newData = [_textView.text dataUsingEncoding:NSUTF8StringEncoding];
    }
    if (!newData) {
        wq_alert(self, @"无法编码", @"The text could not be encoded as UTF-8.");
        return;
    }
    NSString *message = [NSString stringWithFormat:@"%@ will be overwritten in place. The current version is backed up to Backups first.", _path];
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Save changes?" message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        NSUInteger savedRevision = [self->_editState beginSave];
        self->_textView.editable = NO;
        [self->_textView resignFirstResponder];
        [self updateEditButton];
        NSString *path = self->_path;
        NSDictionary *expectedVersion = [self->_version copy];
        dispatch_async(wq_io(), ^{
            NSString *error = nil;
            NSDictionary *newVersion = nil;
            BOOL ok = wq_write_if_unchanged_get_version(path, newData, expectedVersion, &newVersion, &error);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_editState finishSave:ok revision:savedRevision];
                if (ok) self->_version = newVersion;
                self->_textView.editable = self->_editState.dirty;
                [self updateEditButton];
                if (!ok) wq_alert(self, @"Save failed", error ?: wq_permission_hint(path, YES) ?: @"Unknown error");
            });
        });
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)share:(UIBarButtonItem *)sender
{
    wq_share(self, _path, nil);
}

- (void)reopenAs:(WQOpenMode)mode
{
    [self confirmLeaveThen:^{
        UINavigationController *nav = self.navigationController;
        NSString *path = self->_path;
        BOOL readOnly = self->_readOnly;
        [nav popViewControllerAnimated:NO];
        wq_open_file(nav, path, readOnly, mode);
    }];
}

@end

#pragma mark - Choosing a viewer

static WQOpenMode wq_sniff(NSData *head)
{
    const uint8_t *b = head.bytes;
    NSUInteger n = head.length;
    if (n >= 7 && memcmp(b, "bplist0", 7) == 0) return WQOpenPlist;
    if (wq_is_sqlite_header(head)) return WQOpenSQLite;
    if ((n >= 8 && memcmp(b, "\x89PNG", 4) == 0) || (n >= 3 && b[0] == 0xff && b[1] == 0xd8 && b[2] == 0xff) ||
        (n >= 4 && memcmp(b, "GIF8", 4) == 0) || (n >= 12 && memcmp(b + 4, "ftyp", 4) == 0))
        return WQOpenText;   // images: the file viewer renders them
    if (n == 0) return WQOpenText;
    if (memchr(b, 0, n)) return WQOpenHex;
    NSString *text = nil;
    for (NSUInteger cut = 0; cut < 4 && !text && cut < n; cut++)   // the sample may end mid-character
        text = [[NSString alloc] initWithBytes:b length:n - cut encoding:NSUTF8StringEncoding];
    if (!text) return WQOpenHex;
    if ([text containsString:@"<plist"] || [text containsString:@"<!DOCTYPE plist"]) return WQOpenPlist;
    return WQOpenText;
}

static NSUInteger wq_open_generation;

static void wq_open_file(UINavigationController *nav, NSString *path, BOOL readOnly, WQOpenMode mode)
{
    if (!nav || !path.length) return;
    // All calls originate on the main thread. A newer explicit or automatic
    // open invalidates older sniff requests, and leaving the originating screen
    // also prevents a late push.
    NSUInteger request = ++wq_open_generation;
    UIViewController *origin = nav.topViewController;
    void (^push)(WQOpenMode) = ^(WQOpenMode m) {
        if (request != wq_open_generation || nav.topViewController != origin) return;
        UIViewController *vc;
        if (m == WQOpenPlist) {
            WQPlistEditorViewController *editor = [[WQPlistEditorViewController alloc] initWithPath:path readOnly:readOnly];
            __weak UINavigationController *weakNav = nav;
            editor.openAsText = ^{ wq_open_file(weakNav, path, readOnly, WQOpenText); };
            editor.openAsHex = ^{ wq_open_file(weakNav, path, readOnly, WQOpenHex); };
            vc = editor;
        } else if (m == WQOpenHex) {
            vc = [[WQHexViewController alloc] initWithPath:path readOnly:readOnly];
        } else if (m == WQOpenSQLite) {
            vc = [[WQSQLiteViewController alloc] initWithPath:path];
        } else {
            WQFileViewController *file = [[WQFileViewController alloc] initWithPath:path];
            file.readOnly = readOnly;
            vc = file;
        }
        [nav pushViewController:vc animated:YES];
    };
    if (!wq_regular_file_for_ui(path)) {
        UIViewController *host = nav.topViewController;
        struct stat st;
        BOOL link = wq_stat(path, &st) && S_ISLNK(st.st_mode);
        if (host) wq_alert(host, link ? @"符号链接" : @"无法打开此项目",
                           link ? @"WQ Files 查看、分享和编辑时不跟随符号链接。"
                                : @"只能查看普通文件。");
        return;
    }
    if (mode != WQOpenAuto) { push(mode); return; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *head = wq_permission_hint(path, NO) ? nil : wq_read_range(path, 0, 4096, NULL);
        WQOpenMode m = head ? wq_sniff(head) : WQOpenText;   // unreadable: the file viewer shows why
        dispatch_async(dispatch_get_main_queue(), ^{ push(m); });
    });
}

#pragma mark - Folder

static NSString *wq_folder_date_text(NSDate *date)
{
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSDateFormatter new];
        formatter.dateStyle = NSDateFormatterShortStyle;
        formatter.timeStyle = NSDateFormatterShortStyle;
        formatter.locale = NSLocale.autoupdatingCurrentLocale;
    });
    return date ? [formatter stringFromDate:date] : @"";
}

#pragma mark - Folder sorting

// One sort order for all folders, remembered. Each key starts in its natural
// direction (A–Z, newest first, largest first); picking it again reverses it.
typedef NS_ENUM(NSInteger, WQSortKey) { WQSortName, WQSortModified, WQSortCreated, WQSortSize };
static NSString *const kWQSortKeyPref = @"WQFolderSortKey";
static NSString *const kWQSortAscendingPref = @"WQFolderSortAscending";
static NSString *const kWQFoldersFirstPref = @"WQFolderSortFoldersFirst";

static WQSortKey wq_sort_key(void)
{
    NSInteger key = [NSUserDefaults.standardUserDefaults integerForKey:kWQSortKeyPref];
    return key >= WQSortName && key <= WQSortSize ? (WQSortKey)key : WQSortName;
}

static BOOL wq_sort_ascending(void)
{
    id value = [NSUserDefaults.standardUserDefaults objectForKey:kWQSortAscendingPref];
    return value ? [value boolValue] : YES;
}

static BOOL wq_folders_first(void)
{
    id value = [NSUserDefaults.standardUserDefaults objectForKey:kWQFoldersFirstPref];
    return value ? [value boolValue] : YES;
}

static void wq_choose_sort(WQSortKey key)
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    BOOL ascending = key == wq_sort_key() ? !wq_sort_ascending() : key == WQSortName;
    [d setInteger:key forKey:kWQSortKeyPref];
    [d setBool:ascending forKey:kWQSortAscendingPref];
}

static NSString *wq_sort_direction_text(WQSortKey key, BOOL ascending)
{
    switch (key) {
        case WQSortName: return ascending ? @"A–Z" : @"Z–A";
        case WQSortSize: return ascending ? @"Smallest first" : @"从大到小";
        default: return ascending ? @"Oldest first" : @"从新到旧";
    }
}

static NSArray<WQItem *> *wq_sorted_items(NSArray<WQItem *> *items)
{
    WQSortKey key = wq_sort_key();
    BOOL ascending = wq_sort_ascending(), foldersFirst = wq_folders_first();
    return [items sortedArrayUsingComparator:^NSComparisonResult(WQItem *a, WQItem *b) {
        if (foldersFirst && a.isDir != b.isDir) return a.isDir ? NSOrderedAscending : NSOrderedDescending;
        NSComparisonResult r = NSOrderedSame;
        switch (key) {
            case WQSortName: break;
            case WQSortModified: r = [(a.modified ?: NSDate.distantPast) compare:(b.modified ?: NSDate.distantPast)]; break;
            case WQSortCreated: r = [(a.created ?: NSDate.distantPast) compare:(b.created ?: NSDate.distantPast)]; break;
            case WQSortSize: r = a.size < b.size ? NSOrderedAscending : a.size > b.size ? NSOrderedDescending : NSOrderedSame; break;
        }
        NSComparisonResult byName = [(a.label ?: a.name ?: @"") localizedStandardCompare:(b.label ?: b.name ?: @"")];
        if (key == WQSortName) r = byName;
        if (r == NSOrderedSame) return byName;
        return ascending ? r : (NSComparisonResult)-r;
    }];
}

// Sidebar letter for an entry: its first letter without accents, "#" for the rest.
static NSString *wq_index_letter(NSString *name)
{
    if (!name.length) return @"#";
    NSString *first = [[name substringWithRange:[name rangeOfComposedCharacterSequenceAtIndex:0]]
                       stringByFoldingWithOptions:NSDiacriticInsensitiveSearch | NSCaseInsensitiveSearch locale:nil].uppercaseString;
    unichar c = first.length ? [first characterAtIndex:0] : 0;
    return (c >= 'A' && c <= 'Z') ? [NSString stringWithCharacters:&c length:1] : @"#";
}

@implementation WQDirViewController {
    NSString *_path;
    NSArray<WQItem *> *_all;     // everything in the folder
    NSArray<WQItem *> *_items;   // what the search lets through (shown)
    NSString *_query;
    UILabel *_pathLabel;
    UIView *_headerBox;
    NSString *_scanStatus;
    CGFloat _headerWidth;
    NSString *_error;
    BOOL _labels;
    BOOL _backupManager;
    BOOL _backupStorage;
    BOOL _selectingBackups;
    NSMutableSet<NSString *> *_selectedBackups;
    UIBarButtonItem *_selectItem;
    UIBarButtonItem *_menuItem;
    UIBarButtonItem *_doneItem;
    UIBarButtonItem *_deleteItem;
    UIBarButtonItem *_allItem;
    NSString *_baseTitle;
    WQScanCancellation *_scanCancellation;
    NSUInteger _scanGeneration;
    BOOL _scanInFlight;
    BOOL _scanNeedsRefresh;
    NSTimeInterval _lastReloadFinished;
    NSArray<NSString *> *_indexTitles;          // sidebar letters, when sorted by name
    NSDictionary<NSString *, NSNumber *> *_indexRows;   // letter -> first row
}

- (instancetype)initWithPath:(NSString *)path title:(NSString *)title
{
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        _path = [path copy];
        self.title = title ?: (path.lastPathComponent.length ? path.lastPathComponent : @"/");
        _baseTitle = self.title;
        _selectedBackups = [NSMutableSet new];
        // Container parents: show bundle/group identifiers instead of UUIDs.
        NSString *parent = path.lastPathComponent;
        _labels = [@[@"Application", @"AppGroup", @"PluginKitPlugin", @"InternalDaemon", @"System"] containsObject:parent];
        NSString *appBackups = wq_app_backup_root();
        NSString *fileBackups = wq_backup_root();
        _backupManager = appBackups.length &&
            ([_path isEqualToString:appBackups] || [_path hasPrefix:[appBackups stringByAppendingString:@"/"]]);
        _backupStorage = _backupManager ||
            (fileBackups.length && ([_path isEqualToString:fileBackups] || [_path hasPrefix:[fileBackups stringByAppendingString:@"/"]]));
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(userRefresh) forControlEvents:UIControlEventValueChanged];
    __weak typeof(self) weakSelf = self;
    NSString *path = _path;
    NSMutableArray<UIMenuElement *> *menuItems = [NSMutableArray new];
    if (!self.readOnly && !_backupStorage) {
        [menuItems addObject:[UIAction actionWithTitle:@"新建文件夹" image:[UIImage systemImageNamed:@"folder.badge.plus"] identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf promptNewFolder]; }]];
        [menuItems addObject:[UIAction actionWithTitle:@"导入文件" image:[UIImage systemImageNamed:@"square.and.arrow.down"] identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf importFile]; }]];
    }
    [menuItems addObject:[UIAction actionWithTitle:@"拷贝路径" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil
                          handler:^(UIAction *__unused a) { UIPasteboard.generalPasteboard.string = path; }]];
    // Built when the menu opens, so the checkmarks show the current order.
    [menuItems addObject:[UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
        WQSortKey current = wq_sort_key();
        BOOL ascending = wq_sort_ascending();
        NSMutableArray *sortActions = [NSMutableArray new];
        NSArray *titles = @[@"Name", @"修改日期", @"创建日期", @"Size"];
        for (NSInteger key = WQSortName; key <= WQSortSize; key++) {
            UIAction *action = [UIAction actionWithTitle:titles[(NSUInteger)key] image:nil identifier:nil handler:^(UIAction *__unused a) {
                wq_choose_sort((WQSortKey)key);
                [weakSelf resortAfterChange];
            }];
            if (key == current) {
                action.state = UIMenuElementStateOn;
                action.subtitle = wq_sort_direction_text((WQSortKey)key, ascending);
            }
            [sortActions addObject:action];
        }
        UIAction *folders = [UIAction actionWithTitle:@"文件夹置顶" image:nil identifier:nil handler:^(UIAction *__unused a) {
            [NSUserDefaults.standardUserDefaults setBool:!wq_folders_first() forKey:kWQFoldersFirstPref];
            [weakSelf resortAfterChange];
        }];
        folders.state = wq_folders_first() ? UIMenuElementStateOn : UIMenuElementStateOff;
        UIMenu *order = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[folders]];
        UIMenu *sort = [UIMenu menuWithTitle:@"Sort By" image:[UIImage systemImageNamed:@"arrow.up.arrow.down"] identifier:nil options:0
                                    children:[sortActions arrayByAddingObject:order]];
        sort.subtitle = [NSString stringWithFormat:@"%@, %@", titles[(NSUInteger)current], wq_sort_direction_text(current, ascending)];
        completion(@[sort]);
    }]];
    _menuItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
                                                 menu:[UIMenu menuWithChildren:menuItems]];
    if (_backupStorage) {
        _selectItem = [[UIBarButtonItem alloc] initWithTitle:@"选择" style:UIBarButtonItemStylePlain
                                                       target:self action:@selector(enterBackupSelection)];
        _selectItem.enabled = NO;
        self.navigationItem.rightBarButtonItems = @[_selectItem, _menuItem];
    } else {
        self.navigationItem.rightBarButtonItem = _menuItem;
    }
    [self updateHeader];
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = _labels ? @"Search names and bundle IDs" : @"Search this folder";
    search.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    search.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    [self reload];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    if (_scanInFlight) return;
    NSTimeInterval age = NSDate.date.timeIntervalSinceReferenceDate - _lastReloadFinished;
    // Returning from a child screen used to re-read the whole folder every 2s.
    // A fresh listing is reused; the interval is configurable in Settings.
    if (_scanNeedsRefresh || _lastReloadFinished <= 0 || age > WQSettingReloadAge()) [self reload];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    if (_selectingBackups) [self exitBackupSelection];
    if (_scanInFlight) {
        _scanNeedsRefresh = YES;
        [_scanCancellation cancel];
    }
    _scanStatus = nil;
    [self.refreshControl endRefreshing];
    [self updateHeader];
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    if (!self.presentedViewController && self.navigationController.topViewController != self) {
        wq_share_cancel(self);
    }
}

// Device strip, then the full path in normal-size text that wraps at the
// slashes (the navigation bar's prompt shrank it until unreadable). Tap to copy.
- (void)updateHeader
{
    CGFloat width = self.tableView.bounds.size.width ?: self.view.bounds.size.width;
    if (!_pathLabel) {
        _pathLabel = [UILabel new];
        _pathLabel.numberOfLines = 0;
        _pathLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
        _pathLabel.textColor = UIColor.secondaryLabelColor;
        _pathLabel.userInteractionEnabled = YES;
        [_pathLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(copyPath)]];
    }
    if (!_headerBox) {
        _headerBox = wq_device_header(width);
        [_headerBox addSubview:_pathLabel];
        self.tableView.tableHeaderView = _headerBox;
    }
    // Zero-width spaces after each slash let lines break between components.
    NSString *breakable = [_path stringByReplacingOccurrencesOfString:@"/" withString:@"/\u200B"];
    _pathLabel.text = _scanStatus ? [NSString stringWithFormat:@"%@\n%@", breakable, _scanStatus] : breakable;
    CGFloat side = 16, top = 42;
    CGSize fit = [_pathLabel sizeThatFits:CGSizeMake(width - 2 * side, CGFLOAT_MAX)];
    CGFloat height = top + ceil(fit.height) + 10;
    CGFloat oldHeight = _headerBox.frame.size.height;
    _headerBox.frame = CGRectMake(0, 0, width, height);
    _pathLabel.frame = CGRectMake(side, top, width - 2 * side, ceil(fit.height));
    _headerWidth = width;
    if (fabs(height - oldHeight) > 0.5) self.tableView.tableHeaderView = _headerBox;
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    if (fabs(self.tableView.bounds.size.width - _headerWidth) > 0.5) [self updateHeader];
}

- (void)copyPath
{
    UIPasteboard.generalPasteboard.string = _path;
    _scanStatus = @"Path copied";
    [self updateHeader];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([self->_scanStatus isEqualToString:@"Path copied"]) { self->_scanStatus = nil; [self updateHeader]; }
    });
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    NSString *q = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    _query = q.length ? q : nil;
    [self applyFilter];
    [self.tableView reloadData];
}

// App name, bundle or group ID, or file name; case and accents ignored.
- (void)applyFilter
{
    NSArray<WQItem *> *shown = _all ?: @[];
    if (_query) {
        NSStringCompareOptions opts = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
        NSString *q = _query;
        shown = [shown filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(WQItem *item, NSDictionary *__unused b) {
            for (NSString *field in @[item.label ?: @"", item.name ?: @"", item.bundleID ?: @""])
                if ([field rangeOfString:q options:opts].location != NSNotFound) return YES;
            return NO;
        }]];
    }
    _items = wq_sorted_items(shown);
    // Alphabet sidebar: only for longer lists sorted by name.
    NSMutableArray *titles = [NSMutableArray new];
    NSMutableDictionary *rows = [NSMutableDictionary new];
    if (wq_sort_key() == WQSortName && _items.count >= 25) {
        [_items enumerateObjectsUsingBlock:^(WQItem *item, NSUInteger row, BOOL *__unused stop) {
            NSString *letter = wq_index_letter(item.label ?: item.name);
            if (!rows[letter]) { rows[letter] = @(row); [titles addObject:letter]; }
        }];
    }
    _indexTitles = titles.count > 1 ? titles : nil;
    _indexRows = rows;
}

- (NSArray<NSString *> *)sectionIndexTitlesForTableView:(UITableView *)tableView
{
    return _selectingBackups || _error ? nil : _indexTitles;
}

- (NSInteger)tableView:(UITableView *)tableView sectionForSectionIndexTitle:(NSString *)title atIndex:(NSInteger)index
{
    NSNumber *row = _indexRows[title];
    if (row && row.unsignedIntegerValue < _items.count)
        [tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:row.integerValue inSection:0]
                         atScrollPosition:UITableViewScrollPositionTop animated:NO];
    return -1;   // already scrolled to the row; the list has one section
}

- (void)resortAfterChange
{
    [self applyFilter];
    [self.tableView reloadData];
    [self.tableView reloadSectionIndexTitles];
}

#pragma mark Backup multi-selection

- (NSArray<NSString *> *)backupUnitPathsInItems
{
    NSMutableArray<NSString *> *paths = [NSMutableArray new];
    for (WQItem *item in _items)
        if (wq_backup_unit_deletable(item.path)) [paths addObject:item.path];
    return paths;
}

- (void)updateBackupSelectionAvailability
{
    _selectItem.enabled = !_selectingBackups && [self backupUnitPathsInItems].count > 0;
}

- (void)updateBackupSelectionBar
{
    _deleteItem.enabled = _selectedBackups.count > 0;
    _allItem.enabled = _selectedBackups.count < [self backupUnitPathsInItems].count;
}

- (void)enterBackupSelection
{
    if ([self backupUnitPathsInItems].count == 0) {
        wq_alert(self, @"Nothing to select", @"Only complete backup folders can be selected here.");
        return;
    }
    _selectingBackups = YES;
    [_selectedBackups removeAllObjects];
    if (!_doneItem) {
        _doneItem = [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleProminent
                                                       target:self action:@selector(exitBackupSelection)];
        _deleteItem = [[UIBarButtonItem alloc] initWithTitle:@"删除" style:UIBarButtonItemStylePlain
                                                       target:self action:@selector(deleteSelectedBackups)];
        _deleteItem.tintColor = WQColorStrong();
        _allItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.circle"]
                                                     style:UIBarButtonItemStylePlain
                                                    target:self action:@selector(selectAllBackups)];
        _allItem.accessibilityLabel = @"Select All";
    }
    self.refreshControl.enabled = NO;
    self.tableView.allowsMultipleSelection = YES;
    self.title = @"选择备份";
    self.navigationItem.rightBarButtonItems = @[_allItem, _deleteItem, _doneItem];
    [self updateBackupSelectionBar];
    [self.tableView reloadData];
}

- (void)exitBackupSelection
{
    if (!_selectingBackups) return;
    _selectingBackups = NO;
    [_selectedBackups removeAllObjects];
    self.tableView.allowsMultipleSelection = NO;
    self.refreshControl.enabled = YES;
    self.title = _baseTitle;
    self.navigationItem.rightBarButtonItems = _backupStorage ? @[_selectItem, _menuItem] : nil;
    if (!_backupStorage) self.navigationItem.rightBarButtonItem = _menuItem;
    [self.tableView reloadData];
    [self updateBackupSelectionAvailability];
}

- (void)selectAllBackups
{
    NSArray<NSString *> *paths = [self backupUnitPathsInItems];
    [_selectedBackups addObjectsFromArray:paths];
    [self updateBackupSelectionBar];
    [self.tableView reloadData];
}

- (void)deleteSelectedBackups
{
    NSArray<NSString *> *paths = [_selectedBackups.allObjects sortedArrayUsingSelector:@selector(compare:)];
    if (paths.count == 0) return;
    NSString *message = [NSString stringWithFormat:
        @"This permanently removes %lu complete backup%@ and everything inside them. It cannot be undone.",
        (unsigned long)paths.count, paths.count == 1 ? @"" : @"s"];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Delete backups?"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
                                              handler:^(UIAlertAction *__unused a) {
        [self exitBackupSelection];
        [self runIO:^BOOL(NSString **error) {
            NSString *first = nil;
            for (NSString *path in paths) {
                NSString *failure = nil;
                if (!wq_delete_backup(path, &failure) && first == nil)
                    first = failure ?: @"Could not remove a backup.";
            }
            if (first) {
                if (error) *error = [NSString stringWithFormat:@"%@ Some selected backups may still exist.", first];
                return NO;
            }
            return YES;
        } failure:@"无法删除备份"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

// Pull to refresh: container lists are scanned again instead of reused.
- (void)userRefresh
{
    wq_enumerate_invalidate();
    wq_display_names_reset_miss();
    [self reload];
}

- (void)reload
{
    [_scanCancellation cancel];
    WQScanCancellation *cancellation = [WQScanCancellation new];
    _scanCancellation = cancellation;
    NSUInteger generation = ++_scanGeneration;
    _scanInFlight = YES;
    _scanNeedsRefresh = NO;
    _scanStatus = nil;
    [self.refreshControl endRefreshing];
    [self updateHeader];
    NSString *path = _path;
    BOOL labels = _labels;
    BOOL enumerable = [@[@"/private/var/mobile/Containers/Data/Application",
                         @"/var/mobile/Containers/Data/Application",
                         @"/private/var/mobile/Containers/Data/PluginKitPlugin",
                         @"/var/mobile/Containers/Data/PluginKitPlugin",
                         @"/private/var/mobile/Containers/Data/InternalDaemon",
                         @"/var/mobile/Containers/Data/InternalDaemon",
                         // Listable on iOS 27; on iOS 26 only by scanning.
                         @"/private/var/mobile/Containers/Shared/AppGroup",
                         @"/var/mobile/Containers/Shared/AppGroup"] containsObject:path];
    dispatch_async(wq_io(), ^{
        NSString *error = nil;
        NSArray *names = wq_list(path, &error);
        NSArray *childPaths = nil;
        // Parent gives no token on 27.x: discover children with fsgetpath.
        if (!names && enumerable && !cancellation.isCancelled) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                self->_scanStatus = @"Scanning inodes…";
                [self updateHeader];
            });
            CFAbsoluteTime scanStarted = CFAbsoluteTimeGetCurrent();
            childPaths = wq_enumerate(path, 0, cancellation, ^(int64_t done, int64_t total, NSUInteger __unused f) {
                // Time left, once the rate is known: an iOS 26 id scan can take most of an hour.
                double elapsed = CFAbsoluteTimeGetCurrent() - scanStarted;
                NSString *left = @"";
                if (elapsed > 5 && done > 0 && done < total) {
                    double remaining = elapsed * (double)(total - done) / (double)done;
                    left = remaining >= 90 ? [NSString stringWithFormat:@" · about %.0f min left", ceil(remaining / 60)]
                                           : @" · less than 2 min left";
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                    self->_scanStatus = [NSString stringWithFormat:@"Scanning inodes… %lld%% · %lu found%@",
                                         total ? (long long)(done * 100 / total) : 0, (unsigned long)f, left];
                    [self updateHeader];
                });
            });
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                self->_scanStatus = nil;
                [self updateHeader];
            });
        }
        if (cancellation.isCancelled) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self->_scanGeneration) return;
                self->_scanInFlight = NO;
                self->_scanNeedsRefresh = YES;
                self->_scanStatus = nil;
                [self.refreshControl endRefreshing];
                [self updateHeader];
            });
            return;
        }
        NSMutableArray<WQItem *> *items = [NSMutableArray new];
        NSUInteger labelIssues = 0;
        NSArray *entries = names ?: childPaths;
        BOOL haveFullPaths = names == nil;
        NSUInteger entryIndex = 0, entryCount = entries.count;
        for (NSString *entry in entries) {
            entryIndex++;
            // Each container needs a token and its identifier: hundreds take a
            // few seconds, so show where it is.
            if (haveFullPaths && (entryIndex == 1 || entryIndex % 10 == 0)) {
                NSUInteger shown = entryIndex;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                    self->_scanStatus = [NSString stringWithFormat:@"Reading containers… %lu of %lu",
                                         (unsigned long)shown, (unsigned long)entryCount];
                    [self updateHeader];
                });
            }
            if (cancellation.isCancelled) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != self->_scanGeneration) return;
                    self->_scanInFlight = NO;
                    self->_scanNeedsRefresh = YES;
                    self->_scanStatus = nil;
                    [self.refreshControl endRefreshing];
                    [self updateHeader];
                });
                return;
            }
            WQItem *item = [WQItem new];
            item.name = haveFullPaths ? entry.lastPathComponent : entry;
            item.path = haveFullPaths ? entry : [path stringByAppendingPathComponent:entry];
            NSString *name = item.name;
            // Enumerated containers need a token before they can be stat'd.
            // Resolving hundreds of identifiers is the slow part, so reuse it.
            if (haveFullPaths) {
                item.isDir = YES;
                NSDictionary *cached = [WQContainerInfoCache() objectForKey:item.path];
                if (cached) {
                    item.bundleID = cached[@"bid"];
                    item.label = cached[@"label"];
                } else {
                    BOOL token = wq_grant(item.path);
                    NSString *bid = token ? wq_container_label(item.path) : nil;
                    item.bundleID = bid;
                    if (bid) (void)wq_app_icon(bid);   // warm the icon off the main thread
                    item.label = token ? (wq_display_name(bid) ?: bid ?: @"(no label)") : @"NO TOKEN";
                    // "NO TOKEN" can be temporary; only cache a resolved label.
                    if (token && item.label.length && ![item.label isEqualToString:@"NO TOKEN"])
                        [WQContainerInfoCache() setObject:@{@"bid": bid ?: @"", @"label": item.label}
                                                    forKey:item.path];
                    if (!token && labelIssues < 3) {
                        wq_log(@"label: no token for %@", item.path);
                        labelIssues++;
                    } else if (token && !bid.length && labelIssues < 3) {
                        wq_log(@"label: no container identifier for %@", item.path);
                        labelIssues++;
                    }
                }
            }
            struct stat st;
            if (lstat(item.path.fileSystemRepresentation, &st) == 0) {
                item.isLink = S_ISLNK(st.st_mode);
                item.isDir = S_ISDIR(st.st_mode);
                item.isRegular = S_ISREG(st.st_mode);
                item.size = (unsigned long long)st.st_size;
                item.mode = st.st_mode;
                item.uid = st.st_uid;
                item.modified = [NSDate dateWithTimeIntervalSince1970:st.st_mtimespec.tv_sec];
                item.created = [NSDate dateWithTimeIntervalSince1970:st.st_birthtimespec.tv_sec];
            }
            if (!haveFullPaths && labels && item.isDir && wq_looks_like_uuid(name)) {
                NSString *bid = wq_container_label(item.path);
                item.bundleID = bid;
                if (bid) (void)wq_app_icon(bid);   // warm the icon off the main thread
                item.label = wq_display_name(bid) ?: bid;
            }
            if (!haveFullPaths && item.isDir && !item.bundleID) {
                // App backups: AppBackups/<bundle id>/...
                if ([path.lastPathComponent isEqualToString:@"AppBackups"]) {
                    item.bundleID = name;
                    item.label = wq_display_name(name) ?: name;
                }
                // File backups mirror the original path; label container UUIDs
                // from the live container they came from.
                NSString *live = wq_backup_original_path(item.path);
                if (live && wq_looks_like_uuid(name)) {
                    NSString *bid = wq_container_label(live);
                    if (bid) { item.bundleID = bid; item.label = wq_display_name(bid) ?: bid; (void)wq_app_icon(bid); }
                }
                if ([path isEqualToString:wq_backup_root().stringByDeletingLastPathComponent]) {
                    if ([name isEqualToString:@"备份"]) item.label = @"文件备份";
                    if ([name isEqualToString:@"AppBackups"]) item.label = @"应用备份";
                }
            }
            [items addObject:item];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_scanGeneration) return;
            self->_scanInFlight = NO;
            if (cancellation.isCancelled) {
                self->_scanNeedsRefresh = YES;
                self->_scanStatus = nil;
                [self.refreshControl endRefreshing];
                [self updateHeader];
                return;
            }
            self->_all = items;
            [self applyFilter];
            self->_error = (names || childPaths != nil) ? nil
                : (error.length ? error
                   : wq_full_scan_was_declined() ? @"Not listed yet: this needs a scan of all files. Pull down to start it."
                   : @"Cannot list this folder. Container enumeration failed; see Log.");
            self->_scanStatus = nil;
            self->_lastReloadFinished = NSDate.date.timeIntervalSinceReferenceDate;
            [self.refreshControl endRefreshing];
            [self updateHeader];
            [self.tableView reloadData];
            [self updateBackupSelectionAvailability];
            if (self->_selectingBackups) [self updateBackupSelectionBar];
        });
    });
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return _error ? 1 : (NSInteger)_items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"item"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"item"];
    UIListContentConfiguration *c = cell.defaultContentConfiguration;
    if (_error) {
        c.text = @"无法打开此文件夹";
        BOOL container = [_path containsString:@"/Containers/"] || [_path containsString:@"/SystemGroup/"];
        c.secondaryText = container ? _error
            : [NSString stringWithFormat:@"%@\n\n此方法只能打开容器。请在 /private/var 内使用应用数据、应用组、扩展数据、内部守护进程或系统组。", _error];
        c.secondaryTextProperties.numberOfLines = 0;
        c.textProperties.color = WQColorText();
        c.secondaryTextProperties.color = WQColorText2();
        c.image = WQLinearIcon(@"info.circle");
        c.imageProperties.tintColor = WQColorText2();
        cell.contentConfiguration = c;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    WQItem *item = _items[(NSUInteger)indexPath.row];
    c.text = item.label ?: item.name;
    BOOL byCreated = wq_sort_key() == WQSortCreated;
    NSString *date = wq_folder_date_text(byCreated ? item.created : item.modified);
    if (byCreated) date = [@"created " stringByAppendingString:date];
    NSString *detail = item.isDir ? date : [NSString stringWithFormat:@"%@ · %@", wq_size_text(item.size), date];
    if (item.label) detail = [NSString stringWithFormat:@"%@\n%@", item.name, detail];
    if (item.isLink) detail = [@"symlink · " stringByAppendingString:detail];
    c.secondaryText = detail;
    c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    UIImage *appIcon = item.bundleID ? wq_app_icon(item.bundleID) : nil;
    c.image = appIcon ?: [UIImage systemImageNamed:item.isDir ? @"folder.fill" : (item.isLink ? @"link" : @"doc")];
    if (appIcon) c.imageProperties.maximumSize = CGSizeMake(36, 36);
    cell.contentConfiguration = c;
    if (_selectingBackups) {
        BOOL selectable = wq_backup_unit_deletable(item.path);
        cell.accessoryType = selectable && [_selectedBackups containsObject:item.path]
            ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.selectionStyle = selectable ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    } else {
        cell.accessoryType = item.isDir ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return cell;
}

- (NSIndexPath *)tableView:(UITableView *)tableView willSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (_error || indexPath.section != 0 || (NSUInteger)indexPath.row >= _items.count) return nil;
    if (!_selectingBackups) return indexPath;
    WQItem *item = _items[(NSUInteger)indexPath.row];
    return wq_backup_unit_deletable(item.path) ? indexPath : nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (_selectingBackups) {
        if (indexPath.section != 0 || (NSUInteger)indexPath.row >= _items.count) return;
        WQItem *selected = _items[(NSUInteger)indexPath.row];
        if (!wq_backup_unit_deletable(selected.path)) return;
        [_selectedBackups addObject:selected.path];
        [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
        [self updateBackupSelectionBar];
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_error) return;
    if (indexPath.section != 0 || (NSUInteger)indexPath.row >= _items.count) return;
    WQItem *item = _items[(NSUInteger)indexPath.row];
    UIViewController *next;
    if (item.isLink) {
        wq_alert(self, @"符号链接",
                 @"WQ Files 查看、分享和编辑时不跟随符号链接。如需打开目标，请显式使用拷贝路径。");
        return;
    }
    if (item.isDir) {
        WQDirViewController *dir = [[WQDirViewController alloc] initWithPath:item.path title:item.label ?: item.name];
        dir.readOnly = self.readOnly;
        next = dir;
    } else {
        if (!item.isRegular) {
            wq_alert(self, @"无法打开此项目", item.isLink
                     ? @"Symbolic links are not followed for viewing, sharing or editing."
                     : @"只能查看普通文件。");
            return;
        }
        _scanNeedsRefresh = YES;
        wq_open_file(self.navigationController, item.path, self.readOnly, WQOpenAuto);
        return;
    }
    [self.navigationController pushViewController:next animated:YES];
}

- (void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (!_selectingBackups) return;
    if (indexPath.section != 0 || (NSUInteger)indexPath.row >= _items.count) return;
    WQItem *item = _items[(NSUInteger)indexPath.row];
    [_selectedBackups removeObject:item.path];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    [self updateBackupSelectionBar];
}

// Swipe left or right to delete, with the same rules and confirmation as the
// long-press menu (files are backed up first; backups only as whole units).
- (UISwipeActionsConfiguration *)deleteSwipeForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (_selectingBackups || _error) return nil;
    if (indexPath.section != 0 || (NSUInteger)indexPath.row >= _items.count) return nil;
    WQItem *item = _items[(NSUInteger)indexPath.row];
    BOOL backupUnit = item.isDir && wq_backup_unit_deletable(item.path);
    BOOL regular = !self.readOnly && !_backupStorage;
    if (!backupUnit && !regular) return nil;
    NSString *itemPath = [item.path copy];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *action = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"删除" handler:^(UIContextualAction *__unused a, UIView *__unused view, void (^done)(BOOL)) {
        WQDirViewController *strongSelf = weakSelf;
        WQItem *current = nil;
        if (strongSelf && (NSUInteger)indexPath.row < strongSelf->_items.count &&
            [strongSelf->_items[(NSUInteger)indexPath.row].path isEqualToString:itemPath])
            current = strongSelf->_items[(NSUInteger)indexPath.row];
        // The row stays until the confirmed delete reloads the folder.
        done(NO);
        if (!current) return;
        if (backupUnit) [strongSelf confirmDeleteBackup:current];
        else [strongSelf confirmDelete:current];
    }];
    action.image = [UIImage systemImageNamed:@"trash"];
    UISwipeActionsConfiguration *config = [UISwipeActionsConfiguration configurationWithActions:@[action]];
    config.performsFirstActionWithFullSwipe = YES;
    return config;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return [self deleteSwipeForRowAtIndexPath:indexPath];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return [self deleteSwipeForRowAtIndexPath:indexPath];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point
{
    if (_selectingBackups || _error) return nil;
    if (indexPath.section != 0 || (NSUInteger)indexPath.row >= _items.count) return nil;
    WQItem *item = _items[(NSUInteger)indexPath.row];
    NSString *itemPath = [item.path copy];
    __weak typeof(self) weakSelf = self;
    WQItem *(^currentItem)(void) = ^WQItem *{
        WQDirViewController *strongSelf = weakSelf;
        if (!strongSelf || indexPath.section != 0 || (NSUInteger)indexPath.row >= strongSelf->_items.count) return nil;
        WQItem *current = strongSelf->_items[(NSUInteger)indexPath.row];
        return [current.path isEqualToString:itemPath] ? current : nil;
    };
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
        actionProvider:^UIMenu *(NSArray<UIMenuElement *> *__unused suggested) {
        WQItem *current = currentItem();
        WQDirViewController *strongSelf = weakSelf;
        if (!current || !strongSelf) return nil;
        NSMutableArray *actions = [NSMutableArray new];
        if (current.isDir) {
            [actions addObject:[UIAction actionWithTitle:@"Share as ZIP (AirDrop…)" image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                              identifier:nil handler:^(UIAction *__unused a) {
                WQItem *latest = currentItem();
                UITableViewCell *cell = [weakSelf.tableView cellForRowAtIndexPath:indexPath];
                if (latest && weakSelf) wq_share_folder(weakSelf, latest.path, nil, cell);
            }]];
        }
        if (!current.isDir && current.isRegular) {
            [actions addObject:[UIAction actionWithTitle:@"Share" image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                              identifier:nil handler:^(UIAction *__unused a) {
                WQItem *latest = currentItem();
                UITableViewCell *cell = [weakSelf.tableView cellForRowAtIndexPath:indexPath];
                if (latest && weakSelf) wq_share(weakSelf, latest.path, cell);
            }]];
            NSString *original = wq_backup_original_path(current.path);
            if (original) {
                [actions addObject:[UIAction actionWithTitle:@"Restore to Original Location"
                                                       image:[UIImage systemImageNamed:@"arrow.uturn.backward"]
                                                  identifier:nil handler:^(UIAction *__unused a) {
                    WQItem *latest = currentItem();
                    if (latest && weakSelf) [weakSelf restoreBackup:latest.path to:original];
                }]];
            }
        }
        if (!current.isDir && current.isRegular) {
            BOOL ro = weakSelf.readOnly;
            [actions addObject:[UIMenu menuWithTitle:@"Open As" image:[UIImage systemImageNamed:@"arrow.up.forward.app"] identifier:nil
                                             options:0 children:@[
                [UIAction actionWithTitle:@"Plist Editor" image:[UIImage systemImageNamed:@"list.bullet.indent"] identifier:nil
                                  handler:^(UIAction *__unused a) { WQDirViewController *strongSelf = weakSelf; WQItem *latest = currentItem(); if (strongSelf && latest) wq_open_file(strongSelf.navigationController, latest.path, ro, WQOpenPlist); }],
                [UIAction actionWithTitle:@"Text / Image" image:[UIImage systemImageNamed:@"doc.plaintext"] identifier:nil
                                  handler:^(UIAction *__unused a) { WQDirViewController *strongSelf = weakSelf; WQItem *latest = currentItem(); if (strongSelf && latest) wq_open_file(strongSelf.navigationController, latest.path, ro, WQOpenText); }],
                [UIAction actionWithTitle:@"十六进制查看器" image:[UIImage systemImageNamed:@"number"] identifier:nil
                                  handler:^(UIAction *__unused a) { WQDirViewController *strongSelf = weakSelf; WQItem *latest = currentItem(); if (strongSelf && latest) wq_open_file(strongSelf.navigationController, latest.path, ro, WQOpenHex); }],
                [UIAction actionWithTitle:@"SQLite Viewer" image:[UIImage systemImageNamed:@"tablecells"] identifier:nil
                                  handler:^(UIAction *__unused a) { WQDirViewController *strongSelf = weakSelf; WQItem *latest = currentItem(); if (strongSelf && latest) wq_open_file(strongSelf.navigationController, latest.path, ro, WQOpenSQLite); }],
            ]]];
        }
        [actions addObject:[UIAction actionWithTitle:@"拷贝路径" image:[UIImage systemImageNamed:@"doc.on.doc"]
                                          identifier:nil handler:^(UIAction *__unused a) {
            WQItem *latest = currentItem();
            if (latest) UIPasteboard.generalPasteboard.string = latest.path;
        }]];
        if (current.label) {
            [actions addObject:[UIAction actionWithTitle:@"拷贝标识" image:[UIImage systemImageNamed:@"tag"]
                                              identifier:nil handler:^(UIAction *__unused a) {
                WQItem *latest = currentItem();
                if (latest) UIPasteboard.generalPasteboard.string = latest.bundleID ?: latest.label;
            }]];
        }
        if (current.isDir && wq_backup_unit_deletable(current.path)) {
            UIAction *remove = [UIAction actionWithTitle:@"删除备份…" image:[UIImage systemImageNamed:@"trash"]
                                              identifier:nil handler:^(UIAction *__unused a) {
                WQItem *latest = currentItem();
                if (latest) [weakSelf confirmDeleteBackup:latest];
            }];
            remove.attributes = UIMenuElementAttributesDestructive;
            [actions addObject:remove];
        }
        if (!strongSelf.readOnly && !strongSelf->_backupStorage) {
            [actions addObject:[UIAction actionWithTitle:@"重命名" image:[UIImage systemImageNamed:@"pencil"]
                                              identifier:nil handler:^(UIAction *__unused a) { WQItem *latest = currentItem(); if (latest) [weakSelf promptRename:latest]; }]];
            UIAction *del = [UIAction actionWithTitle:@"删除" image:[UIImage systemImageNamed:@"trash"]
                                           identifier:nil handler:^(UIAction *__unused a) { WQItem *latest = currentItem(); if (latest) [weakSelf confirmDelete:latest]; }];
            del.attributes = UIMenuElementAttributesDestructive;
            [actions addObject:del];
        }
        return [UIMenu menuWithChildren:actions];
    }];
}

#pragma mark Actions

- (void)runIO:(BOOL (^)(NSString **error))work failure:(NSString *)failureTitle
{
    dispatch_async(wq_io(), ^{
        NSString *error = nil;
        BOOL ok = work(&error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) wq_alert(self, failureTitle, error ?: @"Unknown error");
            [self reload];
        });
    });
}

- (void)promptNewFolder
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"新建文件夹" message:_path
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = @"Name"; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"创建" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
        NSString *name = alert.textFields.firstObject.text;
        if (name.length == 0 || [name containsString:@"/"]) return;
        NSString *path = [self->_path stringByAppendingPathComponent:name];
        [self runIO:^BOOL(NSString **error) { return wq_create_dir(path, error); } failure:@"无法创建文件夹"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)promptRename:(WQItem *)item
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重命名" message:item.path
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) { f.text = item.name; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"重命名" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
        NSString *name = alert.textFields.firstObject.text;
        [self runIO:^BOOL(NSString **error) { return wq_rename(item.path, name, error); } failure:@"无法重命名"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmDeleteBackup:(WQItem *)item
{
    BOOL bundle = [item.path.stringByDeletingLastPathComponent isEqualToString:wq_app_backup_root()];
    NSString *message = bundle
        ? [NSString stringWithFormat:@"%@\n\n将移除该应用的全部备份，无法撤销。", item.path]
        : [NSString stringWithFormat:@"%@\n\n将移除所选备份，无法撤销。", item.path];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"删除备份？"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self runIO:^BOOL(NSString **error) { return wq_delete_backup(item.path, error); } failure:@"无法删除备份"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmDelete:(WQItem *)item
{
    BOOL recursive = item.isDir && WQSettingBool(WQSettingDeleteTreeKey, NO);
    NSString *message;
    if (item.isLink) {
        message = [NSString stringWithFormat:@"%@\n\n仅移除符号链接本身，不改动其目标。", item.path];
    } else if (item.isDir) {
        message = recursive
            ? [NSString stringWithFormat:@"%@\n\n将删除该文件夹及其全部内容。不保留备份，且无法撤销。", item.path]
            : [NSString stringWithFormat:@"%@\n\n只能删除空文件夹。", item.path];
    } else if (item.isRegular) {
        message = [NSString stringWithFormat:@"%@\n\n会在备份中保留一份副本。", item.path];
    } else {
        message = [NSString stringWithFormat:@"%@\n\n此特殊文件将被移除，不保留备份。", item.path];
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"删除「%@」？", item.name]
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self runIO:^BOOL(NSString **error) {
            return recursive ? wq_delete_tree(item.path, error) : wq_delete(item.path, error);
        } failure:@"无法删除"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)restoreBackup:(NSString *)backup to:(NSString *)original
{
    NSString *message = [NSString stringWithFormat:@"将这份备份写回\n%@？\n\n若该位置已有文件，会先为它保留一份副本。", original];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"还原" message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"还原" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self runIO:^BOOL(NSString **error) {
            struct stat st;
            return wq_stat(original, &st) ? wq_write_from_file(original, backup, error)
                                          : wq_create_file_from(original, backup, error);
        } failure:@"还原失败"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)importFile
{
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    // The picker hands over a local copy (asCopy). It is streamed into place,
    // never read into memory, and the existence check runs off the main thread.
    NSString *source = urls.firstObject.path;
    if (!source) return;
    NSString *dest = [_path stringByAppendingPathComponent:source.lastPathComponent];
    void (^cleanup)(void) = ^{ [NSFileManager.defaultManager removeItemAtPath:source error:nil]; };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        struct stat st;
        BOOL exists = wq_stat(dest, &st);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!exists) {
                [self runIO:^BOOL(NSString **error) {
                    BOOL ok = wq_create_file_from(dest, source, error);
                    cleanup();
                    return ok;
                } failure:@"导入失败"];
                return;
            }
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Replace existing file?"
                message:[NSString stringWithFormat:@"%@ already exists. It is backed up before being replaced.", dest]
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
                                                    handler:^(UIAlertAction *__unused a) { cleanup(); }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"Replace" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
                [self runIO:^BOOL(NSString **error) {
                    BOOL ok = wq_write_from_file(dest, source, error);
                    cleanup();
                    return ok;
                } failure:@"导入失败"];
            }]];
            [self presentViewController:alert animated:YES completion:nil];
        });
    });
}

@end

#pragma mark - System groups

// The SystemGroup parent gets no token on 27.0.1, so it cannot be listed.
// Known container names are checked one by one (lstat works without access).
@interface WQSystemGroupsViewController : UITableViewController
@end

@implementation WQSystemGroupsViewController {
    NSArray<NSString *> *_names;
    BOOL _listed;
}

static NSString *const kSystemGroupRoot = @"/private/var/containers/Shared/SystemGroup";

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"System Groups";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                                           target:self action:@selector(tryName)];
    dispatch_async(wq_io(), ^{
        NSArray *listed = wq_list(kSystemGroupRoot, NULL);
        NSArray *names = listed;
        if (!names) {
            NSArray *known = @[
                @"systemgroup.com.apple.configurationprofiles", @"systemgroup.com.apple.mobilegestaltcache",
                @"systemgroup.com.apple.osanalytics", @"systemgroup.com.apple.lsd.iconscache",
                @"systemgroup.com.apple.lsd.identifiers", @"systemgroup.com.apple.ManagedSettings",
                @"systemgroup.com.apple.sharedpclogging", @"systemgroup.com.apple.media.shared.books",
                @"systemgroup.com.apple.nsurlstoragedresources", @"systemgroup.com.apple.pisco.suinfo",
                @"systemgroup.com.apple.icloud.findmydevice.managed", @"systemgroup.com.apple.mobilestoragemounter",
                @"systemgroup.com.apple.mobileactivationd", @"systemgroup.com.apple.sensorkit",
                @"systemgroup.com.apple.powerlog", @"systemgroup.com.apple.diagnosticextensionsd",
                @"systemgroup.com.apple.mediaanalysisd", @"systemgroup.com.apple.translationd",
                @"systemgroup.com.apple.chronod", @"systemgroup.com.apple.coreaudio",
                @"systemgroup.com.apple.ManagedConfiguration.ExternalTrust", @"systemgroup.com.apple.cfprefsd",
            ];
            NSMutableArray *found = [NSMutableArray new];
            for (NSString *name in known) {
                struct stat st;
                NSString *p = [kSystemGroupRoot stringByAppendingPathComponent:name];
                if (lstat(p.fileSystemRepresentation, &st) == 0) [found addObject:name];
            }
            names = found;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_listed = listed != nil;
            self->_names = [names sortedArrayUsingSelector:@selector(compare:)];
            [self.tableView reloadData];
        });
    });
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (!_names) return @"Loading…";
    return _listed ? nil : @"This folder cannot be listed on this iOS version. Known names that exist are shown; tap + to try another name.";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)_names.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"g"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"g"];
    UIListContentConfiguration *c = cell.defaultContentConfiguration;
    c.text = [_names[(NSUInteger)indexPath.row] stringByReplacingOccurrencesOfString:@"systemgroup." withString:@""];
    c.image = [UIImage systemImageNamed:@"folder.fill"];
    cell.contentConfiguration = c;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *name = _names[(NSUInteger)indexPath.row];
    [self.navigationController pushViewController:[[WQDirViewController alloc]
        initWithPath:[kSystemGroupRoot stringByAppendingPathComponent:name] title:nil] animated:YES];
}

- (void)tryName
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Open System Group" message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = @"systemgroup.com.apple.";
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"打开" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
        NSString *name = alert.textFields.firstObject.text;
        if (name.length == 0 || [name containsString:@"/"]) return;
        NSString *path = [kSystemGroupRoot stringByAppendingPathComponent:name];
        struct stat st;
        if (lstat(path.fileSystemRepresentation, &st) != 0) {
            wq_alert(self, @"未找到", path);
            return;
        }
        [self.navigationController pushViewController:[[WQDirViewController alloc] initWithPath:path title:nil] animated:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Log

@interface WQLogViewController : UIViewController
@end

@implementation WQLogViewController {
    UITextView *_textView;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"日志";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    _textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _textView.editable = NO;
    _textView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    [self.view addSubview:_textView];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                                                           target:self action:@selector(share:)];
}

// App version, device and iOS first, so a Log someone sends in says where it
// came from.
- (NSString *)fullLog
{
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    return [NSString stringWithFormat:@"WQ Files %@ (%@)\n%@\n\n%@",
            info[@"CFBundleShortVersionString"] ?: @"?", info[@"CFBundleVersion"] ?: @"?", wq_device_line(), wq_log_text()];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    _textView.text = [self fullLog];
}

- (void)share:(UIBarButtonItem *)sender
{
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[[self fullLog]]
                                                                        applicationActivities:nil];
    share.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:share animated:YES completion:nil];
}

@end

#pragma mark - Navigation

// Adds a Home button next to Back on screens two or more levels deep. Editors
// guard Back, Home and the interactive edge swipe through WQUnsavedEditing.
@interface WQNavigationController : UINavigationController <UINavigationControllerDelegate, UIGestureRecognizerDelegate>
@end

@implementation WQNavigationController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.delegate = self;
    self.interactivePopGestureRecognizer.delegate = self;

    // iOS 26+ gives bars the Liquid Glass material automatically, but an
    // appearance with an opaque background would replace it. Use the system
    // default for both states and keep the whole chrome neutral.
    UINavigationBar *bar = self.navigationBar;
    UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
    [appearance configureWithDefaultBackground];
    appearance.titleTextAttributes = @{NSForegroundColorAttributeName: WQColorText()};
    appearance.largeTitleTextAttributes = @{NSForegroundColorAttributeName: WQColorText()};
    bar.standardAppearance = appearance;
    bar.scrollEdgeAppearance = appearance;
    bar.compactAppearance = appearance;
    bar.tintColor = WQColorText();
}

- (void)navigationController:(UINavigationController *)nav willShowViewController:(UIViewController *)vc animated:(BOOL)animated
{
    NSUInteger depth = [nav.viewControllers indexOfObject:vc];
    if (depth == NSNotFound || depth < 2) {
        if (vc.navigationItem.leftBarButtonItem.tag == 0x484f4d45) vc.navigationItem.leftBarButtonItem = nil;
        return;
    }
    if (vc.navigationItem.leftBarButtonItem) return;
    UIBarButtonItem *home = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"house"]
                                                             style:UIBarButtonItemStylePlain target:self action:@selector(goHome)];
    home.tag = 0x484f4d45;   // "HOME"
    home.accessibilityLabel = @"Home";
    vc.navigationItem.leftItemsSupplementBackButton = YES;
    vc.navigationItem.leftBarButtonItem = home;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer
{
    if (gestureRecognizer != self.interactivePopGestureRecognizer) return YES;
    if (self.viewControllers.count <= 1) return NO;
    UIViewController<WQUnsavedEditing> *editor = (UIViewController<WQUnsavedEditing> *)self.topViewController;
    if (![editor conformsToProtocol:@protocol(WQUnsavedEditing)] || !editor.wq_needsLeaveConfirmation) return YES;
    __weak typeof(self) weakSelf = self;
    [editor confirmLeaveThen:^{ [weakSelf popViewControllerAnimated:YES]; }];
    return NO;
}

- (void)goHome
{
    UIViewController<WQUnsavedEditing> *top = (UIViewController<WQUnsavedEditing> *)self.topViewController;
    __weak typeof(self) weakSelf = self;
    void (^home)(void) = ^{ [weakSelf popToRootViewControllerAnimated:YES]; };
    if ([top conformsToProtocol:@protocol(WQUnsavedEditing)]) [top confirmLeaveThen:home];
    else home();
}

@end

#pragma mark - Settings and path form

static BOOL WQSettingBool(NSString *key, BOOL fallback)
{
    return WQSettingGet(key, fallback);
}

static void WQSettingSetBool(NSString *key, BOOL value)
{
    WQSettingPut(key, value);
}

// Each row is one line: label on the left, control or value on the right.
// Actions carry a numeric tag; dynamic rows recompute their value on reload.
typedef NS_ENUM(NSInteger, WQSettingAction) {
    WQSettingActionClearStaging  = 1,
    WQSettingActionClearCache    = 2,
    WQSettingActionOpenBackups   = 3,
    WQSettingActionClearPaths    = 4,
    WQSettingActionResetAll      = 5,
};

@interface WQSettingRow : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *value;
@property (nonatomic) BOOL isSwitch;
@property (nonatomic) BOOL isAction;
@property (nonatomic) BOOL tappable;
@property (nonatomic) WQSettingAction action;
@end

@implementation WQSettingRow
@end

static WQSettingRow *WQSwitchRow(NSString *title, NSString *key)
{
    WQSettingRow *row = [WQSettingRow new];
    row.title = title;
    row.key = key;
    row.isSwitch = YES;
    return row;
}

static WQSettingRow *WQValueRow(NSString *title, NSString *value)
{
    WQSettingRow *row = [WQSettingRow new];
    row.title = title;
    row.value = value;
    return row;
}

static WQSettingRow *WQDynamicRow(NSString *title, NSString *key)
{
    WQSettingRow *row = WQValueRow(title, @"");
    row.key = key;
    return row;
}

static WQSettingRow *WQTapRow(NSString *title, NSString *key)
{
    WQSettingRow *row = WQDynamicRow(title, key);
    row.tappable = YES;
    return row;
}

static WQSettingRow *WQActionRow(NSString *title, NSString *buttonTitle, WQSettingAction action)
{
    WQSettingRow *row = [WQSettingRow new];
    row.title = title;
    row.value = buttonTitle;
    row.isAction = YES;
    row.action = action;
    return row;
}

// Settings are single rows: label on the left, control on the right, no outer
// card, generous space between groups, and dangerous actions isolated last.
@interface WQSettingsViewController : UITableViewController
@end

@implementation WQSettingsViewController {
    NSArray<NSString *> *_titles;
    NSArray<NSString *> *_footers;
    NSArray<NSArray<WQSettingRow *> *> *_rows;
}

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
        self.title = @"设置";
        _titles = @[@"访问范围", @"性能", @"存储与缓存", @"界面", @"文件操作", @"危险操作"];
        _footers = @[
            @"全部应用数据会遍历整棵容器目录树。若 iOS 27.0 上系统数据打不开、或列表一直停在扫描，请开启兼容模式并彻底退出后重开：它会隐藏系统区域，改用 iOS 26 的授权方式与容器列表。切换后需重启才能完全生效。",
            @"快速目录读取用一次目录遍历拿到子文件夹，避免逐个子项授权；并行写入同时处理多个资源文件；检测缓存复用已解析的应用标识。列表缓存时长决定返回页面时是否重读目录。全部开关即时生效。",
            @"注入暂存是导入后、写入前的临时副本。正常写入会自动清理，异常退出可能留下残留。备份不会被这里的清理操作删除。",
            @"液态玻璃只用于导航栏、主入口、按钮与输入控件，内容列表保持平面。关闭后改用中性平面材质；系统开启「降低透明度」时也会自动降级。配色、圆角与间距仍由统一设计变量固定。",
            @"递归删除会清空目录内容，且不逐份保留备份。覆盖与保存校验由访问层固定开启，不提供关闭。",
            @"以下操作不可撤销。清空路径只移除本应用保存的记录，不会删除游戏目录里的文件；重置设置会恢复全部开关默认值，但保留备份与注入路径。",
        ];
        _rows = @[
            @[WQSwitchRow(@"显示全部应用数据", WQSettingShowAllDataKey),
              WQSwitchRow(@"兼容模式", WQSettingLegacyScopeKey),
              WQDynamicRow(@"当前运行模式", @"mode"),
              WQValueRow(@"数据根目录", @"/private/var/mobile/Containers/Data")],
            @[WQSwitchRow(@"快速目录读取", WQSettingFastDirKey),
              WQSwitchRow(@"并行写入资源", WQSettingParallelWriteKey),
              WQSwitchRow(@"缓存应用检测", WQSettingDetectCacheKey),
              WQTapRow(@"列表缓存时长", @"reloadAge")],
            @[WQDynamicRow(@"注入暂存", @"staging"),
              WQActionRow(@"清理注入暂存", @"清理", WQSettingActionClearStaging),
              WQDynamicRow(@"已保存注入路径", @"paths"),
              WQActionRow(@"清除检测缓存", @"清除", WQSettingActionClearCache),
              WQActionRow(@"打开备份", @"打开", WQSettingActionOpenBackups)],
            @[WQDynamicRow(@"材质", @"glassState"),
              WQSwitchRow(@"液态玻璃材质", WQGlassEnabledKey),
              WQValueRow(@"图标", @"线性"),
              WQValueRow(@"圆角", @"8 / 20 点"),
              WQValueRow(@"间距档位", @"4 点"),
              WQSwitchRow(@"紧凑行高", WQSettingCompactRowsKey)],
            @[WQSwitchRow(@"删除非空目录", WQSettingDeleteTreeKey),
              WQValueRow(@"覆盖前保留副本", @"开启"),
              WQValueRow(@"保存时校验版本", @"开启")],
            @[WQActionRow(@"清空所有注入路径", @"清空", WQSettingActionClearPaths),
              WQActionRow(@"重置全部设置", @"重置", WQSettingActionResetAll)],
        ];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.backgroundColor = WQColorBackground();
    self.tableView.separatorColor = WQColorLine();
    self.navigationController.navigationBar.prefersLargeTitles = NO;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (NSString *)dynamicValueForKey:(NSString *)key
{
    if ([key isEqualToString:@"mode"])
        return wq_legacy_scope() ? @"兼容模式"
            : (wq_system_areas_reachable() ? @"iOS 27 原生" : @"iOS 26 方式");
    if ([key isEqualToString:@"reloadAge"]) return WQSettingReloadAgeText();
    if ([key isEqualToString:@"glassState"])
        return !WQGlassEnabled() ? @"平面中性"
            : (WQGlassClassAvailable() ? @"系统液态玻璃" : @"系统材质（降级）");
    if ([key isEqualToString:@"staging"]) {
        NSUInteger n = WQGameStagingFileCount();
        return n ? [NSString stringWithFormat:@"%lu 个文件 · %@", (unsigned long)n,
                                              wq_size_text(WQGameStagingBytes())] : @"无残留";
    }
    if ([key isEqualToString:@"paths"])
        return [NSString stringWithFormat:@"%lu 条", (unsigned long)WQGameSavedPathCount()];
    return @"—";
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return (NSInteger)_titles.count; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)_rows[section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return _titles[section];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return _footers[section];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return WQSettingGet(WQSettingCompactRowsKey, NO) ? 38.0 : WQRowHeight;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    WQSettingRow *row = _rows[indexPath.section][indexPath.row];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"s"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"s"];
    cell.textLabel.text = row.title;
    cell.textLabel.font = WQFontBody();
    cell.textLabel.textColor = WQColorText();
    cell.selectionStyle = row.tappable ? UITableViewCellSelectionStyleDefault
                                       : UITableViewCellSelectionStyleNone;
    cell.backgroundColor = WQColorSurface();
    cell.detailTextLabel.text = nil;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    if (row.isSwitch) {
        UISwitch *control = [UISwitch new];
        BOOL defaultsOn = [row.key isEqualToString:WQSettingShowAllDataKey] ||
                          [row.key isEqualToString:WQSettingFastDirKey] ||
                          [row.key isEqualToString:WQSettingParallelWriteKey] ||
                          [row.key isEqualToString:WQSettingDetectCacheKey];
        control.on = [row.key isEqualToString:WQGlassEnabledKey]
            ? WQGlassEnabled() : WQSettingBool(row.key, defaultsOn);
        control.onTintColor = WQColorStrong();
        control.tag = indexPath.section * 100 + indexPath.row;
        [control addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = control;
    } else if (row.isAction) {
        UIButton *control = [UIButton buttonWithType:UIButtonTypeSystem];
        [control setTitle:row.value forState:UIControlStateNormal];
        BOOL strong = row.action == WQSettingActionClearPaths ||
                      row.action == WQSettingActionResetAll;
        if (strong) WQStylePrimaryButton(control);
        else {
            [control setTitleColor:WQColorText() forState:UIControlStateNormal];
            control.titleLabel.font = WQFontValue();
            WQStyleControl(control);
        }
        control.frame = CGRectMake(0, 0, 84, 32);
        control.tag = (NSInteger)row.action;
        [control addTarget:self action:@selector(actionTapped:) forControlEvents:UIControlEventTouchUpInside];
        cell.accessoryView = control;
    } else {
        cell.detailTextLabel.text = row.key.length ? [self dynamicValueForKey:row.key] : row.value;
        cell.detailTextLabel.font = WQFontValue();
        cell.detailTextLabel.textColor = WQColorText2();
        if (row.tappable) cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    WQSettingRow *row = _rows[indexPath.section][indexPath.row];
    if (!row.tappable) return;
    NSInteger idx = [NSUserDefaults.standardUserDefaults integerForKey:WQSettingReloadAgeIdxKey];
    [NSUserDefaults.standardUserDefaults setInteger:(idx + 1) % 3 forKey:WQSettingReloadAgeIdxKey];
    [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)switchChanged:(UISwitch *)sender
{
    NSUInteger section = (NSUInteger)(sender.tag / 100);
    NSUInteger index = (NSUInteger)(sender.tag % 100);
    if (section >= _rows.count || index >= _rows[section].count) return;
    WQSettingRow *row = _rows[section][index];
    WQSettingSetBool(row.key, sender.on);
    // The scope is read by the access layer immediately; the hidden entries go
    // away on the next appearance. Token flags cached earlier in this run need
    // a restart, which the group footer states.
    if ([row.key isEqualToString:WQSettingLegacyScopeKey]) wq_set_legacy_scope(sender.on);
    if ([row.key isEqualToString:WQSettingDetectCacheKey] && !sender.on) WQGameClearDetectionCache();
    if ([row.key isEqualToString:WQGlassEnabledKey]) {
        [self.tableView reloadData];
        wq_alert(self, @"材质已切换", @"新打开的页面会立即使用新材质；当前已加载的页面重新进入后生效。");
    }
    if ([row.key isEqualToString:WQSettingCompactRowsKey]) [self.tableView reloadData];
    wq_log(@"settings: %@ = %d", row.key, sender.on ? 1 : 0);
}

- (void)actionTapped:(UIButton *)sender
{
    switch ((WQSettingAction)sender.tag) {
        case WQSettingActionClearStaging:  [self clearStaging]; break;
        case WQSettingActionClearCache:    [self clearCache]; break;
        case WQSettingActionOpenBackups:   [self openBackups]; break;
        case WQSettingActionClearPaths:    [self clearPaths]; break;
        case WQSettingActionResetAll:      [self resetAll]; break;
    }
}

- (void)clearStaging
{
    NSUInteger n = WQGameStagingFileCount();
    if (!n) { wq_alert(self, @"无残留", @"注入暂存目录是空的。"); return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清理注入暂存"
        message:[NSString stringWithFormat:@"将删除 %lu 个暂存文件（%@）。它们只是导入后的临时副本，不会改动已写入游戏目录的文件，也不会删除备份。",
            (unsigned long)n, wq_size_text(WQGameStagingBytes())]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"清理" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *__unused a) {
            WQGameClearStaging();
            [weakSelf.tableView reloadData];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)clearCache
{
    WQGameClearDetectionCache();
    [WQContainerInfoCache() removeAllObjects];
    [self.tableView reloadData];
    wq_alert(self, @"已清除", @"应用检测与容器标识缓存已清空，下次进入会重新读取。");
}

- (void)openBackups
{
    [NSFileManager.defaultManager createDirectoryAtPath:wq_backup_root()
                           withIntermediateDirectories:YES attributes:nil error:nil];
    WQDirViewController *dir = [[WQDirViewController alloc] initWithPath:wq_backup_root() title:@"备份"];
    [self.navigationController pushViewController:dir animated:YES];
}

- (void)clearPaths
{
    NSUInteger n = WQGameSavedPathCount();
    if (!n) { wq_alert(self, @"没有记录", @"还没有保存任何注入路径。"); return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清空所有注入路径？"
        message:[NSString stringWithFormat:@"将移除 %lu 条记录。只影响本应用的快捷列表，不会删除游戏目录里的文件，也不会删除备份。此操作无法撤销。", (unsigned long)n]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *__unused a) {
            WQGameClearSavedPaths();
            [weakSelf.tableView reloadData];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)resetAll
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重置全部设置"
        message:@"全部开关恢复默认值，包含兼容模式、性能与界面选项。备份、注入暂存和已保存的注入路径都会保留。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"重置" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *__unused a) {
            NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
            for (NSString *key in @[WQSettingShowAllDataKey, WQSettingDeleteTreeKey,
                                    WQSettingLegacyScopeKey, WQSettingFastDirKey,
                                    WQSettingParallelWriteKey, WQSettingDetectCacheKey,
                                    WQSettingCompactRowsKey, WQSettingReloadAgeIdxKey,
                                    WQGlassEnabledKey])
                [defaults removeObjectForKey:key];
            wq_set_legacy_scope(NO);
            WQGameClearDetectionCache();
            [weakSelf.tableView reloadData];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

// Sequential form: label above a full-width field, with a fixed error slot.
@interface WQPathViewController : UIViewController
@end

@implementation WQPathViewController {
    UITextField *_field;
    UILabel *_hint;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"前往路径";
    self.view.backgroundColor = WQColorBackground();
    self.navigationController.navigationBar.prefersLargeTitles = NO;

    UIView *form = [UIView new];
    form.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:form];

    UILabel *label = [UILabel new];
    label.text = @"绝对路径";
    label.font = WQFontGroup();
    label.textColor = WQColorText2();
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [form addSubview:label];

    _field = [UITextField new];
    _field.text = @"/private/var/mobile/Containers/Data";
    _field.font = WQFontBody();
    _field.textColor = WQColorText();
    _field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _field.autocorrectionType = UITextAutocorrectionTypeNo;
    _field.clearButtonMode = UITextFieldViewModeAlways;
    _field.borderStyle = UITextBorderStyleNone;
    _field.translatesAutoresizingMaskIntoConstraints = NO;
    WQStyleControl(_field);
    _field.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, WQSpace3, 0)];
    _field.leftViewMode = UITextFieldViewModeAlways;
    _field.rightView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, WQSpace3, 0)];
    _field.rightViewMode = UITextFieldViewModeAlways;
    [form addSubview:_field];

    _hint = [UILabel new];
    _hint.font = WQFontCaption();
    _hint.textColor = WQColorText3();
    _hint.text = @"以 / 开头，且路径必须已存在";
    _hint.translatesAutoresizingMaskIntoConstraints = NO;
    [form addSubview:_hint];

    UIButton *open = [UIButton buttonWithType:UIButtonTypeSystem];
    [open setTitle:@"打开" forState:UIControlStateNormal];
    WQStylePrimaryButton(open);
    open.translatesAutoresizingMaskIntoConstraints = NO;
    [open addTarget:self action:@selector(openPath) forControlEvents:UIControlEventTouchUpInside];
    [form addSubview:open];

    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [form.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:WQGutter],
        [form.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-WQGutter],
        [form.topAnchor constraintEqualToAnchor:guide.topAnchor constant:WQSpace6],
        [label.topAnchor constraintEqualToAnchor:form.topAnchor],
        [label.leadingAnchor constraintEqualToAnchor:form.leadingAnchor],
        [_field.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:WQSpace2],
        [_field.leadingAnchor constraintEqualToAnchor:form.leadingAnchor],
        [_field.trailingAnchor constraintEqualToAnchor:form.trailingAnchor],
        [_field.heightAnchor constraintEqualToConstant:WQControlH],
        [_hint.topAnchor constraintEqualToAnchor:_field.bottomAnchor constant:WQSpace1],
        [_hint.leadingAnchor constraintEqualToAnchor:form.leadingAnchor],
        [_hint.heightAnchor constraintEqualToConstant:WQHintSpace],
        [open.topAnchor constraintEqualToAnchor:_hint.bottomAnchor constant:WQSpace4],
        [open.leadingAnchor constraintEqualToAnchor:form.leadingAnchor],
        [open.trailingAnchor constraintEqualToAnchor:form.trailingAnchor],
        [open.heightAnchor constraintEqualToConstant:WQControlH],
        [form.bottomAnchor constraintEqualToAnchor:open.bottomAnchor],
    ]];
}

- (void)openPath
{
    NSString *path = _field.text.stringByStandardizingPath;
    UILabel *hint = _hint;
    UINavigationController *nav = self.navigationController;
    if (![path hasPrefix:@"/"]) {
        hint.text = @"请输入以 / 开头的绝对路径";
        return;
    }
    hint.text = @"正在检查…";
    dispatch_async(wq_io(), ^{
        struct stat st;
        BOOL exists = wq_stat(path, &st);
        BOOL isDir = exists && S_ISDIR(st.st_mode);
        if (exists && S_ISLNK(st.st_mode)) {
            struct stat target;
            isDir = stat(path.fileSystemRepresentation, &target) == 0 && S_ISDIR(target.st_mode);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!exists) { hint.text = @"路径不存在"; return; }
            if (!isDir) { wq_open_file(nav, path, NO, WQOpenAuto); return; }
            [nav pushViewController:[[WQDirViewController alloc] initWithPath:path title:nil] animated:YES];
        });
    });
}

@end

#pragma mark - Root

// The single primary entry is a floating glass panel. It sits in the control
// layer (it navigates), so glass is appropriate here; content rows stay flat.
static UIView *WQRootGameBackground(void)
{
    UIView *outer = [UIView new];
    outer.backgroundColor = UIColor.clearColor;
    UIView *panel = WQGlassPanel(WQRadius4);
    [outer addSubview:panel];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [panel.leadingAnchor constraintEqualToAnchor:outer.leadingAnchor constant:WQGutter],
        [panel.trailingAnchor constraintEqualToAnchor:outer.trailingAnchor constant:-WQGutter],
        [panel.topAnchor constraintEqualToAnchor:outer.topAnchor constant:WQSpace2],
        [panel.bottomAnchor constraintEqualToAnchor:outer.bottomAnchor constant:-WQSpace2],
    ]];
    return outer;
}

@interface WQRootViewController : UITableViewController
@end

@implementation WQRootViewController {
    NSArray<NSArray<NSString *> *> *_locations;  // title, path, symbol
}

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
        self.title = @"WQ Files";
        [self rebuildLocations];
    }
    return self;
}

// The whole container tree is now a first-class entry; the per-type folders
// stay as shortcuts. Settings changes take effect on the next appearance.
- (void)rebuildLocations
{
    NSMutableArray<NSArray<NSString *> *> *locations = [NSMutableArray new];
    if (WQSettingBool(WQSettingShowAllDataKey, YES))
        [locations addObject:@[@"全部应用数据", @"/private/var/mobile/Containers/Data", @"folder"]];
    [locations addObjectsFromArray:@[
        @[@"应用数据", @"/private/var/mobile/Containers/Data/Application", @"square.grid.2x2"],
        @[@"应用组", @"/private/var/mobile/Containers/Shared/AppGroup", @"square.stack.3d.up"],
        @[@"扩展数据", @"/private/var/mobile/Containers/Data/PluginKitPlugin", @"puzzlepiece.extension"],
        @[@"内部守护进程", @"/private/var/mobile/Containers/Data/InternalDaemon", @"gearshape.2"],
    ]];
    if (wq_system_areas_reachable())
        [locations addObject:@[@"系统数据", @"/private/var/containers/Data/System", @"cpu"]];
    _locations = locations;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self rebuildLocations];
    [self.tableView reloadData];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.tableView.backgroundColor = WQColorBackground();
    self.tableView.separatorColor = WQColorLine();
    self.tableView.tableFooterView = [self authorFooter];
    dispatch_async(wq_io(), ^{
        NSString *recovery = wq_recover_interrupted_restore();
        if (recovery) {
            dispatch_async(dispatch_get_main_queue(), ^{
                wq_alert(self, @"恢复中断的还原", recovery);
            });
        }
        (void)wq_app_group();   // resolves (and logs) the group off the main thread
    });
}

// Signing check, once the start screen is on screen (an alert presented
// while it is still loading would be dropped).
- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    static BOOL checked;
    if (checked) return;
    checked = YES;
    dispatch_async(wq_io(), ^{
        NSString *group = wq_app_group();
        if (group) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"签名问题：缺少 App Group"
                message:@"WQ Files 需要 App Group 才能访问其他应用的目录，签名工具把它去掉了。"
                        @"缺少它时所有目录都打不开，应用列表为空或显示「NO TOKEN」。\n\n"
                        @"请用 AltStore、SideStore 或 Sideloadly 重新安装（它们会创建 App Group），"
                        @"或使用包含 App Group 的描述文件签名。通配证书（多数 Feather/ESign 方案）做不到。"
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"签名帮助" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
                [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"https://github.com/kolbicz/WQFiles#signing-the-app-group"]
                                                 options:@{} completionHandler:nil];
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        });
    });
}

// Plain left-aligned credits: no capsule buttons, badges or decorative links.
- (UIView *)authorFooter
{
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 72)];
    UILabel *by = [UILabel new];
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    by.text = [NSString stringWithFormat:@"WQ Files %@ (%@) · GPL-3.0-or-later",
               info[@"CFBundleShortVersionString"] ?: @"?", info[@"CFBundleVersion"] ?: @"?"];
    by.font = WQFontCaption();
    by.textColor = WQColorText3();
    by.textAlignment = NSTextAlignmentLeft;
    by.translatesAutoresizingMaskIntoConstraints = NO;
    [footer addSubview:by];
    [NSLayoutConstraint activateConstraints:@[
        [by.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:WQGutter],
        [by.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-WQGutter],
        [by.topAnchor constraintEqualToAnchor:footer.topAnchor constant:WQSpace3],
    ]];
    return footer;
}

// Section order is fixed: the game feature is the primary entry and sits above
// the low-level container browser and the tools. Keeping the indices in one
// place means a future reorder cannot pair rows with the wrong handler.
typedef NS_ENUM(NSInteger, WQRootSection) {
    WQRootSectionGame = 0,
    WQRootSectionContainers,
    WQRootSectionTools,
};

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == WQRootSectionGame) return 1;
    if (section == WQRootSectionContainers)
        return (NSInteger)_locations.count + (wq_system_areas_reachable() ? 1 : 0);
    return 7;   // WQRootSectionTools
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return @[@"游戏功能", @"容器", @"工具"][section];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == WQRootSectionGame)
        return @"点「进入」查看本机已安装应用，选择游戏容器与注入路径并保存，之后即可快捷放入 pak、sig、lua 等资源文件。仅用于本机调试与补齐缺失资源。\n\n游戏功能 by 淮季 · 公益频道@HeiMaoClub";
    if (section == WQRootSectionContainers && !wq_system_areas_reachable())
        return @"iOS 26 上无法访问系统数据与系统组（仅 iOS 27 可用），内部守护进程需扫描全部文件编号：设备文件较多时首次可能耗时近一小时，之后只检查新增文件。若在 iOS 27.0 上出现入口打不开或长时间扫描，请在设置中开启兼容模式并重启。";
    if (section == WQRootSectionTools)
        return @"被覆盖或删除的文件会先复制到备份（在文件 App 中也可查看）。长按备份可还原到原位置。";
    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return indexPath.section == WQRootSectionGame ? 96.0 : WQRowHeight;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"r"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"r"];
    cell.accessoryView = nil;
    cell.backgroundView = nil;
    UIListContentConfiguration *c = cell.defaultContentConfiguration;
    c.textProperties.color = WQColorText();
    c.secondaryTextProperties.color = WQColorText2();
    c.imageProperties.tintColor = WQColorText2();
    c.imageProperties.maximumSize = CGSizeMake(WQIconSize, WQIconSize);
    c.secondaryText = nil;
    if (indexPath.section == WQRootSectionGame) {
        c.text = @"游戏资源注入";
        c.secondaryText = @"选择容器 → 保存注入路径 → 放入 pak / sig / lua\nby 淮季 · 公益频道@HeiMaoClub";
        c.secondaryTextProperties.numberOfLines = 2;
        c.textProperties.font = WQFontTitle();
        c.image = WQLinearIcon(@"gamecontroller");
        c.imageProperties.maximumSize = CGSizeMake(28.0, 28.0);
        c.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(WQSpace4, WQSpace6, WQSpace4, WQSpace3);
        cell.backgroundView = WQRootGameBackground();
        cell.backgroundColor = UIColor.clearColor;
        UILabel *enter = [UILabel new];
        enter.text = @"进入";
        enter.font = WQFontValue();
        enter.textColor = WQColorText2();
        enter.textAlignment = NSTextAlignmentRight;
        [enter sizeToFit];
        cell.accessoryView = enter;
    } else if (indexPath.section == WQRootSectionContainers) {
        if ((NSUInteger)indexPath.row < _locations.count) {
            NSArray *loc = _locations[(NSUInteger)indexPath.row];
            c.text = loc[0];
            c.image = WQLinearIcon(loc[2]);
        } else {
            c.text = @"系统组";
            c.image = WQLinearIcon(@"lock.square.stack");
        }
    } else {
        NSArray *tools = @[@[@"应用列表", @"square.grid.3x3"], @[@"缓存清理", @"trash"], @[@"前往路径…", @"arrow.right.circle"],
                           @[@"应用备份", @"clock.arrow.circlepath"], @[@"备份", @"clock.arrow.circlepath"], @[@"日志", @"doc.plaintext"],
                           @[@"设置", @"slider.horizontal.3"]];
        c.text = tools[(NSUInteger)indexPath.row][0];
        c.image = WQLinearIcon(tools[(NSUInteger)indexPath.row][1]);
    }
    cell.contentConfiguration = c;
    cell.accessoryType = indexPath.section == WQRootSectionGame
        ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UIViewController *next = nil;
    if (indexPath.section == WQRootSectionGame) {
        next = [WQGameCenterViewController new];
    } else if (indexPath.section == WQRootSectionContainers) {
        if ((NSUInteger)indexPath.row < _locations.count) {
            NSArray *loc = _locations[(NSUInteger)indexPath.row];
            next = [[WQDirViewController alloc] initWithPath:loc[1] title:loc[0]];
        } else {
            next = [WQSystemGroupsViewController new];
        }
    } else {   // WQRootSectionTools — row handlers are scoped to this section
        if (indexPath.row == 0) {
            next = [WQAppsViewController new];
        } else if (indexPath.row == 1) {
            next = [WQCacheCleanerViewController new];
        } else if (indexPath.row == 2) {
            [self goToPath];
            return;
        } else if (indexPath.row == 3) {
            [NSFileManager.defaultManager createDirectoryAtPath:wq_app_backup_root()
                                   withIntermediateDirectories:YES attributes:nil error:nil];
            next = [[WQDirViewController alloc] initWithPath:wq_app_backup_root() title:@"应用备份"];
        } else if (indexPath.row == 4) {
            [NSFileManager.defaultManager createDirectoryAtPath:wq_backup_root()
                                   withIntermediateDirectories:YES attributes:nil error:nil];
            next = [[WQDirViewController alloc] initWithPath:wq_backup_root() title:@"备份"];
        } else if (indexPath.row == 6) {
            next = [WQSettingsViewController new];
        } else {
            next = [WQLogViewController new];
        }
    }
    [self.navigationController pushViewController:next animated:YES];
}

- (void)goToPath
{
    [self.navigationController pushViewController:[WQPathViewController new] animated:YES];
}

@end

#pragma mark - App

@interface WQSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation WQSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options
{
    // Before any view controller can ask for a sandbox extension: apply the
    // saved compatibility mode so the very first grant uses its query flags.
    wq_set_legacy_scope([NSUserDefaults.standardUserDefaults boolForKey:WQSettingLegacyScopeKey]);
    UIWindow *window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    window.rootViewController = [[WQNavigationController alloc] initWithRootViewController:[WQRootViewController new]];
    [window makeKeyAndVisible];
    self.window = window;
}

@end

#pragma mark - Full scan: confirmation and progress window

static UIViewController *wq_top_view_controller(void)
{
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.isKeyWindow) continue;
            UIViewController *top = window.rootViewController;
            while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) top = top.presentedViewController;
            return top;
        }
    }
    return nil;
}

static NSString *wq_duration_text(double seconds)
{
    if (seconds < 90) return @"about a minute";
    if (seconds < 3600) return [NSString stringWithFormat:@"about %.0f minutes", ceil(seconds / 60)];
    return [NSString stringWithFormat:@"about %.1f hours", seconds / 3600];
}

static NSString *wq_count_text(int64_t n)
{
    if (n >= 1000000) return [NSString stringWithFormat:@"%.0f million", n / 1e6];
    return [NSNumberFormatter localizedStringFromNumber:@(n) numberStyle:NSNumberFormatterDecimalStyle];
}

@interface WQScanWindowController : UIViewController
- (void)updateDone:(int64_t)done total:(int64_t)total;
@end

@implementation WQScanWindowController {
    UIProgressView *_bar;
    UILabel *_status;
    CFAbsoluteTime _started;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = WQColorBackground();
    _started = CFAbsoluteTimeGetCurrent();
    UILabel *title = [UILabel new];
    title.text = @"正在扫描所有文件";
    title.font = WQFontTitle();
    title.textColor = WQColorText();
    title.adjustsFontForContentSizeCategory = YES;
    UILabel *text = [UILabel new];
    text.numberOfLines = 0;
    text.textAlignment = NSTextAlignmentCenter;
    text.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    text.textColor = WQColorText2();
    text.text = @"iOS 不允许 WQ Files 直接列出这些目录，因此需要对本机全部文件编号检查一次。"
                @"只有首次较慢，之后只检查新增文件。\n\n"
                @"请保持 WQ Files 在前台；切到其他应用或锁屏会暂停扫描。";
    _bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _status = [UILabel new];
    _status.font = [UIFont monospacedDigitSystemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleBody].pointSize
                                                    weight:UIFontWeightRegular];
    _status.textAlignment = NSTextAlignmentCenter;
    _status.text = @"正在开始…";
    UIButton *hide = [UIButton buttonWithConfiguration:UIButtonConfiguration.borderedButtonConfiguration primaryAction:
        [UIAction actionWithTitle:@"隐藏" image:nil identifier:nil handler:^(UIAction *__unused a) {
            [self dismissViewControllerAnimated:YES completion:nil];
        }]];
    UIButtonConfiguration *stopConfig = UIButtonConfiguration.borderedButtonConfiguration;
    stopConfig.baseForegroundColor = WQColorStrong();
    UIButton *stop = [UIButton buttonWithConfiguration:stopConfig primaryAction:
        [UIAction actionWithTitle:@"停止扫描" image:nil identifier:nil handler:^(UIAction *__unused a) {
            wq_full_scan_stop();
            [self dismissViewControllerAnimated:YES completion:nil];
        }]];
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[hide, stop]];
    buttons.spacing = 12;
    buttons.distribution = UIStackViewDistributionFillEqually;
    UILabel *note = [UILabel new];
    note.numberOfLines = 0;
    note.textAlignment = NSTextAlignmentCenter;
    note.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    note.textColor = WQColorText3();
    note.text = @"隐藏后扫描仍继续，完成后列表会自动填充。";
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, text, _bar, _status, buttons, note]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerYAnchor constraintEqualToAnchor:g.centerYAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-24],
        [_bar.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [buttons.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [text.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [note.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
    ]];
}

- (void)updateDone:(int64_t)done total:(int64_t)total
{
    if (total <= 0) return;
    float fraction = (float)((double)done / (double)total);
    [_bar setProgress:fraction animated:NO];
    double elapsed = CFAbsoluteTimeGetCurrent() - _started;
    NSString *left = @"";
    if (elapsed > 5 && done > 0 && done < total) {
        double remaining = elapsed * (double)(total - done) / (double)done;
        left = [@" · " stringByAppendingString:[wq_duration_text(remaining) stringByAppendingString:@" left"]];
    }
    _status.text = [NSString stringWithFormat:@"%.0f%%%@", fraction * 100, left];
}

@end

static WQScanWindowController *gScanWindow;
static UIBackgroundTaskIdentifier gScanBackgroundTask;   // 0 is UIBackgroundTaskInvalid

// Called on a scan thread: asks on the main thread and waits for the answer.
static BOOL wq_confirm_full_scan(NSString *what, int64_t ids, double seconds)
{
    dispatch_semaphore_t answered = dispatch_semaphore_create(0);
    __block BOOL start = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = wq_top_view_controller();
        if (!top) { dispatch_semaphore_signal(answered); return; }   // not in front: don't scan unasked
        NSString *message = [NSString stringWithFormat:
            @"要列出%@，WQ Files 需要对本机全部文件编号检查一次：%@ 个文件，%@。\n\n"
            @"只有首次需要这样；之后只检查新增文件，几秒即可完成。\n\n"
            @"扫描期间请保持 WQ Files 在前台。", what, wq_count_text(ids), wq_duration_text(seconds)];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"扫描全部文件？" message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"稍后" style:UIAlertActionStyleCancel handler:^(UIAlertAction *__unused a) {
            dispatch_semaphore_signal(answered);
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"开始扫描" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
            start = YES;
            // A little extra time when the user switches away (iOS grants about 30 s).
            if (gScanBackgroundTask == UIBackgroundTaskInvalid) {
                gScanBackgroundTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"WQ full scan" expirationHandler:^{
                    [UIApplication.sharedApplication endBackgroundTask:gScanBackgroundTask];
                    gScanBackgroundTask = UIBackgroundTaskInvalid;
                }];
            }
            WQScanWindowController *window = [WQScanWindowController new];
            window.modalPresentationStyle = UIModalPresentationPageSheet;
            window.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.mediumDetent,
                                                          UISheetPresentationControllerDetent.largeDetent];
            window.sheetPresentationController.prefersGrabberVisible = YES;
            gScanWindow = window;
            dispatch_semaphore_signal(answered);
            // After the alert has gone (presenting during its dismissal fails).
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                UIViewController *host = wq_top_view_controller();
                if (gScanWindow == window && host && host != window) [host presentViewController:window animated:YES completion:nil];
            });
        }]];
        [top presentViewController:alert animated:YES completion:nil];
    });
    dispatch_semaphore_wait(answered, DISPATCH_TIME_FOREVER);
    return start;
}

static void wq_full_scan_progress(int64_t done, int64_t total, BOOL finished)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!finished) { [gScanWindow updateDone:done total:total]; return; }
        WQScanWindowController *window = gScanWindow;
        gScanWindow = nil;
        if (window.presentingViewController && !window.isBeingDismissed) [window dismissViewControllerAnimated:YES completion:nil];
        if (gScanBackgroundTask != UIBackgroundTaskInvalid) {
            [UIApplication.sharedApplication endBackgroundTask:gScanBackgroundTask];
            gScanBackgroundTask = UIBackgroundTaskInvalid;
        }
    });
}

@interface WQAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation WQAppDelegate

- (UISceneConfiguration *)application:(UIApplication *)application
configurationForConnectingSceneSession:(UISceneSession *)session
                              options:(UISceneConnectionOptions *)options
{
    UISceneConfiguration *config = [[UISceneConfiguration alloc] initWithName:@"默认" sessionRole:session.role];
    config.delegateClass = WQSceneDelegate.class;
    return config;
}

@end

int main(int argc, char *argv[])
{
    @autoreleasepool {
        // Container folders get their bundle id from the LaunchServices database
        // when the identifier attribute can't be read (iOS 27.2).
        wq_set_container_label_resolver(wq_bundle_id_for_container);
        wq_set_container_list_provider(wq_ls_container_paths);
        wq_set_full_scan_ui(wq_confirm_full_scan, wq_full_scan_progress);
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(WQAppDelegate.class));
    }
}
