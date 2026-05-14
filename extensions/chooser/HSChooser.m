//
//  HSChooser.m
//  Hammerspoon
//
//  Created by Chris Jones on 29/12/2015.
//  Copyright © 2015 Hammerspoon. All rights reserved.
//

#import "HSChooser.h"
#import "HSChooserRootView.h"
#import "HSChooserVerticallyCenteringTextFieldCell.h"
#import "chooser.h"

#pragma mark - Chooser object implementation

@implementation HSChooser

#pragma mark - Object initialisation

- (id)initWithRefTable:(LSRefTable)refTable completionCallbackRef:(int)completionCallbackRef {
    // Build the window programmatically instead of loading from a nib.
    HSChooserWindow *panel = [self createChooserWindow];
    self = [super initWithWindow:panel];
    if (self) {
        self.refTable = refTable;
        self.selfRefCount = 0;

        self.eventMonitors = [[NSMutableArray alloc] init];

        // Set our defaults
        self.numRows = 10;
        self.width = 40;
        self.fontName = nil;
        self.fontSize = 0;
        self.searchSubText = NO;

        // We're setting these directly, because we've overridden the setters and we don't need to invoke those now
        _fgColor = nil;
        _subTextColor = nil;
        _isObservingThemeChanges = NO;

        self.currentStaticChoices = nil;
        self.currentCallbackChoices = nil;
        self.filteredChoices = nil;
        self.enableDefaultForQuery = NO;

        self.hideCallbackRef = LUA_NOREF;
        self.showCallbackRef = LUA_NOREF;
        self.choicesCallbackRef = LUA_NOREF;
        self.queryChangedCallbackRef = LUA_NOREF;
        self.rightClickCallbackRef = LUA_NOREF;
        self.invalidCallbackRef = LUA_NOREF;
        self.completionCallbackRef = completionCallbackRef;

        self.hasChosen = NO;
        self.reloadWhenVisible = NO;

        // Decide which font to use
        if (!self.fontName) {
            self.font = [NSFont systemFontOfSize:self.fontSize];
        } else {
            self.font = [NSFont fontWithName:self.fontName size:self.fontSize];
        }

        [self calculateRects];

        if (![self setupWindow]) {
            return nil;
        }

        // Start observing interface theme changes.
        self.isObservingThemeChanges = YES;
    }

    return self;
}

#pragma mark - Programmatic window construction

- (HSChooserWindow *)createChooserWindow {
    NSRect contentRect = NSMakeRect(574, 449, 509, 281);
    NSWindowStyleMask styleMask = NSWindowStyleMaskNonactivatingPanel | NSWindowStyleMaskFullSizeContentView;
    HSChooserWindow *panel = [[HSChooserWindow alloc] initWithContentRect:contentRect
                                                                styleMask:styleMask
                                                                  backing:NSBackingStoreBuffered
                                                                    defer:YES];
    panel.title = @"Chooser";
    panel.releasedWhenClosed = NO;
    panel.restorable = NO;
    panel.animationBehavior = NSWindowAnimationBehaviorDefault;
    panel.collectionBehavior = NSWindowCollectionBehaviorIgnoresCycle;
    [panel setAllowsToolTipsWhenApplicationIsInactive:NO];
    [panel setAutorecalculatesKeyViewLoop:NO];

    panel.delegate = self;

    // --- Root content view (HSChooserRootView) ---
    HSChooserRootView *rootView = [[HSChooserRootView alloc] initWithFrame:NSMakeRect(0, 0, 509, 281)];
    rootView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    panel.contentView = rootView;

    // --- Visual effect view (frosted glass) ---
    NSVisualEffectView *effectView = [[NSVisualEffectView alloc] initWithFrame:rootView.bounds];
    effectView.translatesAutoresizingMaskIntoConstraints = NO;
    effectView.wantsLayer = YES;
    effectView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    effectView.material = NSVisualEffectMaterialSidebar;
    effectView.state = NSVisualEffectStateFollowsWindowActiveState;
    [rootView addSubview:effectView];
    self.effectView = effectView;

    // Pin effectView to all edges of rootView
    [NSLayoutConstraint activateConstraints:@[
        [effectView.leadingAnchor constraintEqualToAnchor:rootView.leadingAnchor],
        [effectView.trailingAnchor constraintEqualToAnchor:rootView.trailingAnchor],
        [effectView.topAnchor constraintEqualToAnchor:rootView.topAnchor],
        [effectView.bottomAnchor constraintEqualToAnchor:rootView.bottomAnchor],
    ]];

    // --- Query text field (31pt system font, no border) ---
    NSTextField *queryField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    queryField.translatesAutoresizingMaskIntoConstraints = NO;
    queryField.wantsLayer = YES;
    queryField.font = [NSFont systemFontOfSize:31];
    queryField.textColor = [NSColor controlTextColor];
    queryField.backgroundColor = [NSColor textBackgroundColor];
    queryField.bordered = NO;
    queryField.bezeled = NO;
    queryField.drawsBackground = NO;
    queryField.editable = YES;
    queryField.selectable = YES;
    queryField.usesSingleLineMode = YES;
    queryField.cell.scrollable = YES;
    queryField.cell.lineBreakMode = NSLineBreakByClipping;
    [queryField setContentHuggingPriority:750 forOrientation:NSLayoutConstraintOrientationVertical];
    [effectView addSubview:queryField];
    self.queryField = queryField;

    // --- Separator line ---
    NSBox *separator = [[NSBox alloc] initWithFrame:NSZeroRect];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.boxType = NSBoxSeparator;
    [separator setContentHuggingPriority:750 forOrientation:NSLayoutConstraintOrientationVertical];
    [effectView addSubview:separator];

    // --- Scroll view + table view ---
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.borderType = NSNoBorder;
    scrollView.autohidesScrollers = YES;
    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = YES;
    scrollView.horizontalLineScroll = 42;
    scrollView.horizontalPageScroll = 10;
    scrollView.verticalLineScroll = 42;
    scrollView.verticalPageScroll = 10;
    scrollView.usesPredominantAxisScrolling = NO;
    scrollView.drawsBackground = NO;

    HSChooserTableView *tableView = [[HSChooserTableView alloc] initWithFrame:NSZeroRect];
    tableView.rowHeight = 40;
    tableView.usesAutomaticRowHeights = YES;
    tableView.allowsExpansionToolTips = YES;
    tableView.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    tableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleSourceList;
    tableView.allowsColumnReordering = NO;
    tableView.allowsColumnResizing = NO;
    tableView.allowsMultipleSelection = NO;
    tableView.allowsEmptySelection = NO;
    tableView.autosaveTableColumns = NO;
    tableView.allowsTypeSelect = NO;
    tableView.intercellSpacing = NSMakeSize(3, 2);
    tableView.backgroundColor = [NSColor colorWithSRGBRed:0.0 green:0.41176470588 blue:0.85098039216 alpha:0.0];
    tableView.gridColor = [NSColor colorWithWhite:0.8 alpha:0.0];
    [tableView setContentHuggingPriority:750 forOrientation:NSLayoutConstraintOrientationVertical];

    // Create the single table column
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"MainColumn"];
    column.editable = NO;
    column.width = 487;
    column.minWidth = 40;
    column.maxWidth = 99000;
    column.resizingMask = NSTableColumnAutoresizingMask;
    [tableView addTableColumn:column];

    // Ensure header is hidden (XIB had no visible header)
    tableView.headerView = nil;

    scrollView.documentView = tableView;
    [effectView addSubview:scrollView];
    self.choicesTableView = tableView;

    // --- Auto Layout constraints matching the XIB ---
    // queryField: top=20, leading=20, trailing=20 from effectView; height=43
    // separator: top=20 below queryField; leading=0, trailing=0 from effectView
    // scrollView: top=5 below separator; leading=5, trailing=5, bottom=5 from effectView
    [NSLayoutConstraint activateConstraints:@[
        // Query field
        [queryField.topAnchor constraintEqualToAnchor:effectView.topAnchor constant:20],
        [queryField.leadingAnchor constraintEqualToAnchor:effectView.leadingAnchor constant:20],
        [effectView.trailingAnchor constraintEqualToAnchor:queryField.trailingAnchor constant:20],
        [queryField.heightAnchor constraintEqualToConstant:43],

        // Separator
        [separator.topAnchor constraintEqualToAnchor:queryField.bottomAnchor constant:20],
        [separator.leadingAnchor constraintEqualToAnchor:effectView.leadingAnchor],
        [effectView.trailingAnchor constraintEqualToAnchor:separator.trailingAnchor],

        // Scroll view
        [scrollView.topAnchor constraintEqualToAnchor:separator.bottomAnchor constant:5],
        [scrollView.leadingAnchor constraintEqualToAnchor:effectView.leadingAnchor constant:5],
        [effectView.trailingAnchor constraintEqualToAnchor:scrollView.trailingAnchor constant:5],
        [effectView.bottomAnchor constraintEqualToAnchor:scrollView.bottomAnchor constant:5],
    ]];

    return panel;
}

