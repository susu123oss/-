#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <libkern/OSCacheControl.h>

// 内存补丁工具函数：修改内存保护 -> 写入指令 -> 恢复保护 -> 刷新指令缓存
static BOOL patchMemory(uintptr_t targetAddr, const void *bytes, size_t length) {
    mach_port_t task = mach_task_self();
    vm_size_t pageSize = vm_page_size;
    uintptr_t pageStart = targetAddr & ~(pageSize - 1);
    vm_size_t patchSize = (targetAddr + length - pageStart + pageSize - 1) & ~(pageSize - 1);

    // 修改内存页为可写
    kern_return_t kr = vm_protect(task, (vm_address_t)pageStart, patchSize, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[PVZSun] vm_protect RW 失败: %d", kr);
        return NO;
    }

    // 写入新机器码
    memcpy((void *)targetAddr, bytes, length);

    // 恢复内存页为可读可执行
    kr = vm_protect(task, (vm_address_t)pageStart, patchSize, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[PVZSun] vm_protect RX 警告: %d", kr);
    }

    // 刷新 ARM64 指令缓存
    sys_icache_invalidate((void *)targetAddr, length);
    return YES;
}

// 获取目标模块基地址
static uintptr_t getModuleBase(const char *moduleName) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, moduleName)) {
            return (uintptr_t)_dyld_get_image_header(i);
        }
    }
    return 0; // 未匹配到目标模块时安全返回 0，避免误改主二进制
}

// 补丁配置与地址定义
static const char * const kPVZPluginVersion = "1.3.1";
static uintptr_t g_lawnBase = 0;
static const uintptr_t kSunCostPatchOffset = 0xFDF94;    // sub w0, w0, w20 -> add w0, w0, w20
static const uintptr_t kFreeCostPatchOffset = 0x11B470;  // GetCurrentPlantCost 恒返回 0: mov w0, wzr; ret
static const uintptr_t kCooldownPatchOffset = 0x1B6D28;  // SeedPacket::Update 冷却判断: ldrb w0, [x19, #0x3b] -> b 0x1B6D44

static const uint32_t kSubOpcode = 0x4b140000;         // sub w0, w0, w20
static const uint32_t kAddOpcode = 0x0b140000;         // add w0, w0, w20
static const uint64_t kCostOrigBytes = 0xa9014ff4a9bd57f6ULL; // f6 57 bd a9 f4 4f 01 a9 (stp x22, x21... stp x20, x19...)
static const uint64_t kCostPatchBytes = 0xd65f03c02a1f03e0ULL; // e0 03 1f 2a c0 03 5f d6 (mov w0, wzr; ret)
static const uint32_t kCdOrigOpcode = 0x3940ee60;        // ldrb w0, [x19, #0x3b]
static const uint32_t kCdPatchOpcode = 0x14000007;       // b #0x1c (直跳 0x1B6D44 强制就绪点亮)

// 4. 全屏自动收集掉落物 (Coin::Update 0x143638 未收集分支直接调用 Coin::Collect 0x144540，保留完整音效与飞行动画)
static const uintptr_t kAutoCollectPatchOffset = 0x143638;
static const uint32_t kCollectOrigOpcode = 0x94000762;    // bl 0x1453c0 (原等待掉落)
static const uint32_t kCollectPatchOpcode = 0x940003c2;   // bl 0x144540 (直接触发收集吸附与动画)
static const uintptr_t kOldCollectFixOffset = 0x1461E0;   // 历史误改点复原保护
static const uint32_t kOldCollectFixOpcode = 0x540000e2;  // b.hs 0x1461fc

// 5. 植物绝对无敌保护 (多点底层防御：僵尸啃咬免伤、啃死拦截、巨人重砸、冰车/投石车碾压与自爆免疫，不影响铲子)
typedef struct {
    uintptr_t offset;
    uint32_t origOp;
    uint32_t patchOp;
} PatchPoint;

