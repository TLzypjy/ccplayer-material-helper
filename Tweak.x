#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <substrate.h>
#import <objc/runtime.h>

// 补齐 PSListController 完整声明（系统头里只有前向声明，Logos 编译需要父类信息）
@interface PSListController : UITableViewController
@property (nonatomic, readonly) UITableView *table;
- (void)reloadSpecifiers;
@end

// cc播放器 素材库增强（网格预览 + 长按删除 + 行内改名 + 系统原生导入）
// 注入 Preferences 进程：
//  - 「选择收起/展开背景视频/图片」页由文字列表接管为缩略图网格
//  - 右上角「导入」按钮：系统原生 PHPicker（相册）/ UIDocumentPicker（文件）
//  - 长按缩略图进入抖动编辑态，右上角红 − 删除
//  - 点缩略图下方名字就地输入改名（保留原扩展名）
static NSString *const kCCMDir = @"/var/mobile/Media/CCMusicModuleBackgrounds";
static NSString *const kCCMPrefsDomain = @"com.codex.ccmusicmodule.reborn";
static NSString *const kCCMPrefsChanged = @"com.codex.ccmusicmodule.reborn.prefschanged";
static NSString *const kCCMGridChanged = @"ccm2BackgroundsChanged";
static const void *kCCMKeyImportBtn = &kCCMKeyImportBtn;
static const void *kCCMKeyGridView = &kCCMKeyGridView;
static const void *kCCMKeyDoneBtn = &kCCMKeyDoneBtn;

static BOOL ccm_isSelectionPage(UIViewController *vc) {
    if (!vc) return NO;
    NSString *t = vc.navigationItem.title;
    if (!t.length) t = vc.title;
    if (!t.length) return NO;
    return ([t rangeOfString:@"选择收起背景视频"].location != NSNotFound ||
            [t rangeOfString:@"选择展开背景视频"].location != NSNotFound);
}

static BOOL ccm_isCompactPage(UIViewController *vc) {
    if (!vc) return NO;
    NSString *t = vc.navigationItem.title;
    if (!t.length) t = vc.title;
    return ([t rangeOfString:@"选择收起背景视频"].location != NSNotFound);
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

static void ccm_postPrefsChanged(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)kCCMPrefsChanged, NULL, NULL, YES);
}

static void ccm_postGridChanged(void) {
    [[NSNotificationCenter defaultCenter] postNotificationName:kCCMGridChanged object:nil];
}

