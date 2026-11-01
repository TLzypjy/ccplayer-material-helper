#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <substrate.h>
#import <objc/runtime.h>

// 补齐 PSListController 完整声明（系统头里只有前向声明，Logos 编译需要父类信息）
@interface PSListController : UITableViewController
@property (nonatomic, readonly) UITableView *table;
- (void)reloadSpecifiers;
@end

// cc播放器 素材导入助手（精简版：仅导入）
// 注入 Preferences 进程, 在「选择收起/展开背景视频/图片」页加右上角「导入」按钮,
// 支持从相册 / 文件 导入视频与图片素材到原插件素材目录。
static NSString *const kCCMDir = @"/var/mobile/Media/CCMusicModuleBackgrounds";
static const void *kCCMKeyImportBtn = &kCCMKeyImportBtn;

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

static void ccm_ensureDir(void) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:kCCMDir]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:kCCMDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
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

static void ccm_finishImport(UIViewController *picker, UIViewController *host, BOOL ok) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *title = ok ? @"已导入" : @"导入失败";
        NSString *msg = ok ? @"素材已导入到背景素材目录" : @"请重试";
        [picker dismissViewControllerAnimated:YES completion:^{
            ccm_reload(host);
            UIAlertController *al = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
            [al addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [host presentViewController:al animated:YES completion:nil];
        }];
    });
}

#pragma mark - 从文件导入（内置文件浏览器，不依赖系统文件选择器远程服务）

@interface CCMFileBrowserController : UITableViewController
@property (nonatomic, strong) NSString *dir;
@property (nonatomic, strong) NSArray<NSString *> *subdirs;
@property (nonatomic, strong) NSArray<NSString *> *files;
@property (nonatomic, weak) UIViewController *host;
- (instancetype)initWithDir:(NSString *)dir host:(UIViewController *)host;
@end