static const PatchPoint kInvulnPoints[] = {
    { 0x25C2E0, 0xb941ca60, 0x14000073 }, // Zombie::EatPlant 啃咬结算跳过: ldr w0, [x19, 0x1c8] -> b 0x25c4ac (不扣血不致死)
    { 0x18AA90, 0xa9bf7bfd, 0xd65f03c0 }, // Plant::EatenDie 被吃死阻断: stp x29, x30... -> ret (铲子不走此处仍正常可用)
    { 0x25E5BC, 0x97fcb141, 0xd503201f }, // Bungee Zombie Steal 1 (bl Plant::Die -> nop)
    { 0x25ED88, 0x97fcaf4e, 0xd503201f }, // Bungee Zombie Steal 2 (bl Plant::Die -> nop)
    { 0x26971C, 0x97fc84e9, 0xd503201f }, // Gargantuar Smash (bl Plant::Die -> nop)
    { 0x270940, 0x97fc6860, 0xd503201f }, // Zamboni Crush (bl Plant::Die -> nop)
    { 0x2790B0, 0x97fc4684, 0xd503201f }, // Catapult Crush (bl Plant::Die -> nop)
    { 0x279740, 0x97fc44e0, 0xd503201f }  // Jack-in-the-box Explode (bl Plant::Die -> nop)
};

// 持久化配置键名与读写辅助
static NSString * const kPrefKeySunAdd       = @"PVZSun_Pref_SunAdd";
static NSString * const kPrefKeyFreePlant    = @"PVZSun_Pref_FreePlant";
static NSString * const kPrefKeyNoCooldown   = @"PVZSun_Pref_NoCooldown";
static NSString * const kPrefKeyAutoCollect  = @"PVZSun_Pref_AutoCollect";
static NSString * const kPrefKeyInvulnerable = @"PVZSun_Pref_Invulnerable";

static BOOL getPrefBool(NSString *key, BOOL defaultVal) {
    id val = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    if (val == nil) {
        return defaultVal;
    }
    return [val boolValue];
}

