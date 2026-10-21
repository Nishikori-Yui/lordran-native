// Edge-docked menu and a live, nonmodal control editor over the game picture.
#import "DmControlOverlay.h"
#import "DmGamepad.h"
#import "DmDiagnostics.h"
#import "DmAppSettings.h"
#include "../../host/cheats.h"
#import <QuartzCore/QuartzCore.h>

enum { PageClosed, PageMenu, PageEditor, PageInput, PageAppearance, PageCheats };
enum { SliderX, SliderY, SliderScale, SliderAngle, SliderOpacity, SliderDeadzone, SliderLookSensitivity, SliderCount };
static NSString *const kDockKey = @"DmControlDock.v1";
static NSString *T(NSString *english, NSString *simplifiedChinese) { return DmAppText(english, simplifiedChinese); }

@implementation DmControlOverlay {
    UIButton *_ball, *_selection, *_export, *_confirm;
    UIView *_panel;
    UIScrollView *_scroll;
    UIStackView *_stack;
    UISlider *_sliders[SliderCount];
    UIButton *_lookPresets;
    UILabel *_values[SliderCount], *_controllerLabel;
    NSInteger _page, _edge;
    CGFloat _fraction;
    CGPoint _panStart, _panelPanStart;
    BOOL _draggingBall, _panelMoved;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor; self.opaque = NO;
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:kDockKey];
        _edge = [saved[@"edge"] integerValue]; if (_edge < 0 || _edge > 3) _edge = 1;
        _fraction = saved ? [saved[@"fraction"] doubleValue] : 0.42;
        if (!isfinite(_fraction)) _fraction = 0.42; _fraction = fmax(0, fmin(1, _fraction));
        if (!saved) _edge = 1;
        _ball = [UIButton buttonWithType:UIButtonTypeSystem];
        _ball.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.58];
        _ball.layer.cornerRadius = 24; _ball.layer.borderWidth = 1;
        _ball.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
        _ball.tintColor = [UIColor colorWithWhite:1 alpha:0.9];
        [_ball setImage:[UIImage systemImageNamed:@"line.3.horizontal"] forState:UIControlStateNormal];
        _ball.accessibilityLabel = T(@"Controls menu", @"控制菜单");
        _ball.accessibilityHint = T(@"Tap to open. Drag to dock at an edge.", @"点按展开，拖动后吸附屏幕边缘。");
        [_ball addTarget:self action:@selector(toggleMenu) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panBall:)];
        [_ball addGestureRecognizer:pan]; [self addSubview:_ball];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(controllerChanged) name:DmControllerChangedNotification object:nil];
    }
    return self;
}
- (void)setGamepad:(DmGamepad *)gamepad {
    _gamepad.selectionChanged = nil; _gamepad = gamepad;
    __weak DmControlOverlay *weakSelf = self;
    gamepad.selectionChanged = ^{ [weakSelf updateEditor]; };
    if (_page == PageMenu || _page == PageInput || _page == PageAppearance || _page == PageCheats) [self showPage:_page];
}
- (CGRect)dockRect { return CGRectInset(UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets), 24, 24); }
- (void)placeBall {
    if (_draggingBall) return;
    CGRect r = self.dockRect;
    CGPoint c;
    if (_edge < 2) c = CGPointMake(_edge ? CGRectGetMaxX(r) : CGRectGetMinX(r), CGRectGetMinY(r) + r.size.height * _fraction);
    else c = CGPointMake(CGRectGetMinX(r) + r.size.width * _fraction, _edge == 2 ? CGRectGetMinY(r) : CGRectGetMaxY(r));
    _ball.bounds = CGRectMake(0, 0, 48, 48); _ball.center = c;
}
- (void)layoutSubviews {
    [super layoutSubviews]; [self placeBall];
    if (_confirm) {
        _confirm.bounds = CGRectMake(0, 0, 128, 52);
        _confirm.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    }
    if (!_panel) return;
    CGRect safe = CGRectInset(UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets), 8, 8);
    CGRect panelSafe = safe;
    if (_page == PageCheats) {
        CGFloat topReserve = MIN(120, MAX(0, safe.size.height - 120));
        panelSafe.origin.y += topReserve;
        panelSafe.size.height -= topReserve;
    }
    CGFloat preferredWidth = _page == PageEditor || _page == PageInput ? 310 : (_page == PageCheats ? 340 : 290);
    CGFloat width = MIN(preferredWidth, panelSafe.size.width);
    CGSize content = [_stack systemLayoutSizeFittingSize:CGSizeMake(width - 24, UILayoutFittingCompressedSize.height)
        withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    CGFloat height = MIN(content.height + 24, panelSafe.size.height);
    CGPoint origin;
    if (_panelMoved) origin = _panel.frame.origin;
    else {
        origin.x = _ball.center.x < CGRectGetMidX(panelSafe) ? CGRectGetMaxX(_ball.frame) + 8 : CGRectGetMinX(_ball.frame) - 8 - width;
        origin.y = _ball.center.y - 24;
    }
    origin.x = fmax(CGRectGetMinX(panelSafe), fmin(CGRectGetMaxX(panelSafe) - width, origin.x));
    origin.y = fmax(CGRectGetMinY(panelSafe), fmin(CGRectGetMaxY(panelSafe) - height, origin.y));
    _panel.frame = CGRectMake(origin.x, origin.y, width, height); _scroll.frame = _panel.bounds;
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self && (_page == PageClosed || _page == PageEditor)) return nil;
    return hit;
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_page != PageEditor) [self closeMenu];
}
- (void)toggleMenu {
    if (_page == PageClosed) [self showPage:PageMenu];
    else if (_page != PageEditor) [self closeMenu];
}
- (void)panBall:(UIPanGestureRecognizer *)pan {
    if (pan.state == UIGestureRecognizerStateBegan) {
        _panStart = _ball.center; _draggingBall = YES; [_gamepad setInputSuspended:YES];
    }
    CGPoint delta = [pan translationInView:self]; CGRect r = self.dockRect;
    _ball.center = CGPointMake(fmax(CGRectGetMinX(r), fmin(CGRectGetMaxX(r), _panStart.x + delta.x)),
                              fmax(CGRectGetMinY(r), fmin(CGRectGetMaxY(r), _panStart.y + delta.y)));
    if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        CGPoint p = _ball.center;
        CGFloat distances[] = {fabs(p.x - CGRectGetMinX(r)), fabs(p.x - CGRectGetMaxX(r)), fabs(p.y - CGRectGetMinY(r)), fabs(p.y - CGRectGetMaxY(r))};
        _edge = 0; for (NSInteger i = 1; i < 4; i++) if (distances[i] < distances[_edge]) _edge = i;
        _fraction = _edge < 2 ? (p.y - r.origin.y) / MAX(1, r.size.height) : (p.x - r.origin.x) / MAX(1, r.size.width);
        [NSUserDefaults.standardUserDefaults setObject:@{@"edge": @(_edge), @"fraction": @(_fraction)} forKey:kDockKey];
        _draggingBall = NO; _panelMoved = NO;
        [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0 : 0.2 animations:^{ [self placeBall]; [self setNeedsLayout]; [self layoutIfNeeded]; }];
        [_gamepad setInputSuspended:_page != PageClosed];
    }
}
- (void)panPanel:(UIPanGestureRecognizer *)pan {
    if (pan.state == UIGestureRecognizerStateBegan) { _panelPanStart = _panel.frame.origin; _panelMoved = YES; }
    CGPoint delta = [pan translationInView:self]; CGRect f = _panel.frame;
    f.origin = CGPointMake(_panelPanStart.x + delta.x, _panelPanStart.y + delta.y); _panel.frame = f;
    [self setNeedsLayout]; [self layoutIfNeeded];
}
- (UILabel *)addText:(NSString *)text small:(BOOL)small {
    UILabel *label = [UILabel new]; label.text = text; label.numberOfLines = 0;
    label.textColor = small ? [UIColor colorWithWhite:1 alpha:0.7] : UIColor.whiteColor;
    label.font = [UIFont preferredFontForTextStyle:small ? UIFontTextStyleFootnote : UIFontTextStyleHeadline];
    label.adjustsFontForContentSizeCategory = YES; [_stack addArrangedSubview:label]; return label;
}
- (UIButton *)addButton:(NSString *)title symbol:(NSString *)symbol action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *c = UIButtonConfiguration.tintedButtonConfiguration;
    c.title = title; if (symbol) c.image = [UIImage systemImageNamed:symbol]; c.imagePadding = 8;
    c.baseForegroundColor = [UIColor colorWithRed:0.55 green:1.0 blue:0.12 alpha:1.0];
    c.baseBackgroundColor = UIColor.clearColor;
    c.titleLineBreakMode = NSLineBreakByWordWrapping; button.configuration = c;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    if (action) [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [_stack addArrangedSubview:button]; return button;
}
- (UISwitch *)addSwitch:(NSString *)title on:(BOOL)on action:(SEL)action {
    UILabel *label = [UILabel new]; label.text = title; label.numberOfLines = 0;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]; label.adjustsFontForContentSizeCategory = YES;
    UISwitch *toggle = [UISwitch new]; toggle.on = on; toggle.accessibilityLabel = title;
    [toggle addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [toggle setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[label, toggle]];
    row.alignment = UIStackViewAlignmentCenter; row.spacing = 8; [_stack addArrangedSubview:row];
    [row.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    return toggle;
}
- (void)addSlider:(NSInteger)tag title:(NSString *)title min:(float)low max:(float)high value:(float)value {
    _values[tag] = [self addText:title small:YES];
    UISlider *slider = [UISlider new]; slider.tag = tag; slider.minimumValue = low; slider.maximumValue = high; slider.value = value;
    slider.accessibilityLabel = title; [slider.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    _sliders[tag] = slider; [_stack addArrangedSubview:slider];
}
- (UIButton *)addChoice:(NSString *)title choices:(NSArray<NSString *> *)choices selected:(NSInteger)selected change:(void (^)(NSInteger))change {
    UIButton *button = [self addButton:[NSString stringWithFormat:@"%@: %@", title, choices[MAX(0, MIN((NSInteger)choices.count - 1, selected))]] symbol:@"chevron.up.chevron.down" action:NULL];
    NSMutableArray *actions = [NSMutableArray new];
    __weak UIButton *weakButton = button;
    for (NSInteger i = 0; i < (NSInteger)choices.count; i++) {
        UIAction *action = [UIAction actionWithTitle:choices[i] image:nil identifier:nil handler:^(UIAction *action) {
            change(i);
            UIButtonConfiguration *c = weakButton.configuration; c.title = [NSString stringWithFormat:@"%@: %@", title, choices[i]]; weakButton.configuration = c;
            for (UIAction *item in weakButton.menu.children) item.state = [item.title isEqualToString:choices[i]] ? UIMenuElementStateOn : UIMenuElementStateOff;
        }];
        action.state = i == selected ? UIMenuElementStateOn : UIMenuElementStateOff; [actions addObject:action];
    }
    button.menu = [UIMenu menuWithChildren:actions]; button.showsMenuAsPrimaryAction = YES; return button;
}
- (void)showPage:(NSInteger)page {
    _page = page; _panelMoved = NO; [_panel removeFromSuperview];
    _panel = nil;
    for (int i = 0; i < SliderCount; i++) { _sliders[i] = nil; _values[i] = nil; }
    _selection = nil; _export = nil; _controllerLabel = nil; _lookPresets = nil;
    [_confirm removeFromSuperview]; _confirm = nil;
    _ball.hidden = page != PageClosed;
    if (page == PageEditor) {
        // Layout editing is a clean canvas: only frames, resize handles and Done remain visible.
        [_gamepad setInputSuspended:YES];
        [self buildEditor];
        _ball.accessibilityValue = T(@"Editing", @"编辑中");
        [self setNeedsLayout]; [self layoutIfNeeded];
        return;
    }
    _panel = [UIView new]; _panel.backgroundColor = UIColor.clearColor;
    _panel.layer.cornerRadius = 0; _panel.layer.borderWidth = 0;
    _panel.clipsToBounds = YES; [self insertSubview:_panel belowSubview:_ball];
    _scroll = [UIScrollView new]; _scroll.alwaysBounceVertical = YES; [_panel addSubview:_scroll];
    _stack = [UIStackView new]; _stack.axis = UILayoutConstraintAxisVertical; _stack.spacing = 8;
    _stack.translatesAutoresizingMaskIntoConstraints = NO; [_scroll addSubview:_stack];
    [NSLayoutConstraint activateConstraints:@[
        [_stack.leadingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.leadingAnchor constant:12],
        [_stack.trailingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.trailingAnchor constant:-12],
        [_stack.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor constant:12],
        [_stack.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor constant:-12],
        [_stack.widthAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.widthAnchor constant:-24]
    ]];
    NSString *headingText = page == PageMenu ? T(@"Controls", @"控制菜单") : page == PageInput ? T(@"Input", @"输入设置") :
        page == PageCheats ? T(@"Cheats", @"金手指") : T(@"Button appearance", @"按键外观");
    UILabel *heading = [self addText:headingText small:NO];
    heading.textColor = [UIColor colorWithRed:0.55 green:1.0 blue:0.12 alpha:1.0];
    heading.userInteractionEnabled = YES;
    [heading addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panPanel:)]];
    [_gamepad setInputSuspended:YES];
    if (page == PageMenu) [self buildMenu]; else if (page == PageInput) [self buildInput];
    else if (page == PageCheats) [self buildCheats]; else [self buildAppearance];
    _ball.accessibilityValue = T(@"Open", @"已展开");
    [self setNeedsLayout]; [self layoutIfNeeded];
}
- (void)buildMenu {
    [self addButton:T(@"Edit controls", @"调整按键") symbol:@"hand.draw" action:@selector(editControls)].enabled = _gamepad != nil;
    [self addButton:T(@"Button appearance", @"按键外观") symbol:@"paintbrush" action:@selector(buttonAppearance)].enabled = _gamepad != nil;
    [self addSwitch:T(@"Show FPS", @"显示帧率") on:self.showsFPS action:@selector(fpsToggled:)];
    [self addButton:T(@"Cheats", @"金手指") symbol:@"switch.2" action:@selector(cheats)];
    _export = [self addButton:T(@"Export log", @"导出日志") symbol:@"square.and.arrow.up" action:@selector(exportLog)];
    __weak DmControlOverlay *weakSelf = self;
    NSArray *languages = DmAppUsesChinese() ? @[@"英语", @"简体中文"] : @[@"English", @"Simplified Chinese"];
    [self addChoice:T(@"Language", @"语言") choices:languages selected:DmAppUsesChinese() ? 1 : 0 change:^(NSInteger index) {
        [weakSelf requestLanguage:index];
    }];
    NSArray *modes = DmAppUsesChinese() ? @[@"主机模式", @"掌机模式"] : @[@"Console mode", @"Handheld mode"];
    [self addChoice:T(@"Operation mode", @"运行模式") choices:modes selected:DmAppOperationMode() == 0 ? 1 : 0 change:^(NSInteger index) {
        [weakSelf requestOperationMode:index];
    }];
    [self addButton:T(@"Input & controller", @"触控与手柄") symbol:@"gamecontroller" action:@selector(inputSettings)].enabled = _gamepad != nil;
    [self addButton:T(@"Close", @"关闭") symbol:nil action:@selector(closeMenu)];
}
- (void)fpsToggled:(UISwitch *)toggle {
    self.showsFPS = toggle.on; [NSUserDefaults.standardUserDefaults setBool:toggle.on forKey:DmAppFPSKey];
    if (self.fpsChanged) self.fpsChanged(toggle.on);
}
- (void)exportLog { DmDiagnosticsShare(self.presenter, _export); }
- (void)closeMenu {
    _page = PageClosed; [_panel removeFromSuperview]; _panel = nil; [_confirm removeFromSuperview]; _confirm = nil;
    _ball.hidden = NO;
    [_gamepad setInputSuspended:NO]; _ball.accessibilityValue = T(@"Closed", @"已收起");
}
- (void)editControls { [_gamepad beginEditingControls]; [self showPage:PageEditor]; }
- (void)inputSettings { [self showPage:PageInput]; }
- (void)buttonAppearance { [self showPage:PageAppearance]; }
- (void)cheats { [self showPage:PageCheats]; }
- (void)buildCheats {
    unsigned count = dm_cheat_count();
    if (!count) [self addText:T(@"No switchable cheats are included in this build.", @"此版本未包含可即时切换的金手指。") small:YES];
    else {
        UILabel *warning = [self addText:T(@"Keep cheats off before entering the game. Enable them after gameplay starts.",
                                           @"进入游戏前请保持关闭，进入游戏后再开启。") small:YES];
        warning.textColor = [UIColor colorWithRed:0.55 green:1.0 blue:0.12 alpha:1.0];
        [self addText:T(@"Changes apply during play. Disabling a cheat does not undo changes already saved by the game.",
                       @"开关在游玩过程中生效。关闭金手指不会撤销游戏已经保存的变更。") small:YES];
        for (unsigned i = 0; i < count; i++) {
            UILabel *name = [UILabel new]; name.text = @(dm_cheat_name(i));
            name.numberOfLines = 1; name.lineBreakMode = NSLineBreakByTruncatingTail;
            name.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
            name.adjustsFontForContentSizeCategory = YES; name.textColor = UIColor.whiteColor;
            UIButton *toggle = [UIButton buttonWithType:UIButtonTypeSystem]; toggle.tag = i;
            toggle.accessibilityLabel = name.text;
            [toggle addTarget:self action:@selector(cheatToggled:) forControlEvents:UIControlEventTouchUpInside];
            UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[name, toggle]];
            row.axis = UILayoutConstraintAxisHorizontal; row.alignment = UIStackViewAlignmentCenter; row.spacing = 8;
            [name setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
            [toggle setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
            [toggle.widthAnchor constraintEqualToConstant:44].active = YES;
            [row.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
            [_stack addArrangedSubview:row];
            [self updateCheatToggle:toggle enabled:dm_cheat_enabled(i)];
        }
    }
    [self addButton:T(@"Back", @"返回") symbol:@"chevron.left" action:@selector(back)];
}
- (void)updateCheatToggle:(UIButton *)toggle enabled:(BOOL)enabled {
    UIImage *image = [UIImage systemImageNamed:enabled ? @"circle.fill" : @"circle"];
    [toggle setImage:image forState:UIControlStateNormal];
    toggle.tintColor = enabled ? [UIColor colorWithRed:0.55 green:1.0 blue:0.12 alpha:1.0] : [UIColor colorWithWhite:1 alpha:0.55];
    toggle.accessibilityValue = enabled ? T(@"On", @"已开启") : T(@"Off", @"已关闭");
    toggle.accessibilityHint = T(@"Double-tap to toggle this cheat.", @"轻点两下切换此金手指。");
}
- (void)cheatToggled:(UIButton *)toggle {
    BOOL enabled = !dm_cheat_enabled((unsigned)toggle.tag);
    if (dm_cheat_set((unsigned)toggle.tag, enabled)) [self updateCheatToggle:toggle enabled:enabled];
}
- (void)back { [self showPage:PageMenu]; }
- (void)buildEditor {
    // Do not build a floating inspector here. The game view is the editor surface.
    _confirm = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *done = UIButtonConfiguration.filledButtonConfiguration;
    done.title = T(@"Done", @"确定"); done.image = [UIImage systemImageNamed:@"checkmark"];
    done.imagePadding = 8; done.baseBackgroundColor = [UIColor colorWithWhite:0.08 alpha:0.84];
    done.baseForegroundColor = UIColor.whiteColor; _confirm.configuration = done;
    _confirm.layer.cornerRadius = 16; _confirm.layer.borderWidth = 1; _confirm.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.4].CGColor;
    _confirm.accessibilityLabel = T(@"Done editing controls", @"确定按键调整");
    [_confirm addTarget:self action:@selector(saveEdits) forControlEvents:UIControlEventTouchUpInside]; [self addSubview:_confirm];
}
- (void)updateEditor { [self updateAppearance]; }
- (void)saveEdits { [_gamepad finishEditingControlsSaving:YES]; [self closeMenu]; }
- (void)cancelEdits { [_gamepad finishEditingControlsSaving:NO]; [self closeMenu]; }
- (void)resetSelected { [_gamepad.profile setStyle:DmControlStyleDefault() forControl:_gamepad.selectedControl]; [_gamepad setNeedsLayout]; [_gamepad layoutIfNeeded]; [self updateAppearance]; }
- (void)resetLayout { [_gamepad.profile resetStyles]; [_gamepad setNeedsLayout]; [_gamepad layoutIfNeeded]; [self updateAppearance]; }
- (void)requestRestart:(NSString *)title message:(NSString *)message apply:(void (^)(void))apply {
    if (!self.presenter || self.presenter.presentedViewController) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:T(@"Cancel", @"取消") style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        (void)action; [self showPage:PageMenu];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:T(@"Restart now", @"立即重启") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action; apply(); [NSUserDefaults.standardUserDefaults synchronize]; DmAppExitForSettings();
    }]];
    [self.presenter presentViewController:alert animated:YES completion:nil];
}
- (void)requestLanguage:(NSInteger)index {
    NSString *language = index == 1 ? @"zh-Hans" : @"en-US";
    if ([language isEqualToString:DmAppLanguage()]) return;
    NSString *name = index == 1 ? T(@"Simplified Chinese", @"简体中文") : T(@"English", @"英语");
    [self requestRestart:T(@"Restart required", @"需要重启")
        message:[NSString stringWithFormat:T(@"Switch to %@ and restart the game?", @"切换到 %@ 并重启游戏？"), name]
        apply:^{ [NSUserDefaults.standardUserDefaults setObject:language forKey:DmAppLanguageKey]; }];
}
- (void)requestOperationMode:(NSInteger)index {
    NSInteger mode = index == 1 ? 0 : 1;
    if (mode == DmAppOperationMode()) return;
    NSString *name = mode == 0 ? T(@"Handheld mode", @"掌机模式") : T(@"Console mode", @"主机模式");
    [self requestRestart:T(@"Restart required", @"需要重启")
        message:[NSString stringWithFormat:T(@"Switch to %@ and restart the game?", @"切换到 %@ 并重启游戏？"), name]
        apply:^{ [NSUserDefaults.standardUserDefaults setObject:@(mode) forKey:DmAppOperationModeKey]; }];
}
- (void)buildAppearance {
    NSMutableArray *names = [NSMutableArray new];
    for (NSInteger c = 0; c < DmControlCount; c++) [names addObject:DmControlName(c)];
    __weak DmControlOverlay *weakSelf = self;
    _selection = [self addChoice:T(@"Control", @"按键") choices:names selected:_gamepad.selectedControl change:^(NSInteger c) {
        weakSelf.gamepad.selectedControl = c; [weakSelf updateAppearance];
    }];
    [self addSlider:SliderAngle title:T(@"Rotation", @"旋转") min:-180 max:180 value:0];
    [self addSlider:SliderOpacity title:T(@"Opacity", @"透明度") min:0.1 max:1 value:1];
    NSArray *shapes = DmAppUsesChinese() ? @[@"默认", @"圆形", @"方形", @"水滴", @"圆角"] : @[@"Default", @"Circle", @"Square", @"Drop", @"Rounded"];
    UIButton *shapeButton = [self addChoice:T(@"Shape", @"形状") choices:shapes selected:[_gamepad.profile styleForControl:_gamepad.selectedControl].shape change:^(NSInteger shape) {
        DmControlStyle s = [weakSelf.gamepad.profile styleForControl:weakSelf.gamepad.selectedControl]; s.shape = shape;
        [weakSelf.gamepad.profile setStyle:s forControl:weakSelf.gamepad.selectedControl]; [weakSelf.gamepad setNeedsLayout]; [weakSelf.gamepad layoutIfNeeded];
        [weakSelf updateAppearance];
    }];
    shapeButton.tag = 500;
    [self addButton:T(@"Reset this control", @"重置此按键") symbol:@"arrow.counterclockwise" action:@selector(resetSelected)];
    [self addText:T(@"Position and size are adjusted directly in Edit controls.", @"位置和大小请在调整按键中直接拖动。") small:YES];
    [self updateAppearance];
}
- (void)updateAppearance {
    if (_page != PageAppearance || !_selection) return;
    NSInteger c = _gamepad.selectedControl; DmControlStyle s = [_gamepad.profile styleForControl:c];
    UIButtonConfiguration *config = _selection.configuration; config.title = [NSString stringWithFormat:@"%@: %@", T(@"Control", @"按键"), DmControlName(c)]; _selection.configuration = config;
    _sliders[SliderAngle].value = s.angle; _values[SliderAngle].text = [NSString stringWithFormat:T(@"Rotation: %.0f°", @"旋转：%.0f°"), s.angle];
    _sliders[SliderOpacity].value = s.opacity; _values[SliderOpacity].text = [NSString stringWithFormat:T(@"Opacity: %.0f%%", @"透明度：%.0f%%"), s.opacity * 100];
    UIButton *shape = [_stack viewWithTag:500];
    NSArray *names = DmAppUsesChinese() ? @[@"默认", @"圆形", @"方形", @"水滴", @"圆角"] : @[@"Default", @"Circle", @"Square", @"Drop", @"Rounded"];
    config = shape.configuration; config.title = [NSString stringWithFormat:@"%@: %@", T(@"Shape", @"形状"), names[s.shape]]; shape.configuration = config;
}
- (void)sliderChanged:(UISlider *)slider {
    if (slider.tag == SliderLookSensitivity) {
        slider.value = roundf(slider.value * 100) / 100;
        _gamepad.profile.lookSensitivity = slider.value; [_gamepad profileChanged];
        [self updateLookSensitivity];
        return;
    }
    if (slider.tag == SliderDeadzone) {
        _gamepad.profile.deadzone = slider.value; [_gamepad profileChanged];
        _values[SliderDeadzone].text = [NSString stringWithFormat:T(@"Stick deadzone: %.0f%%", @"摇杆死区：%.0f%%"), slider.value * 100];
        return;
    }
    if (_page != PageAppearance) return;
    DmControlStyle s = [_gamepad.profile styleForControl:_gamepad.selectedControl];
    if (slider.tag == SliderAngle) s.angle = slider.value;
    if (slider.tag == SliderOpacity) s.opacity = slider.value;
    [_gamepad.profile setStyle:s forControl:_gamepad.selectedControl]; [_gamepad setNeedsLayout]; [_gamepad layoutIfNeeded]; [self updateAppearance];
}
- (void)buildInput {
    [self addButton:T(@"Back", @"返回") symbol:@"chevron.left" action:@selector(back)];
    __weak DmControlOverlay *weakSelf = self;
    NSArray *modes = DmAppUsesChinese() ? @[@"摇杆", @"滑屏"] : @[@"Joystick", @"Swipe"];
    [self addChoice:T(@"Left", @"左侧") choices:modes selected:_gamepad.profile.leftMode change:^(NSInteger mode) {
        weakSelf.gamepad.profile.leftMode = mode; [weakSelf.gamepad profileChanged];
    }];
    [self addChoice:T(@"Right", @"右侧") choices:modes selected:_gamepad.profile.rightMode change:^(NSInteger mode) {
        weakSelf.gamepad.profile.rightMode = mode; [weakSelf.gamepad profileChanged];
    }];
    [self addText:T(@"Swipe empty space to move or look. If both sides use swipe, each uses its own half.", @"在空白处滑动以移动或转动视角；两侧都选滑屏时，分别使用左右半屏。") small:YES];
    [self addText:T(@"Touch camera", @"触屏视角") small:NO];
    [self addSwitch:T(@"Invert horizontal", @"横轴反转") on:_gamepad.profile.lookInvertX action:@selector(lookInvertXToggled:)];
    [self addSwitch:T(@"Invert vertical", @"纵轴反转") on:_gamepad.profile.lookInvertY action:@selector(lookInvertYToggled:)];
    [self addSlider:SliderLookSensitivity title:T(@"Sensitivity", @"灵敏度") min:0.05 max:3 value:_gamepad.profile.lookSensitivity];
    [self updateLookSensitivity];
    NSArray *speeds = DmAppUsesChinese() ? @[@"慢速 0.5 倍", @"标准 1 倍", @"快速 2 倍"] :
                                         @[@"Slow 0.5x", @"Standard 1x", @"Fast 2x"];
    CGFloat sensitivity = _gamepad.profile.lookSensitivity;
    NSInteger preset = fabs(sensitivity - 0.5) < 0.001 ? 0 : fabs(sensitivity - 1) < 0.001 ? 1 :
                       fabs(sensitivity - 2) < 0.001 ? 2 : UISegmentedControlNoSegment;
    _lookPresets = [self addChoice:T(@"Camera speed", @"视角速度") choices:speeds selected:preset change:^(NSInteger index) {
        const CGFloat values[] = {0.5, 1, 2};
        weakSelf.gamepad.profile.lookSensitivity = values[index];
        [weakSelf.gamepad profileChanged]; [weakSelf showPage:PageInput];
    }];
    [self updateLookSensitivity];
    [self addText:T(@"1x matches the previous 3x. Fine-tune from 0.05x to 3x; saved settings keep their previous response.", @"新 1 倍相当于旧 3 倍，可在 0.05–3 倍间微调；已保存的设置保留原来的响应强度。") small:YES];
    [self addButton:T(@"Reset touch camera", @"重置触屏视角") symbol:@"arrow.counterclockwise" action:@selector(resetTouchCamera)];
    [self addSwitch:T(@"D-pad & L3/R3", @"十字键与按压键") on:_gamepad.profile.fullLayout action:@selector(layoutToggled:)];
    _controllerLabel = [self addText:_gamepad.controllerStatus small:YES];
    NSArray *controllers = _gamepad.controllerNames;
    if (controllers.count > 1) [self addChoice:T(@"Controller", @"当前手柄") choices:controllers selected:_gamepad.activeControllerIndex change:^(NSInteger index) { [weakSelf.gamepad selectController:index]; }];
    NSArray *mapping = DmAppUsesChinese() ? @[@"按位置", @"自动识别", @"Xbox 字母"] : @[@"Position", @"Auto", @"Xbox letters"];
    [self addChoice:T(@"Face buttons", @"ABXY 映射") choices:mapping selected:_gamepad.profile.faceMapping change:^(NSInteger mode) {
        weakSelf.gamepad.profile.faceMapping = mode; [weakSelf.gamepad profileChanged];
    }];
    [self addText:T(@"Position: east A, south B. Auto: Nintendo letters on Switch; Xbox letters on Xbox and PlayStation.", @"按位置：右 A、下 B。自动：Switch 按任天堂字母，Xbox 与 PlayStation 按 Xbox 布局。") small:YES];
    [self addSlider:SliderDeadzone title:T(@"Stick deadzone", @"摇杆死区") min:0.05 max:0.35 value:_gamepad.profile.deadzone];
    _values[SliderDeadzone].text = [NSString stringWithFormat:T(@"Stick deadzone: %.0f%%", @"摇杆死区：%.0f%%"), _gamepad.profile.deadzone * 100];
    [self addSwitch:T(@"Hide touch controls with controller", @"连手柄时隐藏触控") on:_gamepad.profile.hideWithController action:@selector(hideToggled:)];
    [self addText:T(@"Pair a controller in iOS Bluetooth settings. Shoulders, triggers, stick clicks, menu and options are supported when present.", @"在 iOS 蓝牙设置中配对手柄；支持手柄提供的肩键、扳机、摇杆按压、菜单与选项键。") small:YES];
}
- (void)updateLookSensitivity {
    NSString *value = [NSString stringWithFormat:T(@"%.2fx", @"%.2f 倍"), _gamepad.profile.lookSensitivity];
    _values[SliderLookSensitivity].text = [NSString stringWithFormat:@"%@: %@", T(@"Sensitivity", @"灵敏度"), value];
    _sliders[SliderLookSensitivity].accessibilityValue = value;
    CGFloat sensitivity = _gamepad.profile.lookSensitivity;
    NSInteger preset = fabs(sensitivity - 0.5) < 0.001 ? 0 : fabs(sensitivity - 1) < 0.001 ? 1 :
                       fabs(sensitivity - 2) < 0.001 ? 2 : -1;
    NSArray *names = DmAppUsesChinese() ? @[@"慢速 0.5 倍", @"标准 1 倍", @"快速 2 倍"] :
                                        @[@"Slow 0.5x", @"Standard 1x", @"Fast 2x"];
    UIButtonConfiguration *config = _lookPresets.configuration;
    config.title = [NSString stringWithFormat:@"%@: %@", T(@"Camera speed", @"视角速度"),
                    preset < 0 ? T(@"Custom", @"自定义") : names[preset]];
    _lookPresets.configuration = config;
    for (NSInteger i = 0; i < (NSInteger)_lookPresets.menu.children.count; i++) {
        UIAction *action = (UIAction *)_lookPresets.menu.children[i];
        action.state = i == preset ? UIMenuElementStateOn : UIMenuElementStateOff;
    }
}
- (void)lookInvertXToggled:(UISwitch *)toggle { _gamepad.profile.lookInvertX = toggle.on; [_gamepad profileChanged]; }
- (void)lookInvertYToggled:(UISwitch *)toggle { _gamepad.profile.lookInvertY = toggle.on; [_gamepad profileChanged]; }
- (void)resetTouchCamera {
    _gamepad.profile.lookSensitivity = 1; _gamepad.profile.lookInvertX = _gamepad.profile.lookInvertY = NO;
    [_gamepad profileChanged]; [self showPage:PageInput];
}
- (void)layoutToggled:(UISwitch *)toggle { _gamepad.profile.fullLayout = toggle.on; [_gamepad profileChanged]; }
- (void)hideToggled:(UISwitch *)toggle { _gamepad.profile.hideWithController = toggle.on; [_gamepad profileChanged]; }
- (void)controllerChanged {
    if (_page == PageInput) [self showPage:PageInput];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; _gamepad.selectionChanged = nil; }
@end
