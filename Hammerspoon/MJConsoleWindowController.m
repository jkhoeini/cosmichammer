#import "MJConsoleWindowController.h"
#import "MJLua.h"
#import "variables.h"

//
// Enable & Disable Console Dark Mode:
//
BOOL ConsoleDarkModeEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:HSConsoleDarkModeKey];
}

void ConsoleDarkModeSetEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled
                                            forKey:HSConsoleDarkModeKey];
}

@interface MJConsoleWindowController ()

@property NSMutableArray* history;
@property NSUInteger historyIndex;
@property NSTextView* outputView;
@property NSTextField* inputField;
@property NSMutableArray* preshownStdouts;
@property NSDateFormatter *dateFormatter;
@property NSMutableArray *outputBuffer;
@property NSTimer *outputTimer;

@end

typedef NS_ENUM(NSUInteger, MJReplLineType) {
    MJReplLineTypeCommand,
    MJReplLineTypeResult,
    MJReplLineTypeStdout,
};

@implementation MJConsoleWindowController

- (id) init {
    self = [super init];
    if (self) {
        self.dateFormatter = [[NSDateFormatter alloc] init];
        NSLocale *enUSPOSIXLocale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        [self.dateFormatter setLocale:enUSPOSIXLocale];
        [self.dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];

        self.outputBuffer = [[NSMutableArray alloc] initWithCapacity:1000];

        // Strings that we want to add to the console window are batched up in self.outputBuffer and this timer drains them
        self.outputTimer = [NSTimer timerWithTimeInterval:0.2 repeats:YES block:^(NSTimer * _Nonnull __unused timer) {
            if (self.outputBuffer.count > 0) {
                @autoreleasepool {
                    NSTextStorage *storage = self.outputView.textStorage;
                    [storage beginEditing];

                    for (NSAttributedString *attrstr in self.outputBuffer) {
                        NSUInteger curLength = storage.length;
                        NSUInteger maxLength = (NSUInteger)self.maxConsoleOutputHistory.integerValue;
                        NSUInteger addLength = attrstr.length;

                        [storage appendAttributedString:attrstr];
                        if (curLength > maxLength && maxLength > 0) {
                            [storage deleteCharactersInRange:NSMakeRange(0, curLength - maxLength + addLength)];
                        }
                    }

                    [self.outputBuffer removeAllObjects];
                    [storage endEditing];
                    [self.outputView scrollToEndOfDocument:self];
                }
            }
        }];
        [[NSRunLoop mainRunLoop] addTimer:self.outputTimer forMode:NSRunLoopCommonModes];

        [self initializeConsoleColorsAndFont] ;

        // NSWindowController -init calls -initWithWindow:nil which marks
        // isWindowLoaded=YES, preventing loadWindow from ever running.
        // Force it to run here.
        [self loadWindow];

        // Post-load setup (windowDidLoad equivalent)
        [self setShouldCascadeWindows:NO];
        self.history = [NSMutableArray array];
        [self appendString:@""
         "Welcome to the Hammerspoon Console!\n"
         "You can run any Lua code in here.\n\n"
                      type:MJReplLineTypeStdout];
    }
    return self;
}

#pragma mark - Programmatic window construction

