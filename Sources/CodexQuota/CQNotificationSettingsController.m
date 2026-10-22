#import "CQNotificationSettingsController.h"
#import "CQTheme.h"

@interface CQSettingsDocumentView : NSView
@end
@implementation CQSettingsDocumentView
- (BOOL)isFlipped { return YES; }
@end

@interface CQSettingsActionButton : NSButton
@property(nonatomic, strong) NSTrackingArea *hoverArea;
@property(nonatomic) BOOL hovered;
@property(nonatomic) BOOL primary;
@end

@implementation CQSettingsActionButton
- (void)updateAppearance {
    self.wantsLayer = YES;
    self.bordered = NO;
    self.layer.cornerRadius = 6;
    NSColor *fill = self.enabled ? (self.primary ? CQTheme.accent : CQTheme.panel) : CQTheme.surface;
    if (self.enabled && self.hovered) fill = self.primary ? [fill blendedColorWithFraction:0.1 ofColor:NSColor.blackColor] : CQTheme.mantle;
    self.layer.backgroundColor = fill.CGColor;
    self.layer.borderWidth = self.primary ? 0 : 1;
    self.layer.borderColor = (self.enabled ? [CQTheme.overlay colorWithAlphaComponent:0.85] : CQTheme.surface).CGColor;
    self.attributedTitle = [[NSAttributedString alloc] initWithString:self.title ?: @""
        attributes:@{NSFontAttributeName: self.font ?: [NSFont systemFontOfSize:12], NSForegroundColorAttributeName: self.enabled ? (self.primary ? CQTheme.panel : CQTheme.text) : CQTheme.subtext}];
}
- (void)setPrimary:(BOOL)primary { _primary = primary; [self updateAppearance]; }
- (void)setTitle:(NSString *)title { [super setTitle:title]; [self updateAppearance]; }
- (void)setEnabled:(BOOL)enabled { [super setEnabled:enabled]; [self updateAppearance]; }
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.hoverArea) [self removeTrackingArea:self.hoverArea];
    self.hoverArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:self.hoverArea];
}
- (void)mouseEntered:(NSEvent *)event { (void)event; self.hovered = YES; [self updateAppearance]; }
- (void)mouseExited:(NSEvent *)event { (void)event; self.hovered = NO; [self updateAppearance]; }
- (void)mouseDown:(NSEvent *)event {
    self.layer.opacity = self.enabled ? 0.8 : 1;
    [super mouseDown:event];
    self.layer.opacity = 1;
    [self updateAppearance];
}
@end

@interface CQNotificationSettingsController () <NSTextFieldDelegate>
@property(nonatomic, strong, nullable) CQBarkNotificationService *service;
@property(nonatomic, strong) NSSwitch *enabledSwitch;
@property(nonatomic, strong) NSTextField *summaryLabel;
@property(nonatomic, strong) NSView *inputSurface;
@property(nonatomic, strong) NSSecureTextField *endpointField;
@property(nonatomic, strong) NSTextField *visibleEndpointField;
@property(nonatomic, strong) NSButton *revealButton;
@property(nonatomic, strong) NSButton *saveButton;
@property(nonatomic, strong) NSButton *testButton;
@property(nonatomic, strong) NSButton *clearButton;
@property(nonatomic, strong) NSStackView *feedbackRow;
@property(nonatomic, strong) NSImageView *feedbackIcon;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, copy) NSString *savedEndpoint;
@property(nonatomic) BOOL savedEnabled;
@property(nonatomic) BOOL revealed;
@property(nonatomic) BOOL testing;
@property(nonatomic) BOOL dirty;
@property(nonatomic) BOOL inputFocused;
@end

@implementation CQNotificationSettingsController

- (instancetype)initWithBarkService:(CQBarkNotificationService *)service {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    _service = service;
    _savedEndpoint = @"";
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowDidResignKey:) name:NSWindowDidResignKeyNotification object:nil];
    __weak typeof(self) weakSelf = self;
    _service.statusDidChange = ^{
        typeof(self) self = weakSelf;
        if (self.isViewLoaded && !self.testing && !self.dirty) [self showStatus:self.service.deliveryStatus failed:self.service.deliveryFailed];
    };
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    if (self.revealed) [self toggleVisibility:nil];
}

- (void)windowDidResignKey:(NSNotification *)notification {
    if (self.isViewLoaded && notification.object == self.view.window && self.revealed) [self toggleVisibility:nil];
}

- (NSStackView *)horizontalStack {
    NSStackView *stack = [NSStackView new];
    stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stack.alignment = NSLayoutAttributeCenterY;
    stack.spacing = 8;
    return stack;
}