static NSString *ccm_prefString(NSString *key) {
    CFStringRef v = (CFStringRef)CFPreferencesCopyValue((__bridge CFStringRef)key,
                                           (__bridge CFStringRef)kCCMPrefsDomain,
                                           kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    return v ? CFBridgingRelease(v) : nil;
}

static void ccm_setPrefString(NSString *key, NSString *val) {
    CFPreferencesSetValue((__bridge CFStringRef)key, (__bridge CFStringRef)val,
                          (__bridge CFStringRef)kCCMPrefsDomain,
                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize((__bridge CFStringRef)kCCMPrefsDomain,
                             kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
}

#pragma mark - 素材网格 Cell

@interface CCM2BgCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *thumbView;
@property (nonatomic, strong) UIButton *nameButton;
@property (nonatomic, strong) UIButton *deleteButton;
@property (nonatomic, strong) UIImageView *checkView;
@property (nonatomic, strong) UILabel *videoPill;
@property (nonatomic, strong) NSString *currentPath;
@property (nonatomic, copy) void (^onLongPress)(void);
@property (nonatomic, copy) void (^onDelete)(void);
@property (nonatomic, copy) void (^onRenameTap)(void);
- (void)setJiggling:(BOOL)jiggle;
@end

@implementation CCM2BgCell
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _thumbView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _thumbView.contentMode = UIViewContentModeScaleAspectFill;
        _thumbView.clipsToBounds = YES;
        _thumbView.layer.cornerRadius = 14;
        _thumbView.userInteractionEnabled = YES;
        _thumbView.backgroundColor = [UIColor colorWithWhite:0.94 alpha:1.0];
        [self.contentView addSubview:_thumbView];

        _nameButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _nameButton.titleLabel.font = [UIFont systemFontOfSize:12];
        _nameButton.backgroundColor = [UIColor colorWithWhite:0.84 alpha:1.0];
        _nameButton.layer.cornerRadius = 8;
        _nameButton.layer.masksToBounds = YES;
        _nameButton.titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _nameButton.titleLabel.numberOfLines = 1;
        [_nameButton setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        [_nameButton addTarget:self action:@selector(ccm_nameTapped) forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:_nameButton];

        _deleteButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_deleteButton setTitle:@"−" forState:UIControlStateNormal];
        [_deleteButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        _deleteButton.titleLabel.font = [UIFont boldSystemFontOfSize:19];
        _deleteButton.backgroundColor = [UIColor systemRedColor];
        _deleteButton.layer.cornerRadius = 13;
        _deleteButton.layer.masksToBounds = YES;
        _deleteButton.hidden = YES;
        [_deleteButton addTarget:self action:@selector(ccm_deleteTapped) forControlEvents:UIControlEventTouchUpInside];
        [_thumbView addSubview:_deleteButton];

        _videoPill = [[UILabel alloc] initWithFrame:CGRectZero];
        _videoPill.text = @"视频";
        _videoPill.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
        _videoPill.textColor = [UIColor whiteColor];
        _videoPill.textAlignment = NSTextAlignmentCenter;
        _videoPill.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        _videoPill.layer.cornerRadius = 9;
        _videoPill.layer.masksToBounds = YES;
        _videoPill.hidden = YES;
        [_thumbView addSubview:_videoPill];

        _checkView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _checkView.backgroundColor = [UIColor colorWithWhite:0.84 alpha:1.0];
        _checkView.layer.cornerRadius = 10;
        _checkView.layer.masksToBounds = YES;
        _checkView.hidden = YES;
        [_checkView setImage:[[UIImage systemImageNamed:@"checkmark"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
        _checkView.tintColor = [UIColor whiteColor];
        _checkView.contentMode = UIViewContentModeCenter;
        [self.contentView addSubview:_checkView];

        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(ccm_longPressed:)];
        lp.minimumPressDuration = 0.4;
        [_thumbView addGestureRecognizer:lp];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat h = self.contentView.bounds.size.height;
    CGFloat thumbH = h - 54;
    self.thumbView.frame = CGRectMake(0, 0, w, thumbH);
    self.nameButton.frame = CGRectMake(0, thumbH + 4, w, 24);
    self.checkView.frame = CGRectMake(w / 2 - 10, thumbH + 34, 20, 20);
    self.deleteButton.frame = CGRectMake(w - 28, 4, 24, 24);
    self.videoPill.frame = CGRectMake(8, 8, 40, 18);
}

- (void)ccm_longPressed:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan && self.onLongPress) self.onLongPress();
}

- (void)ccm_deleteTapped {
    if (self.onDelete) self.onDelete();
}

- (void)ccm_nameTapped {
    if (self.onRenameTap) self.onRenameTap();
}

- (void)setJiggling:(BOOL)jiggle {
    if (jiggle) {
        CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"transform.rotation"];
        anim.toValue = @(0.03);
        anim.fromValue = @(-0.03);
        anim.duration = 0.12;
        anim.autoreverses = YES;
        anim.repeatCount = 100000;
        [self.thumbView.layer addAnimation:anim forKey:@"ccmJiggle"];
    } else {
        [self.thumbView.layer removeAnimationForKey:@"ccmJiggle"];
    }
}
@end

#pragma mark - 素材网格视图

@interface CCM2BackgroundsGridView : UIView <UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout, UITextFieldDelegate>
@property (nonatomic, strong) UICollectionView *cv;
@property (nonatomic, strong) NSMutableArray<NSString *> *files;
@property (nonatomic, assign) BOOL editing;
@property (nonatomic, weak) UIViewController *host;
@property (nonatomic, strong) UITextField *activeField;
@property (nonatomic, strong) NSIndexPath *activeIndex;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UILabel *footerLabel;
@end

@implementation CCM2BackgroundsGridView

- (instancetype)initWithFrame:(CGRect)frame host:(UIViewController *)host {
    self = [super initWithFrame:frame];
    if (self) {
        _host = host;

        UICollectionViewFlowLayout *fl = [[UICollectionViewFlowLayout alloc] init];
        fl.scrollDirection = UICollectionViewScrollDirectionVertical;
        fl.minimumInteritemSpacing = 14;
        fl.minimumLineSpacing = 18;
        fl.sectionInset = UIEdgeInsetsMake(16, 16, 40, 16);

        _cv = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:fl];
        _cv.backgroundColor = [UIColor colorWithWhite:0.94 alpha:1.0];
        _cv.dataSource = self;
        _cv.delegate = self;
        _cv.alwaysBounceVertical = YES;
        [_cv registerClass:[CCM2BgCell class] forCellWithReuseIdentifier:@"ccmbg"];
        [_cv registerClass:[UICollectionReusableView class] forSupplementaryViewOfKind:UICollectionElementKindSectionFooter withReuseIdentifier:@"ccmfooter"];
        [self addSubview:_cv];

        _emptyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _emptyLabel.text = @"未找到背景文件";
        _emptyLabel.textColor = [UIColor secondaryLabelColor];
        _emptyLabel.font = [UIFont systemFontOfSize:15];
        _emptyLabel.textAlignment = NSTextAlignmentCenter;
        [_cv addSubview:_emptyLabel];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ccm_onChanged) name:kCCMGridChanged object:nil];

        [self ccm_rescan];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.cv.frame = self.bounds;
    self.emptyLabel.frame = CGRectMake(0, 120, self.bounds.size.width, 30);
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark 数据

- (void)ccm_rescan {
    ccm_ensureDir();
    NSArray *all = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:kCCMDir error:nil] ?: @[];
    NSMutableArray *arr = [NSMutableArray array];
    for (NSString *n in all) {
        if (ccm_supportedName(n)) [arr addObject:n];
    }
    [arr sortUsingSelector:@selector(localizedStandardCompare:)];
    self.files = arr;
    self.emptyLabel.hidden = self.files.count > 0;
    [self.cv reloadData];
}

