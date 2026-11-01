#import <UIKit/UIKit.h>
#import <AVKit/AVKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <substrate.h>
#import <objc/runtime.h>

// 补齐 PSListController 完整声明（系统头里只有前向声明，Logos 编译需要父类信息）
@interface PSListController : UITableViewController
@property (nonatomic, readonly) UITableView *table;
- (void)reloadSpecifiers;
@end

// cc播放器 素材导入助手
// 注入 Preferences 进程, 在「选择收起/展开背景视频/图片」页加右上角「导入」按钮,
// 长按素材行可预览 / 改名 / 删除。素材目录与原插件一致。
static NSString *const kCCMDir = @"/var/mobile/Media/CCMusicModuleBackgrounds";
static const void *kCCMKeyImportBtn = &kCCMKeyImportBtn;
static const void *kCCMKeyGesture = &kCCMKeyGesture;
static const void *kCCMKeyPickerDelegate = &kCCMKeyPickerDelegate;

static BOOL ccm_isSelectionPage(UIViewController *vc) {
    if (!vc) return NO;
    NSString *t = vc.navigationItem.title;
    if (!t.length) t = vc.title;
    if (!t.length) return NO;
    return ([t rangeOfString:@"选择收起背景视频"].location != NSNotFound ||
            [t rangeOfString:@"选择展开背景视频"].location != NSNotFound);
}

static BOOL ccm_supportedName(NSString *name) {
    NSString *ext = name.pathExtension.lowercaseString;
    static NSSet *s = nil;
    if (!s) s = [NSSet setWithArray:@[@"mp4", @"mov", @"gif", @"png", @"jpg", @"jpeg"]];
    return [s containsObject:ext];
}

static NSString *ccm_uniquePath(NSString *dir, NSString *name) {
    NSString *base = name.stringByDeletingPathExtension;
    NSString *ext = name.pathExtension;
    NSString *cand = name;
    int i = 1;
    while ([[NSFileManager defaultManager] fileExistsAtPath:[dir stringByAppendingPathComponent:cand]]) {
        cand = ext.length ? [NSString stringWithFormat:@"%@ (%d).%@", base, i, ext] : [NSString stringWithFormat:@"%@ (%d)", base, i];
        i++;
    }
    return [dir stringByAppendingPathComponent:cand];
}

static void ccm_reload(id self) {
    if ([self respondsToSelector:@selector(reloadSpecifiers)]) {
        ((void(*)(id, SEL))objc_msgSend)(self, @selector(reloadSpecifiers));
    }
}

#pragma mark - 预览

@interface CCMImagePreviewController : UIViewController
- (void)ccm_setImagePath:(NSString *)path;
@end

@implementation CCMImagePreviewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(ccm_dismissSelf)];
    [self.view addGestureRecognizer:tap];
}
- (void)ccm_setImagePath:(NSString *)path {
    UIImage *img = [UIImage imageWithContentsOfFile:path];
    if (!img) return;
    UIImageView *iv = [[UIImageView alloc] initWithImage:img];
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.frame = self.view.bounds;
    iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:iv];
}
- (void)ccm_dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end

static void ccm_presentPreview(UIViewController *vc, NSString *path) {
    NSString *ext = path.pathExtension.lowercaseString;
    if ([@[@"mp4", @"mov"] containsObject:ext]) {
        AVPlayerViewController *p = [[AVPlayerViewController alloc] init];
        p.player = [AVPlayer playerWithURL:[NSURL fileURLWithPath:path]];
        [vc presentViewController:p animated:YES completion:^{ [p.player play]; }];
    } else {
        CCMImagePreviewController *pv = [[CCMImagePreviewController alloc] init];
        [pv ccm_setImagePath:path];
        [vc presentViewController:pv animated:YES completion:nil];
    }
}

#pragma mark - 改名 / 删除