@implementation CCMFileBrowserController
- (instancetype)initWithDir:(NSString *)dir host:(UIViewController *)host {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) { _dir = dir; _host = host; }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.dir.lastPathComponent.length ? self.dir.lastPathComponent : self.dir;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(ccm_close)];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *all = [fm contentsOfDirectoryAtPath:self.dir error:nil] ?: @[];
    NSMutableArray *subs = [NSMutableArray array], *fls = [NSMutableArray array];
    for (NSString *n in all) {
        NSString *p = [self.dir stringByAppendingPathComponent:n];
        BOOL isDir = NO;
        [fm fileExistsAtPath:p isDirectory:&isDir];
        if (isDir) [subs addObject:n];
        else if (ccm_supportedName(n)) [fls addObject:n];
    }
    [subs sortUsingSelector:@selector(localizedStandardCompare:)];
    [fls sortUsingSelector:@selector(localizedStandardCompare:)];
    self.subdirs = subs;
    self.files = fls;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"文件夹" : @"视频 / 图片";
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? self.subdirs.count : self.files.count;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"ccmcell"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"ccmcell"];
    if (ip.section == 0) {
        c.textLabel.text = self.subdirs[ip.row];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        c.textLabel.text = self.files[ip.row];
        c.accessoryType = UITableViewCellAccessoryNone;
    }
    return c;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0) {
        CCMFileBrowserController *sub = [[CCMFileBrowserController alloc] initWithDir:[self.dir stringByAppendingPathComponent:self.subdirs[ip.row]] host:self.host];
        [self.navigationController pushViewController:sub animated:YES];
        return;
    }
    NSString *name = self.files[ip.row];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:name message:@"导入到背景素材目录？" preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"导入" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        ccm_ensureDir();
        NSString *src = [self.dir stringByAppendingPathComponent:name];
        NSString *dst = ccm_uniquePath(kCCMDir, name);
        NSError *err = nil;
        BOOL ok = [[NSFileManager defaultManager] copyItemAtPath:src toPath:dst error:&err];
        ccm_finishImport(self, self.host, ok);
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}
- (void)ccm_close {
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end

#pragma mark - 从相册导入（Photos 框架自制选择器，不走远程服务）

@interface CCMPhotoPickerController : UITableViewController
@property (nonatomic, strong) NSArray<PHAsset *> *assets;
@property (nonatomic, weak) UIViewController *host;
- (instancetype)initWithHost:(UIViewController *)host;
@end

@implementation CCMPhotoPickerController
- (instancetype)initWithHost:(UIViewController *)host {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) { _host = host; }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"从相册导入";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(ccm_close)];
    PHAuthorizationStatus st = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
    if (st == PHAuthorizationStatusNotDetermined) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelReadWrite handler:^(PHAuthorizationStatus s){
            dispatch_async(dispatch_get_main_queue(), ^{
                if (s == PHAuthorizationStatusAuthorized) [self ccm_load];
                else [self ccm_showNoAuth];
            });
        }];
    } else if (st == PHAuthorizationStatusAuthorized) {
        [self ccm_load];
    } else {
        [self ccm_showNoAuth];
    }
}
- (void)ccm_load {
    PHFetchOptions *fo = [PHFetchOptions new];
    fo.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"creationDate" ascending:NO]];
    PHFetchResult *res = [PHAsset fetchAssetsWithOptions:fo];
    NSMutableArray *arr = [NSMutableArray array];
    [res enumerateObjectsUsingBlock:^(PHAsset *a, NSUInteger idx, BOOL *stop){
        [arr addObject:a];
    }];
    self.assets = arr;
    [self.tableView reloadData];
}
- (void)ccm_showNoAuth {
    self.assets = @[];
    [self.tableView reloadData];
    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"需要照片权限" message:@"请在 设置 → 隐私与安全性 → 照片 中允许访问照片后重试。" preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:al animated:YES completion:nil];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.assets.count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"ccmphoto"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"ccmphoto"];
    PHAsset *a = self.assets[ip.row];
    NSArray *res = [PHAssetResource assetResourcesForAsset:a];
    NSString *nm = res.count ? ((PHAssetResource *)res.firstObject).originalFilename : @"";
    if (!nm.length) nm = a.mediaType == PHAssetMediaTypeVideo ? @"视频" : @"图片";
    c.textLabel.text = nm;
    c.detailTextLabel.text = a.mediaType == PHAssetMediaTypeVideo ? @"视频" : @"图片";
    c.imageView.image = nil;
    PHImageRequestOptions *ro = [PHImageRequestOptions new];
    ro.networkAccessAllowed = YES;
    ro.deliveryMode = PHImageRequestOptionsDeliveryModeFastFormat;
    [[PHImageManager defaultManager] requestImageForAsset:a targetSize:CGSizeMake(88, 88) contentMode:PHImageContentModeAspectFill options:ro resultHandler:^(UIImage *img, NSDictionary *info){
        if (img) { c.imageView.image = img; [c setNeedsLayout]; }
    }];
    return c;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    PHAsset *a = self.assets[ip.row];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"导入这个素材？" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"导入" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act){
        ccm_ensureDir();
        if (a.mediaType == PHAssetMediaTypeVideo) {
            [self ccm_exportVideo:a];
        } else {
            [self ccm_exportImage:a];
        }
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}
- (void)ccm_exportImage:(PHAsset *)asset {
    PHImageRequestOptions *o = [PHImageRequestOptions new];
    o.networkAccessAllowed = YES;
    o.deliveryMode = PHImageRequestOptionsDeliveryModeHighQualityFormat;
    [[PHImageManager defaultManager] requestImageDataAndOrientationForAsset:asset options:o resultHandler:^(NSData *data, NSString *dataUTI, CGImagePropertyOrientation orientation, NSDictionary *info){
        if (!data.length) { ccm_finishImport(self, self.host, NO); return; }
        UTType *t = [UTType typeWithIdentifier:dataUTI];
        NSString *ext = t.preferredFilenameExtension;
        if (!ext.length) ext = @"jpg";
        NSArray *res = [PHAssetResource assetResourcesForAsset:asset];
        NSString *base = res.count ? ((PHAssetResource *)res.firstObject).originalFilename.stringByDeletingPathExtension : @"";
        if (!base.length) base = [NSString stringWithFormat:@"image_%lld", (long long)[NSDate date].timeIntervalSince1970];
        NSString *dst = ccm_uniquePath(kCCMDir, [base stringByAppendingPathExtension:ext]);
        BOOL ok = [data writeToFile:dst atomically:YES];
        ccm_finishImport(self, self.host, ok);
    }];
}
- (void)ccm_exportVideo:(PHAsset *)asset {
    PHVideoRequestOptions *o = [PHVideoRequestOptions new];
    o.networkAccessAllowed = YES;
    o.deliveryMode = PHVideoRequestOptionsDeliveryModeHighQualityFormat;
    [[PHImageManager defaultManager] requestAVAssetForVideo:asset options:o resultHandler:^(AVAsset *av, AVAudioMix *am, NSDictionary *info){
        if (!av) { ccm_finishImport(self, self.host, NO); return; }
        if ([av isKindOfClass:[AVURLAsset class]] && ((AVURLAsset *)av).URL.isFileURL) {
            NSURL *srcURL = ((AVURLAsset *)av).URL;
            if (ccm_supportedName(srcURL.lastPathComponent)) {
                NSError *err = nil;
                NSString *dst = ccm_uniquePath(kCCMDir, srcURL.lastPathComponent);
                BOOL ok = [[NSFileManager defaultManager] copyItemAtURL:srcURL toURL:[NSURL fileURLWithPath:dst] error:&err];
                ccm_finishImport(self, self.host, ok);
                return;
            }
        }
        NSArray *res = [PHAssetResource assetResourcesForAsset:asset];
        NSString *base = res.count ? ((PHAssetResource *)res.firstObject).originalFilename.stringByDeletingPathExtension : @"";
        if (!base.length) base = [NSString stringWithFormat:@"video_%lld", (long long)[NSDate date].timeIntervalSince1970];
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"ccm_%lld.mp4", (long long)[NSDate date].timeIntervalSince1970]];
        AVAssetExportSession *ex = [[AVAssetExportSession alloc] initWithAsset:av presetName:AVAssetExportPresetPassthrough];
        ex.outputURL = [NSURL fileURLWithPath:tmp];
        ex.outputFileType = AVFileTypeMPEG4;
        __weak typeof(self) ws = self;
        [ex exportAsynchronouslyWithCompletionHandler:^{
            BOOL ok = (ex.status == AVAssetExportSessionStatusCompleted) && [[NSFileManager defaultManager] fileExistsAtPath:tmp];
            if (ok) {
                NSString *dst = ccm_uniquePath(kCCMDir, [base stringByAppendingPathExtension:@"mp4"]);
                NSError *err = nil;
                ok = [[NSFileManager defaultManager] moveItemAtPath:tmp toPath:dst error:&err];
                if (!ok) [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
            }
            ccm_finishImport(ws, ws.host, ok);
        }];
    }];
}
- (void)ccm_close {
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end

#pragma mark - 导入入口（C 函数实现，手动注册 selector，避免 Logos 自动注册失效导致 unrecognized selector 崩溃）

static void ccm_importTappedImpl(id self, SEL _cmd) {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"导入素材" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"从相册导入" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        CCMPhotoPickerController *pp = [[CCMPhotoPickerController alloc] initWithHost:self];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:pp];
        [self presentViewController:nav animated:YES completion:nil];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"从文件导入" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        CCMFileBrowserController *fb = [[CCMFileBrowserController alloc] initWithDir:@"/var/mobile/Media" host:self];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:fb];
        [self presentViewController:nav animated:YES completion:nil];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UIBarButtonItem *imp = objc_getAssociatedObject(self, kCCMKeyImportBtn);
    if (imp && ac.popoverPresentationController) {
        ac.popoverPresentationController.barButtonItem = imp;
    }
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - Hook（注入 Preferences 进程）

%hook PSListController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!ccm_isSelectionPage(self)) return;
    // 确保「导入」selector 已注册到当前 controller 类（手动 addMethod，兜底 Logos 自动注册）
    SEL sel = @selector(ccm_importTapped);
    if (![self respondsToSelector:sel]) {
        class_addMethod([self class], sel, (IMP)(void(*)(id,SEL))ccm_importTappedImpl, "v@:");
    }
    UIBarButtonItem *imp = objc_getAssociatedObject(self, kCCMKeyImportBtn);
    if (!imp) {
        imp = [[UIBarButtonItem alloc] initWithTitle:@"导入" style:UIBarButtonItemStylePlain target:self action:sel];
        objc_setAssociatedObject(self, kCCMKeyImportBtn, imp, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSArray *items = self.navigationItem.rightBarButtonItems;
    if (![items containsObject:imp]) {
        NSMutableArray *arr = items.count ? [items mutableCopy] : [NSMutableArray array];
        [arr addObject:imp];
        self.navigationItem.rightBarButtonItems = arr;
    }
}

%end