static void setPrefBool(NSString *key, BOOL val) {
    [[NSUserDefaults standardUserDefaults] setBool:val forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

// 开关处理函数：阳光不减反增加
static void toggleSunAdd(BOOL enabled) {
    if (!g_lawnBase) g_lawnBase = getModuleBase("Lawn_IOS");
    if (!g_lawnBase) return;
    uintptr_t target = g_lawnBase + kSunCostPatchOffset;

    // 指令指纹防护校验：确保当前位置确为预期指令，防止游戏版本差异导致覆写未知逻辑
    uint32_t currentOp = *(volatile uint32_t *)target;
    if (currentOp != kSubOpcode && currentOp != kAddOpcode) {
        NSLog(@"[PVZSun] 警告：阳光目标地址 0x%lx 指令校验失败 (当前: 0x%08x)，已跳过覆写以防闪退", (unsigned long)target, currentOp);
        return;
    }

    uint32_t code = enabled ? kAddOpcode : kSubOpcode;
    if (patchMemory(target, &code, sizeof(code))) {
        NSLog(@"[PVZSun] 阳光不减反增状态已切换: %@", enabled ? @"开启" : @"关闭");
    }
}

// 开关处理函数：任意植物免费种植
static void toggleFreePlant(BOOL enabled) {
    if (!g_lawnBase) g_lawnBase = getModuleBase("Lawn_IOS");
    if (!g_lawnBase) return;
    uintptr_t target = g_lawnBase + kFreeCostPatchOffset;

    // 指令指纹防护校验
    uint64_t currentBytes = *(volatile uint64_t *)target;
    if (currentBytes != kCostOrigBytes && currentBytes != kCostPatchBytes) {
        NSLog(@"[PVZSun] 警告：免费种植目标地址 0x%lx 指令校验失败 (当前: 0x%016llx)，已跳过覆写以防闪退", (unsigned long)target, currentBytes);
        return;
    }

    uint64_t code = enabled ? kCostPatchBytes : kCostOrigBytes;
    if (patchMemory(target, &code, sizeof(code))) {
        NSLog(@"[PVZSun] 任意植物免费种植状态已切换: %@", enabled ? @"开启" : @"关闭");
    }
}

// 开关处理函数：植物种植无冷却
static void toggleNoCooldown(BOOL enabled) {
    if (!g_lawnBase) g_lawnBase = getModuleBase("Lawn_IOS");
    if (!g_lawnBase) return;
    uintptr_t target = g_lawnBase + kCooldownPatchOffset;

    // 指令指纹防护校验：确保当前位置确为预期指令，防止游戏版本差异导致覆写未知逻辑
    uint32_t currentOp = *(volatile uint32_t *)target;
    if (currentOp != kCdOrigOpcode && currentOp != kCdPatchOpcode) {
        NSLog(@"[PVZSun] 警告：冷却目标地址 0x%lx 指令校验失败 (当前: 0x%08x)，已跳过覆写以防闪退", (unsigned long)target, currentOp);
        return;
    }

    uint32_t code = enabled ? kCdPatchOpcode : kCdOrigOpcode;
    if (patchMemory(target, &code, sizeof(code))) {
        NSLog(@"[PVZSun] 植物种植无冷却状态已切换: %@", enabled ? @"开启" : @"关闭");
    }
}

// 开关处理函数：全屏自动收集掉落物
static void toggleAutoCollect(BOOL enabled) {
    if (!g_lawnBase) g_lawnBase = getModuleBase("Lawn_IOS");
    if (!g_lawnBase) return;

    // 复原历史误改点 (确保 0x1461E0 恢复为原版 b.hs，保证飞行动画完整)
    uintptr_t oldTarget = g_lawnBase + kOldCollectFixOffset;
    uint32_t oldOp = *(volatile uint32_t *)oldTarget;
    if (oldOp != kOldCollectFixOpcode) {
        patchMemory(oldTarget, &kOldCollectFixOpcode, sizeof(kOldCollectFixOpcode));
    }

    // 应用真正的掉落物自动吸附补丁
    uintptr_t target = g_lawnBase + kAutoCollectPatchOffset;

    uint32_t currentOp = *(volatile uint32_t *)target;
    if (currentOp != kCollectOrigOpcode && currentOp != kCollectPatchOpcode) {
        NSLog(@"[PVZSun] 警告：自动收集目标地址 0x%lx 指令校验失败 (当前: 0x%08x)，已跳过", (unsigned long)target, currentOp);
        return;
    }

    uint32_t code = enabled ? kCollectPatchOpcode : kCollectOrigOpcode;
    if (patchMemory(target, &code, sizeof(code))) {
        NSLog(@"[PVZSun] 全屏自动收集状态已切换: %@", enabled ? @"开启" : @"关闭");
    }
}

// 开关处理函数：植物绝对无敌保护
static void togglePlantInvulnerable(BOOL enabled) {
    if (!g_lawnBase) g_lawnBase = getModuleBase("Lawn_IOS");
    if (!g_lawnBase) return;

    size_t count = sizeof(kInvulnPoints) / sizeof(kInvulnPoints[0]);
    for (size_t i = 0; i < count; i++) {
        uintptr_t target = g_lawnBase + kInvulnPoints[i].offset;
        uint32_t currentOp = *(volatile uint32_t *)target;
        if (currentOp != kInvulnPoints[i].origOp && currentOp != kInvulnPoints[i].patchOp) {
            NSLog(@"[PVZSun] 警告：植物无敌点[%zu] 0x%lx 指令校验失败 (当前: 0x%08x)，跳过该点", i, (unsigned long)target, currentOp);
            continue;
        }
        uint32_t code = enabled ? kInvulnPoints[i].patchOp : kInvulnPoints[i].origOp;
        patchMemory(target, &code, sizeof(code));
    }
    NSLog(@"[PVZSun] 植物绝对无敌状态已切换: %@", enabled ? @"开启" : @"关闭");
}

// 统一应用当前配置的热补丁（含就绪校验与二次容错）
static void applyConfiguredPatches(void) {
    if (!g_lawnBase) g_lawnBase = getModuleBase("Lawn_IOS");
    if (!g_lawnBase) return;

    toggleSunAdd(getPrefBool(kPrefKeySunAdd, NO));
    toggleFreePlant(getPrefBool(kPrefKeyFreePlant, NO));
    toggleNoCooldown(getPrefBool(kPrefKeyNoCooldown, NO));
    toggleAutoCollect(getPrefBool(kPrefKeyAutoCollect, NO));
    togglePlantInvulnerable(getPrefBool(kPrefKeyInvulnerable, NO));
}

@class PVZModWindow;
@class PVZDraggableBall;

// UI: 悬浮球与弹出菜单管理器声明
@interface PVZModMenuManager : NSObject
@property (nonatomic, strong) PVZModWindow *modWindow;
@property (nonatomic, strong) PVZDraggableBall *floatingBall;
@property (nonatomic, strong) UIVisualEffectView *menuPanel;
@property (nonatomic, strong) UIView *dimBackground;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, assign) BOOL isAnimating;
+ (instancetype)shared;
- (void)initUI;
- (void)handleTransitionToSize:(CGSize)size coordinator:(id<UIViewControllerTransitionCoordinator>)coordinator;
- (void)updateLayoutOnBoundsChange;
@end

// 穿透点击的顶层悬浮专属窗口控制器
@interface PVZWindowViewController : UIViewController
@end

@implementation PVZWindowViewController
- (BOOL)shouldAutorotate {
    return YES;
}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    // 优先匹配当前活跃窗口/宿主界面的屏幕方向掩码，确保与宿主游戏绝对同步
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w != self.view.window && !w.hidden && w.rootViewController) {
            UIInterfaceOrientationMask mask = [w.rootViewController supportedInterfaceOrientations];
            if (mask != 0) return mask;
        }
    }
    return UIInterfaceOrientationMaskAll;
}
- (BOOL)prefersStatusBarHidden {
    return YES;
}
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [[PVZModMenuManager shared] handleTransitionToSize:size coordinator:coordinator];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [[PVZModMenuManager shared] updateLayoutOnBoundsChange];
}
@end

