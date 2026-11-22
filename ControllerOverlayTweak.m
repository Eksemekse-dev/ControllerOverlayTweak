#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

typedef NS_ENUM(NSInteger, PadInputBinding) {
    PadInputRightTrigger = 0, // RT / R2
    PadInputLeftTrigger  = 1, // LT / L2
    PadInputButtonA      = 2, // A / Cross
    PadInputButtonB      = 3, // B / Circle
    PadInputButtonX      = 4, // X / Square
    PadInputButtonY      = 5, // Y / Triangle
    PadInputLeftShoulder = 6, // LB / L1
    PadInputRightShoulder= 7  // RB / R1
};

@interface TouchActionBinding : NSObject
@property (nonatomic, copy) NSString *label;
@property (nonatomic, assign) PadInputBinding inputType;
@property (nonatomic, assign) CGFloat normalizedX;
@property (nonatomic, assign) CGFloat normalizedY;
@property (nonatomic, assign) CGFloat swipeUpLength;
@property (nonatomic, assign) NSTimeInterval duration;
@property (nonatomic, assign) CGFloat triggerThreshold;
@property (nonatomic, assign) BOOL wasActive;
@end

@implementation TouchActionBinding
+ (NSString *)nameForInputType:(PadInputBinding)type {
    switch (type) {
        case PadInputRightTrigger:  return @"RT/R2";
        case PadInputLeftTrigger:   return @"LT/L2";
        case PadInputButtonA:       return @"A/✕";
        case PadInputButtonB:       return @"B/○";
        case PadInputButtonX:       return @"X/□";
        case PadInputButtonY:       return @"Y/△";
        case PadInputLeftShoulder:  return @"LB/L1";
        case PadInputRightShoulder: return @"RB/R1";
    }
}
@end

@interface TouchProfile : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSMutableArray<TouchActionBinding *> *bindings;
@end

@implementation TouchProfile
@end

@interface PassthroughWindow : UIWindow
@end

@implementation PassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) {
        return nil;
    }
    return hit;
}
@end

@interface OverlayControllerManager : NSObject
@property (nonatomic, strong) PassthroughWindow *barWindow;
@property (nonatomic, strong) PassthroughWindow *editorWindow;
@property (nonatomic, strong) UIView *profileBar;
@property (nonatomic, strong) UIView *editPanel;
@property (nonatomic, strong) UIView *gestureMarker;
@property (nonatomic, strong) UILabel *markerCaptionLabel;
@property (nonatomic, strong) CAShapeLayer *swipePreviewLayer;
@property (nonatomic, strong) UILabel *lengthLabel;
@property (nonatomic, strong) UIButton *inputTypeBtn;
@property (nonatomic, strong) UIButton *bindingCycleBtn;
@property (nonatomic, strong) NSMutableArray<TouchProfile *> *profiles;
@property (nonatomic, strong) TouchProfile *activeProfile;
@property (nonatomic, assign) NSUInteger selectedBindingIndex;
@property (nonatomic, assign) BOOL editMode;
+ (instancetype)shared;
- (void)setup;
- (void)performSwipeUpForBinding:(TouchActionBinding *)binding;
@end

@interface OverlayControllerManager (UIKitTouchInjection)
- (UIWindowScene *)activeScene;
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
    [self attachWindowsWhenReady];
}

- (TouchActionBinding *)currentBinding {
    if (!self.activeProfile || self.activeProfile.bindings.count == 0) return nil;
    if (self.selectedBindingIndex >= self.activeProfile.bindings.count) {
        self.selectedBindingIndex = 0;
    }
    return self.activeProfile.bindings[self.selectedBindingIndex];
}