- (void)ccm_onChanged {
    [self ccm_rescan];
}

- (NSString *)ccm_filePathForIndex:(NSIndexPath *)ip {
    return [kCCMDir stringByAppendingPathComponent:self.files[ip.row]];
}

- (void)ccm_startJiggling {
    for (CCM2BgCell *c in self.cv.visibleCells) [c setJiggling:YES];
}

- (void)ccm_stopJiggling {
    for (CCM2BgCell *c in self.cv.visibleCells) [c setJiggling:NO];
}

#pragma mark 编辑态

- (void)enterEditing {
    if (self.editing) return;
    self.editing = YES;
    [self.cv reloadData];
    [self ccm_startJiggling];

    UIBarButtonItem *done = objc_getAssociatedObject(self.host, kCCMKeyDoneBtn);
    if (!done) {
        done = [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleDone target:self action:@selector(exitEditing)];
        objc_setAssociatedObject(self.host, kCCMKeyDoneBtn, done, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSMutableArray *arr = [self.host.navigationItem.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
    if (![arr containsObject:done]) [arr addObject:done];
    self.host.navigationItem.rightBarButtonItems = arr;
}

- (void)exitEditing {
    if (!self.editing) return;
    [self.activeField resignFirstResponder];
    self.editing = NO;
    UIBarButtonItem *done = objc_getAssociatedObject(self.host, kCCMKeyDoneBtn);
    if (done) {
        NSMutableArray *arr = [self.host.navigationItem.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
        [arr removeObject:done];
        self.host.navigationItem.rightBarButtonItems = arr;
    }
    [self.cv reloadData];
    [self ccm_stopJiggling];
}

#pragma mark 删除 / 选中 / 改名

- (void)ccm_deleteFile:(NSIndexPath *)ip {
    NSString *path = [self ccm_filePathForIndex:ip];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    [self ccm_rescan];
    ccm_postGridChanged();
}

- (void)ccm_selectFile:(NSIndexPath *)ip {
    NSString *file = self.files[ip.row];
    NSString *key = ccm_isCompactPage(self.host) ? @"selectedCompactBackgroundFile" : @"selectedExpandedBackgroundFile";
    ccm_setPrefString(key, file);
    ccm_postPrefsChanged();
    [self.cv reloadData];
}

- (void)beginRename:(NSIndexPath *)ip {
    if (!self.files.count) return;
    // 先结束上一次未完成的编辑
    if (self.activeField) [self.activeField resignFirstResponder];
    CCM2BgCell *cell = (CCM2BgCell *)[self.cv cellForItemAtIndexPath:ip];
    if (!cell) return;
    UITextField *tf = [[UITextField alloc] initWithFrame:cell.nameButton.frame];
    tf.borderStyle = UITextBorderStyleRoundedRect;
    tf.font = [UIFont systemFontOfSize:10];
    tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    tf.returnKeyType = UIReturnKeyDone;
    tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    tf.text = [self.files[ip.row] stringByDeletingPathExtension];
    tf.delegate = self;
    [cell.contentView addSubview:tf];
    cell.nameButton.hidden = YES;
    self.activeField = tf;
    self.activeIndex = ip;
    [tf becomeFirstResponder];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    if (self.activeField != textField) return;
    NSIndexPath *ip = self.activeIndex;
    NSString *old = ip.row < self.files.count ? self.files[ip.row] : nil;
    NSString *newBase = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    // 先恢复当前 cell 的 UI，再改名刷新（避免 reload 复用残留输入框盖住其他名字）
    CCM2BgCell *curCell = (CCM2BgCell *)[self.cv cellForItemAtIndexPath:ip];
    [textField removeFromSuperview];
    self.activeField = nil;
    self.activeIndex = nil;
    if (curCell) curCell.nameButton.hidden = NO;
    if (old.length && newBase.length && ![newBase isEqualToString:old.stringByDeletingPathExtension]) {
        NSString *ext = old.pathExtension;
        NSString *newName = ext.length ? [newBase stringByAppendingPathExtension:ext] : newBase;
        NSString *oldPath = [kCCMDir stringByAppendingPathComponent:old];
        NSString *newPath = ccm_uniquePath(kCCMDir, newName);
        if (![oldPath isEqualToString:newPath]) {
            [[NSFileManager defaultManager] moveItemAtPath:oldPath toPath:newPath error:nil];
        }
        [self ccm_rescan];
        ccm_postGridChanged();
    }
}

#pragma mark 缩略图加载

- (void)ccm_loadThumb:(NSString *)path into:(CCM2BgCell *)cell at:(NSIndexPath *)ip {
    cell.currentPath = path;
    cell.thumbView.image = nil;
    NSString *ext = path.pathExtension.lowercaseString;
    BOOL isVideo = [@[@"mp4", @"mov"] containsObject:ext];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        UIImage *img = nil;
        if (isVideo) {
            AVURLAsset *asset = [AVURLAsset assetWithURL:[NSURL fileURLWithPath:path]];
            AVAssetImageGenerator *gen = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
            gen.appliesPreferredTrackTransform = YES;
            gen.maximumSize = CGSizeMake(320, 320);
            NSError *err = nil;
            CGImageRef cg = [gen copyCGImageAtTime:CMTimeMakeWithSeconds(0.1, 600) actualTime:NULL error:&err];
            if (cg) {
                img = [UIImage imageWithCGImage:cg];
                CGImageRelease(cg);
            }
        } else {
            img = [UIImage imageWithContentsOfFile:path];
        }
        if (!img) img = [UIImage systemImageNamed:@"film"];
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([cell.currentPath isEqualToString:path]) cell.thumbView.image = img;
        });
    });
}