@interface PVZModWindow : UIWindow
@end

@implementation PVZModWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (hitView == self || hitView == self.rootViewController.view) {
        return nil; // 窗口空白区域触控穿透给游戏本身
    }
    return hitView;
}
@end

// 自定义高质感拖拽吸边悬浮球
@interface PVZDraggableBall : UIButton
@property (nonatomic, assign) CGPoint startLocation;
@property (nonatomic, assign) CGPoint startCenter;
@property (nonatomic, assign) BOOL hasMoved;
@property (nonatomic, strong) CAGradientLayer *gradientLayer;
@property (nonatomic, strong) UIImpactFeedbackGenerator *feedbackGenerator;
@property (nonatomic, copy) void (^tapHandler)(void);
- (void)resetIdleTimer;
- (void)adjustForContainerSize:(CGSize)size;
@end

@implementation PVZDraggableBall

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.layer.cornerRadius = frame.size.width / 2.0;
        self.layer.masksToBounds = NO;
        
        // 金色太阳质感渐变层
        self.gradientLayer = [CAGradientLayer layer];
        self.gradientLayer.frame = self.bounds;
        self.gradientLayer.cornerRadius = frame.size.width / 2.0;
        self.gradientLayer.colors = @[
            (id)[UIColor colorWithRed:0.98 green:0.75 blue:0.14 alpha:1.0].CGColor,
            (id)[UIColor colorWithRed:0.96 green:0.55 blue:0.05 alpha:1.0].CGColor
        ];
        self.gradientLayer.startPoint = CGPointMake(0.1, 0.1);
        self.gradientLayer.endPoint = CGPointMake(0.9, 0.9);
        [self.layer insertSublayer:self.gradientLayer atIndex:0];

        // 外发光与精致投影
        self.layer.shadowColor = [UIColor colorWithRed:0.96 green:0.60 blue:0.05 alpha:0.65].CGColor;
        self.layer.shadowOffset = CGSizeMake(0, 4);
        self.layer.shadowRadius = 10.0;
        self.layer.shadowOpacity = 0.85;
        self.layer.borderWidth = 1.5;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.85].CGColor;

        self.feedbackGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [self.feedbackGenerator prepare];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.gradientLayer.frame = self.bounds;
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    CGPoint pt = [[touches anyObject] locationInView:self.superview];
    self.startLocation = pt;
    self.startCenter = self.center;
    self.hasMoved = NO;
    
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(applyIdleState) object:nil];
    [UIView animateWithDuration:0.15 animations:^{
        self.alpha = 1.0;
        self.transform = CGAffineTransformMakeScale(1.08, 1.08);
    }];
    [[self superview] bringSubviewToFront:self];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesMoved:touches withEvent:event];
    CGPoint pt = [[touches anyObject] locationInView:self.superview];
    float dx = pt.x - self.startLocation.x;
    float dy = pt.y - self.startLocation.y;
    if (hypot(dx, dy) > 8.0) {
        self.hasMoved = YES;
        CGPoint newCenter = CGPointMake(self.startCenter.x + dx, self.startCenter.y + dy);
        
        CGFloat halfW = self.bounds.size.width / 2.0;
        CGFloat halfH = self.bounds.size.height / 2.0;
        CGSize superSize = self.superview.bounds.size;
        newCenter.x = MAX(halfW, MIN(superSize.width - halfW, newCenter.x));
        newCenter.y = MAX(halfH, MIN(superSize.height - halfH, newCenter.y));
        self.center = newCenter;
    }
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    [UIView animateWithDuration:0.15 animations:^{
        self.transform = CGAffineTransformIdentity;
    }];
    
    if (!self.hasMoved) {
        [self.feedbackGenerator impactOccurred];
        if (self.tapHandler) {
            self.tapHandler();
        }
    } else {
        [self.feedbackGenerator impactOccurred];
        CGFloat screenW = self.superview.bounds.size.width;
        CGFloat screenH = self.superview.bounds.size.height;
        CGFloat halfW = self.bounds.size.width / 2.0;
        CGFloat halfH = self.bounds.size.height / 2.0;
        UIEdgeInsets insets = UIEdgeInsetsZero;
        if (@available(iOS 11.0, *)) {
            insets = self.superview.safeAreaInsets;
        }
        CGFloat minX = halfW + 2.0;
        CGFloat maxX = screenW - halfW - 2.0;
        CGFloat targetX = (self.center.x < screenW / 2.0) ? minX : maxX;
        
        CGFloat minY = insets.top + 8.0 + halfH;
        CGFloat maxY = screenH - insets.bottom - 8.0 - halfH;
        CGFloat targetY = MAX(minY, MIN(maxY, self.center.y));

        [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.72 initialSpringVelocity:0.6 options:UIViewAnimationOptionCurveEaseOut animations:^{
            self.center = CGPointMake(targetX, targetY);
        } completion:nil];
    }
    [self resetIdleTimer];
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    self.hasMoved = NO;
    [UIView animateWithDuration:0.15 animations:^{
        self.transform = CGAffineTransformIdentity;
    }];
    [self resetIdleTimer];
}