static void ccm_promptRename(UIViewController *vc, NSString *dir, NSString *name) {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"重命名素材" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf){
        tf.text = name;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        UITextField *tf = ac.textFields.firstObject;
        NSString *newName = [tf.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!newName.length) return;
        NSString *ext = name.pathExtension;
        if (ext.length && ![newName.pathExtension.lowercaseString isEqualToString:ext.lowercaseString]) {
            newName = [newName stringByAppendingPathExtension:ext];
        }
        NSString *src = [dir stringByAppendingPathComponent:name];
        NSString *dst = ccm_uniquePath(dir, newName);
        NSError *err = nil;
        if (![[NSFileManager defaultManager] moveItemAtPath:src toPath:dst error:&err]) {
            UIAlertController *al = [UIAlertController alertControllerWithTitle:@"改名失败" message:(err.localizedDescription ?: @"请重试") preferredStyle:UIAlertControllerStyleAlert];
            [al addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [vc presentViewController:al animated:YES completion:nil];
            return;
        }
        ccm_reload(vc);
    }]];
    [vc presentViewController:ac animated:YES completion:nil];
}

static void ccm_promptDelete(UIViewController *vc, NSString *dir, NSString *name) {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"删除素材" message:[NSString stringWithFormat:@"确定删除「%@」？", name] preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a){
        NSString *p = [dir stringByAppendingPathComponent:name];
        [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
        ccm_reload(vc);
    }]];
    [vc presentViewController:ac animated:YES completion:nil];
}

static void ccm_showActions(UIViewController *vc, NSString *name) {
    if (!ccm_supportedName(name)) return;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:name message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"预览" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        ccm_presentPreview(vc, [kCCMDir stringByAppendingPathComponent:name]);
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"改名" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        ccm_promptRename(vc, kCCMDir, name);
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a){
        ccm_promptDelete(vc, kCCMDir, name);
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:ac animated:YES completion:nil];
}

#pragma mark - 导入（文件选择器）

@interface CCMImportPickerDelegate : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, weak) UIViewController *host;
@end

@implementation CCMImportPickerDelegate
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kCCMDir]) {
        [fm createDirectoryAtPath:kCCMDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    for (NSURL *u in urls) {
        BOOL scoped = [u startAccessingSecurityScopedResource];
        NSString *name = u.lastPathComponent;
        NSString *dst = ccm_uniquePath(kCCMDir, name);
        NSError *err = nil;
        [fm copyItemAtURL:u toURL:[NSURL fileURLWithPath:dst] error:&err];
        if (scoped) [u stopAccessingSecurityScopedResource];
    }
    ccm_reload(self.host);
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
}
@end

#pragma mark - Hook（注入 Preferences 进程）

%hook PSListController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!ccm_isSelectionPage(self)) return;
    UIBarButtonItem *imp = objc_getAssociatedObject(self, kCCMKeyImportBtn);
    if (!imp) {
        imp = [[UIBarButtonItem alloc] initWithTitle:@"导入" style:UIBarButtonItemStylePlain target:self action:@selector(ccm_importTapped)];
        objc_setAssociatedObject(self, kCCMKeyImportBtn, imp, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSArray *items = self.navigationItem.rightBarButtonItems;
    if (![items containsObject:imp]) {
        NSMutableArray *arr = items.count ? [items mutableCopy] : [NSMutableArray array];
        [arr addObject:imp];
        self.navigationItem.rightBarButtonItems = arr;
    }
}

- (id)tableView:(id)tableView cellForRowAtIndexPath:(id)indexPath {
    id cell = %orig;
    if (ccm_isSelectionPage(self)) {
        UILongPressGestureRecognizer *g = objc_getAssociatedObject(cell, kCCMKeyGesture);
        if (!g) {
            g = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(ccm_longPress:)];
            [cell addGestureRecognizer:g];
            objc_setAssociatedObject(cell, kCCMKeyGesture, g, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    return cell;
}

- (void)ccm_importTapped {
    CCMImportPickerDelegate *d = [[CCMImportPickerDelegate alloc] init];
    d.host = self;
    objc_setAssociatedObject(self, kCCMKeyPickerDelegate, d, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSArray *types = @[UTTypeMovie, UTTypeImage];
    UIDocumentPickerViewController *pk = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    pk.delegate = d;
    pk.allowsMultipleSelection = YES;
    [self presentViewController:pk animated:YES completion:nil];
}

- (void)ccm_longPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UITableViewCell *cell = (UITableViewCell *)g.view;
    NSIndexPath *ip = [self.table indexPathForCell:cell];
    if (!ip) return;
    NSString *name = cell.textLabel.text;
    if (!name.length) return;
    ccm_showActions(self, name);
}

%end