#pragma mark UICollectionView

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)cv { return 1; }

- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)section {
    return self.files.count;
}

- (CGSize)collectionView:(UICollectionView *)cv layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)ip {
    CGFloat w = cv.bounds.size.width;
    if (w < 100) return CGSizeMake(100, 200);
    CGFloat side = (w - 32.0 - 28.0) / 3.0;
    CGFloat thumbH = side * 1.16;
    return CGSizeMake(side, thumbH + 54);
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)ip {
    CCM2BgCell *cell = [cv dequeueReusableCellWithReuseIdentifier:@"ccmbg" forIndexPath:ip];
    NSString *file = self.files[ip.row];
    NSString *path = [kCCMDir stringByAppendingPathComponent:file];
    [cell.nameButton setTitle:file forState:UIControlStateNormal];
    cell.nameButton.hidden = NO;
    // 清理复用残留的编辑输入框（防止盖住名字）
    for (UIView *v in cell.contentView.subviews) {
        if ([v isKindOfClass:[UITextField class]] && v != self.activeField) [v removeFromSuperview];
    }
    cell.deleteButton.hidden = !self.editing;
    cell.videoPill.hidden = YES;
    NSString *low = file.pathExtension.lowercaseString;
    if ([@[@"mp4", @"mov"] containsObject:low]) cell.videoPill.hidden = NO;

    NSString *selKey = ccm_isCompactPage(self.host) ? @"selectedCompactBackgroundFile" : @"selectedExpandedBackgroundFile";
    BOOL selected = [ccm_prefString(selKey) isEqualToString:file];
    cell.checkView.hidden = self.editing;
    cell.checkView.backgroundColor = selected ? [UIColor systemBlueColor] : [UIColor colorWithWhite:0.84 alpha:1.0];
    cell.checkView.image = selected ? [[UIImage systemImageNamed:@"checkmark"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] : nil;

    __weak typeof(self) ws = self;
    cell.onLongPress = ^{ [ws enterEditing]; };
    cell.onDelete = ^{ [ws ccm_deleteFile:ip]; };
    cell.onRenameTap = nil;
    if (self.editing) cell.onRenameTap = ^{ [ws beginRename:ip]; };
    [cell setJiggling:self.editing];
    [self ccm_loadThumb:path into:cell at:ip];
    return cell;
}

- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)ip {
    if (self.editing) return;
    [self ccm_selectFile:ip];
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)cv viewForSupplementaryElementOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)ip {
    UICollectionReusableView *v = [cv dequeueReusableSupplementaryViewOfKind:UICollectionElementKindSectionFooter withReuseIdentifier:@"ccmfooter" forIndexPath:ip];
    if (!self.footerLabel || self.footerLabel.superview != v) {
        [self.footerLabel removeFromSuperview];
        self.footerLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.footerLabel.numberOfLines = 0;
        self.footerLabel.font = [UIFont systemFontOfSize:12];
        self.footerLabel.textColor = [UIColor secondaryLabelColor];
        self.footerLabel.text = @"将多个 mp4/mov/gif/png/jpg/jpeg 放到 /var/mobile/Media/CCMusicModuleBackgrounds。这里选择的素材只会作用到当前这个状态；如果这个状态还没单独选过，就会回退到默认背景选择。\n\n长按素材进入编辑模式：点红色 − 删除，点名字改名。背景视频已强制静音，不会打断音乐。";
        [v addSubview:self.footerLabel];
    }
    return v;
}