- (void)resetIdleTimer {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(applyIdleState) object:nil];
    [self performSelector:@selector(applyIdleState) withObject:nil afterDelay:3.5];
}

- (void)applyIdleState {
    [UIView animateWithDuration:0.3 animations:^{
        self.alpha = 0.65;
    }];
}

- (void)adjustForContainerSize:(CGSize)size {
    if (size.width <= 0 || size.height <= 0) return;
    CGFloat halfW = self.bounds.size.width / 2.0;
    CGFloat halfH = self.bounds.size.height / 2.0;
    UIEdgeInsets insets = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) {
        insets = self.superview ? self.superview.safeAreaInsets : UIEdgeInsetsZero;
    }
    CGFloat minX = halfW + 2.0;
    CGFloat maxX = size.width - halfW - 2.0;
    CGFloat targetX = (self.center.x < size.width / 2.0) ? minX : maxX;

    CGFloat minY = insets.top + 8.0 + halfH;
    CGFloat maxY = size.height - insets.bottom - 8.0 - halfH;
    CGFloat targetY = MAX(minY, MIN(maxY, self.center.y));
    self.center = CGPointMake(targetX, targetY);
}
@end

@implementation PVZModMenuManager

+ (instancetype)shared {
    static PVZModMenuManager *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[PVZModMenuManager alloc] init];
    });
    return inst;
}

