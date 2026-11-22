#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <objc/runtime.h>
#import <objc/message.h>

@interface TouchProfile : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) CGFloat normalizedX;      // 0.0 - 1.0 szerokości okna
@property (nonatomic, assign) CGFloat normalizedY;      // 0.0 - 1.0 wysokości okna
@property (nonatomic, assign) CGFloat swipeUpLength;    // długość przesunięcia w górę (w punktach)
@property (nonatomic, assign) NSTimeInterval duration;  // czas trwania gestu w sekundach
@property (nonatomic, assign) CGFloat triggerThreshold; // próg naciśnięcia spustu (0.0 - 1.0)
@end

@implementation TouchProfile
@end

@interface PassthroughOverlayView : UIView
@property (nonatomic, assign) BOOL editMode;
@end

@implementation PassthroughOverlayView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // W trybie grania przepuszczamy dotyk dalej do aplikacji, chyba że kliknięto bezpośrednio w pasek nakładki
    if (!self.editMode && hit == self) {
        return nil;
    }
    return hit;
}
@end

@interface OverlayControllerManager : NSObject
@property (nonatomic, strong) UIWindow *overlayWindow;
@property (nonatomic, strong) PassthroughOverlayView *overlayView;
@property (nonatomic, strong) UIView *profileBar;
@property (nonatomic, strong) UIView *gestureMarker;
@property (nonatomic, strong) CAShapeLayer *swipePreviewLayer;
@property (nonatomic, strong) UILabel *lengthLabel;
@property (nonatomic, strong) NSArray<TouchProfile *> *profiles;
@property (nonatomic, strong) TouchProfile *activeProfile;
@property (nonatomic, assign) BOOL triggerWasActive;
@property (nonatomic, assign) BOOL editMode;
+ (instancetype)shared;
- (void)setup;
- (void)performSwipeUpForActiveProfile;
@end

@interface OverlayControllerManager (UIKitTouchInjection)
- (UIWindow *)targetAppWindow;
- (UITouch *)createTouchAtWindowPoint:(CGPoint)windowPoint inWindow:(UIWindow *)window phase:(UITouchPhase)phase;
- (void)updateTouch:(UITouch *)touch toWindowPoint:(CGPoint)windowPoint phase:(UITouchPhase)phase;
- (UIEvent *)touchesEventWithTouch:(UITouch *)touch;
- (void)dispatchTouch:(UITouch *)touch;
@end

@implementation OverlayControllerManager

+ (instancetype)shared {
    static OverlayControllerManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[OverlayControllerManager alloc] init];
    });
    return instance;
}

- (void)setup {
    [self loadDefaultProfiles];
    [self registerControllerObservers];
    [self attachOverlayWindowWhenReady];
}

- (void)loadDefaultProfiles {
    TouchProfile *p1 = [[TouchProfile alloc] init];
    p1.name = @"Swipe Góra (Krótki)";
    p1.normalizedX = 0.75;
    p1.normalizedY = 0.75;
    p1.swipeUpLength = 120.0;
    p1.duration = 0.16;
    p1.triggerThreshold = 0.5;

    TouchProfile *p2 = [[TouchProfile alloc] init];
    p2.name = @"Swipe Góra (Długi)";
    p2.normalizedX = 0.75;
    p2.normalizedY = 0.82;
    p2.swipeUpLength = 240.0;
    p2.duration = 0.24;
    p2.triggerThreshold = 0.5;

    self.profiles = @[p1, p2];
    self.activeProfile = p1;
}

- (void)registerControllerObservers {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(controllerConnected:)
                                                 name:GCControllerDidConnectNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(controllerDisconnected:)
                                                 name:GCControllerDidDisconnectNotification
                                               object:nil];

    for (GCController *controller in [GCController controllers]) {
        [self bindController:controller];
    }
}

- (void)controllerConnected:(NSNotification *)note {
    GCController *controller = note.object;
    [self bindController:controller];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self showProfilePicker];
    });
}