#pragma mark - Window related methods

- (void)windowDidBecomeKey:(NSNotification *)notification {
    __weak id _self = self;
    __weak id _tableView = self.choicesTableView;
    __weak id _window = self.window;

    if (self.reloadWhenVisible) {
        [self.choicesTableView reloadData];
        self.reloadWhenVisible = NO;
    }

    [self addShortcut:@"1" keyCode:-1 mods:NSEventModifierFlagCommand handler:^{ [_self tableView:_tableView didClickedRow:0]; }];
    [self addShortcut:@"2" keyCode:-1 mods:NSEventModifierFlagCommand handler:^{ [_self tableView:_tableView didClickedRow:1]; }];
    [self addShortcut:@"3" keyCode:-1 mods:NSEventModifierFlagCommand handler:^{ [_self tableView:_tableView didClickedRow:2]; }];
    [self addShortcut:@"4" keyCode:-1 mods:NSEventModifierFlagCommand handler:^{ [_self tableView:_tableView didClickedRow:3]; }];
    [self addShortcut:@"5" keyCode:-1 mods:NSEventModifierFlagCommand handler:^{ [_self tableView:_tableView didClickedRow:4]; }];
    [self addShortcut:@"6" keyCode:-1 mods:NSEventModifierFlagCommand handler:^{ [_self tableView:_tableView didClickedRow:5]; }];
    [self addShortcut:@"7" keyCode:-1 mods:NSEventModifierFlagCommand handler:^{ [_self tableView:_tableView didClickedRow:6]; }];
    [self addShortcut:@"8" keyCode:-1 mods:NSEventModifierFlagCommand handler:^{ [_self tableView:_tableView didClickedRow:7]; }];
    [self addShortcut:@"9" keyCode:-1 mods:NSEventModifierFlagCommand handler:^{ [_self tableView:_tableView didClickedRow:8]; }];
    [self addShortcut:@"0" keyCode:-1 mods:NSEventModifierFlagCommand handler:^{ [_self tableView:_tableView didClickedRow:9]; }];

    [self addShortcut:@"Escape" keyCode:27 mods:0 handler:^{ [_window resignKeyWindow]; }];

    [self addShortcut:@"Up" keyCode:NSUpArrowFunctionKey mods:NSEventModifierFlagFunction|NSEventModifierFlagNumericPad handler:^{ [_self selectPreviousChoice]; }];
    [self addShortcut:@"Down" keyCode:NSDownArrowFunctionKey mods:NSEventModifierFlagFunction|NSEventModifierFlagNumericPad handler:^{ [_self selectNextChoice]; }];
    [self addShortcut:@"p" keyCode:-1 mods:NSEventModifierFlagControl handler:^{ [_self selectPreviousChoice]; }];
    [self addShortcut:@"n" keyCode:-1 mods:NSEventModifierFlagControl handler:^{ [_self selectNextChoice]; }];

    [self addShortcut:@"PageUp" keyCode:NSPageUpFunctionKey mods:NSEventModifierFlagFunction handler:^{ [_self selectPreviousPage]; }];
    [self addShortcut:@"PageDown" keyCode:NSPageDownFunctionKey mods:NSEventModifierFlagFunction handler:^{ [_self selectNextPage]; }];
    [self addShortcut:@"v" keyCode:-1 mods:NSEventModifierFlagControl handler:^{ [_self selectNextPage]; }];
}