- (void)initUI {
    if (self.floatingBall) return;

    CGRect screenBounds = [UIScreen mainScreen].bounds;
    
    // 优先匹配当前活跃的 UIWindowScene
    UIWindowScene *activeScene = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                activeScene = (UIWindowScene *)scene;
                break;
            }
        }
    }
    
    if (@available(iOS 13.0, *)) {
        if (activeScene) {
            self.modWindow = [[PVZModWindow alloc] initWithWindowScene:activeScene];
        } else {
            self.modWindow = [[PVZModWindow alloc] initWithFrame:screenBounds];
        }
    } else {
        self.modWindow = [[PVZModWindow alloc] initWithFrame:screenBounds];
    }
    
    PVZWindowViewController *rootVC = [[PVZWindowViewController alloc] init];
    rootVC.view.backgroundColor = [UIColor clearColor];
    self.modWindow.rootViewController = rootVC;
    self.modWindow.backgroundColor = [UIColor clearColor];
    self.modWindow.windowLevel = UIWindowLevelAlert + 100;
    self.modWindow.hidden = NO;
    self.modWindow.userInteractionEnabled = YES;

    // 创建悬浮球
    CGFloat ballSize = 52.0;
    CGFloat maxDim = MAX(screenBounds.size.width, screenBounds.size.height);
    CGFloat screenW = rootVC.view.bounds.size.width > 0 ? rootVC.view.bounds.size.width : maxDim;
    CGFloat defaultX = screenW - ballSize - 2.0;
    self.floatingBall = [[PVZDraggableBall alloc] initWithFrame:CGRectMake(defaultX, 140, ballSize, ballSize)];
    [self.floatingBall setTitle:@"☀️" forState:UIControlStateNormal];
    self.floatingBall.titleLabel.font = [UIFont systemFontOfSize:26];

    __weak typeof(self) weakSelf = self;
    self.floatingBall.tapHandler = ^{
        [weakSelf toggleMenu];
    };
    [self.floatingBall resetIdleTimer];

    [rootVC.view addSubview:self.floatingBall];
    [self.floatingBall adjustForContainerSize:rootVC.view.bounds.size];

    // 创建半透明背景遮罩
    self.dimBackground = [[UIView alloc] initWithFrame:rootVC.view.bounds];
    self.dimBackground.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.dimBackground.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    self.dimBackground.alpha = 0;
    UITapGestureRecognizer *tapBg = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleMenu)];
    [self.dimBackground addGestureRecognizer:tapBg];

    // 创建功能菜单面板 (深色毛玻璃，保持 316pt 紧凑优雅居中展示)
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    self.menuPanel = [[UIVisualEffectView alloc] initWithEffect:blur];
    CGFloat panelW = 320.0;
    CGFloat panelH = 316.0;
    self.menuPanel.frame = CGRectMake((rootVC.view.bounds.size.width - panelW) / 2.0,
                                      (rootVC.view.bounds.size.height - panelH) / 2.0,
                                      panelW, panelH);
    self.menuPanel.layer.cornerRadius = 22.0;
    self.menuPanel.layer.masksToBounds = NO;
    self.menuPanel.layer.shadowColor = [UIColor colorWithWhite:0 alpha:0.55].CGColor;
    self.menuPanel.layer.shadowOffset = CGSizeMake(0, 10);
    self.menuPanel.layer.shadowRadius = 24.0;
    self.menuPanel.layer.shadowOpacity = 1.0;
    self.menuPanel.transform = CGAffineTransformMakeScale(0.85, 0.85);
    self.menuPanel.alpha = 0;

    UIView *content = self.menuPanel.contentView;
    content.layer.cornerRadius = 22.0;
    content.layer.masksToBounds = YES;
    content.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
    content.layer.borderWidth = 1.0;

    // 标题栏：发光小图标底座、标题与版本胶囊
    UIView *iconBadgeBg = [[UIView alloc] initWithFrame:CGRectMake(16, 12, 28, 28)];
    iconBadgeBg.backgroundColor = [UIColor colorWithRed:0.98 green:0.75 blue:0.14 alpha:0.20];
    iconBadgeBg.layer.cornerRadius = 8.0;
    iconBadgeBg.layer.borderWidth = 0.5;
    iconBadgeBg.layer.borderColor = [UIColor colorWithRed:0.98 green:0.75 blue:0.14 alpha:0.40].CGColor;
    [content addSubview:iconBadgeBg];

    UILabel *iconBadge = [[UILabel alloc] initWithFrame:iconBadgeBg.bounds];
    iconBadge.text = @"☀️";
    iconBadge.font = [UIFont systemFontOfSize:16];
    iconBadge.textAlignment = NSTextAlignmentCenter;
    [iconBadgeBg addSubview:iconBadge];

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(52, 14, 150, 24)];
    titleLabel.text = @"植物大战僵尸 辅助控制";
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [content addSubview:titleLabel];

    UILabel *verBadge = [[UILabel alloc] initWithFrame:CGRectMake(208, 17, 44, 18)];
    verBadge.text = [NSString stringWithUTF8String:kPVZPluginVersion];
    verBadge.textColor = [UIColor colorWithRed:0.20 green:0.85 blue:0.55 alpha:1.0];
    verBadge.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightMedium];
    verBadge.textAlignment = NSTextAlignmentCenter;
    verBadge.backgroundColor = [UIColor colorWithRed:0.06 green:0.72 blue:0.51 alpha:0.15];
    verBadge.layer.cornerRadius = 9.0;
    verBadge.layer.masksToBounds = YES;
    [content addSubview:verBadge];

    // 现代化胶囊关闭按钮
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(panelW - 42, 13, 26, 26);
    closeBtn.layer.cornerRadius = 13.0;
    closeBtn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor colorWithWhite:0.80 alpha:1.0] forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [closeBtn addTarget:self action:@selector(toggleMenu) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:closeBtn];

    // 分割线
    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(16, 46, panelW - 32, 0.5)];
    line.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    [content addSubview:line];

    // 滚动区域容纳五大核心功能卡片
    self.scrollView = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 48, panelW, 256)];
    self.scrollView.contentSize = CGSizeMake(panelW, 298);
    self.scrollView.showsVerticalScrollIndicator = YES;
    self.scrollView.alwaysBounceVertical = YES;
    if (@available(iOS 13.0, *)) {
        self.scrollView.automaticallyAdjustsScrollIndicatorInsets = NO;
    }
    [content addSubview:self.scrollView];

    // 五大核心功能卡片（带专属图标与高辨识度视觉设计）
    [self addToggleItemIn:self.scrollView y:4 icon:@"☀️" title:@"阳光不减反增加" desc:@"种植植物不消耗，反而补充对应阳光" defaultOn:getPrefBool(kPrefKeySunAdd, NO) action:@selector(sunAddChanged:)];

    [self addToggleItemIn:self.scrollView y:62 icon:@"🌱" title:@"任意植物免费种植" desc:@"植物花费恒为0，开局立即可种" defaultOn:getPrefBool(kPrefKeyFreePlant, NO) action:@selector(freePlantChanged:)];

    [self addToggleItemIn:self.scrollView y:120 icon:@"⚡" title:@"植物种植无冷却" desc:@"卡片种植后瞬间点亮，无需等待冷却" defaultOn:getPrefBool(kPrefKeyNoCooldown, NO) action:@selector(noCooldownChanged:)];

    [self addToggleItemIn:self.scrollView y:178 icon:@"🧲" title:@"全屏自动吸附掉落" desc:@"阳光、金币、钻石生成瞬间自动入账" defaultOn:getPrefBool(kPrefKeyAutoCollect, NO) action:@selector(autoCollectChanged:)];

    [self addToggleItemIn:self.scrollView y:236 icon:@"🛡️" title:@"植物绝对无敌保护" desc:@"免疫僵尸啃咬、巨人重砸、冰车碾压与自爆" defaultOn:getPrefBool(kPrefKeyInvulnerable, NO) action:@selector(plantInvulnerableChanged:)];

}