- (void)loadDefaultProfiles {
    TouchActionBinding *b1 = [[TouchActionBinding alloc] init];
    b1.label = @"Skok / Góra";
    b1.inputType = PadInputRightTrigger;
    b1.normalizedX = 0.75;
    b1.normalizedY = 0.75;
    b1.swipeUpLength = 120.0;
    b1.duration = 0.16;
    b1.triggerThreshold = 0.5;

    TouchActionBinding *b2 = [[TouchActionBinding alloc] init];
    b2.label = @"Lewy Spust";
    b2.inputType = PadInputLeftTrigger;
    b2.normalizedX = 0.25;
    b2.normalizedY = 0.75;
    b2.swipeUpLength = 160.0;
    b2.duration = 0.18;
    b2.triggerThreshold = 0.5;

    TouchProfile *p1 = [[TouchProfile alloc] init];
    p1.name = @"Profil 1";
    p1.bindings = [@[b1, b2] mutableCopy];

    TouchActionBinding *p2b1 = [[TouchActionBinding alloc] init];
    p2b1.label = @"Długi Swipe A";
    p2b1.inputType = PadInputButtonA;
    p2b1.normalizedX = 0.78;
    p2b1.normalizedY = 0.80;
    p2b1.swipeUpLength = 240.0;
    p2b1.duration = 0.24;
    p2b1.triggerThreshold = 0.5;

    TouchProfile *p2 = [[TouchProfile alloc] init];
    p2.name = @"Profil 2";
    p2.bindings = [@[p2b1] mutableCopy];

    self.profiles = [@[p1, p2] mutableCopy];
    self.activeProfile = p1;
    self.selectedBindingIndex = 0;
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
    (void)note;
    for (GCController *controller in [GCController controllers]) {
        [self bindController:controller];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self showBar];
    });
}

- (void)controllerDisconnected:(NSNotification *)note {
    (void)note;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([GCController controllers].count == 0 && !self.editMode) {
            [self hideAll];
        }
    });
}

- (void)handleButtonInput:(GCControllerButtonInput *)button value:(float)value pressed:(BOOL)pressed forType:(PadInputBinding)type {
    (void)button;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.activeProfile) return;

        for (TouchActionBinding *b in strongSelf.activeProfile.bindings) {
            if (b.inputType != type) continue;

            BOOL isAnalog = (type == PadInputRightTrigger || type == PadInputLeftTrigger);
            BOOL activeNow = isAnalog ? (value >= b.triggerThreshold) : pressed;

            if (activeNow && !b.wasActive) {
                b.wasActive = YES;
                [strongSelf performSwipeUpForBinding:b];
            } else if (!activeNow) {
                b.wasActive = NO;
            }
        }
    });
}

- (void)bindController:(GCController *)controller {
    GCExtendedGamepad *pad = controller.extendedGamepad;
    if (!pad) return;

    __weak typeof(self) weakSelf = self;

    pad.rightTrigger.valueChangedHandler = ^(GCControllerButtonInput *btn, float val, BOOL pressed) {
        [weakSelf handleButtonInput:btn value:val pressed:pressed forType:PadInputRightTrigger];
    };
    pad.leftTrigger.valueChangedHandler = ^(GCControllerButtonInput *btn, float val, BOOL pressed) {
        [weakSelf handleButtonInput:btn value:val pressed:pressed forType:PadInputLeftTrigger];
    };
    pad.buttonA.pressedChangedHandler = ^(GCControllerButtonInput *btn, float val, BOOL pressed) {
        [weakSelf handleButtonInput:btn value:val pressed:pressed forType:PadInputButtonA];
    };
    pad.buttonB.pressedChangedHandler = ^(GCControllerButtonInput *btn, float val, BOOL pressed) {
        [weakSelf handleButtonInput:btn value:val pressed:pressed forType:PadInputButtonB];
    };
    pad.buttonX.pressedChangedHandler = ^(GCControllerButtonInput *btn, float val, BOOL pressed) {
        [weakSelf handleButtonInput:btn value:val pressed:pressed forType:PadInputButtonX];
    };
    pad.buttonY.pressedChangedHandler = ^(GCControllerButtonInput *btn, float val, BOOL pressed) {
        [weakSelf handleButtonInput:btn value:val pressed:pressed forType:PadInputButtonY];
    };
    pad.leftShoulder.pressedChangedHandler = ^(GCControllerButtonInput *btn, float val, BOOL pressed) {
        [weakSelf handleButtonInput:btn value:val pressed:pressed forType:PadInputLeftShoulder];
    };
    pad.rightShoulder.pressedChangedHandler = ^(GCControllerButtonInput *btn, float val, BOOL pressed) {
        [weakSelf handleButtonInput:btn value:val pressed:pressed forType:PadInputRightShoulder];
    };
}