- (void)controllerDisconnected:(NSNotification *)note {
    (void)note;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.profileBar.hidden = YES;
        self.gestureMarker.hidden = YES;
        self.swipePreviewLayer.hidden = YES;
    });
}

- (void)bindController:(GCController *)controller {
    GCExtendedGamepad *pad = controller.extendedGamepad;
    if (!pad) return;

    __weak typeof(self) weakSelf = self;
    pad.rightTrigger.valueChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        (void)button;
        (void)pressed;
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.activeProfile) return;

        BOOL aboveThreshold = (value >= strongSelf.activeProfile.triggerThreshold);
        if (aboveThreshold && !strongSelf.triggerWasActive) {
            strongSelf.triggerWasActive = YES;
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf performSwipeUpForActiveProfile];
            });
        } else if (!aboveThreshold) {
            strongSelf.triggerWasActive = NO;
        }
    };

    // Przełączanie profilu przyciskiem Y / Triangle
    pad.buttonY.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        (void)button;
        (void)value;
        if (pressed) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf cycleNextProfile];
            });
        }
    };
}

- (void)attachOverlayWindowWhenReady {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.overlayWindow) return;

        UIWindowScene *activeScene = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] &&
                scene.activationState == UISceneActivationStateForegroundActive) {
                activeScene = (UIWindowScene *)scene;
                break;
            }
        }

        UIWindow *win = activeScene
            ? [[UIWindow alloc] initWithWindowScene:activeScene]
            : [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

        win.windowLevel = UIWindowLevelAlert + 100;
        win.backgroundColor = [UIColor clearColor];

        UIViewController *rootVC = [[UIViewController alloc] init];
        PassthroughOverlayView *overlay = [[PassthroughOverlayView alloc] initWithFrame:win.bounds];
        overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        overlay.backgroundColor = [UIColor clearColor];
        rootVC.view = overlay;

        win.rootViewController = rootVC;
        win.hidden = NO;

        self.overlayWindow = win;
        self.overlayView = overlay;

        [self buildUI];

        if ([GCController controllers].count > 0) {
            [self showProfilePicker];
        }
    });
}

- (void)buildUI {
    // Pasek wyboru profilu i edycji gestu
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(20, 44, 520, 44)];
    bar.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82];
    bar.layer.cornerRadius = 10;
    bar.hidden = YES;

    UIButton *profileBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    profileBtn.frame = CGRectMake(8, 4, 185, 36);
    [profileBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    profileBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    profileBtn.tag = 101;
    [profileBtn addTarget:self action:@selector(cycleNextProfile) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:profileBtn];

    UIButton *editBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    editBtn.frame = CGRectMake(198, 4, 92, 36);
    [editBtn setTitleColor:[UIColor systemYellowColor] forState:UIControlStateNormal];
    editBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    [editBtn setTitle:@"Edytuj gest" forState:UIControlStateNormal];
    [editBtn addTarget:self action:@selector(toggleEditMode:) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:editBtn];

    UIButton *minusBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    minusBtn.frame = CGRectMake(295, 4, 34, 36);
    [minusBtn setTitleColor:[UIColor systemCyanColor] forState:UIControlStateNormal];
    minusBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [minusBtn setTitle:@"-" forState:UIControlStateNormal];
    [minusBtn addTarget:self action:@selector(decreaseSwipeLength) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:minusBtn];

    UILabel *lenLbl = [[UILabel alloc] initWithFrame:CGRectMake(331, 4, 72, 36)];
    lenLbl.textColor = [UIColor whiteColor];
    lenLbl.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightBold];
    lenLbl.textAlignment = NSTextAlignmentCenter;
    [bar addSubview:lenLbl];
    self.lengthLabel = lenLbl;

    UIButton *plusBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    plusBtn.frame = CGRectMake(405, 4, 34, 36);
    [plusBtn setTitleColor:[UIColor systemCyanColor] forState:UIControlStateNormal];
    plusBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [plusBtn setTitle:@"+" forState:UIControlStateNormal];
    [plusBtn addTarget:self action:@selector(increaseSwipeLength) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:plusBtn];

    UIButton *hideBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    hideBtn.frame = CGRectMake(446, 4, 66, 36);
    [hideBtn setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    hideBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    [hideBtn setTitle:@"Ukryj" forState:UIControlStateNormal];
    [hideBtn addTarget:self action:@selector(hideOverlay) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:hideBtn];

    [self.overlayView addSubview:bar];
    self.profileBar = bar;

    // Warstwa podglądu wektora przesunięcia w górę
    CAShapeLayer *preview = [CAShapeLayer layer];
    preview.strokeColor = [UIColor cyanColor].CGColor;
    preview.fillColor = [UIColor clearColor].CGColor;
    preview.lineWidth = 2.5;
    preview.lineDashPattern = @[@6, @4];
    preview.hidden = YES;
    [self.overlayView.layer addSublayer:preview];
    self.swipePreviewLayer = preview;

    // Punkt startowy gestu (przeciągalny w trybie edycji)
    UIView *marker = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 28, 28)];
    marker.backgroundColor = [[UIColor systemCyanColor] colorWithAlphaComponent:0.5];
    marker.layer.cornerRadius = 14;
    marker.layer.borderWidth = 2;
    marker.layer.borderColor = [UIColor cyanColor].CGColor;
    marker.hidden = YES;

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleMarkerPan:)];
    [marker addGestureRecognizer:pan];

    [self.overlayView addSubview:marker];
    self.gestureMarker = marker;

    [self refreshProfileLabelsAndMarker];
}