- (void)loadWindow {
    // --- Window ---
    NSWindowStyleMask styleMask = NSWindowStyleMaskTitled
                                | NSWindowStyleMaskClosable
                                | NSWindowStyleMaskMiniaturizable
                                | NSWindowStyleMaskResizable;
    NSRect contentRect = NSMakeRect(916, 704, 510, 389);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:contentRect
                                                   styleMask:styleMask
                                                     backing:NSBackingStoreBuffered
                                                       defer:YES];
    window.title = @"Hammerspoon Console";
    window.releasedWhenClosed = NO;
    window.minSize = NSMakeSize(340, 200);
    window.frameAutosaveName = @"console";
    window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    window.animationBehavior = NSWindowAnimationBehaviorDefault;
    window.autorecalculatesKeyViewLoop = NO;
    window.allowsToolTipsWhenApplicationIsInactive = NO;

    NSView *contentView = window.contentView;

    // --- ScrollView + TextView (output) ---
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = NO;
    scrollView.horizontalScrollElasticity = NSScrollElasticityNone;
    scrollView.drawsBackground = YES;
    scrollView.contentView.drawsBackground = NO;

    NSTextView *textView = [[NSTextView alloc] initWithFrame:NSZeroRect];
    textView.editable = NO;
    textView.selectable = YES;
    textView.richText = NO;
    textView.importsGraphics = NO;
    textView.verticallyResizable = YES;
    textView.horizontallyResizable = NO;
    textView.usesFindBar = YES;
    textView.allowsCharacterPickerTouchBarItem = NO;
    textView.automaticTextCompletionEnabled = NO;
    textView.textColor = [NSColor textColor];
    textView.backgroundColor = [NSColor textBackgroundColor];

    // Let the text view track the scroll view's clip width but grow vertically
    textView.textContainer.containerSize = NSMakeSize(0, CGFLOAT_MAX);
    textView.textContainer.widthTracksTextView = YES;
    textView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    scrollView.documentView = textView;
    [contentView addSubview:scrollView];
    self.outputView = textView;

    // --- Input field ---
    HSGrowingTextField *inputField = [[HSGrowingTextField alloc] initWithFrame:NSZeroRect];
    inputField.translatesAutoresizingMaskIntoConstraints = NO;
    inputField.font = [NSFont fontWithName:@"Menlo-Regular" size:12.0];
    inputField.textColor = [NSColor controlTextColor];
    inputField.backgroundColor = [NSColor textBackgroundColor];
    inputField.drawsBackground = YES;
    inputField.bordered = YES;
    inputField.bezeled = YES;
    inputField.bezelStyle = NSTextFieldSquareBezel;
    inputField.editable = YES;
    inputField.selectable = YES;
    inputField.focusRingType = NSFocusRingTypeNone;
    [inputField setContentCompressionResistancePriority:250 forOrientation:NSLayoutConstraintOrientationHorizontal];
    inputField.target = self;
    inputField.action = @selector(tryMessage:);
    inputField.delegate = self;
    [contentView addSubview:inputField];
    self.inputField = inputField;

    // --- Auto Layout constraints (matching XIB: 20pt margins, 8pt gap) ---
    [NSLayoutConstraint activateConstraints:@[
        // Scroll view edges
        [scrollView.topAnchor constraintEqualToAnchor:contentView.topAnchor constant:20],
        [scrollView.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:20],
        [scrollView.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-20],

        // Input field edges
        [inputField.leadingAnchor constraintEqualToAnchor:scrollView.leadingAnchor],
        [inputField.trailingAnchor constraintEqualToAnchor:scrollView.trailingAnchor],
        [inputField.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor constant:-20],

        // 8pt gap between scroll view bottom and input field top
        [inputField.topAnchor constraintEqualToAnchor:scrollView.bottomAnchor constant:8],
    ]];

    window.initialFirstResponder = inputField;
    [self setWindow:window];
}

- (void)initializeConsoleColorsAndFont {
    self.MJColorForStdout  = [NSColor colorWithCalibratedHue:0.88 saturation:1.0 brightness:0.6 alpha:1.0] ;
    self.MJColorForCommand = [NSColor blackColor] ;
    self.MJColorForResult  = [NSColor colorWithCalibratedHue:0.54 saturation:1.0 brightness:0.7 alpha:1.0] ;
    self.consoleFont       = [NSFont fontWithName:@"Menlo" size:12.0] ;
    self.maxConsoleOutputHistory = [NSNumber numberWithInt:100000];
}

+ (instancetype) singleton {
    static MJConsoleWindowController* s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [[MJConsoleWindowController alloc] init];
    });
    return s;
}

- (void) setup {
    self.preshownStdouts = [NSMutableArray array];
    MJLuaSetupLogHandler(^(NSString* str){
        if (self.outputView) {
            [self appendString:str type:MJReplLineTypeStdout];
            [self.outputView scrollToEndOfDocument:self];
        }
        else {
            [self.preshownStdouts addObject:str];
        }
    });
    [self reflectDefaults];
}

- (void) reflectDefaults {
    
    //
    // Dark Mode:
    //        
    if (ConsoleDarkModeEnabled()) {
        self.window.appearance = [NSAppearance appearanceNamed: NSAppearanceNameVibrantDark] ;
        self.window.titlebarAppearsTransparent = YES ;
        self.outputView.enclosingScrollView.drawsBackground = NO ;
    } else {
        self.window.appearance = [NSAppearance appearanceNamed: NSAppearanceNameVibrantLight] ;
        self.window.titlebarAppearsTransparent = NO ;
        self.outputView.enclosingScrollView.drawsBackground = YES ;
    }

    [[self window] setLevel: MJConsoleWindowAlwaysOnTop() ? NSFloatingWindowLevel : NSNormalWindowLevel];
}