- (void)attachWindowsWhenReady {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindowScene *scene = [self activeScene];
        if (!scene) return;

        if (!self.barWindow) {
            PassthroughWindow *bWin = [[PassthroughWindow alloc] initWithFrame:CGRectMake(20, 44, 420, 40)];
            if (@available(iOS 13.0, *)) {
                bWin.windowScene = scene;
            }
            bWin.windowLevel = UIWindowLevelAlert + 500;
            bWin.backgroundColor = [UIColor clearColor];
            bWin.userInteractionEnabled = YES;
            bWin.hidden = YES;

            UIViewController *vc = [[UIViewController alloc] init];
            vc.view.frame = bWin.bounds;
            vc.view.backgroundColor = [UIColor clearColor];
            vc.view.userInteractionEnabled = YES;
            bWin.rootViewController = vc;

            self.barWindow = bWin;
            [self buildBarUI];
        }

        // Pokazujemy pasek po starcie, aby łatwo przetestować GUI nawet bez podłączonego pada
        [self showBar];
    });
}

- (void)ensureEditorWindow {
    if (self.editorWindow) return;
    UIWindowScene *scene = [self activeScene];
    if (!scene) return;

    PassthroughWindow *eWin = [[PassthroughWindow alloc] initWithFrame:scene.coordinateSpace.bounds];
    if (@available(iOS 13.0, *)) {
        eWin.windowScene = scene;
    }
    eWin.windowLevel = UIWindowLevelAlert + 400;
    eWin.backgroundColor = [UIColor clearColor];
    eWin.userInteractionEnabled = YES;
    eWin.hidden = YES;

    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.frame = eWin.bounds;
    vc.view.backgroundColor = [UIColor clearColor];
    vc.view.userInteractionEnabled = YES;
    eWin.rootViewController = vc;

    self.editorWindow = eWin;
    [self buildEditorUI];
}