- (void)showProfilePicker {
    self.profileBar.hidden = NO;
    [self refreshProfileLabelsAndMarker];
}

- (void)hideOverlay {
    self.editMode = NO;
    self.overlayView.editMode = NO;
    self.gestureMarker.hidden = YES;
    self.swipePreviewLayer.hidden = YES;
    self.profileBar.hidden = YES;
}

- (void)toggleEditMode:(UIButton *)sender {
    self.editMode = !self.editMode;
    self.overlayView.editMode = self.editMode;
    self.gestureMarker.hidden = !self.editMode;
    self.swipePreviewLayer.hidden = !self.editMode;
    [sender setTitle:(self.editMode ? @"Gotowe" : @"Edytuj gest") forState:UIControlStateNormal];
    [self refreshProfileLabelsAndMarker];
}

- (void)decreaseSwipeLength {
    if (!self.activeProfile) return;
    self.activeProfile.swipeUpLength = MAX(30.0, self.activeProfile.swipeUpLength - 20.0);
    [self refreshProfileLabelsAndMarker];
}

- (void)increaseSwipeLength {
    if (!self.activeProfile) return;
    self.activeProfile.swipeUpLength = MIN(600.0, self.activeProfile.swipeUpLength + 20.0);
    [self refreshProfileLabelsAndMarker];
}

- (void)cycleNextProfile {
    if (self.profiles.count == 0) return;
    NSUInteger idx = [self.profiles indexOfObject:self.activeProfile];
    NSUInteger nextIdx = (idx == NSNotFound) ? 0 : (idx + 1) % self.profiles.count;
    self.activeProfile = self.profiles[nextIdx];
    [self refreshProfileLabelsAndMarker];
}

- (void)handleMarkerPan:(UIPanGestureRecognizer *)pan {
    if (!self.editMode || !self.activeProfile) return;
    CGSize size = self.overlayView.bounds.size;
    CGPoint loc = [pan locationInView:self.overlayView];

    self.activeProfile.normalizedX = MIN(MAX(loc.x / size.width, 0.05), 0.95);
    self.activeProfile.normalizedY = MIN(MAX(loc.y / size.height, 0.15), 0.95);
    [self refreshProfileLabelsAndMarker];
}