- (void) appendString:(NSString*)str type:(MJReplLineType)type {
    NSColor* color = self.MJColorForStdout;

    if (!str) {
        return;
    }

    switch (type) {
        case MJReplLineTypeStdout:  color = self.MJColorForStdout; break;
        case MJReplLineTypeCommand: color = self.MJColorForCommand; break;
        case MJReplLineTypeResult:  color = self.MJColorForResult; break;
    }

    if (type == MJReplLineTypeStdout) {
        str = [NSString stringWithFormat:@"%@: %@", [self.dateFormatter stringFromDate:[NSDate date]], str];
    }

    NSDictionary* attrs = @{NSFontAttributeName: self.consoleFont, NSForegroundColorAttributeName: color};
    NSAttributedString* attrstr = [[NSAttributedString alloc] initWithString:str attributes:attrs];

    // We don't actually append the string immediately, it goes into a buffer that drains on a timer (see above)
    [self.outputBuffer addObject:attrstr];
}

- (NSString*) run:(NSString*)command {
    return MJLuaRunString(command);
}

- (IBAction) tryMessage:(NSTextField*)sender {
    NSString* command = [sender stringValue];
    [self appendString:[NSString stringWithFormat:@"\n> %@\n", command] type:MJReplLineTypeCommand];

    NSString* result = [self run:command];
    [self appendString:[NSString stringWithFormat:@"%@\n", result] type:MJReplLineTypeResult];

    [sender setStringValue:@""];
    [(HSGrowingTextField *)sender resetGrowth];

    [self saveToHistory:command];
    [self.outputView scrollToEndOfDocument:self];
}

- (void) saveToHistory:(NSString*)cmd {
    [self.history addObject:cmd];
    self.historyIndex = [self.history count];
    [self useCurrentHistoryIndex];
}

- (void) goPrevHistory {
    self.historyIndex = MAX(self.historyIndex - 1, 0);
    [self useCurrentHistoryIndex];
}

- (void) goNextHistory {
    self.historyIndex = MIN(self.historyIndex + 1, [self.history count]);
    [self useCurrentHistoryIndex];
}

- (void) useCurrentHistoryIndex {
    [(HSGrowingTextField *)self.inputField resetGrowth];

    if (self.historyIndex == [self.history count])
        [self.inputField setStringValue: @""];
    else
        [self.inputField setStringValue: [self.history objectAtIndex:self.historyIndex]];

    NSText* editor = [[self.inputField window] fieldEditor:YES forObject:self.inputField];
    NSRange position = (NSRange){[[editor string] length], 0};
    [editor setSelectedRange:position];
}

BOOL MJConsoleWindowAlwaysOnTop(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey: MJKeepConsoleOnTopKey];
}

void MJConsoleWindowSetAlwaysOnTop(BOOL alwaysOnTop) {
    [[NSUserDefaults standardUserDefaults] setBool:alwaysOnTop
                                            forKey:MJKeepConsoleOnTopKey];
    [[MJConsoleWindowController singleton] reflectDefaults];
}

#pragma mark - NSTextFieldDelegate

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command {
    BOOL result = YES;

    if (command == @selector(moveUp:)) {
        [self goPrevHistory];
    } else if (command == @selector(moveDown:)) {
        [self goNextHistory];
    } else if (command == @selector(insertTab:)) {// || command == @selector(complete:)) {
        [self.inputField.currentEditor complete:nil];
    } else {
        result = NO;
    }
    return result;
}

- (NSArray<NSString *> *)control:(NSControl *)control
                        textView:(NSTextView *)textView
                     completions:(NSArray<NSString *> *)words
             forPartialWordRange:(NSRange)charRange
             indexOfSelectedItem:(NSInteger *)index
{
    NSString *currentText = textView.string;
    NSString *textBeforeCursor = [currentText substringToIndex:NSMaxRange(charRange)];
    NSString *textAfterCursor = [currentText substringFromIndex:NSMaxRange(charRange)];
    NSString *completionWord = [currentText substringWithRange:charRange];
    NSArray *completions = MJLuaCompletionsForWord(completionWord);
    if (completions.count == 1) {
        // We have only one completion, so we should just insert it into the text field
        NSString *completeWith = [completions objectAtIndex:0];
        NSString *stringToAdd = @"";

        //NSLog(@"Need to shove in the difference between %@ and %@", completeWith, completionWord);

        if ([completeWith hasPrefix:completionWord]) {
            stringToAdd = [completeWith substringFromIndex:[completionWord length]];
        }

        textView.string = [NSString stringWithFormat:@"%@%@%@", textBeforeCursor, stringToAdd, textAfterCursor];
        [textView setSelectedRange:NSMakeRange(NSMaxRange(charRange) + stringToAdd.length, 0)];
        return @[];
    }
    return completions;
}

@end