- (CGSize)collectionView:(UICollectionView *)cv layout:(UICollectionViewLayout *)layout referenceSizeForFooterInSection:(NSInteger)section {
    return CGSizeMake(cv.bounds.size.width - 24, 120);
}

- (void)collectionView:(UICollectionView *)cv willDisplaySupplementaryView:(UICollectionReusableView *)view forElementKind:(NSString *)elementKind atIndexPath:(NSIndexPath *)ip {
    if ([elementKind isEqualToString:UICollectionElementKindSectionFooter]) {
        self.footerLabel.frame = CGRectInset(view.bounds, 4, 0);
    }
}

@end

#pragma mark - 系统原生选择器协调器（相册=PHPicker, 文件=UIDocumentPicker）

@interface CCM2ImportCoordinator : NSObject <PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic, weak) id host;
+ (instancetype)shared;
- (void)presentPhotoPickerFrom:(id)host;
- (void)presentDocumentPickerFrom:(id)host;
@end

@implementation CCM2ImportCoordinator

+ (instancetype)shared {
    static CCM2ImportCoordinator *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[CCM2ImportCoordinator alloc] init]; });
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
        ccm_postGridChanged();
        if (!h) return;
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

static void ccm2_importTappedImpl(id self, SEL _cmd) {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"导入素材" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"从相册导入" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        [[CCM2ImportCoordinator shared] presentPhotoPickerFrom:self];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"从文件导入" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        [[CCM2ImportCoordinator shared] presentDocumentPickerFrom:self];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UIBarButtonItem *imp = objc_getAssociatedObject(self, kCCMKeyImportBtn);
    if (imp && ac.popoverPresentationController) {
        ac.popoverPresentationController.barButtonItem = imp;
    }
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - 背景视频静音（SpringBoard：防止背景视频声音打断音乐 App）

@interface MCCContentViewController : UIViewController
@property (nonatomic, strong) AVPlayer *videoPlayer;
@end

static void ccm2_killVideoAudioOnce(AVPlayer *player) {
    if (!player) return;
    player.muted = YES;
    AVPlayerItem *item = player.currentItem;
    if (!item) return;
    NSMutableArray *params = [NSMutableArray array];
    for (AVPlayerItemTrack *t in item.tracks) {
        AVAssetTrack *at = t.assetTrack;
        if (at && [at.mediaType isEqualToString:AVMediaTypeAudio]) {
            t.enabled = NO;
            AVMutableAudioMixInputParameters *ip = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:at];
            [ip setVolume:0.0 atTime:kCMTimeZero];
            [params addObject:ip];
        }
    }
    if (params.count) {
        AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
        mix.inputParameters = params;
        item.audioMix = mix;
    }
}