- (void)refreshProfileLabelsAndMarker {
    if (!self.activeProfile || !self.overlayView) return;

    UIButton *profileBtn = [self.profileBar viewWithTag:101];
    [profileBtn setTitle:[NSString stringWithFormat:@"Profil: %@", self.activeProfile.name] forState:UIControlStateNormal];
    self.lengthLabel.text = [NSString stringWithFormat:@"%.0f pt ↑", self.activeProfile.swipeUpLength];

    CGSize size = self.overlayView.bounds.size;
    CGFloat x = self.activeProfile.normalizedX * size.width;
    CGFloat y = self.activeProfile.normalizedY * size.height;
    self.gestureMarker.center = CGPointMake(x, y);

    if (self.editMode) {
        UIBezierPath *path = [UIBezierPath bezierPath];
        [path moveToPoint:CGPointMake(x, y)];
        [path addLineToPoint:CGPointMake(x, y - self.activeProfile.swipeUpLength)];
        self.swipePreviewLayer.path = path.CGPath;
        self.swipePreviewLayer.hidden = NO;
    } else {
        self.swipePreviewLayer.hidden = YES;
    }
}

@end

@implementation OverlayControllerManager (UIKitTouchInjection)

- (UIWindow *)targetAppWindow {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]] ||
            scene.activationState != UISceneActivationStateForegroundActive) {
            continue;
        }
        UIWindowScene *winScene = (UIWindowScene *)scene;
        for (UIWindow *win in winScene.windows) {
            if (win != self.overlayWindow && !win.hidden && win.alpha > 0.01 && win.isKeyWindow) {
                return win;
            }
        }
        for (UIWindow *win in winScene.windows) {
            if (win != self.overlayWindow && !win.hidden && win.alpha > 0.01) {
                return win;
            }
        }
    }
    return [UIApplication sharedApplication].keyWindow;
}