- (void)buildBarUI {
    UIView *bar = [[UIView alloc] initWithFrame:self.barWindow.bounds];
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    bar.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.88];
    bar.layer.cornerRadius = 10;
    bar.userInteractionEnabled = YES;

    UIButton *profileBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    profileBtn.frame = CGRectMake(8, 4, 155, 32);
    profileBtn.userInteractionEnabled = YES;
    [profileBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    profileBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    profileBtn.tag = 101;
    [profileBtn addTarget:self action:@selector(cycleNextProfile) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:profileBtn];

    UIButton *editBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    editBtn.frame = CGRectMake(170, 4, 100, 32);
    editBtn.userInteractionEnabled = YES;
    [editBtn setTitleColor:[UIColor systemYellowColor] forState:UIControlStateNormal];
    editBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    editBtn.tag = 102;
    [editBtn setTitle:@"Edytuj" forState:UIControlStateNormal];
    [editBtn addTarget:self action:@selector(toggleEditMode) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:editBtn];

    UIButton *addBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    addBtn.frame = CGRectMake(276, 4, 72, 32);
    addBtn.userInteractionEnabled = YES;
    [addBtn setTitleColor:[UIColor systemGreenColor] forState:UIControlStateNormal];
    addBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    [addBtn setTitle:@"+ Dodaj" forState:UIControlStateNormal];
    [addBtn addTarget:self action:@selector(addNewBinding) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:addBtn];

    UIButton *hideBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    hideBtn.frame = CGRectMake(354, 4, 58, 32);
    hideBtn.userInteractionEnabled = YES;
    [hideBtn setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    hideBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    [hideBtn setTitle:@"Ukryj" forState:UIControlStateNormal];
    [hideBtn addTarget:self action:@selector(hideAll) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:hideBtn];

    [self.barWindow.rootViewController.view addSubview:bar];
    self.profileBar = bar;
    [self refreshUI];
}

- (void)buildEditorUI {
    UIView *root = self.editorWindow.rootViewController.view;

    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(20, 92, 560, 42)];
    panel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.88];
    panel.layer.cornerRadius = 10;
    panel.userInteractionEnabled = YES;

    UIButton *cycleBindingBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    cycleBindingBtn.frame = CGRectMake(8, 5, 130, 32);
    cycleBindingBtn.userInteractionEnabled = YES;
    [cycleBindingBtn setTitleColor:[UIColor systemCyanColor] forState:UIControlStateNormal];
    cycleBindingBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    [cycleBindingBtn addTarget:self action:@selector(cycleSelectedBinding) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:cycleBindingBtn];
    self.bindingCycleBtn = cycleBindingBtn;

    UIButton *renameBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    renameBtn.frame = CGRectMake(142, 5, 70, 32);
    renameBtn.userInteractionEnabled = YES;
    [renameBtn setTitleColor:[UIColor systemYellowColor] forState:UIControlStateNormal];
    renameBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    [renameBtn setTitle:@"Podpis" forState:UIControlStateNormal];
    [renameBtn addTarget:self action:@selector(promptRenameSelectedBinding) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:renameBtn];

    UIButton *inputBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    inputBtn.frame = CGRectMake(216, 5, 78, 32);
    inputBtn.userInteractionEnabled = YES;
    [inputBtn setTitleColor:[UIColor systemOrangeColor] forState:UIControlStateNormal];
    inputBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    [inputBtn addTarget:self action:@selector(cycleInputTypeForSelectedBinding) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:inputBtn];
    self.inputTypeBtn = inputBtn;

    UIButton *minusBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    minusBtn.frame = CGRectMake(298, 5, 32, 32);
    minusBtn.userInteractionEnabled = YES;
    [minusBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    minusBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [minusBtn setTitle:@"-" forState:UIControlStateNormal];
    [minusBtn addTarget:self action:@selector(decreaseSwipeLength) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:minusBtn];

    UILabel *lenLbl = [[UILabel alloc] initWithFrame:CGRectMake(332, 5, 72, 32)];
    lenLbl.textColor = [UIColor whiteColor];
    lenLbl.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightBold];
    lenLbl.textAlignment = NSTextAlignmentCenter;
    [panel addSubview:lenLbl];
    self.lengthLabel = lenLbl;

    UIButton *plusBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    plusBtn.frame = CGRectMake(406, 5, 32, 32);
    plusBtn.userInteractionEnabled = YES;
    [plusBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    plusBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [plusBtn setTitle:@"+" forState:UIControlStateNormal];
    [plusBtn addTarget:self action:@selector(increaseSwipeLength) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:plusBtn];

    UISlider *lenSlider = [[UISlider alloc] initWithFrame:CGRectMake(442, 5, 110, 32)];
    lenSlider.minimumValue = 20.0;
    lenSlider.maximumValue = 500.0;
    lenSlider.userInteractionEnabled = YES;
    lenSlider.tag = 201;
    [lenSlider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [panel addSubview:lenSlider];

    [root addSubview:panel];
    self.editPanel = panel;

    CAShapeLayer *preview = [CAShapeLayer layer];
    preview.strokeColor = [UIColor cyanColor].CGColor;
    preview.fillColor = [UIColor clearColor].CGColor;
    preview.lineWidth = 2.5;
    preview.lineDashPattern = @[@6, @4];
    [root.layer addSublayer:preview];
    self.swipePreviewLayer = preview;

    UIView *marker = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 36, 36)];
    marker.backgroundColor = [[UIColor systemCyanColor] colorWithAlphaComponent:0.55];
    marker.layer.cornerRadius = 18;
    marker.layer.borderWidth = 2;
    marker.layer.borderColor = [UIColor cyanColor].CGColor;
    marker.userInteractionEnabled = YES;

    UILabel *caption = [[UILabel alloc] initWithFrame:CGRectMake(-55, 38, 146, 20)];
    caption.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82];
    caption.textColor = [UIColor whiteColor];
    caption.font = [UIFont boldSystemFontOfSize:10];
    caption.textAlignment = NSTextAlignmentCenter;
    caption.layer.cornerRadius = 5;
    caption.clipsToBounds = YES;
    caption.userInteractionEnabled = NO;
    [marker addSubview:caption];
    self.markerCaptionLabel = caption;

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleMarkerPan:)];
    [marker addGestureRecognizer:pan];

    [root addSubview:marker];
    self.gestureMarker = marker;
    [self refreshUI];
}