- (void)windowDidResignKey:(NSNotification *)notification {
    for (id monitor in self.eventMonitors) {
        [NSEvent removeMonitor:monitor];
    }
    [self.eventMonitors removeAllObjects];

    if (!self.hasChosen) {
        [self cancel:nil];
    }
}

- (void)calculateRects {
    // Calculate the sizes of the various bits of our UI
    NSRect winRect, contentViewRect, textRect, listRect, dividerRect;

    winRect = NSMakeRect(0, 0, 100, 100);
    contentViewRect = NSInsetRect(winRect, 10, 10);

    NSDivideRect(contentViewRect, &textRect, &listRect, NSHeight([self.font boundingRectForFont]), NSMaxYEdge);
    NSDivideRect(listRect, &dividerRect, &listRect, 20.0, NSMaxYEdge);
    dividerRect.origin.y += NSHeight(dividerRect) / 2.0;
    dividerRect.size.height = 1.0;

    self.winRect = winRect;
    self.textRect = textRect;
    self.listRect = listRect;
    self.dividerRect = dividerRect;
}

- (BOOL)setupWindow {
    if (!self.window) {
        NSLog(@"ERROR: Unable to create hs.chooser window");
        return NO;
    }

    // Configure delegates and actions (previously set via NIB outlets)
    self.choicesTableView.delegate = self;
    self.choicesTableView.extendedDelegate = self;
    self.choicesTableView.dataSource = self;
    self.choicesTableView.target = self;

    self.queryField.delegate = self;
    self.queryField.target = self;
    self.queryField.action = @selector(queryDidPressEnter:);

    // Previously done in windowDidLoad
    [self.queryField setFocusRingType:NSFocusRingTypeNone];
    [self setAutoBgLightDark];

    return YES;
}