- (UITouch *)createTouchAtWindowPoint:(CGPoint)windowPoint inWindow:(UIWindow *)window phase:(UITouchPhase)phase {
    UITouch *touch = [[UITouch alloc] init];
    UIView *targetView = [window hitTest:windowPoint withEvent:nil] ?: window;

    SEL setWindowSel = NSSelectorFromString(@"setWindow:");
    if ([touch respondsToSelector:setWindowSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(touch, setWindowSel, window);
    }

    SEL setViewSel = NSSelectorFromString(@"setView:");
    if ([touch respondsToSelector:setViewSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(touch, setViewSel, targetView);
    }

    SEL setPhaseSel = NSSelectorFromString(@"setPhase:");
    if ([touch respondsToSelector:setPhaseSel]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(touch, setPhaseSel, (NSInteger)phase);
    }

    SEL setTapCountSel = NSSelectorFromString(@"setTapCount:");
    if ([touch respondsToSelector:setTapCountSel]) {
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(touch, setTapCountSel, 1);
    }

    SEL setTimestampSel = NSSelectorFromString(@"setTimestamp:");
    if ([touch respondsToSelector:setTimestampSel]) {
        ((void (*)(id, SEL, NSTimeInterval))objc_msgSend)(touch, setTimestampSel, [NSProcessInfo processInfo].systemUptime);
    }

    [self updateTouch:touch toWindowPoint:windowPoint phase:phase];
    return touch;
}

- (void)updateTouch:(UITouch *)touch toWindowPoint:(CGPoint)windowPoint phase:(UITouchPhase)phase {
    UIWindow *window = touch.window ?: [self targetAppWindow];
    UIView *targetView = [window hitTest:windowPoint withEvent:nil] ?: touch.view ?: window;
    CGPoint viewPoint = [window convertPoint:windowPoint toView:targetView];

    SEL setViewSel = NSSelectorFromString(@"setView:");
    if ([touch respondsToSelector:setViewSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(touch, setViewSel, targetView);
    }

    SEL setPhaseSel = NSSelectorFromString(@"setPhase:");
    if ([touch respondsToSelector:setPhaseSel]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(touch, setPhaseSel, (NSInteger)phase);
    }

    SEL setTimestampSel = NSSelectorFromString(@"setTimestamp:");
    if ([touch respondsToSelector:setTimestampSel]) {
        ((void (*)(id, SEL, NSTimeInterval))objc_msgSend)(touch, setTimestampSel, [NSProcessInfo processInfo].systemUptime);
    }

    SEL setLocInWinSel = NSSelectorFromString(@"_setLocationInWindow:resetPrevious:");
    if ([touch respondsToSelector:setLocInWinSel]) {
        BOOL resetPrev = (phase == UITouchPhaseBegan);
        ((void (*)(id, SEL, CGPoint, BOOL))objc_msgSend)(touch, setLocInWinSel, windowPoint, resetPrev);
    } else {
        SEL setLocSel = NSSelectorFromString(@"setLocationInView:");
        if ([touch respondsToSelector:setLocSel]) {
            ((void (*)(id, SEL, CGPoint))objc_msgSend)(touch, setLocSel, viewPoint);
        }
    }
}

- (UIEvent *)touchesEventWithTouch:(UITouch *)touch {
    UIEvent *event = nil;
    SEL touchesEventSel = NSSelectorFromString(@"_touchesEvent");
    if ([[UIApplication sharedApplication] respondsToSelector:touchesEventSel]) {
        event = ((id (*)(id, SEL))objc_msgSend)([UIApplication sharedApplication], touchesEventSel);
    }

    if (event) {
        SEL clearTouchesSel = NSSelectorFromString(@"_clearTouches");
        if ([event respondsToSelector:clearTouchesSel]) {
            ((void (*)(id, SEL))objc_msgSend)(event, clearTouchesSel);
        }
        SEL addTouchSel = NSSelectorFromString(@"_addTouch:forDelayedDelivery:");
        if ([event respondsToSelector:addTouchSel]) {
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(event, addTouchSel, touch, NO);
        }
    }
    return event;
}

- (void)dispatchTouch:(UITouch *)touch {
    UIWindow *window = touch.window ?: [self targetAppWindow];
    if (!window) return;

    UIEvent *event = [self touchesEventWithTouch:touch];
    NSSet<UITouch *> *touchesSet = [NSSet setWithObject:touch];

    if (event) {
        [[UIApplication sharedApplication] sendEvent:event];
    } else {
        switch (touch.phase) {
            case UITouchPhaseBegan:
                [touch.view touchesBegan:touchesSet withEvent:nil];
                break;
            case UITouchPhaseMoved:
                [touch.view touchesMoved:touchesSet withEvent:nil];
                break;
            case UITouchPhaseEnded:
                [touch.view touchesEnded:touchesSet withEvent:nil];
                break;
            default:
                break;
        }
    }
}

- (void)performSwipeUpForActiveProfile {
    if (!self.activeProfile) return;
    UIWindow *window = [self targetAppWindow];
    if (!window) return;

    CGSize size = window.bounds.size;
    CGPoint startPt = CGPointMake(self.activeProfile.normalizedX * size.width,
                                  self.activeProfile.normalizedY * size.height);
    CGFloat length = self.activeProfile.swipeUpLength;
    NSTimeInterval duration = MAX(self.activeProfile.duration, 0.06);

    NSInteger steps = 12;
    NSTimeInterval stepInterval = duration / steps;

    UITouch *touch = [self createTouchAtWindowPoint:startPt inWindow:window phase:UITouchPhaseBegan];
    [self dispatchTouch:touch];

    for (NSInteger i = 1; i <= steps; i++) {
        CGFloat progress = (CGFloat)i / (CGFloat)steps;
        CGPoint currentPt = CGPointMake(startPt.x, startPt.y - (length * progress));
        UITouchPhase phase = (i == steps) ? UITouchPhaseEnded : UITouchPhaseMoved;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * stepInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self updateTouch:touch toWindowPoint:currentPt phase:phase];
            [self dispatchTouch:touch];
        });
    }
}

@end

__attribute__((constructor))
static void DylibEntry(void) {
    [[OverlayControllerManager shared] setup];
}
