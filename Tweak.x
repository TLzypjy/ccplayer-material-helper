#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <substrate.h>
#import <objc/runtime.h>

// 补齐 PSListController 完整声明（系统头里只有前向声明，Logos 编译需要父类信息）
@interface PSListController : UITableViewController
@property (nonatomic, readonly) UITableView *table;
- (void)reloadSpecifiers;
@end

// cc播放器 素材导入助手（仅导入）
// 注入 Preferences 进程, 在「选择收起/展开背景视频/图片」页加右上角「导入」按钮,
// 相册走系统原生 PHPicker, 文件走系统原生 UIDocumentPicker (asCopy), 导入到原插件素材目录。
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

#pragma mark - 系统原生选择器协调器（相册=PHPicker, 文件=UIDocumentPicker）

@interface CCMImportCoordinator : NSObject <PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic, weak) id host;
+ (instancetype)shared;
- (void)presentPhotoPickerFrom:(id)host;
- (void)presentDocumentPickerFrom:(id)host;
@end

@implementation CCMImportCoordinator

+ (instancetype)shared {
    static CCMImportCoordinator *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[CCMImportCoordinator alloc] init]; });
    return s;
}

- (void)presentPhotoPickerFrom:(id)host {
    self.host = host;
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
    cfg.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[PHPickerFilter.imagesFilter, PHPickerFilter.videosFilter]];
    cfg.selectionLimit = 0;
    cfg.preferredAssetRepresentationMode = PHPickerConfigurationAssetRepresentationModeCurrent;
    PHPickerViewController *pv = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    pv.delegate = self;
    [host presentViewController:pv animated:YES completion:nil];
}

- (void)presentDocumentPickerFrom:(id)host {
    self.host = host;
    UIDocumentPickerViewController *dp = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeImage, UTTypeMovie] asCopy:YES];
    dp.delegate = self;
    dp.allowsMultipleSelection = YES;
    [host presentViewController:dp animated:YES completion:nil];
}

- (void)ccm_copyIntoMaterials:(NSURL *)src base:(NSString *)base ext:(NSString *)ext {
    if (!src) return;
    ccm_ensureDir();
    if (!base.length) base = src.lastPathComponent.stringByDeletingPathExtension;
    if (!ext.length) ext = src.pathExtension;
    if (!ext.length) ext = @"jpg";
    NSString *dst = ccm_uniquePath(kCCMDir, [base stringByAppendingPathExtension:ext]);
    NSError *err = nil;
    [[NSFileManager defaultManager] copyItemAtURL:src toURL:[NSURL fileURLWithPath:dst] error:&err];
}

- (void)ccm_notifyHost {
    dispatch_async(dispatch_get_main_queue(), ^{
        id h = self.host;
        if (!h) return;
        ccm_reload(h);
        UIAlertController *al = [UIAlertController alertControllerWithTitle:@"导入完成" message:@"素材已导入到背景素材目录" preferredStyle:UIAlertControllerStyleAlert];
        [al addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [h presentViewController:al animated:YES completion:nil];
    });
}

#pragma mark PHPickerViewControllerDelegate

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:^{
        if (!results.count) return;
        __block NSInteger pending = (NSInteger)results.count;
        for (PHPickerResult *res in results) {
            NSItemProvider *prov = res.itemProvider;
            NSString *typeId = nil;
            if ([prov hasItemConformingToTypeIdentifier:@"public.movie"]) typeId = @"public.movie";
            else if ([prov hasItemConformingToTypeIdentifier:@"public.image"]) typeId = @"public.image";
            if (!typeId) { pending--; continue; }
            NSString *suggested = prov.suggestedName;
            [prov loadFileRepresentationForTypeIdentifier:typeId completionHandler:^(NSURL *url, NSError *err){
                if (url) {
                    NSString *ext = url.pathExtension;
                    if (!ext.length) ext = [UTType typeWithIdentifier:typeId].preferredFilenameExtension;
                    [self ccm_copyIntoMaterials:url base:suggested ext:ext];
                }
                pending--;
                if (pending == 0) [self ccm_notifyHost];
            }];
        }
    }];
}

#pragma mark UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    [controller dismissViewControllerAnimated:YES completion:^{
        if (!urls.count) return;
        for (NSURL *u in urls) {
            [self ccm_copyIntoMaterials:u base:u.lastPathComponent.stringByDeletingPathExtension ext:u.pathExtension];
        }
        [self ccm_notifyHost];
    }];
}

@end

#pragma mark - 导入入口（C 函数实现，手动注册 selector，避免 Logos 自动注册失效导致 unrecognized selector 崩溃）

static void ccm_importTappedImpl(id self, SEL _cmd) {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"导入素材" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"从相册导入" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        [[CCMImportCoordinator shared] presentPhotoPickerFrom:self];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"从文件导入" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        [[CCMImportCoordinator shared] presentDocumentPickerFrom:self];
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