- (void)addToggleItemIn:(UIView *)parent y:(CGFloat)y icon:(NSString *)icon title:(NSString *)title desc:(NSString *)desc defaultOn:(BOOL)defaultOn action:(SEL)action {
    CGFloat w = parent.bounds.size.width;
    CGFloat cardW = w - 32;
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(16, y, cardW, 54)];
    card.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.07];
    card.layer.cornerRadius = 14.0;
    card.layer.borderWidth = 0.5;
    card.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;

    // 左侧专属图标圆角容器
    UIView *iconBox = [[UIView alloc] initWithFrame:CGRectMake(10, 9, 36, 36)];
    iconBox.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    iconBox.layer.cornerRadius = 10.0;
    iconBox.layer.borderWidth = 0.5;
    iconBox.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.10].CGColor;
    [card addSubview:iconBox];

    UILabel *iconLabel = [[UILabel alloc] initWithFrame:iconBox.bounds];
    iconLabel.text = icon;
    iconLabel.font = [UIFont systemFontOfSize:18];
    iconLabel.textAlignment = NSTextAlignmentCenter;
    [iconBox addSubview:iconLabel];

    CGFloat textW = cardW - 54 - 64;
    UILabel *tLabel = [[UILabel alloc] initWithFrame:CGRectMake(54, 8, textW, 19)];
    tLabel.text = title;
    tLabel.textColor = [UIColor whiteColor];
    tLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [card addSubview:tLabel];

    UILabel *dLabel = [[UILabel alloc] initWithFrame:CGRectMake(54, 29, textW, 16)];
    dLabel.text = desc;
    dLabel.textColor = [UIColor colorWithWhite:0.70 alpha:1.0];
    dLabel.font = [UIFont systemFontOfSize:10.5];
    dLabel.numberOfLines = 1;
    [card addSubview:dLabel];

    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(cardW - 60, 11, 48, 30)];
    sw.on = defaultOn;
    sw.onTintColor = [UIColor colorWithRed:0.06 green:0.75 blue:0.52 alpha:1.0];
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [card addSubview:sw];

    [parent addSubview:card];
}

- (void)sunAddChanged:(UISwitch *)sw {
    UISelectionFeedbackGenerator *feedback = [[UISelectionFeedbackGenerator alloc] init];
    [feedback selectionChanged];
    setPrefBool(kPrefKeySunAdd, sw.isOn);
    toggleSunAdd(sw.isOn);
}

- (void)freePlantChanged:(UISwitch *)sw {
    UISelectionFeedbackGenerator *feedback = [[UISelectionFeedbackGenerator alloc] init];
    [feedback selectionChanged];
    setPrefBool(kPrefKeyFreePlant, sw.isOn);
    toggleFreePlant(sw.isOn);
}

- (void)noCooldownChanged:(UISwitch *)sw {
    UISelectionFeedbackGenerator *feedback = [[UISelectionFeedbackGenerator alloc] init];
    [feedback selectionChanged];
    setPrefBool(kPrefKeyNoCooldown, sw.isOn);
    toggleNoCooldown(sw.isOn);
}