- (void)showBar {
    if (!self.barWindow) {
        [self attachWindowsWhenReady];
        return;
    }
    self.barWindow.hidden = NO;
    [self refreshUI];
}

- (void)hideAll {
    self.editMode = NO;
    if (self.editorWindow) {
        self.editorWindow.hidden = YES;
        self.editorWindow = nil;
    }
    if (self.barWindow) {
        self.barWindow.hidden = YES;
    }
}

- (void)toggleEditMode {
    self.editMode = !self.editMode;
    if (self.editMode) {
        [self ensureEditorWindow];
        self.editorWindow.hidden = NO;
    } else {
        if (self.editorWindow) {
            self.editorWindow.hidden = YES;
            self.editorWindow = nil;
        }
    }
    [self refreshUI];
}

- (void)addNewBinding {
    if (!self.activeProfile) return;
    NSUInteger nextNum = self.activeProfile.bindings.count + 1;

    TouchActionBinding *newB = [[TouchActionBinding alloc] init];
    newB.label = [NSString stringWithFormat:@"Akcja %lu", (unsigned long)nextNum];
    newB.inputType = PadInputButtonA;
    newB.normalizedX = 0.5;
    newB.normalizedY = 0.65;
    newB.swipeUpLength = 140.0;
    newB.duration = 0.18;
    newB.triggerThreshold = 0.5;

    [self.activeProfile.bindings addObject:newB];
    self.selectedBindingIndex = self.activeProfile.bindings.count - 1;

    if (!self.editMode) {
        [self toggleEditMode];
    } else {
        [self refreshUI];
    }
}

- (void)cycleSelectedBinding {
    if (!self.activeProfile || self.activeProfile.bindings.count == 0) return;
    self.selectedBindingIndex = (self.selectedBindingIndex + 1) % self.activeProfile.bindings.count;
    [self refreshUI];
}

- (void)cycleInputTypeForSelectedBinding {
    TouchActionBinding *b = [self currentBinding];
    if (!b) return;
    NSInteger nextType = ((NSInteger)b.inputType + 1) % 8;
    b.inputType = (PadInputBinding)nextType;
    [self refreshUI];
}

- (void)promptRenameSelectedBinding {
    TouchActionBinding *b = [self currentBinding];
    if (!b || !self.editorWindow) return;

    UIViewController *topVC = self.editorWindow.rootViewController;
    while (topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Podpis elementu"
                                                                message:@"Wpisz nazwę dla tego przycisku lub suwaka:"
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = b.label;
        textField.placeholder = @"np. Skok / Kamera";
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Anuluj" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Zapisz" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        NSString *typed = alert.textFields.firstObject.text;
        NSString *trimmed = [typed stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length > 0) {
            b.label = trimmed;
            [weakSelf refreshUI];
        }
    }]];

    [topVC presentViewController:alert animated:YES completion:nil];
}

- (void)sliderChanged:(UISlider *)sender {
    TouchActionBinding *b = [self currentBinding];
    if (!b) return;
    b.swipeUpLength = sender.value;
    [self refreshUI];
}

- (void)decreaseSwipeLength {
    TouchActionBinding *b = [self currentBinding];
    if (!b) return;
    b.swipeUpLength = MAX(20.0, b.swipeUpLength - 20.0);
    [self refreshUI];
}

- (void)increaseSwipeLength {
    TouchActionBinding *b = [self currentBinding];
    if (!b) return;
    b.swipeUpLength = MIN(500.0, b.swipeUpLength + 20.0);
    [self refreshUI];
}

