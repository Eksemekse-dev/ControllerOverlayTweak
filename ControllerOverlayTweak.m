#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <objc/runtime.h>

typedef NS_ENUM(NSInteger, OverlayTouchPhase) {
    OverlayTouchPhaseBegan = 0,
    OverlayTouchPhaseMoved = 1,
    OverlayTouchPhaseEnded = 2
};

@interface TouchProfile : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) CGFloat normalizedX;      // 0.0 - 1.0 szerokości ekranu
@property (nonatomic, assign) CGFloat normalizedY;      // 0.0 - 1.0 wysokości ekranu
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
    // W trybie grania przepuszczamy dotyk dalej do gry, chyba że kliknięto bezpośrednio w kontrolkę nakładki
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
@property (nonatomic, strong) NSArray<TouchProfile *> *profiles;
@property (nonatomic, strong) TouchProfile *activeProfile;
@property (nonatomic, assign) BOOL triggerWasActive;
@property (nonatomic, assign) BOOL editMode;
+ (instancetype)shared;
- (void)setup;
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
    p1.name = @"Skok / Swipe Góra (Krótki)";
    p1.normalizedX = 0.75;
    p1.normalizedY = 0.75;
    p1.swipeUpLength = 120.0;
    p1.duration = 0.16;
    p1.triggerThreshold = 0.5;

    TouchProfile *p2 = [[TouchProfile alloc] init];
    p2.name = @"Wysoki Swipe w Górę";
    p2.normalizedX = 0.75;
    p2.normalizedY = 0.80;
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
    dispatch_async(dispatch_get_main_queue(), ^{
        self.profileBar.hidden = YES;
        self.gestureMarker.hidden = YES;
    });
}

- (void)bindController:(GCController *)controller {
    GCExtendedGamepad *pad = controller.extendedGamepad;
    if (!pad) return;

    __weak typeof(self) weakSelf = self;
    pad.rightTrigger.valueChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
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

    // Szybkie przełączanie profili np. przyciskiem Y / Triangle
    pad.buttonY.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
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
    // Pasek wyboru profilu i trybu edycji na górze ekranu
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(20, 44, 420, 44)];
    bar.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.8];
    bar.layer.cornerRadius = 10;
    bar.hidden = YES;

    UIButton *profileBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    profileBtn.frame = CGRectMake(10, 4, 210, 36);
    [profileBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    profileBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [profileBtn setTitle:[NSString stringWithFormat:@"Profil: %@", self.activeProfile.name] forState:UIControlStateNormal];
    profileBtn.tag = 101;
    [profileBtn addTarget:self action:@selector(cycleNextProfile) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:profileBtn];

    UIButton *editBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    editBtn.frame = CGRectMake(226, 4, 110, 36);
    [editBtn setTitleColor:[UIColor systemYellowColor] forState:UIControlStateNormal];
    editBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [editBtn setTitle:@"Edytuj gest" forState:UIControlStateNormal];
    [editBtn addTarget:self action:@selector(toggleEditMode:) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:editBtn];

    UIButton *hideBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    hideBtn.frame = CGRectMake(342, 4, 68, 36);
    [hideBtn setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    hideBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [hideBtn setTitle:@"Ukryj" forState:UIControlEventTouchUpInside];
    [hideBtn addTarget:self action:@selector(hideOverlay) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:hideBtn];

    [self.overlayView addSubview:bar];
    self.profileBar = bar;

    // Wizualny podgląd punktu startu i długości przesunięcia w górę
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
    [self refreshMarkerPosition];
}

- (void)showProfilePicker {
    self.profileBar.hidden = NO;
    [self refreshMarkerPosition];
}

- (void)hideOverlay {
    self.editMode = NO;
    self.overlayView.editMode = NO;
    self.gestureMarker.hidden = YES;
    self.profileBar.hidden = YES;
}

- (void)toggleEditMode:(UIButton *)sender {
    self.editMode = !self.editMode;
    self.overlayView.editMode = self.editMode;
    self.gestureMarker.hidden = !self.editMode;
    [sender setTitle:(self.editMode ? @"Gotowe" : @"Edytuj gest") forState:UIControlStateNormal];
}

- (void)cycleNextProfile {
    if (self.profiles.count == 0) return;
    NSUInteger idx = [self.profiles indexOfObject:self.activeProfile];
    NSUInteger nextIdx = (idx == NSNotFound) ? 0 : (idx + 1) % self.profiles.count;
    self.activeProfile = self.profiles[nextIdx];

    UIButton *profileBtn = [self.profileBar viewWithTag:101];
    [profileBtn setTitle:[NSString stringWithFormat:@"Profil: %@", self.activeProfile.name] forState:UIControlStateNormal];
    [self refreshMarkerPosition];
}

- (void)handleMarkerPan:(UIPanGestureRecognizer *)pan {
    if (!self.editMode || !self.activeProfile) return;
    CGSize size = self.overlayView.bounds.size;
    CGPoint loc = [pan locationInView:self.overlayView];

    self.activeProfile.normalizedX = MIN(MAX(loc.x / size.width, 0.05), 0.95);
    self.activeProfile.normalizedY = MIN(MAX(loc.y / size.height, 0.10), 0.95);
    [self refreshMarkerPosition];
}

- (void)refreshMarkerPosition {
    if (!self.activeProfile || !self.overlayView) return;
    CGSize size = self.overlayView.bounds.size;
    CGFloat x = self.activeProfile.normalizedX * size.width;
    CGFloat y = self.activeProfile.normalizedY * size.height;
    self.gestureMarker.center = CGPointMake(x, y);
}

- (void)performSwipeUpForActiveProfile {
    if (!self.activeProfile || !self.overlayView) return;

    CGSize size = self.overlayView.bounds.size;
    CGPoint startPt = CGPointMake(self.activeProfile.normalizedX * size.width,
                                  self.activeProfile.normalizedY * size.height);
    CGFloat length = self.activeProfile.swipeUpLength;
    NSTimeInterval duration = MAX(self.activeProfile.duration, 0.05);

    NSInteger steps = 12;
    NSTimeInterval stepInterval = duration / steps;

    [self injectTouchAtPoint:startPt phase:OverlayTouchPhaseBegan];

    for (NSInteger i = 1; i <= steps; i++) {
        CGFloat progress = (CGFloat)i / (CGFloat)steps;
        // Ruch w górę oznacza zmniejszanie współrzędnej Y w układzie UIKit
        CGPoint currentPt = CGPointMake(startPt.x, startPt.y - (length * progress));
        OverlayTouchPhase phase = (i == steps) ? OverlayTouchPhaseEnded : OverlayTouchPhaseMoved;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * stepInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self injectTouchAtPoint:currentPt phase:phase];
        });
    }
}

- (void)injectTouchAtPoint:(CGPoint)point phase:(OverlayTouchPhase)phase {
    // Tutaj podepnij wstrzykiwanie zdarzenia dotykowego na poziomie HID / systemu
    // dla docelowego środowiska iOS.
    (void)point;
    (void)phase;
}

@end

__attribute__((constructor))
static void DylibEntry(void) {
    [[OverlayControllerManager shared] setup];
}