- (void)autoCollectChanged:(UISwitch *)sw {
    UISelectionFeedbackGenerator *feedback = [[UISelectionFeedbackGenerator alloc] init];
    [feedback selectionChanged];
    setPrefBool(kPrefKeyAutoCollect, sw.isOn);
    toggleAutoCollect(sw.isOn);
}

- (void)plantInvulnerableChanged:(UISwitch *)sw {
    UISelectionFeedbackGenerator *feedback = [[UISelectionFeedbackGenerator alloc] init];
    [feedback selectionChanged];
    setPrefBool(kPrefKeyInvulnerable, sw.isOn);
    togglePlantInvulnerable(sw.isOn);
}

- (void)handleTransitionToSize:(CGSize)size coordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    if (coordinator) {
        [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> _Nonnull context) {
            [self.floatingBall adjustForContainerSize:size];
            if (self.menuPanel && self.menuPanel.superview) {
                self.dimBackground.frame = CGRectMake(0, 0, size.width, size.height);
                self.menuPanel.center = CGPointMake(size.width / 2.0, size.height / 2.0);
            }
        } completion:^(id<UIViewControllerTransitionCoordinatorContext> _Nonnull context) {
            [self.floatingBall adjustForContainerSize:size];
        }];
    } else {
        [self.floatingBall adjustForContainerSize:size];
        if (self.menuPanel && self.menuPanel.superview) {
            self.dimBackground.frame = CGRectMake(0, 0, size.width, size.height);
            self.menuPanel.center = CGPointMake(size.width / 2.0, size.height / 2.0);
        }
    }
}

- (void)updateLayoutOnBoundsChange {
    if (!self.modWindow || !self.modWindow.rootViewController) return;
    CGSize currentSize = self.modWindow.rootViewController.view.bounds.size;
    if (currentSize.width <= 0 || currentSize.height <= 0) return;
    [self.floatingBall adjustForContainerSize:currentSize];
    if (self.dimBackground && self.dimBackground.superview) {
        self.dimBackground.frame = CGRectMake(0, 0, currentSize.width, currentSize.height);
    }
    if (self.menuPanel && self.menuPanel.superview) {
        self.menuPanel.center = CGPointMake(currentSize.width / 2.0, currentSize.height / 2.0);
    }
}

- (void)toggleMenu {
    if (self.isAnimating) return;
    self.isAnimating = YES;

    BOOL opening = (self.menuPanel.alpha < 0.5);
    if (opening) {
        UIView *rootView = self.modWindow.rootViewController.view;
        self.dimBackground.frame = rootView.bounds;
        CGFloat panelW = 320.0;
        CGFloat panelH = 316.0;
        self.menuPanel.center = CGPointMake(rootView.bounds.size.width / 2.0, rootView.bounds.size.height / 2.0);
        
        [rootView addSubview:self.dimBackground];
        [rootView addSubview:self.menuPanel];
        [rootView bringSubviewToFront:self.dimBackground];
        [rootView bringSubviewToFront:self.menuPanel];
        [rootView bringSubviewToFront:self.floatingBall];
        
        [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.78 initialSpringVelocity:0.6 options:0 animations:^{
            self.dimBackground.alpha = 1.0;
            self.menuPanel.alpha = 1.0;
            self.menuPanel.transform = CGAffineTransformIdentity;
            self.floatingBall.transform = CGAffineTransformMakeScale(0.85, 0.85);
            self.floatingBall.alpha = 0.5;
        } completion:^(BOOL finished) {
            self.isAnimating = NO;
        }];
    } else {
        [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            self.dimBackground.alpha = 0;
            self.menuPanel.alpha = 0;
            self.menuPanel.transform = CGAffineTransformMakeScale(0.88, 0.88);
            self.floatingBall.transform = CGAffineTransformIdentity;
            self.floatingBall.alpha = 1.0;
        } completion:^(BOOL finished) {
            [self.dimBackground removeFromSuperview];
            [self.menuPanel removeFromSuperview];
            self.isAnimating = NO;
            [self.floatingBall resetIdleTimer];
        }];
    }
}
@end

%ctor {
    @autoreleasepool {
        NSLog(@"[PVZSun] 插件已加载 (v%s)，开始初始化...", kPVZPluginVersion);
        applyConfiguredPatches();

        // 监听应用进入前台或就绪时挂载悬浮球 UI，并二次确保补丁就绪
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                applyConfiguredPatches();
                [[PVZModMenuManager shared] initUI];
            });
        }];
    }
}