- (void)cycleNextProfile {
    if (self.profiles.count == 0) return;
    NSUInteger idx = [self.profiles indexOfObject:self.activeProfile];
    NSUInteger nextIdx = (idx == NSNotFound) ? 0 : (idx + 1) % self.profiles.count;
    self.activeProfile = self.profiles[nextIdx];
    self.selectedBindingIndex = 0;
    [self refreshUI];
}

- (void)handleMarkerPan:(UIPanGestureRecognizer *)pan {
    TouchActionBinding *b = [self currentBinding];
    if (!self.editMode || !b || !self.editorWindow) return;

    CGSize size = self.editorWindow.bounds.size;
    CGPoint loc = [pan locationInView:self.editorWindow.rootViewController.view];

    b.normalizedX = MIN(MAX(loc.x / size.width, 0.05), 0.95);
    b.normalizedY = MIN(MAX(loc.y / size.height, 0.15), 0.92);
    [self refreshUI];
}

- (void)refreshUI {
    if (!self.activeProfile) return;

    UIButton *profileBtn = [self.profileBar viewWithTag:101];
    [profileBtn setTitle:[NSString stringWithFormat:@"Profil: %@", self.activeProfile.name] forState:UIControlStateNormal];

    UIButton *editBtn = [self.profileBar viewWithTag:102];
    [editBtn setTitle:(self.editMode ? @"Gotowe" : @"Edytuj") forState:UIControlStateNormal];

    TouchActionBinding *b = [self currentBinding];
    if (!b || !self.editorWindow) return;

    NSString *inputName = [TouchActionBinding nameForInputType:b.inputType];
    [self.bindingCycleBtn setTitle:[NSString stringWithFormat:@"%lu/%lu: %@",
                                    (unsigned long)(self.selectedBindingIndex + 1),
                                    (unsigned long)self.activeProfile.bindings.count,
                                    b.label] forState:UIControlStateNormal];
    [self.inputTypeBtn setTitle:[NSString stringWithFormat:@"Pad: %@", inputName] forState:UIControlStateNormal];
    self.lengthLabel.text = [NSString stringWithFormat:@"%.0f pt ↑", b.swipeUpLength];
    self.markerCaptionLabel.text = [NSString stringWithFormat:@"%@ [%@]", b.label, inputName];

    UISlider *slider = [self.editPanel viewWithTag:201];
    if (slider) {
        slider.value = b.swipeUpLength;
    }

    CGSize size = self.editorWindow.bounds.size;
    CGFloat x = b.normalizedX * size.width;
    CGFloat y = b.normalizedY * size.height;
    self.gestureMarker.center = CGPointMake(x, y);

    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(x, y)];
    [path addLineToPoint:CGPointMake(x, y - b.swipeUpLength)];
    self.swipePreviewLayer.path = path.CGPath;
}

@end

@implementation OverlayControllerManager (UIKitTouchInjection)

- (UIWindowScene *)activeScene {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] &&
                scene.activationState == UISceneActivationStateForegroundActive) {
                return (UIWindowScene *)scene;
            }
        }
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                return (UIWindowScene *)scene;
            }
        }
    }
    return nil;
}

- (UIWindow *)targetAppWindow {
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = [self activeScene];
        if (scene) {
            for (UIWindow *win in scene.windows) {
                if (win != self.barWindow && win != self.editorWindow && !win.hidden && win.alpha > 0.01 && win.isKeyWindow) {
                    return win;
                }
            }
            for (UIWindow *win in scene.windows) {
                if (win != self.barWindow && win != self.editorWindow && !win.hidden && win.alpha > 0.01) {
                    return win;
                }
            }
        }
    }
    UIWindow *fallback = [UIApplication sharedApplication].keyWindow;
    return (fallback != self.barWindow && fallback != self.editorWindow) ? fallback : nil;
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

- (void)performSwipeUpForBinding:(TouchActionBinding *)binding {
    if (!binding) return;
    UIWindow *window = [self targetAppWindow];
    if (!window) return;

    CGSize size = window.bounds.size;
    CGPoint startPt = CGPointMake(binding.normalizedX * size.width,
                                  binding.normalizedY * size.height);
    CGFloat length = binding.swipeUpLength;
    NSTimeInterval duration = MAX(binding.duration, 0.06);

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