- (NSView *)spacer {
    NSView *view = [NSView new];
    [view setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    return view;
}

- (NSTextField *)paragraph:(NSString *)text {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = [NSFont systemFontOfSize:12];
    label.textColor = CQTheme.subtext;
    label.selectable = NO;
    [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return label;
}

- (void)configureEndpointField:(NSTextField *)field {
    field.font = [NSFont systemFontOfSize:12.5];
    field.textColor = CQTheme.text;
    field.bordered = NO;
    field.bezeled = NO;
    field.drawsBackground = NO;
    field.focusRingType = NSFocusRingTypeNone;
    field.usesSingleLineMode = YES;
    field.lineBreakMode = NSLineBreakByClipping;
    field.cell.scrollable = YES;
    field.delegate = self;
    field.target = self;
    field.action = @selector(save:);
    field.accessibilityLabel = @"Bark 推送链接";
    field.placeholderAttributedString = [[NSAttributedString alloc] initWithString:@"https://api.day.app/设备key"
        attributes:@{NSForegroundColorAttributeName: CQTheme.subtext, NSFontAttributeName: field.font}];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    [self.inputSurface addSubview:field];
    [NSLayoutConstraint activateConstraints:@[
        [field.leadingAnchor constraintEqualToAnchor:self.inputSurface.leadingAnchor constant:10],
        [field.trailingAnchor constraintEqualToAnchor:self.revealButton.leadingAnchor constant:-4],
        [field.centerYAnchor constraintEqualToAnchor:self.inputSurface.centerYAnchor], [field.heightAnchor constraintEqualToConstant:22]
    ]];
}

- (void)loadView {
    NSView *root = CQPanelBackground();
    root.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    self.view = root;
    self.preferredContentSize = NSMakeSize(360, 340);

    NSStackView *header = [self horizontalStack];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    NSButton *back = CQQuietButton(@"", @"chevron.left", self, @selector(back:));
    back.imagePosition = NSImageOnly;
    back.image = [[NSImage imageWithSystemSymbolName:@"chevron.left" accessibilityDescription:nil]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightMedium]];
    back.accessibilityLabel = @"返回额度面板";
    back.toolTip = nil;
    [back.widthAnchor constraintEqualToConstant:28].active = YES;
    [back.heightAnchor constraintEqualToConstant:28].active = YES;
    [header addArrangedSubview:back];
    [header addArrangedSubview:CQLabel(@"通知设置", [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold], CQTheme.text)];
    [header addArrangedSubview:[self spacer]];
    [root addSubview:header];

    NSScrollView *scroll = [NSScrollView new];
    scroll.drawsBackground = NO;
    scroll.borderType = NSNoBorder;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:scroll];
    NSView *document = [CQSettingsDocumentView new];
    document.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = document;
    NSStackView *content = [NSStackView new];
    content.orientation = NSUserInterfaceLayoutOrientationVertical;
    content.alignment = NSLayoutAttributeLeading;
    content.spacing = 12;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [document addSubview:content];

    NSStackView *channelRow = [self horizontalStack];
    NSStackView *channelText = [NSStackView new];
    channelText.orientation = NSUserInterfaceLayoutOrientationVertical;
    channelText.alignment = NSLayoutAttributeLeading;
    channelText.spacing = 4;
    [channelText addArrangedSubview:CQLabel(@"Bark 推送", [NSFont systemFontOfSize:13 weight:NSFontWeightMedium], CQTheme.text)];
    self.summaryLabel = CQLabel(@"待审批 · 任务完成", [NSFont systemFontOfSize:12], CQTheme.subtext);
    [channelText addArrangedSubview:self.summaryLabel];
    [channelRow addArrangedSubview:channelText];
    [channelRow addArrangedSubview:[self spacer]];
    self.enabledSwitch = [NSSwitch new];
    self.enabledSwitch.target = self;
    self.enabledSwitch.action = @selector(configurationChanged:);
    self.enabledSwitch.accessibilityLabel = @"启用 Bark 推送，保存后生效";
    [channelRow addArrangedSubview:self.enabledSwitch];
    [content addArrangedSubview:channelRow];

    NSStackView *addressSection = [NSStackView new];
    addressSection.orientation = NSUserInterfaceLayoutOrientationVertical;
    addressSection.alignment = NSLayoutAttributeLeading;
    addressSection.spacing = 8;
    NSStackView *addressHeading = [self horizontalStack];
    [addressHeading.heightAnchor constraintEqualToConstant:24].active = YES;
    [addressHeading addArrangedSubview:CQLabel(@"推送地址", [NSFont systemFontOfSize:12 weight:NSFontWeightMedium], CQTheme.text)];
    [addressHeading addArrangedSubview:[self spacer]];
    self.clearButton = CQQuietButton(@"移除链接", @"", self, @selector(clear:));
    self.clearButton.image = nil;
    self.clearButton.imagePosition = NSNoImage;
    self.clearButton.font = [NSFont systemFontOfSize:12];
    self.clearButton.accessibilityLabel = @"移除已保存的 Bark 链接并关闭推送";
    [self.clearButton.heightAnchor constraintEqualToConstant:24].active = YES;
    [addressHeading addArrangedSubview:self.clearButton];
    [addressSection addArrangedSubview:addressHeading];

    self.inputSurface = [NSView new];
    self.inputSurface.wantsLayer = YES;
    self.inputSurface.layer.backgroundColor = CQTheme.panel.CGColor;
    self.inputSurface.layer.borderColor = [CQTheme.overlay colorWithAlphaComponent:0.85].CGColor;
    self.inputSurface.layer.borderWidth = 1;
    self.inputSurface.layer.cornerRadius = 7;
    [self.inputSurface.heightAnchor constraintEqualToConstant:36].active = YES;
    self.revealButton = CQQuietButton(@"", @"eye", self, @selector(toggleVisibility:));
    self.revealButton.imagePosition = NSImageOnly;
    self.revealButton.accessibilityLabel = @"显示推送链接";
    self.revealButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.inputSurface addSubview:self.revealButton];
    [NSLayoutConstraint activateConstraints:@[
        [self.revealButton.trailingAnchor constraintEqualToAnchor:self.inputSurface.trailingAnchor constant:-4],
        [self.revealButton.centerYAnchor constraintEqualToAnchor:self.inputSurface.centerYAnchor],
        [self.revealButton.widthAnchor constraintEqualToConstant:28], [self.revealButton.heightAnchor constraintEqualToConstant:28]
    ]];
    self.endpointField = [NSSecureTextField new];
    self.visibleEndpointField = [NSTextField new];
    [self configureEndpointField:self.endpointField];
    [self configureEndpointField:self.visibleEndpointField];
    self.visibleEndpointField.hidden = YES;
    [addressSection addArrangedSubview:self.inputSurface];
    for (NSView *view in addressSection.arrangedSubviews) [view.widthAnchor constraintEqualToAnchor:addressSection.widthAnchor].active = YES;
    [content addArrangedSubview:addressSection];

    self.feedbackRow = [self horizontalStack];
    self.feedbackRow.alignment = NSLayoutAttributeTop;
    [self.feedbackRow.heightAnchor constraintGreaterThanOrEqualToConstant:28].active = YES;
    self.feedbackIcon = [NSImageView new];
    [self.feedbackIcon.widthAnchor constraintEqualToConstant:16].active = YES;
    [self.feedbackIcon.heightAnchor constraintEqualToConstant:16].active = YES;
    [self.feedbackRow addArrangedSubview:self.feedbackIcon];
    self.statusLabel = [self paragraph:@""];
    [self.statusLabel setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.feedbackRow addArrangedSubview:self.statusLabel];
    [content addArrangedSubview:self.feedbackRow];
    [content addArrangedSubview:[self paragraph:@"链接存入钥匙串，仅发送任务标题和项目名。"]];
    for (NSView *view in content.arrangedSubviews) [view.widthAnchor constraintEqualToAnchor:content.widthAnchor].active = YES;

    NSView *footer = CQFooterSurface();
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:footer];
    NSStackView *actions = [self horizontalStack];
    actions.translatesAutoresizingMaskIntoConstraints = NO;
    self.testButton = [CQSettingsActionButton buttonWithTitle:@"测试推送" target:self action:@selector(test:)];
    self.testButton.bezelStyle = NSBezelStyleRounded;
    self.testButton.font = [NSFont systemFontOfSize:12];
    self.testButton.controlSize = NSControlSizeRegular;
    [self.testButton.widthAnchor constraintEqualToConstant:92].active = YES;
    [self.testButton.heightAnchor constraintEqualToConstant:30].active = YES;
    [actions addArrangedSubview:self.testButton];
    [actions addArrangedSubview:[self spacer]];
    self.saveButton = [CQSettingsActionButton buttonWithTitle:@"保存" target:self action:@selector(save:)];
    ((CQSettingsActionButton *)self.saveButton).primary = YES;
    self.saveButton.bezelStyle = NSBezelStyleRounded;
    self.saveButton.bezelColor = CQTheme.accent;
    self.saveButton.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    self.saveButton.controlSize = NSControlSizeRegular;
    [self.saveButton.widthAnchor constraintEqualToConstant:104].active = YES;
    [self.saveButton.heightAnchor constraintEqualToConstant:30].active = YES;
    [actions addArrangedSubview:self.saveButton];
    [footer addSubview:actions];
    [NSLayoutConstraint activateConstraints:@[
        [header.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:14], [header.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-20],
        [header.topAnchor constraintEqualToAnchor:root.topAnchor constant:14], [header.heightAnchor constraintEqualToConstant:28],
        [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor], [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:10], [scroll.bottomAnchor constraintEqualToAnchor:footer.topAnchor],
        [document.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor], [document.trailingAnchor constraintEqualToAnchor:scroll.contentView.trailingAnchor],
        [document.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor], [document.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
        [content.leadingAnchor constraintEqualToAnchor:document.leadingAnchor constant:20], [content.trailingAnchor constraintEqualToAnchor:document.trailingAnchor constant:-20],
        [content.topAnchor constraintEqualToAnchor:document.topAnchor constant:8], [content.bottomAnchor constraintEqualToAnchor:document.bottomAnchor constant:-20],
        [footer.leadingAnchor constraintEqualToAnchor:root.leadingAnchor], [footer.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [footer.bottomAnchor constraintEqualToAnchor:root.bottomAnchor], [footer.heightAnchor constraintEqualToConstant:60],
        [actions.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:20], [actions.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-20],
        [actions.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor]
    ]];
    NSError *error = nil;
    self.savedEndpoint = [self.service savedEndpointWithError:&error] ?: @"";
    self.savedEnabled = self.service.enabled;
    self.endpointField.stringValue = self.savedEndpoint;
    self.visibleEndpointField.stringValue = self.savedEndpoint;
    self.enabledSwitch.state = self.savedEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [self updateControls];
    if (error) [self showStatus:error.localizedDescription failed:YES];
    else if (self.service.deliveryStatus.length > 0) [self showStatus:self.service.deliveryStatus failed:self.service.deliveryFailed];
    else [self showStatus:self.savedEndpoint.length > 0 ? (self.savedEnabled ? @"Bark 同步已开启" : @"Bark 同步已暂停") : @"从 Bark App 复制推送链接。" failed:NO];
}

- (NSTextField *)activeEndpointField {
    return self.revealed ? self.visibleEndpointField : self.endpointField;
}

- (void)updateControls {
    BOOL configured = self.savedEndpoint.length > 0;
    BOOL hasDraft = [self.activeEndpointField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0;
    self.testButton.enabled = self.service && !self.testing && hasDraft;
    self.testButton.title = self.testing ? @"发送中…" : @"测试推送";
    self.saveButton.title = configured ? @"保存" : @"保存并启用";
    self.saveButton.enabled = self.service && !self.testing && self.dirty && hasDraft;
    self.clearButton.hidden = !configured;
    self.clearButton.enabled = !self.testing;
    self.endpointField.enabled = !self.testing;
    self.visibleEndpointField.enabled = !self.testing;
    self.revealButton.enabled = !self.testing && hasDraft;
    self.enabledSwitch.enabled = !self.testing && configured;
    self.summaryLabel.stringValue = configured ? @"待审批 · 任务完成" : @"保存地址后开启同步";
}

- (void)showStatus:(NSString *)status failed:(BOOL)failed {
    self.statusLabel.stringValue = status ?: @"";
    self.statusLabel.textColor = failed ? CQTheme.red : CQTheme.subtext;
    BOOL hint = status.length == 0 || [status isEqualToString:@"从 Bark App 复制推送链接。"];
    self.feedbackIcon.hidden = hint;
    self.feedbackIcon.image = [NSImage imageWithSystemSymbolName:failed ? @"exclamationmark.circle" : @"info.circle" accessibilityDescription:nil];
    self.feedbackIcon.contentTintColor = self.statusLabel.textColor;
    self.inputSurface.layer.borderColor = (failed ? CQTheme.red : (self.inputFocused ? CQTheme.accent : [CQTheme.overlay colorWithAlphaComponent:0.85])).CGColor;
    if (self.view.window.visible) {
        [self.statusLabel scrollRectToVisible:self.statusLabel.bounds];
        NSAccessibilityPostNotification(self.statusLabel, NSAccessibilityValueChangedNotification);
    }
}

- (void)controlTextDidBeginEditing:(NSNotification *)notification {
    (void)notification;
    self.inputFocused = YES;
    self.inputSurface.layer.borderColor = CQTheme.accent.CGColor;
    self.inputSurface.layer.borderWidth = 2;
}

- (void)controlTextDidEndEditing:(NSNotification *)notification {
    (void)notification;
    self.inputFocused = NO;
    self.inputSurface.layer.borderColor = [CQTheme.overlay colorWithAlphaComponent:0.85].CGColor;
    self.inputSurface.layer.borderWidth = 1;
}

- (void)controlTextDidChange:(NSNotification *)notification {
    (void)notification;
    [self configurationChanged:nil];
}

- (void)configurationChanged:(id)sender {
    (void)sender;
    self.dirty = ![self.activeEndpointField.stringValue isEqualToString:self.savedEndpoint]
        || (self.savedEndpoint.length > 0 && (self.enabledSwitch.state == NSControlStateValueOn) != self.savedEnabled);
    [self updateControls];
    [self showStatus:self.dirty ? @"更改尚未保存" : @"" failed:NO];
}

- (void)toggleVisibility:(id)sender {
    (void)sender;
    NSTextField *previous = self.activeEndpointField;
    NSTextView *editor = (NSTextView *)previous.currentEditor;
    NSRange selection = editor ? editor.selectedRange : NSMakeRange(previous.stringValue.length, 0);
    NSString *draft = previous.stringValue;
    self.revealed = !self.revealed;
    self.endpointField.stringValue = draft;
    self.visibleEndpointField.stringValue = draft;
    self.endpointField.hidden = self.revealed;
    self.visibleEndpointField.hidden = !self.revealed;
    self.revealButton.image = [NSImage imageWithSystemSymbolName:self.revealed ? @"eye.slash" : @"eye" accessibilityDescription:nil];
    self.revealButton.accessibilityLabel = self.revealed ? @"隐藏推送链接" : @"显示推送链接";
    [self.view.window makeFirstResponder:self.activeEndpointField];
    NSTextView *nextEditor = (NSTextView *)self.activeEndpointField.currentEditor;
    if (NSMaxRange(selection) <= draft.length) nextEditor.selectedRange = selection;
}

- (void)save:(id)sender {
    (void)sender;
    if (self.testing || !self.dirty) return;
    NSError *error = nil;
    BOOL enabled = self.savedEndpoint.length == 0 || self.enabledSwitch.state == NSControlStateValueOn;
    if (![self.service saveEndpoint:self.activeEndpointField.stringValue enabled:enabled error:&error]) {
        [self showStatus:error.localizedDescription failed:YES];
        [self.view.window makeFirstResponder:self.activeEndpointField];
        return;
    }
    self.savedEndpoint = [self.service savedEndpointWithError:nil] ?: self.activeEndpointField.stringValue;
    self.savedEnabled = self.service.enabled;
    self.endpointField.stringValue = self.savedEndpoint;
    self.visibleEndpointField.stringValue = self.savedEndpoint;
    self.enabledSwitch.state = self.savedEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.dirty = NO;
    [self updateControls];
    [self showStatus:enabled ? @"已保存，Bark 同步已开启" : @"已保存，Bark 同步已暂停" failed:NO];
}

- (void)test:(id)sender {
    (void)sender;
    if (self.testing) return;
    self.testing = YES;
    [self updateControls];
    [self showStatus:@"正在发送测试通知…" failed:NO];
    __weak typeof(self) weakSelf = self;
    [self.service sendTestToEndpoint:self.activeEndpointField.stringValue completion:^(NSError *error) {
        typeof(self) self = weakSelf;
        if (!self) return;
        self.testing = NO;
        [self updateControls];
        [self showStatus:error.localizedDescription ?: (self.dirty ? @"测试已发送，请查看 iPhone。保存后开始同步。" : @"测试已发送，请查看 iPhone。") failed:error != nil];
    }];
}

- (void)clear:(id)sender {
    (void)sender;
    NSError *error = nil;
    if (![self.service clearConfigurationWithError:&error]) { [self showStatus:error.localizedDescription failed:YES]; return; }
    self.savedEndpoint = @"";
    self.savedEnabled = NO;
    self.endpointField.stringValue = @"";
    self.visibleEndpointField.stringValue = @"";
    self.enabledSwitch.state = NSControlStateValueOff;
    self.dirty = NO;
    if (self.revealed) [self toggleVisibility:nil];
    [self updateControls];
    [self showStatus:@"已移除链接并关闭推送" failed:NO];
}

- (void)back:(id)sender {
    (void)sender;
    if (self.revealed) [self toggleVisibility:nil];
    if (self.backHandler) self.backHandler();
}

@end