- (BOOL)control: (NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector {
    if (commandSelector == @selector(insertNewlineIgnoringFieldEditor:)) {
        // User hit cmd-enter
        [self queryDidPressEnter:self];
        return true;
    } else if (commandSelector == @selector(insertLineBreak:)) {
        // User hit option-enter
        [self queryDidPressEnter:self];
        return true;
    }

    return false;
}

- (void)resizeWindow {
    NSRect screenFrame = [[NSScreen mainScreen] visibleFrame];

    CGFloat rowHeight = [self.choicesTableView rowHeight];
    CGFloat intercellHeight =[self.choicesTableView intercellSpacing].height;
    CGFloat allRowsHeight = (rowHeight + intercellHeight) * self.numRows;

    CGFloat toolbarHeight = 0.0;
    if (self.window.toolbar && self.window.toolbar.visible) {
        NSRect windowFrame = [NSWindow contentRectForFrameRect:self.window.frame styleMask:self.window.styleMask];
        toolbarHeight = NSHeight(windowFrame) - NSHeight(self.window.contentView.frame);
    }

    CGFloat windowHeight = NSHeight([[self.window contentView] bounds]);
    CGFloat tableHeight = NSHeight([[self.choicesTableView superview] frame]);
    CGFloat finalHeight = (windowHeight - tableHeight) + allRowsHeight + toolbarHeight;

    CGFloat width;
    if (self.width >= 0 && self.width <= 100) {
        CGFloat percentWidth = self.width / 100.0;
        width = NSWidth(screenFrame) * percentWidth;
    } else {
        width = NSWidth(screenFrame) * 0.50;
        width = MIN(width, 800);
        width = MAX(width, 400);
    }

    NSRect winRect = NSMakeRect(0, 0, width, finalHeight);
    [self.window setFrame:winRect display:YES];
    [self.choicesTableView setFrameSize:NSMakeSize(winRect.size.width, self.choicesTableView.frame.size.height)];
}

- (void)showAtPoint:(NSPoint)topLeft {
    [self showWithHints:NO atPoint:topLeft];
}

- (void)show {
    [self showWithHints:YES atPoint:NSMakePoint(0,0)];
}

- (void)showWithHints:(BOOL)center atPoint:(NSPoint)topLeft {
    self.hasChosen = NO;

    // Call hs.chooser.globalCallback("willShow")
    LuaSkin *skin = [LuaSkin sharedWithState:NULL];
    lua_State *L = skin.L;
    _lua_stackguard_entry(L);
    [skin requireModule:"hs.chooser"] ;
    lua_getfield(L, -1, "globalCallback") ;
    lua_remove(L, -2) ;

    // Check the type of `globalCallback`
    if (lua_type(L, -1) == LUA_TNIL) {
        lua_remove(L, -1);
    } else if (lua_type(L, -1) != LUA_TFUNCTION) {
        [skin logError:[NSString stringWithFormat:@"hs.chooser.globalCallback is expected to be a function, but is a %s", lua_typename(L, lua_type(L, -1))]];
        // Remove whatever `globalCallback` is, from the stack
        lua_remove(L, -1);
    } else {
        [skin pushNSObject:self];
        lua_pushstring(L, "willOpen");
        [skin protectedCallAndError:@"hs.chooser.globalCallback willOpen" nargs:2 nresults:0];
    }

    [self resizeWindow];

    [self showWindow:self];
    self.window.isVisible = YES;

    if (center) {
        [self.window center];
    } else {
        [self.window setFrameTopLeftPoint:topLeft];
    }
    [self.window makeKeyAndOrderFront:self];
    [self.window makeFirstResponder:self.queryField];

    [self.window setLevel:(CGWindowLevelForKey(kCGMainMenuWindowLevelKey) + 3)];

    //if (!self.window.isKeyWindow) {
    //    NSApplication *app = [NSApplication sharedApplication];
    //    [app activateIgnoringOtherApps:YES];
    //}

    [self controlTextDidChange:[NSNotification notificationWithName:@"Unused" object:nil]];

    if (self.showCallbackRef != LUA_NOREF && self.showCallbackRef != LUA_REFNIL) {
        [skin pushLuaRef:self.refTable ref:self.showCallbackRef];
        [skin protectedCallAndError:@"hs.chooser:showCallback" nargs:0 nresults:0];
    }
    _lua_stackguard_exit(skin.L);
}

- (void)hide {
    self.window.isVisible = NO;

    // Call hs.chooser.globalCallback("didClose")
    LuaSkin *skin = [LuaSkin sharedWithState:NULL];
    lua_State *L = skin.L;
    _lua_stackguard_entry(L);
    [skin requireModule:"hs.chooser"] ;
    lua_getfield(L, -1, "globalCallback") ;
    lua_remove(L, -2) ;

    // Check the type of `globalCallback`
    if (lua_type(L, -1) == LUA_TNIL) {
        lua_remove(L, -1);
    } else if (lua_type(L, -1) != LUA_TFUNCTION) {
        [skin logError:[NSString stringWithFormat:@"hs.chooser.globalCallback is expected to be a function, but is a %s", lua_typename(L, lua_type(L, -1))]];
        // Remove whatever `globalCallback` is, from the stack
        lua_remove(L, -1);
    } else {
        [skin pushNSObject:self];
        lua_pushstring(L, "didClose");
        [skin protectedCallAndError:@"hs.chooser.globalCallback didClose" nargs:2 nresults:0];
    }

    // Call hs.chooser:hideCallback()
    if (self.hideCallbackRef != LUA_NOREF && self.hideCallbackRef != LUA_REFNIL) {
        [skin pushLuaRef:self.refTable ref:self.hideCallbackRef];
        [skin protectedCallAndError:@"hs.chooser:hideCallback" nargs:0 nresults:0];
    }
    _lua_stackguard_exit(L);
}

- (BOOL)isVisible {
    return self.window.isVisible;
}

#pragma mark - NSTableViewDataSource

- (NSInteger) numberOfRowsInTableView:(NSTableView *)tableView {
    NSInteger rowCount = 0;
    NSArray *choices = [self getChoices];

    if (choices) {
        rowCount = choices.count;
    }

    return rowCount;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSArray *choices = [self getChoices];
    NSDictionary *choice = [choices objectAtIndex:row];

    id text                = [choice objectForKey:@"text"];
    id subText             = [choice objectForKey:@"subText"];
    NSString *shortcutText = @"";
    NSImage  *image        = [choice objectForKey:@"image"];

    if (text && ![text isKindOfClass:[NSString class]] && ![text isKindOfClass:[NSAttributedString class]]) {
        text = [NSString stringWithFormat:@"%@", text];
    }
    if (subText && ![subText isKindOfClass:[NSString class]] && ![subText isKindOfClass:[NSAttributedString class]]) {
        subText = [NSString stringWithFormat:@"%@", subText];
    }
    if (image && ![image isKindOfClass:[NSImage class]]) image = nil;

    if (row >= 0 && row < 9) {
        shortcutText = [NSString stringWithFormat:@"⌘%ld", (long)row + 1];
    } else {
        shortcutText = @"";
    }

    NSString *chooserCellIdentifier = subText ? @"HSChooserCellSubtext" : @"HSChooserCell";
    HSChooserCell *cellView = [tableView makeViewWithIdentifier:chooserCellIdentifier owner:self];

    if (!cellView) {
        if (subText) {
            cellView = [self makeSubtextCellWithIdentifier:chooserCellIdentifier];
        } else {
            cellView = [self makePlainCellWithIdentifier:chooserCellIdentifier];
        }
    }

    if ([text isKindOfClass:[NSAttributedString class]]) {
        cellView.text.attributedStringValue = (NSAttributedString *)text;
    } else {
        cellView.text.stringValue = text ? (NSString *)text : @"";
    }

    if (subText) {
        if ([subText isKindOfClass:[NSAttributedString class]]) {
            [cellView.subText setAttributedStringValue:(NSAttributedString *)subText];
        } else {
            cellView.subText.stringValue = subText ? (NSString *)subText : @"";
        }
    }

    cellView.shortcutText.stringValue = shortcutText ? shortcutText : @"??";
    cellView.image.image = image ? image : [NSImage imageNamed:NSImageNameFollowLinkFreestandingTemplate];

    if (self.fgColor) {
        cellView.text.textColor = self.fgColor;
        cellView.shortcutText.textColor = self.fgColor;
    }

    if (self.subTextColor) {
        cellView.subText.textColor = self.subTextColor;
    }

    return cellView;
}

#pragma mark - Programmatic cell construction

// Create the "HSChooserCellSubtext" cell: icon (36px) | main text (15pt) + subtext (cellTitle font) | shortcut text (25pt)
- (HSChooserCell *)makeSubtextCellWithIdentifier:(NSString *)identifier {
    HSChooserCell *cell = [[HSChooserCell alloc] initWithFrame:NSMakeRect(0, 0, 496, 40)];
    cell.identifier = identifier;
    cell.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    // --- Image view (36px wide, pinned top+bottom+leading) ---
    NSImageView *imageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    imageView.translatesAutoresizingMaskIntoConstraints = NO;
    imageView.wantsLayer = YES;
    imageView.tag = 4;
    imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
    imageView.image = [NSImage imageNamed:NSImageNameActionTemplate];
    [cell addSubview:imageView];
    cell.image = imageView;
    cell.imageView = imageView;

    // --- Main text field (15pt system, secondaryLabelColor) ---
    NSTextField *textField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    textField.translatesAutoresizingMaskIntoConstraints = NO;
    textField.tag = 1;
    textField.bordered = NO;
    textField.bezeled = NO;
    textField.drawsBackground = NO;
    textField.editable = NO;
    textField.selectable = NO;
    textField.allowsExpansionToolTips = YES;
    textField.font = [NSFont systemFontOfSize:15];
    textField.textColor = [NSColor secondaryLabelColor];
    textField.lineBreakMode = NSLineBreakByTruncatingTail;
    textField.cell.sendsActionOnEndEditing = YES;
    [textField setContentHuggingPriority:750 forOrientation:NSLayoutConstraintOrientationVertical];
    [textField setContentCompressionResistancePriority:250 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [cell addSubview:textField];
    cell.text = textField;

    // --- Subtext field (cellTitle font, tertiaryLabelColor) ---
    NSTextField *subTextField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    subTextField.translatesAutoresizingMaskIntoConstraints = NO;
    subTextField.tag = -1;
    subTextField.bordered = NO;
    subTextField.bezeled = NO;
    subTextField.drawsBackground = NO;
    subTextField.editable = NO;
    subTextField.selectable = NO;
    subTextField.allowsExpansionToolTips = YES;
    subTextField.font = [NSFont fontWithName:[[NSFont systemFontOfSize:0] fontName] size:[NSFont smallSystemFontSize]];
    subTextField.textColor = [NSColor tertiaryLabelColor];
    subTextField.lineBreakMode = NSLineBreakByTruncatingMiddle;
    subTextField.cell.truncatesLastVisibleLine = YES;
    subTextField.cell.sendsActionOnEndEditing = YES;
    [subTextField setContentHuggingPriority:750 forOrientation:NSLayoutConstraintOrientationVertical];
    [subTextField setContentCompressionResistancePriority:250 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [cell addSubview:subTextField];
    cell.subText = subTextField;

    // --- Shortcut text field (25pt system, 40x40, vertically centering cell) ---
    NSTextField *shortcutField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    shortcutField.translatesAutoresizingMaskIntoConstraints = NO;
    shortcutField.tag = 2;
    shortcutField.bordered = NO;
    shortcutField.bezeled = NO;
    shortcutField.drawsBackground = NO;
    shortcutField.editable = NO;
    shortcutField.selectable = NO;
    shortcutField.allowsExpansionToolTips = YES;
    shortcutField.cell = [[HSChooserVerticallyCenteringTextFieldCell alloc] initTextCell:@"??"];
    shortcutField.font = [NSFont systemFontOfSize:25];
    shortcutField.textColor = [NSColor secondaryLabelColor];
    shortcutField.alignment = NSTextAlignmentLeft;
    [shortcutField setContentCompressionResistancePriority:1000 forOrientation:NSLayoutConstraintOrientationVertical];
    [shortcutField setContentHuggingPriority:750 forOrientation:NSLayoutConstraintOrientationVertical];
    [cell addSubview:shortcutField];
    cell.shortcutText = shortcutField;

    // --- Constraints matching XIB "HSChooserCellSubtext" ---
    [NSLayoutConstraint activateConstraints:@[
        // Image: width=36, leading=cell.leading, top=cell.top+2, bottom=cell.bottom
        [imageView.widthAnchor constraintEqualToConstant:36],
        [imageView.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor],
        [imageView.topAnchor constraintEqualToAnchor:cell.topAnchor constant:2],
        [cell.bottomAnchor constraintEqualToAnchor:imageView.bottomAnchor],

        // Main text: top=cell.top+5, leading=image.trailing+5
        [textField.topAnchor constraintEqualToAnchor:cell.topAnchor constant:5],
        [textField.leadingAnchor constraintEqualToAnchor:imageView.trailingAnchor constant:5],

        // Subtext: leading=image.trailing+5, bottom=cell.bottom-3
        [subTextField.leadingAnchor constraintEqualToAnchor:imageView.trailingAnchor constant:5],
        [cell.bottomAnchor constraintEqualToAnchor:subTextField.bottomAnchor constant:3],

        // Main text bottom = subtext top + 2
        [textField.bottomAnchor constraintEqualToAnchor:subTextField.topAnchor constant:2],

        // Shortcut: width=40, height=40, trailing=cell.trailing, centerY=image.centerY
        [shortcutField.widthAnchor constraintEqualToConstant:40],
        [shortcutField.heightAnchor constraintEqualToConstant:40],
        [cell.trailingAnchor constraintEqualToAnchor:shortcutField.trailingAnchor],
        [shortcutField.centerYAnchor constraintEqualToAnchor:imageView.centerYAnchor],

        // Shortcut leading = text.trailing+5 and subtext.trailing+5
        [shortcutField.leadingAnchor constraintEqualToAnchor:textField.trailingAnchor constant:5],
        [shortcutField.leadingAnchor constraintEqualToAnchor:subTextField.trailingAnchor constant:5],
    ]];

    return cell;
}

// Create the "HSChooserCell" cell: icon (36px) | main text (20pt, vertically centering) | shortcut text (25pt)
- (HSChooserCell *)makePlainCellWithIdentifier:(NSString *)identifier {
    HSChooserCell *cell = [[HSChooserCell alloc] initWithFrame:NSMakeRect(0, 0, 496, 40)];
    cell.identifier = identifier;
    cell.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    // --- Image view (36px wide) ---
    NSImageView *imageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    imageView.translatesAutoresizingMaskIntoConstraints = NO;
    imageView.wantsLayer = YES;
    imageView.tag = 4;
    imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
    imageView.image = [NSImage imageNamed:NSImageNameActionTemplate];
    [cell addSubview:imageView];
    cell.image = imageView;
    cell.imageView = imageView;

    // --- Main text field (20pt, vertically centering cell, secondaryLabelColor) ---
    NSTextField *textField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    textField.translatesAutoresizingMaskIntoConstraints = NO;
    textField.tag = 1;
    textField.bordered = NO;
    textField.bezeled = NO;
    textField.drawsBackground = NO;
    textField.editable = NO;
    textField.selectable = NO;
    textField.allowsExpansionToolTips = YES;
    textField.cell = [[HSChooserVerticallyCenteringTextFieldCell alloc] initTextCell:@""];
    textField.font = [NSFont systemFontOfSize:20];
    textField.textColor = [NSColor secondaryLabelColor];
    textField.lineBreakMode = NSLineBreakByTruncatingTail;
    textField.cell.sendsActionOnEndEditing = YES;
    [textField setContentHuggingPriority:750 forOrientation:NSLayoutConstraintOrientationVertical];
    [textField setContentCompressionResistancePriority:250 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [cell addSubview:textField];
    cell.text = textField;

    // --- Shortcut text field (25pt, 40x40, vertically centering cell) ---
    NSTextField *shortcutField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    shortcutField.translatesAutoresizingMaskIntoConstraints = NO;
    shortcutField.tag = 2;
    shortcutField.bordered = NO;
    shortcutField.bezeled = NO;
    shortcutField.drawsBackground = NO;
    shortcutField.editable = NO;
    shortcutField.selectable = NO;
    shortcutField.allowsExpansionToolTips = YES;
    shortcutField.cell = [[HSChooserVerticallyCenteringTextFieldCell alloc] initTextCell:@"??"];
    shortcutField.font = [NSFont systemFontOfSize:25];
    shortcutField.textColor = [NSColor secondaryLabelColor];
    shortcutField.alignment = NSTextAlignmentLeft;
    [shortcutField setContentHuggingPriority:750 forOrientation:NSLayoutConstraintOrientationVertical];
    [shortcutField setContentCompressionResistancePriority:1000 forOrientation:NSLayoutConstraintOrientationVertical];
    [cell addSubview:shortcutField];
    cell.shortcutText = shortcutField;

    // --- Constraints matching XIB "HSChooserCell" ---
    [NSLayoutConstraint activateConstraints:@[
        // Image: width=36, leading=cell.leading, top=cell.top+2, bottom=cell.bottom
        [imageView.widthAnchor constraintEqualToConstant:36],
        [imageView.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor],
        [imageView.topAnchor constraintEqualToAnchor:cell.topAnchor constant:2],
        [cell.bottomAnchor constraintEqualToAnchor:imageView.bottomAnchor],

        // Text: top=cell.top+5, bottom=cell.bottom-5, leading=image.trailing+5
        [textField.topAnchor constraintEqualToAnchor:cell.topAnchor constant:5],
        [cell.bottomAnchor constraintEqualToAnchor:textField.bottomAnchor constant:5],
        [textField.leadingAnchor constraintEqualToAnchor:imageView.trailingAnchor constant:5],

        // Shortcut: width=40, height=40, trailing=cell.trailing, centerY=image.centerY
        [shortcutField.widthAnchor constraintEqualToConstant:40],
        [shortcutField.heightAnchor constraintEqualToConstant:40],
        [cell.trailingAnchor constraintEqualToAnchor:shortcutField.trailingAnchor],
        [shortcutField.centerYAnchor constraintEqualToAnchor:imageView.centerYAnchor],

        // Shortcut leading = text.trailing+5
        [shortcutField.leadingAnchor constraintEqualToAnchor:textField.trailingAnchor constant:5],
    ]];

    return cell;
}

#pragma mark - HSTableViewDelegate

- (void)tableView:(NSTableView *)tableView didClickedRow:(NSInteger)row {
    //NSLog(@"didClickedRow: %li", (long)row);
    if (row >= 0 && row < [[self getChoices] count]) {
        self.hasChosen = YES;
        LuaSkin *skin = [LuaSkin sharedWithState:NULL];
        _lua_stackguard_entry(skin.L);
        NSDictionary *choice = [[self getChoices] objectAtIndex:row];

        if ([choice objectForKey:@"valid"] && ![[choice objectForKey:@"valid"] boolValue] && self.invalidCallbackRef != LUA_NOREF && self.invalidCallbackRef != LUA_REFNIL) {
            [skin pushLuaRef:self.refTable ref:self.invalidCallbackRef];
            [skin pushNSObject:choice];
            [skin protectedCallAndError:@"hs.chooser:invalidCallback" nargs:1 nresults:0];
        } else if (self.completionCallbackRef != LUA_NOREF && self.completionCallbackRef != LUA_REFNIL) {
            [self hide];
            [skin pushLuaRef:self.refTable ref:self.completionCallbackRef];
            [skin pushNSObject:choice];
            [skin protectedCallAndError:@"hs.chooser:completionCallback" nargs:1 nresults:0];
        }

        _lua_stackguard_exit(skin.L);
    } else if (self.enableDefaultForQuery != NO && self.completionCallbackRef != LUA_NOREF && self.completionCallbackRef != LUA_REFNIL) {
        // No row remaining in choices, return just query
        self.hasChosen = YES;
        LuaSkin *skin = [LuaSkin sharedWithState:NULL];
        _lua_stackguard_entry(skin.L);
        NSDictionary<NSString*, NSString*> *choice = @{@"text": self.queryField.stringValue};
        [self hide];
        [skin pushLuaRef:self.refTable ref:self.completionCallbackRef];
        [skin pushNSObject:choice];
        [skin protectedCallAndError:@"hs.chooser:completionCallback" nargs:1 nresults:0];

        _lua_stackguard_exit(skin.L);
    }
}

- (void)didRightClickAtRow:(NSInteger)row {
    if (self.rightClickCallbackRef != LUA_NOREF && self.rightClickCallbackRef != LUA_REFNIL) {
        // We have a right click callback set
        LuaSkin *skin = [LuaSkin sharedWithState:NULL];
        _lua_stackguard_entry(skin.L);
        [skin pushLuaRef:self.refTable ref:self.rightClickCallbackRef];
        lua_pushinteger(skin.L, row + 1);
        [skin protectedCallAndError:@"hs.chooser:rightClickCallback" nargs:1 nresults:0];
        _lua_stackguard_exit(skin.L);
    }
}

#pragma mark - UI callbacks

- (IBAction)cancel:(id)sender {
    //NSLog(@"HSChooser::cancel:");
    [self hide];
    LuaSkin *skin = [LuaSkin sharedWithState:NULL];
    _lua_stackguard_entry(skin.L);

    if (![skin checkRefs:self.refTable, self.completionCallbackRef, LS_RBREAK]) {
        [skin logWarn:@"Unable to call hs.chooser:completionCallback, reference is no longer valid"];
        _lua_stackguard_exit(skin.L);
        return;
    }

    [skin pushLuaRef:self.refTable ref:self.completionCallbackRef];
    lua_pushnil(skin.L);
    [skin protectedCallAndError:@"hs.chooser:completionCallback" nargs:1 nresults:0];
    _lua_stackguard_exit(skin.L);
}

- (IBAction)queryDidPressEnter:(id)sender {
    //NSLog(@"in queryDidPressEnter:");
    [self tableView:self.choicesTableView didClickedRow:self.choicesTableView.selectedRow];
}

- (void)controlTextDidChange:(NSNotification *)aNotification {
    //NSLog(@"controlTextDidChange: %@", self.queryField.stringValue);
    NSString *queryString = self.queryField.stringValue;

    if (self.queryChangedCallbackRef != LUA_NOREF && self.queryChangedCallbackRef != LUA_REFNIL) {
        // We have a query callback set, we are passing on responsibility for displaying/filtering results, to Lua
        LuaSkin *skin = [LuaSkin sharedWithState:NULL];
        _lua_stackguard_entry(skin.L);
        [skin pushLuaRef:self.refTable ref:self.queryChangedCallbackRef];
        [skin pushNSObject:queryString];
        [skin protectedCallAndError:@"hs.chooser:queryChangedCallback" nargs:1 nresults:0];
        _lua_stackguard_exit(skin.L);
    } else {
        // We do not have a query callback set, so we are doing the filtering
        if (queryString.length > 0) {
            NSMutableArray *filteredChoices = [[NSMutableArray alloc] init];

            for (NSDictionary *choice in [self getChoicesWithOptions:NO]) {
                NSString *text = [choice objectForKey:@"text"];
                if (text && ![text isKindOfClass:[NSString class]]) text = [NSString stringWithFormat:@"%@", text] ;
                if (!text) text = @"" ;
                if ([[text lowercaseString] containsString:[queryString lowercaseString]]) {
                    [filteredChoices addObject: choice];
                } else if (self.searchSubText) {
                    NSString *subText = [choice objectForKey:@"subText"];
                    if (subText && ![subText isKindOfClass:[NSString class]]) subText = [NSString stringWithFormat:@"%@", subText] ;
                    if (!subText) subText = @"" ;
                    if ([[subText lowercaseString] containsString:[queryString lowercaseString]]) {
                        [filteredChoices addObject:choice];
                    }
                }
            }

            self.filteredChoices = filteredChoices;
        } else {
            self.filteredChoices = nil;
        }
        [self.choicesTableView reloadData];
    }
}

- (void)selectChoice:(NSInteger)row {
    NSUInteger numRows = [[self getChoices] count];
    if (row < 0 || row > (numRows - 1)) {
        [LuaSkin logError:[NSString stringWithFormat:@"ERROR: unable to select row %li of %li", (long)row, (long)numRows]];
        return;
    }
    [self.choicesTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];

    // FIXME: This scrolling is awfully jumpy
    [self.choicesTableView scrollRowToVisible:row];
}

- (void)selectNextChoice {
    NSInteger currentRow = [self.choicesTableView selectedRow];
    if (currentRow == [[self getChoices] count] - 1) {
        currentRow = -1;
    }
    [self selectChoice:currentRow+1];
}

- (void)selectPreviousChoice {
    NSInteger currentRow = [self.choicesTableView selectedRow];
    if (currentRow == 0) {
        currentRow = [[self getChoices] count];
    }
    [self selectChoice:currentRow-1];
}

- (void)selectNextPage {
    NSInteger currentRow = [self.choicesTableView selectedRow];
	NSInteger count = [[self getChoices] count];
    if (currentRow == count-1) {
        [self selectChoice:0];
    } else if (currentRow >= count-10) {
        [self selectChoice:count-1];
    } else {
        [self selectChoice:currentRow+10];
    }
}

- (void)selectPreviousPage {
    NSInteger currentRow = [self.choicesTableView selectedRow];
    if (currentRow == 0) {
        [self selectChoice:[[self getChoices] count]-1];
    } else if (currentRow < 10) {
        [self selectChoice:0];
    } else {
        [self selectChoice:currentRow-10];
    }
}

#pragma mark - Choice management methods

- (void)updateChoices {
    if (self.window.visible) {
        [self.choicesTableView reloadData];
    } else {
        self.reloadWhenVisible = YES;
    }
}

- (void)clearChoices {
    self.currentStaticChoices = nil;
    self.currentCallbackChoices = nil;
    self.filteredChoices = nil;
}

- (void)clearChoicesAndUpdate {
    [self clearChoices];
    [self updateChoices];
}

- (NSArray *)getChoices {
    return [self getChoicesWithOptions:YES];
}

- (NSArray *)getChoicesWithOptions:(BOOL)includeFiltered {
    NSArray *choices = nil;

    if (includeFiltered && self.filteredChoices != nil) {
        // We have some previously filtered choices, so we will return that
        choices = self.filteredChoices;
    } else if (self.choicesCallbackRef == LUA_NOREF) {
        // No callback is set, we can only return the static choices, even if it's nil
        choices = self.currentStaticChoices;
    } else if (self.choicesCallbackRef != LUA_NOREF) {
        // We have a callback set
        if (self.currentCallbackChoices == nil) {
            // We have previously cached the callback choices
            LuaSkin *skin = [LuaSkin sharedWithState:NULL];
            _lua_stackguard_entry(skin.L);
            [skin pushLuaRef:self.refTable ref:self.choicesCallbackRef];
            if ([skin protectedCallAndTraceback:0 nresults:1]) {
                self.currentCallbackChoices = [skin toNSObjectAtIndex:-1];

                BOOL callbackChoicesTypeCheckPass = NO;
                if ([self.currentCallbackChoices isKindOfClass:[NSArray class]]) {
                    callbackChoicesTypeCheckPass = YES;
                    for (id arrayElement in self.currentCallbackChoices) {
                        if (![arrayElement isKindOfClass:[NSDictionary class]]) {
                            callbackChoicesTypeCheckPass = NO;
                            break;
                        }
                    }
                }
                if (!callbackChoicesTypeCheckPass) {
                    // Light verification of the callback choices shows the format is wrong, so let's ignore it
                    [LuaSkin logError:@"ERROR: data returned by hs.chooser:choices() callback could not be parsed correctly"];
                    self.currentCallbackChoices = nil;
                }
            } else {
                [skin logError:[NSString stringWithFormat:@"%s:choices error - %@", USERDATA_TAG, [skin toNSObjectAtIndex:-1]]] ;
                // No need to lua_pop() here, see below
            }
            lua_pop(skin.L, 1) ; // remove result or error message
            _lua_stackguard_exit(skin.L);
        }

        if (self.currentCallbackChoices != nil) {
            choices = self.currentCallbackChoices;
        }
    }

    //NSLog(@"HSChooser::getChoicesWithOptions: returning: %@", choices);
    return choices;
}

#pragma mark - UI customisation methods

- (void)setFgColor:(NSColor *)fgColor {
    _fgColor = fgColor;
    self.queryField.textColor = _fgColor;

    for (int x = 0; x < [self.choicesTableView numberOfRows]; x++) {
        NSTableCellView *cellView = [self.choicesTableView viewAtColumn:0 row:x makeIfNecessary:NO];
        NSTextField *text = [cellView viewWithTag:1];
        NSTextField *shortcutText = [cellView viewWithTag:2];
        text.textColor = _fgColor;
        shortcutText.textColor = _fgColor;
    }
}

- (void)setSubTextColor:(NSColor *)subTextColor {
    _subTextColor = subTextColor;

    for (int x = 0; x < [self.choicesTableView numberOfRows]; x++) {
        NSTableCellView *cellView = [self.choicesTableView viewAtColumn:0 row:x makeIfNecessary:NO];
        NSTextField *subText = [cellView viewWithTag:3];
        subText.textColor = _subTextColor;
    }
}

- (void)applyDarkSetting:(BOOL)beDark {
    NSAppearance *appearance = beDark ? [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark] : [NSAppearance appearanceNamed:NSAppearanceNameVibrantLight];
    self.window.appearance = appearance;
}

- (void)setAutoBgLightDark {
    NSString *interfaceStyle = [[NSUserDefaults standardUserDefaults] stringForKey:@"AppleInterfaceStyle"];
    BOOL isDark = (interfaceStyle && [[interfaceStyle lowercaseString] isEqualToString:@"dark"]);

    [self applyDarkSetting:isDark];
}

- (void)setBgLightDark:(NSNotification *)notification {
    if (notification.object == nil) {
        self.isObservingThemeChanges = YES;
        [self setAutoBgLightDark];
        return;
    }
    self.isObservingThemeChanges = NO;

    [self applyDarkSetting:((NSNumber *)notification.object).boolValue];
}

- (BOOL)isBgLightDark {
    return [self.window.appearance.name isEqualToString:NSAppearanceNameVibrantDark];
}

#pragma mark - Utility methods

- (void) addShortcut:(NSString*)key keyCode:(unsigned short)keyCode mods:(NSEventModifierFlags)mods handler:(dispatch_block_t)action {
    //NSLog(@"Adding shortcut for %lu %@:%i", mods, key, keyCode);
    id x = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^ NSEvent*(NSEvent* event) {
        NSEventModifierFlags flags = ([event modifierFlags] & NSEventModifierFlagDeviceIndependentFlagsMask);
        //NSLog(@"Got an event: %lu %@:%i", (unsigned long)flags, [event charactersIgnoringModifiers], [[event charactersIgnoringModifiers] characterAtIndex:0]);

        if (flags == mods) {
            @try {
                if ([[event charactersIgnoringModifiers] isEqualToString: key] || [[event charactersIgnoringModifiers] characterAtIndex:0] == keyCode) {
                    //NSLog(@"firing action");
                    action();
                    return nil;
                }
            } @catch (NSException *exception) {
                ;
            } @finally {
                ;
            }
        }
        return event;
    }];
    [self.eventMonitors addObject: x];
}

#pragma mark - Interface theme changes observer

-(void)setIsObservingThemeChanges:(BOOL)isObservingThemeChanges {
    if (_isObservingThemeChanges == isObservingThemeChanges) {
        return;
    }

    _isObservingThemeChanges = isObservingThemeChanges;
    if (isObservingThemeChanges) {
        // Activate the observer.
        [[NSDistributedNotificationCenter defaultCenter] addObserver:self selector:@selector(setBgLightDark:) name:@"AppleInterfaceThemeChangedNotification" object:nil];
    } else {
        // Deactivate the observer.
        [[NSDistributedNotificationCenter defaultCenter] removeObserver:self name:@"AppleInterfaceThemeChangedNotification" object:nil];
    }
}

@end