static void ccm2_killVideoAudio(AVPlayer *player) {
    if (!player) return;
    ccm2_killVideoAudioOnce(player);
    // assetTrack 异步加载，延迟补一次
    __weak AVPlayer *wp = player;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ccm2_killVideoAudioOnce(wp);
    });
}

%hook MCCContentViewController

- (void)setVideoPlayer:(AVPlayer *)player {
    %orig;
    ccm2_killVideoAudio(player);
}

- (void)ccm_applyBackgroundIfNeeded {
    %orig;
    [self ccm2_tameVideo];
}

- (void)ccm_videoPlayerItemDidPlayToEnd:(id)note {
    %orig;
    [self ccm2_tameVideo];
}

// 模块每秒 tick 都会同步一次；在音乐真正在播时把背景视频暂停掉，
// 避免其音频会话反复打断音乐 App（只有从模块按钮发起的播放才会压制视频，
// 音乐 App 自己播放时模块不知道，所以这里兜底）
- (void)syncPlaybackStateAndUpdateUI {
    %orig;
    [self ccm2_tameVideo];
}

%new
- (void)ccm2_tameVideo {
    AVPlayer *p = self.videoPlayer;
    if (!p) return;
    BOOL musicPlaying = NO;
    if ([self respondsToSelector:@selector(isNowPlaying)]) {
        musicPlaying = [(id)self isNowPlaying];
    }
    if (musicPlaying) {
        [p pause];
        p.rate = 0.0;
    }
    ccm2_killVideoAudio(p);
}

%end

#pragma mark - Hook（注入 Preferences 进程）

%hook PSListController

- (void)viewDidLoad {
    %orig;
    if (!ccm_isSelectionPage(self)) return;
    // 移除旧版导入器（CCMaterialImporter.dylib）留下的网格，避免两层叠加
    Class legacyCls = NSClassFromString(@"CCMBackgroundsGridView");
    if (legacyCls) {
        for (UIView *v in [self.view subviews]) {
            if ([v isKindOfClass:legacyCls]) [v removeFromSuperview];
        }
    }
    CCM2BackgroundsGridView *gv = objc_getAssociatedObject(self, kCCMKeyGridView);
    if (!gv) {
        gv = [[CCM2BackgroundsGridView alloc] initWithFrame:self.view.bounds host:self];
        gv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.view addSubview:gv];
        objc_setAssociatedObject(self, kCCMKeyGridView, gv, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!ccm_isSelectionPage(self)) return;
    // 确保「导入」selector 已注册到当前 controller 类（手动 addMethod，兜底 Logos 自动注册）
    SEL sel = @selector(ccm2_importTapped);
    if (![self respondsToSelector:sel]) {
        class_addMethod([self class], sel, (IMP)(void(*)(id,SEL))ccm2_importTappedImpl, "v@:");
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
    CCM2BackgroundsGridView *gv2 = objc_getAssociatedObject(self, kCCMKeyGridView);
    if (gv2.superview) [self.view bringSubviewToFront:gv2];
}

%end
