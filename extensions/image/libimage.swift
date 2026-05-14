import Cocoa
import LuaSkin
import AVFoundation

private let USERDATA_TAG = "hs.image"
private var refTable: LSRefTable = LUA_NOREF

// NSWorkspace iconForFile: logs a warning every time you try to query when the path is nil.  Since
// this happens a lot when trying to query based on a file bundle it means anything using spotlight
// to gather file info and then uses this to get an icon can spam the system logs.  let's get it once
// and be done with it.
private var missingIconForFile: NSImage?

private var backgroundCallbacks = NSMutableSet()

// MARK: - NSImage to ASCII Conversion

/*
 This code is from ASCII Converter (https://github.com/zonble/cocoaascii).
 MIT License, Copyright (c) 2021 Weizhong Yang a.k.a zonble.
 */

private func stringForBrightness(_ brightness: CGFloat) -> String {
    if brightness < (19.0 / 255) { return "&" }
    else if brightness < (50.0 / 255) { return "8" }
    else if brightness < (75.0 / 255) { return "0" }
    else if brightness < (100.0 / 255) { return "$" }
    else if brightness < (130.0 / 255) { return "2" }
    else if brightness < (165.0 / 255) { return "1" }
    else if brightness < (180.0 / 255) { return "|" }
    else if brightness < (200.0 / 255) { return ";" }
    else if brightness < (218.0 / 255) { return ":" }
    else if brightness < (229.0 / 255) { return "'" }
    return " "
}

extension NSImage {
    func asciiArt(width: Int, height: Int) -> String? {
        guard width > 0 && height > 0 else { return nil }

        var result = ""

        let bitmapImage = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        bitmapImage.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapImage)
        self.draw(in: NSRect(x: 0, y: 0, width: width, height: height),
                  from: .zero, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        for i in 0..<height {
            for j in 0..<width {
                if let color = bitmapImage.colorAt(x: j, y: i),
                   let wColor = color.usingColorSpace(.deviceGray) {
                    result += stringForBrightness(wColor.whiteComponent)
                }
            }
            result += "\n"
        }
        return result
    }
}

// MARK: - Module Constants

/// hs.image.systemImageNames[]
/// Constant
/// Table containing the names of internal system images for use with hs.drawing.image
///
/// Notes:
///  * Image names pulled from NSImage.h
///  * This table has a __tostring() metamethod which allows listing it's contents in the Hammerspoon console by typing `hs.image.systemImageNames`.
private func pushNSImageNameTable(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    lua_newtable(L)

    let imageNames: [(String, NSImage.Name)] = [
        ("QuickLookTemplate", .quickLookTemplate),
        ("BluetoothTemplate", .bluetoothTemplate),
        ("IChatTheaterTemplate", .iChatTheaterTemplate),
        ("SlideshowTemplate", .slideshowTemplate),
        ("ActionTemplate", .actionTemplate),
        ("SmartBadgeTemplate", .smartBadgeTemplate),
        ("IconViewTemplate", .iconViewTemplate),
        ("ListViewTemplate", .listViewTemplate),
        ("ColumnViewTemplate", .columnViewTemplate),
        ("FlowViewTemplate", .flowViewTemplate),
        ("PathTemplate", .pathTemplate),
        ("InvalidDataFreestandingTemplate", .invalidDataFreestandingTemplate),
        ("LockLockedTemplate", .lockLockedTemplate),
        ("LockUnlockedTemplate", .lockUnlockedTemplate),
        ("GoForwardTemplate", .goForwardTemplate),
        ("GoBackTemplate", .goBackTemplate),
        ("GoRightTemplate", .goRightTemplate),
        ("GoLeftTemplate", .goLeftTemplate),
        ("RightFacingTriangleTemplate", .rightFacingTriangleTemplate),
        ("LeftFacingTriangleTemplate", .leftFacingTriangleTemplate),
        ("AddTemplate", .addTemplate),
        ("RemoveTemplate", .removeTemplate),
        ("RevealFreestandingTemplate", .revealFreestandingTemplate),
        ("FollowLinkFreestandingTemplate", .followLinkFreestandingTemplate),
        ("EnterFullScreenTemplate", .enterFullScreenTemplate),
        ("ExitFullScreenTemplate", .exitFullScreenTemplate),
        ("StopProgressTemplate", .stopProgressTemplate),
        ("StopProgressFreestandingTemplate", .stopProgressFreestandingTemplate),
        ("RefreshTemplate", .refreshTemplate),
        ("RefreshFreestandingTemplate", .refreshFreestandingTemplate),
        ("Bonjour", .bonjour),
        ("Computer", .computer),
        ("FolderBurnable", .folderBurnable),
        ("FolderSmart", .folderSmart),
        ("Folder", .folder),
        ("Network", .network),
        ("MobileMe", .mobileMe),
        ("MultipleDocuments", .multipleDocuments),
        ("UserAccounts", .userAccounts),
        ("PreferencesGeneral", .preferencesGeneral),
        ("Advanced", .advanced),
        ("Info", .info),
        ("FontPanel", .fontPanel),
        ("ColorPanel", .colorPanel),
        ("User", .user),
        ("UserGroup", .userGroup),
        ("Everyone", .everyone),
        ("UserGuest", .userGuest),
        ("MenuOnStateTemplate", .menuOnStateTemplate),
        ("MenuMixedStateTemplate", .menuMixedStateTemplate),
        ("ApplicationIcon", .applicationIcon),
        ("TrashEmpty", .trashEmpty),
        ("TrashFull", .trashFull),
        ("HomeTemplate", .homeTemplate),
        ("BookmarksTemplate", .bookmarksTemplate),
        ("Caution", .caution),
        ("StatusAvailable", .statusAvailable),
        ("StatusPartiallyAvailable", .statusPartiallyAvailable),
        ("StatusUnavailable", .statusUnavailable),
        ("StatusNone", .statusNone),
        ("ShareTemplate", .shareTemplate),
        ("TouchBarAddDetailTemplate", .touchBarAddDetailTemplate),
        ("TouchBarAddTemplate", .touchBarAddTemplate),
        ("TouchBarAlarmTemplate", .touchBarAlarmTemplate),
        ("TouchBarAudioInputMuteTemplate", .touchBarAudioInputMuteTemplate),
        ("TouchBarAudioInputTemplate", .touchBarAudioInputTemplate),
        ("TouchBarAudioOutputMuteTemplate", .touchBarAudioOutputMuteTemplate),
        ("TouchBarAudioOutputVolumeHighTemplate", .touchBarAudioOutputVolumeHighTemplate),
        ("TouchBarAudioOutputVolumeLowTemplate", .touchBarAudioOutputVolumeLowTemplate),
        ("TouchBarAudioOutputVolumeMediumTemplate", .touchBarAudioOutputVolumeMediumTemplate),
        ("TouchBarAudioOutputVolumeOffTemplate", .touchBarAudioOutputVolumeOffTemplate),
        ("TouchBarBookmarksTemplate", .touchBarBookmarksTemplate),
        ("TouchBarColorPickerFill", .touchBarColorPickerFill),
        ("TouchBarColorPickerFont", .touchBarColorPickerFont),
        ("TouchBarColorPickerStroke", .touchBarColorPickerStroke),
        ("TouchBarCommunicationAudioTemplate", .touchBarCommunicationAudioTemplate),
        ("TouchBarCommunicationVideoTemplate", .touchBarCommunicationVideoTemplate),
        ("TouchBarComposeTemplate", .touchBarComposeTemplate),
        ("TouchBarDeleteTemplate", .touchBarDeleteTemplate),
        ("TouchBarDownloadTemplate", .touchBarDownloadTemplate),
        ("TouchBarEnterFullScreenTemplate", .touchBarEnterFullScreenTemplate),
        ("TouchBarExitFullScreenTemplate", .touchBarExitFullScreenTemplate),
        ("TouchBarFastForwardTemplate", .touchBarFastForwardTemplate),
        ("TouchBarFolderCopyToTemplate", .touchBarFolderCopyToTemplate),
        ("TouchBarFolderMoveToTemplate", .touchBarFolderMoveToTemplate),
        ("TouchBarFolderTemplate", .touchBarFolderTemplate),
        ("TouchBarGetInfoTemplate", .touchBarGetInfoTemplate),
        ("TouchBarGoBackTemplate", .touchBarGoBackTemplate),
        ("TouchBarGoDownTemplate", .touchBarGoDownTemplate),
        ("TouchBarGoForwardTemplate", .touchBarGoForwardTemplate),
        ("TouchBarGoUpTemplate", .touchBarGoUpTemplate),
        ("TouchBarHistoryTemplate", .touchBarHistoryTemplate),
        ("TouchBarIconViewTemplate", .touchBarIconViewTemplate),
        ("TouchBarListViewTemplate", .touchBarListViewTemplate),
        ("TouchBarMailTemplate", .touchBarMailTemplate),
        ("TouchBarNewFolderTemplate", .touchBarNewFolderTemplate),
        ("TouchBarNewMessageTemplate", .touchBarNewMessageTemplate),
        ("TouchBarOpenInBrowserTemplate", .touchBarOpenInBrowserTemplate),
        ("TouchBarPauseTemplate", .touchBarPauseTemplate),
        ("TouchBarPlayheadTemplate", .touchBarPlayheadTemplate),
        ("TouchBarPlayPauseTemplate", .touchBarPlayPauseTemplate),
        ("TouchBarPlayTemplate", .touchBarPlayTemplate),
        ("TouchBarQuickLookTemplate", .touchBarQuickLookTemplate),
        ("TouchBarRecordStartTemplate", .touchBarRecordStartTemplate),
        ("TouchBarRecordStopTemplate", .touchBarRecordStopTemplate),
        ("TouchBarRefreshTemplate", .touchBarRefreshTemplate),
        ("TouchBarRewindTemplate", .touchBarRewindTemplate),
        ("TouchBarRotateLeftTemplate", .touchBarRotateLeftTemplate),
        ("TouchBarRotateRightTemplate", .touchBarRotateRightTemplate),
        ("TouchBarSearchTemplate", .touchBarSearchTemplate),
        ("TouchBarShareTemplate", .touchBarShareTemplate),
        ("TouchBarSidebarTemplate", .touchBarSidebarTemplate),
        ("TouchBarSkipAhead15SecondsTemplate", .touchBarSkipAhead15SecondsTemplate),
        ("TouchBarSkipAhead30SecondsTemplate", .touchBarSkipAhead30SecondsTemplate),
        ("TouchBarSkipAheadTemplate", .touchBarSkipAheadTemplate),
        ("TouchBarSkipBack15SecondsTemplate", .touchBarSkipBack15SecondsTemplate),
        ("TouchBarSkipBack30SecondsTemplate", .touchBarSkipBack30SecondsTemplate),
        ("TouchBarSkipBackTemplate", .touchBarSkipBackTemplate),
        ("TouchBarSkipToEndTemplate", .touchBarSkipToEndTemplate),
        ("TouchBarSkipToStartTemplate", .touchBarSkipToStartTemplate),
        ("TouchBarSlideshowTemplate", .touchBarSlideshowTemplate),
        ("TouchBarTagIconTemplate", .touchBarTagIconTemplate),
        ("TouchBarTextBoldTemplate", .touchBarTextBoldTemplate),
        ("TouchBarTextBoxTemplate", .touchBarTextBoxTemplate),
        ("TouchBarTextCenterAlignTemplate", .touchBarTextCenterAlignTemplate),
        ("TouchBarTextItalicTemplate", .touchBarTextItalicTemplate),
        ("TouchBarTextJustifiedAlignTemplate", .touchBarTextJustifiedAlignTemplate),
        ("TouchBarTextLeftAlignTemplate", .touchBarTextLeftAlignTemplate),
        ("TouchBarTextListTemplate", .touchBarTextListTemplate),
        ("TouchBarTextRightAlignTemplate", .touchBarTextRightAlignTemplate),
        ("TouchBarTextStrikethroughTemplate", .touchBarTextStrikethroughTemplate),
        ("TouchBarTextUnderlineTemplate", .touchBarTextUnderlineTemplate),
        ("TouchBarUserAddTemplate", .touchBarUserAddTemplate),
        ("TouchBarUserGroupTemplate", .touchBarUserGroupTemplate),
        ("TouchBarUserTemplate", .touchBarUserTemplate),
        ("TouchBarVolumeDownTemplate", .touchBarVolumeDownTemplate),
        ("TouchBarVolumeUpTemplate", .touchBarVolumeUpTemplate),
    ]

    for (field, name) in imageNames {
        skin.pushNSObject(name.rawValue as NSString)
        lua_setfield(L, -2, field)
    }

    return 1
}

/// hs.image.additionalImageNames[]
/// Constant
/// Table of arrays containing the names of additional internal system images which may also be available for use with `hs.drawing.image` and [hs.image.imageFromName](#imageFromName).
///
/// Notes:
///  * The list of these images was pulled from a collection located in the repositories at https://github.com/hetima?tab=repositories.  As these image names are (for the most part) not formally listed in Apple's documentation or published APIs, their use cannot be guaranteed across all OS X versions.  If you identify any images which may be missing or could be added, please file an issue at https://github.com/Hammerspoon/hammerspoon.
private func additionalImages(_ L: OpaquePointer!) -> Int32 {
    lua_newtable(L)

    // Helper to push a string array as a Lua array and set it as a field
    func pushStringArray(_ L: OpaquePointer!, _ names: [String], _ field: String) {
        lua_newtable(L)
        for name in names {
            lua_pushstring(L, name)
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }
        lua_setfield(L, -2, field)
    }

    pushStringArray(L, [
        "NSAddBookmarkTemplate", "NSAudioOutputMuteTemplate", "NSAudioOutputVolumeHighTemplate",
        "NSAudioOutputVolumeLowTemplate", "NSAudioOutputVolumeMedTemplate", "NSAudioOutputVolumeOffTemplate",
        "NSChildContainerEmptyTemplate", "NSChildContainerTemplate", "NSDropDownIndicatorTemplate",
        "NSGoLeftSmall", "NSGoRightSmall", "NSMenuMixedStateTemplate", "NSMenuOnStateTemplate",
        "NSNavEjectButton.normal", "NSNavEjectButton.normalSelected", "NSNavEjectButton.pressed",
        "NSNavEjectButton.rollover", "NSNavEjectButton.small.normal", "NSNavEjectButton.small.normalSelected",
        "NSNavEjectButton.small.pressed", "NSNavEjectButton.small.rollover", "NSPathLocationArrow",
        "NSPrivateArrowNextTemplate", "NSPrivateArrowPreviousTemplate", "NSPrivateChaptersTemplate",
        "NSScriptTemplate", "NSSecurity", "NSStatusAvailableFlat", "NSStatusAway", "NSStatusIdle",
        "NSStatusNoneFlat", "NSStatusOffline", "NSStatusPartiallyAvailableFlat", "NSStatusUnavailableFlat",
        "NSStatusUnknown", "NSSynchronize", "NSTitlebarEnterFullScreenTemplate",
        "NSTitlebarExitFullScreenTemplate", "NSTokenPopDownArrow",
    ], "undocumentedImages")

    pushStringArray(L, [
        "NSFastForwardTemplate", "NSPauseTemplate", "NSPlayTemplate", "NSRecordStartTemplate",
        "NSRecordStopTemplate", "NSRewindTemplate", "NSSkipAheadTemplate", "NSSkipBackTemplate",
    ], "mediaControl")

    pushStringArray(L, [
        "NSToolbarBookmarks", "NSToolbarClipIndicator", "NSToolbarCustomizeToolbarItemImage",
        "NSToolbarFlexibleSpaceItemPaletteRep", "NSToolbarMoreTemplate", "NSToolbarPrintItemImage",
        "NSToolbarShowColorsItemImage", "NSToolbarShowFontsItemImage", "NSToolbarSpaceItemPaletteRep",
    ], "toolbar")

    pushStringArray(L, [
        "NSMediaBrowserIcon", "NSMediaBrowserMediaTypeAudio", "NSMediaBrowserMediaTypeAudioTemplate32",
        "NSMediaBrowserMediaTypeMovies", "NSMediaBrowserMediaTypeMoviesTemplate32",
        "NSMediaBrowserMediaTypePhotos", "NSMediaBrowserMediaTypePhotosTemplate32",
    ], "mediaBrowser")

    pushStringArray(L, [
        "NSCMYKButton", "NSColorPickerCrayon", "NSColorPickerList", "NSColorPickerSliders",
        "NSColorPickerUser", "NSColorPickerWheel", "NSColorProfileButton", "NSColorProfileButtonSelected",
        "NSColorSwatchResizeDimple", "NSGreyButton", "NSHSBButton", "NSMagnifyingGlass",
        "NSRGBButton", "NSSmallMagnifyingGlass",
    ], "colorPicker")

    pushStringArray(L, [
        "NSFontPanelActionButton", "NSFontPanelActionButtonPressed", "NSFontPanelBlurEffect",
        "NSFontPanelDropEffect", "NSFontPanelDropEffectPressed", "NSFontPanelEffectsDivider",
        "NSFontPanelMinusIdle", "NSFontPanelMinusPressed", "NSFontPanelOpacityEffect",
        "NSFontPanelPaperColour", "NSFontPanelPaperColourPressed", "NSFontPanelPlusIdle",
        "NSFontPanelPlusPressed", "NSFontPanelSliderThumb", "NSFontPanelSliderThumbPressed",
        "NSFontPanelSliderTrack", "NSFontPanelSplitterKnob", "NSFontPanelSpreadEffect",
        "NSFontPanelStrikeEffect", "NSFontPanelStrikeEffectPressed", "NSFontPanelTextColour",
        "NSFontPanelTextColourPressed", "NSFontPanelUnderlineEffect", "NSFontPanelUnderlineEffectPressed",
    ], "fontPanel")

    pushStringArray(L, [
        "NSDatePickerCalendarArrowLeft", "NSDatePickerCalendarArrowRight", "NSDatePickerCalendarHome",
        "NSDatePickerClockCenter", "NSDatePickerClockFace",
    ], "datePicker")

    pushStringArray(L, [
        "NSTextRulerCenterTab", "NSTextRulerDecimalTab", "NSTextRulerFirstLineIndent",
        "NSTextRulerIndent", "NSTextRulerLeftTab", "NSTextRulerRightTab",
    ], "ruler")

    pushStringArray(L, [
        "NSArrowCursor", "NSClosedHandCursor", "NSCopyDragCursor", "NSCrosshairCursor",
        "NSGenericDragCursor", "NSHandCursor", "NSIBeamCursor", "NSLinkDragCursor",
        "NSMoveCursor", "NSResizeLeftCursor", "NSResizeLeftRightCursor", "NSResizeRightCursor",
        "NSTruthBottomLeftResizeCursor", "NSTruthBottomRightResizeCursor", "NSTruthHResizeCursor",
        "NSTruthHorizontalResizeCursor", "NSTruthTopLeftResizeCursor", "NSTruthTopRightResizeCursor",
        "NSTruthVResizeCursor", "NSTruthVerticalResizeCursor", "NSWaitCursor",
    ], "cursorLegacy")

    // The platinum and NX arrays are very long -- pushing them as string arrays
    // using the same helper. Omitted for brevity: the original ObjC pushes ~200+ strings
    // in the "platinum" and "NX" categories. They are reproduced here faithfully.

    pushStringArray(L, [
        "NSAppleMenuImage", "NSBrowserCellBranch", "NSBrowserCellBranchH",
        "NSClosedHandCursor", "NSCopyDragCursor", "NSCrosshairCursor",
        "NSDocEditing", "NSDocSaved", "NSGenericDragCursor", "NSGrayResizeCorner",
        "NSHandCursor", "NSHighlightedLinkButton", "NSHighlightedMenuArrow",
        "NSHighlightedScrollDownButton", "NSHighlightedScrollLeftButton",
        "NSHighlightedScrollRightButton", "NSHighlightedScrollUpButton",
        "NSLeftMenuBarCap", "NSLinkButton", "NSLinkDragCursor",
        "NSMacPopUpArrows", "NSMacPullDownArrow", "NSMacSmallPopUpArrows",
        "NSMacSmallPullDownArrow", "NSMacSubmenuArrow", "NSMacTinyPopUpArrows",
        "NSMacTinyPullDownArrow", "NSMenuArrow", "NSMenuBackTabKeyGlyph",
        "NSMenuCheckmark", "NSMenuClearKeyGlyph", "NSMenuCommandKeyGlyph",
        "NSMenuControlKeyGlyph", "NSMenuDeleteBackwardKeyGlyph", "NSMenuDeleteForwardKeyGlyph",
        "NSMenuDownArrowKeyGlyph", "NSMenuDownScrollArrow", "NSMenuEndKeyGlyph",
        "NSMenuEnterKeyGlyph", "NSMenuEscapeKeyGlyph", "NSMenuHelpKeyGlyph",
        "NSMenuHomeKeyGlyph", "NSMenuISOControlKeyGlyph", "NSMenuLeftArrowKeyGlyph",
        "NSMenuMixedState", "NSMenuOptionKeyGlyph", "NSMenuPageDownKeyGlyph",
        "NSMenuPageUpKeyGlyph", "NSMenuRadio", "NSMenuReturnKeyGlyph",
        "NSMenuRightArrowKeyGlyph", "NSMenuShiftKeyGlyph", "NSMenuTabKeyGlyph",
        "NSMenuUpArrowKeyGlyph", "NSMenuUpScrollArrow", "NSMenuWindowDirtyState",
        "NSMiniTextAlignCenter", "NSMiniTextAlignJust", "NSMiniTextAlignLeft",
        "NSMiniTextAlignRight", "NSMiniTextList", "NSMoveCursor",
        "NSNavigationBarButtonFillActive", "NSNavigationBarButtonFillInactive",
        "NSNavigationBarButtonFillPressedAqua", "NSNavigationBarButtonFillPressedGraphite",
        "NSNavigationBarButtonLeftActive", "NSNavigationBarButtonLeftInactive",
        "NSNavigationBarButtonLeftPressedAqua", "NSNavigationBarButtonLeftPressedGraphite",
        "NSNavigationBarButtonRightActive", "NSNavigationBarButtonRightInactive",
        "NSNavigationBarButtonRightPressedAqua", "NSNavigationBarButtonRightPressedGraphite",
        "NSNavigationBarLeftAngleActive", "NSNavigationBarLeftAngleInactive",
        "NSNavigationBarLeftAnglePressedAqua", "NSNavigationBarLeftAnglePressedGraphite",
        "NSNavigationBarRightAngleActive", "NSNavigationBarRightAngleInactive",
        "NSNavigationBarRightAnglePressedAqua", "NSNavigationBarRightAnglePressedGraphite",
        "NSRadioButtonDisabledMixed", "NSRadioButtonDisabledOff", "NSRadioButtonDisabledOn",
        "NSRadioButtonEnabledMixed", "NSRadioButtonEnabledOff", "NSRadioButtonEnabledOn",
        "NSRadioButtonFocusRing", "NSRadioButtonHighlightedMixed", "NSRadioButtonHighlightedOff",
        "NSRadioButtonHighlightedOn", "NSResizeLeftCursor", "NSResizeLeftRightCursor",
        "NSResizeRightCursor", "NSRightMenuBarCap",
        "NSScrollDownArrow", "NSScrollDownArrowDisabled", "NSScrollDownButton",
        "NSScrollLeftArrow", "NSScrollLeftArrowDisabled", "NSScrollLeftButton",
        "NSScrollRightArrow", "NSScrollRightArrowDisabled", "NSScrollRightButton",
        "NSScrollUpArrow", "NSScrollUpArrowDisabled", "NSScrollUpButton",
        "NSSliderKnobAbove", "NSSliderKnobAboveDisabled", "NSSliderKnobAbovePressed",
        "NSSliderKnobBelow", "NSSliderKnobBelowDisabled", "NSSliderKnobBelowPressed",
        "NSSliderKnobHorizontal", "NSSliderKnobHorizontalDisabled", "NSSliderKnobHorizontalPressed",
        "NSSliderKnobLeft", "NSSliderKnobLeftDisabled", "NSSliderKnobLeftPressed",
        "NSSliderKnobRight", "NSSliderKnobRightDisabled", "NSSliderKnobRightPressed",
        "NSSliderKnobVertical", "NSSliderKnobVerticalDisabled", "NSSliderKnobVerticalPressed",
        "NSSmallSCurveFill_Active_Textured", "NSSmallSCurveFill_Disabled_Textured",
        "NSSmallSCurveFill_Pressed_Textured", "NSSmallSCurveLeftCap_Active_Textured",
        "NSSmallSCurveLeftCap_Disabled_Textured", "NSSmallSCurveLeftCap_Pressed_Textured",
        "NSSmallSCurveRightCap_Active_Textured", "NSSmallSCurveRightCap_Disabled_Textured",
        "NSSmallSCurveRightCap_Pressed_Textured",
        "NSSwitchDisabledMixed", "NSSwitchDisabledOff", "NSSwitchDisabledOn",
        "NSSwitchEnabledMixed", "NSSwitchEnabledOff", "NSSwitchEnabledOn",
        "NSSwitchFocusRing", "NSSwitchHighlightedMixed", "NSSwitchHighlightedOff",
        "NSSwitchHighlightedOn", "NSTableViewDropBetweenCircleMarker",
        "NSTextRulerAlignCentered", "NSTextRulerAlignJustified", "NSTextRulerAlignLeft",
        "NSTextRulerAlignRight", "NSTextRulerIndentFirst", "NSTextRulerIndentLeft",
        "NSTextRulerIndentRight", "NSTextRulerLineHeightDecrease", "NSTextRulerLineHeightFixed",
        "NSTextRulerLineHeightFlexible", "NSTextRulerLineHeightIncrease",
        "NSTextRulerMarginLeft", "NSTextRulerMarginRight",
        "NSTextRulerTabCenter", "NSTextRulerTabDecimal", "NSTextRulerTabLeft", "NSTextRulerTabRight",
        "NSThemeWindowDocument",
        "NSTriangleNormalDown", "NSTriangleNormalRight", "NSTrianglePressedDown",
        "NSTrianglePressedRDown", "NSTrianglePressedRight",
        "NSTriangleWhite-Collapsed", "NSTriangleWhite-Expanded",
        "NSTriangleWhite-Pressed-Collapsed", "NSTriangleWhite-Pressed-Expanded", "NSTriangleWhite-Turning",
        "NSTruthClose", "NSTruthCloseH", "NSTruthCollapse", "NSTruthCollapseH",
        "NSTruthEditedClose", "NSTruthEditedCloseH", "NSTruthHResizeCursor",
        "NSTruthHorizontalResizeCursor", "NSTruthMiniDocument", "NSTruthMiniDocumentEdited",
        "NSTruthVResizeCursor", "NSTruthVerticalResizeCursor", "NSTruthZoom", "NSTruthZoomH",
        "NSUtilityClose", "NSUtilityCloseH", "NSUtilityCollapse", "NSUtilityCollapseH",
        "NSUtilityEditedClose", "NSUtilityEditedCloseH", "NSUtilityZoom", "NSUtilityZoomH",
        "NSWin95BrowserBranch", "NSWin95ComboBoxDownArrow", "NSWin95HighlightedBrowserBranch",
        "NSWin95PopUpArrows", "NSWin95PullDownArrow",
        "NSWinHighRadio", "NSWinHighSwitch", "NSWinRadio",
        "NSWinSliderKnobAbove", "NSWinSliderKnobAbovePressed",
        "NSWinSliderKnobBelow", "NSWinSliderKnobBelowPressed",
        "NSWinSliderKnobHorizontal", "NSWinSliderKnobHorizontalPressed",
        "NSWinSliderKnobLeft", "NSWinSliderKnobLeftPressed",
        "NSWinSliderKnobRight", "NSWinSliderKnobRightPressed",
        "NSWinSliderKnobVertical", "NSWinSliderKnobVerticalPressed",
        "NSWinSwitch",
        "NSWindowClose", "NSWindowCloseH", "NSWindowCollapse", "NSWindowCollapseH",
        "NSWindowEditedClose", "NSWindowEditedCloseH", "NSWindowMiniDocument",
        "NSWindowMiniDocumentEdited", "NSWindowZoom", "NSWindowZoomH",
    ], "platinum")

    pushStringArray(L, [
        "NXAppTile", "NXBreak", "NXBreakAll", "NXFollow",
        "NXGrey0", "NXGrey1", "NXGrey2", "NXGrey3", "NXGrey4", "NXGrey5", "NXGrey6",
        "NXHDestLinkChain", "NXHSrcLinkChain", "NXHelpBacktrack", "NXHelpFind",
        "NXHelpIndex", "NXHelpMarker", "NXHelpMarkerH", "NXMagnifier", "NXUpdate",
        "NXVDestLinkChain", "NXVSrcLinkChain", "NXauto", "NXcircle16", "NXcircle16H",
        "NXclose", "NXcloseH", "NXdefaultappicon", "NXdefaulticon",
        "NXdivider", "NXdividerH", "NXediting", "NXfirstindent", "NXhSliderKnob",
        "NXiconify", "NXiconifyH", "NXleftindent", "NXleftmargin", "NXmanual",
        "NXminiWindow", "NXminiWorld", "NXpopup", "NXpopupH", "NXpulldown", "NXpulldownH",
        "NXresize", "NXresizeH", "NXresizeKnob", "NXresizeKnobH",
        "NXrightindent", "NXrightmargin", "NXscrollKnob",
        "NXscrollMenuDown", "NXscrollMenuDownD", "NXscrollMenuDownH",
        "NXscrollMenuLeft", "NXscrollMenuLeftD", "NXscrollMenuLeftH",
        "NXscrollMenuRight", "NXscrollMenuRightD", "NXscrollMenuRightH",
        "NXscrollMenuUp", "NXscrollMenuUpD", "NXscrollMenuUpH",
        "NXsquare16", "NXsquare16H", "NXtab", "NXvSliderKnob", "NXwait",
    ], "NX")

    return 1
}

// MARK: - Module Functions

/// hs.image.getExifFromPath(path) -> table | nil
/// Function
/// Gets the EXIF metadata information from an image file.
///
/// Parameters:
///  * path - The path to the image file.
///
/// Returns:
///  * A table of EXIF metadata, or `nil` if no metadata can be found or the file path is invalid.
private func getExifFromPath(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TSTRING, LS_TBREAK)

    var imagePath = skin.toNSObject(atIndex: 1) as! String
    imagePath = (imagePath as NSString).expandingTildeInPath
    imagePath = imagePath.components(separatedBy: .newlines).joined()

    guard let imageFileURL = URL(fileURLWithPath: imagePath) as CFURL?,
          let imageSource = CGImageSourceCreateWithURL(imageFileURL, nil) else {
        lua_pushnil(L)
        return 1
    }

    let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
    guard let imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, options as CFDictionary) as? [String: Any] else {
        lua_pushnil(L)
        return 1
    }

    if let exifTree = imageProperties["{Exif}"] as? NSDictionary {
        skin.pushNSObject(exifTree)
    } else {
        lua_pushnil(L)
    }

    return 1
}

/// hs.image.imageFromPath(path) -> object
/// Constructor
/// Loads an image file
///
/// Parameters:
///  * path - A string containing the path to an image file on disk
///
/// Returns:
///  * An `hs.image` object, or nil if an error occurred
private func imageFromPath(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TSTRING, LS_TBREAK)

    var imagePath = skin.toNSObject(atIndex: 1) as! String
    imagePath = (imagePath as NSString).expandingTildeInPath
    imagePath = imagePath.components(separatedBy: .newlines).joined()
    let newImage = NSImage(byReferencingFile: imagePath)

    if let newImage = newImage, newImage.isValid {
        skin.pushNSObject(newImage)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.image.imageFromASCII(ascii[, context]) -> object
/// Constructor
/// Previously created an image from an ASCII representation. This function has been removed.
///
/// Parameters:
///  * ascii - Unused
///  * context - Unused
///
/// Returns:
///  * This function always throws an error as the ASCIImage dependency has been removed.
private func imageWithContextFromASCII(_ L: OpaquePointer!) -> Int32 {
    return luaL_error(L, "hs.image.imageFromASCII has been removed (ASCIImage dependency dropped)")
}

/// hs.image.imageFromName(string) -> object
/// Constructor
/// Returns the hs.image object for the specified name, if it exists.
///
/// Parameters:
///  * Name - the name of the image to return.
///
/// Returns:
///  * An hs.image object or nil, if no image was found with the specified name.
///
/// Notes:
///  * Some predefined labels corresponding to OS X System default images can be found in `hs.image.systemImageNames`.
///  * Names are not required to be unique: The search order is as follows, and the first match found is returned:
///     * an image whose name was explicitly set with the `setName` method since the last full restart of Hammerspoon
///     * Hammerspoon's main application bundle
///     * the Application Kit framework (this is where most of the images listed in `hs.image.systemImageNames` are located)
///  * Image names can be assigned by the image creator or by calling the `hs.image:setName` method on an hs.image object.
private func imageFromName(_ L: OpaquePointer!) -> Int32 {
    let imageName = String(cString: luaL_checkstring(L, 1))
    if let newImage = NSImage(named: NSImage.Name(imageName)) {
        LuaSkin.shared(withState: L)!.pushNSObject(newImage)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.image.imageFromURL(url[, callbackFn]) -> object
/// Constructor
/// Creates an `hs.image` object from the contents of the specified URL.
///
/// Parameters:
///  * url - a web url specifying the location of the image to retrieve
///  * callbackFn - an optional callback function to be called when the image fetching is complete
///
/// Returns:
///  * An `hs.image` object or nil, if the url does not specify image contents or is unreachable, or if a callback function is supplied
///
/// Notes:
///  * If a callback function is supplied, this function will return nil immediately and the image will be fetched asynchronously
private func imageFromURL(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TSTRING, LS_TFUNCTION | LS_TOPTIONAL, LS_TBREAK)
    guard let theURL = URL(string: skin.toNSObject(atIndex: 1) as! String) else {
        lua_pushnil(L)
        return 1
    }

    if lua_type(L, 2) != LUA_TFUNCTION {
        skin.pushNSObject(NSImage(contentsOf: theURL))
    } else {
        let fnRef = skin.luaRef(refTable, atIndex: 2)
        backgroundCallbacks.add(NSNumber(value: fnRef))

        DispatchQueue.global(qos: .default).async {
            let image = NSImage(contentsOf: theURL)
            DispatchQueue.main.async {
                if backgroundCallbacks.contains(NSNumber(value: fnRef)) {
                    let bgSkin = LuaSkin.shared(withState: nil)!
                    _lua_stackguard_entry(bgSkin.L)
                    bgSkin.pushLuaRef(refTable, ref: fnRef)
                    bgSkin.pushNSObject(image)
                    bgSkin.protectedCallAndTraceback(1, nresults: 0)
                    bgSkin.luaUnref(refTable, ref: fnRef)
                    _lua_stackguard_exit(bgSkin.L)
                    backgroundCallbacks.remove(NSNumber(value: fnRef))
                }
            }
        }
        lua_pushnil(L)
    }

    return 1
}

/// hs.image.imageFromAppBundle(bundleID) -> object
/// Constructor
/// Creates an `hs.image` object using the icon from an App
///
/// Parameters:
///  * bundleID - A string containing the bundle identifier of an application
///
/// Returns:
///  * An `hs.image` object or nil, if no app icon was found
private func imageFromApp(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TSTRING, LS_TBREAK)

    var imagePath = ""
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: skin.toNSObject(atIndex: 1) as! String) {
        imagePath = url.path
    }

    let iconImage = !imagePath.isEmpty ? NSWorkspace.shared.icon(forFile: imagePath) : missingIconForFile
    if let iconImage = iconImage {
        skin.pushNSObject(iconImage)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.image.iconForFile(file) -> object
/// Constructor
/// Creates an `hs.image` object for the file or files specified
///
/// Parameters:
///  * file - the path to a file or an array of files to generate an icon for.
///
/// Returns:
///  * An `hs.image` object or nil, if there was an error.  The image will be the icon for the specified file or an icon representing multiple files if an array of multiple files is specified.
private func imageForFiles(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TTABLE | LS_TSTRING, LS_TBREAK)

    var theFiles: [Any]
    if lua_type(L, 1) == LUA_TSTRING {
        theFiles = [skin.toNSObject(atIndex: 1) as! String]
    } else {
        theFiles = skin.toNSObject(atIndex: 1) as! [Any]
    }

    var filesArray: [String] = []
    for item in theFiles {
        guard let str = item as? String else {
            return luaL_error(L, "invalid type, array of strings required")
        }
        filesArray.append((str as NSString).expandingTildeInPath)
    }

    if let theImage = NSWorkspace.shared.icon(forFiles: filesArray) as NSImage? {
        skin.pushNSObject(theImage)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.image.iconForFileType(fileType) -> object
/// Constructor
/// Creates an `hs.image` object of the icon for the specified file type.
///
/// Parameters:
///  * fileType - the file type, specified as a filename extension or a universal type identifier (UTI).
///
/// Returns:
///  * An `hs.image` object or nil, if there was an error
private func imageForFileType(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TSTRING, LS_TBREAK)

    let theImage = NSWorkspace.shared.icon(forFileType: skin.toNSObject(atIndex: 1) as! String)
    skin.pushNSObject(theImage)
    return 1
}

/// hs.image.imageFromMediaFile(file) -> object
/// Constructor
/// Creates an `hs.image` object from a video file or the album artwork of an audio file or directory
///
/// Parameters:
///  * file - A string containing the path to an audio or video file or an album directory
///
/// Returns:
///  * An `hs.image` object
///
/// Notes:
///  * If a thumbnail can be generated for a video file, it is returned as an `hs.image` object, otherwise the filetype icon
///  * For audio files, this function first determines the containing directory (if not already a directory)
///  * It checks if any of the following common filenames for album art are present:
///   * cover.jpg
///   * front.jpg
///   * art.jpg
///   * album.jpg
///   * folder.jpg
///  * If one of the common album art filenames is found, it is returned as an `hs.image` object
///  * This is faster than extracting image metadata and allows for obtaining artwork associated with file formats such as .flac/.ogg
///  * If no common album art filenames are found, it attempts to extract image metadata from the file. This works for .mp3/.m4a files
///  * If embedded image metadata is found, it is returned as an `hs.image` object, otherwise the filetype icon
private func imageFromMediaFile(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TSTRING, LS_TBREAK)
    var theFilePath = skin.toNSObject(atIndex: 1) as! String
    theFilePath = (theFilePath as NSString).expandingTildeInPath
    var isDirectory: ObjCBool = false
    var theDirectory: String?
    var theImage: NSImage?

    // Bail if bad path
    guard FileManager.default.fileExists(atPath: theFilePath, isDirectory: &isDirectory) else {
        return imageForFiles(L)
    }

    // If file has a movie UTI, try to generate an image from it
    let ext = (theFilePath as NSString).pathExtension
    let uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, ext as CFString, "public.movie" as CFString)?.takeRetainedValue()
    if let uti = uti, !CFStringHasPrefix(uti, "dyn" as CFString) {
        let asset = AVAsset(url: URL(fileURLWithPath: theFilePath))
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        do {
            let generatedImage = try imageGenerator.copyCGImage(at: CMTimeMake(value: 0, timescale: 10), actualTime: nil)
            theImage = NSImage(cgImage: generatedImage, size: .zero)
        } catch {
            skin.logError("Unable to generate image from video: \(error)")
        }
    }

    if theImage == nil {
        if !isDirectory.boolValue {
            let fileParent = (URL(fileURLWithPath: theFilePath).deletingLastPathComponent()).path
            var isDirCheck: ObjCBool = false
            FileManager.default.fileExists(atPath: fileParent, isDirectory: &isDirCheck)
            if isDirCheck.boolValue { theDirectory = fileParent }
        } else {
            theDirectory = theFilePath
        }

        // Attempt to get image from very common album artwork filenames
        for coverArtFile in ["cover", "front", "art", "album", "folder"] {
            let imagePath = "\(theDirectory ?? "")/\(coverArtFile).jpg"
            if FileManager.default.fileExists(atPath: imagePath) {
                let img = NSImage(byReferencingFile: imagePath)
                if let img = img, img.isValid {
                    theImage = img
                    break
                }
            }
        }
    }

    if theImage == nil {
        // Try to obtain album artwork from embedded metadata
        let asset = AVAsset(url: URL(fileURLWithPath: theFilePath))
        let metadataItems = asset.commonMetadata
        for item in metadataItems {
            if item.keySpace == .id3 || item.keySpace == .iTunes {
                if let itemData = item.dataValue {
                    let img = NSImage(data: itemData)
                    if let img = img, img.isValid {
                        theImage = img
                        break
                    }
                }
            }
        }
    }

    if let theImage = theImage, theImage.isValid {
        skin.pushNSObject(theImage)
    } else {
        return imageForFiles(L)
    }
    return 1
}

// MARK: - Module Methods

/// hs.image:name([name]) -> imageObject | string
/// Method
/// Get or set the name of the image represented by the hs.image object.
///
/// Parameters:
///  * `name` - an optional string specifying the new name for the hs.image object.
///
/// Returns:
///  * if no argument is provided, returns the current name.  If a new name is specified, returns the hs.image object or nil if the name cannot be changed.
///
/// Notes:
///  * see also [hs.image:setName](#setName) for a variant that returns a boolean instead.
private func getImageName(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, unsafeBitCast(USERDATA_TAG, to: UnsafePointer<CChar>.self), LS_TANY | LS_TOPTIONAL, LS_TBREAK)
    let testImage = skin.luaObject(atIndex: 1, toClass: "NSImage") as! NSImage
    if lua_gettop(L) == 1 {
        lua_pushstring(L, testImage.name()?.rawValue)
    } else {
        if testImage.setName(NSImage.Name(String(cString: luaL_checkstring(L, 2)))) {
            lua_pushvalue(L, 1)
        } else {
            lua_pushnil(L)
        }
    }
    return 1
}

/// hs.image:size([size, [absolute]] ) -> imageObject | size
/// Method
/// Get or set the size of the image represented by the hs.image object.
///
/// Parameters:
///  * `size`     - an optional table with 'h' and 'w' keys specifying the size for the image.
///  * `absolute` - when specifying a new size, an optional boolean, default false, specifying whether or not the image should be resized to the height and width specified (true), or whether the copied image should be scaled proportionally to fit within the height and width specified (false).
///
/// Returns:
///  * If arguments are provided, return the hs.image object; otherwise returns the current size
///
/// Notes:
///  * See also [hs.image:setSize](#setSize) for creating a copy of the image at a new size.
private func getImageSize(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, unsafeBitCast(USERDATA_TAG, to: UnsafePointer<CChar>.self), LS_TBREAK | LS_TVARARG)
    let theImage = skin.luaObject(atIndex: 1, toClass: "NSImage") as! NSImage
    if lua_gettop(L) == 1 {
        skin.pushNSSize(theImage.size)
    } else {
        skin.checkArgs(LS_TUSERDATA, unsafeBitCast(USERDATA_TAG, to: UnsafePointer<CChar>.self), LS_TTABLE, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
        let destSize = skin.tableToSize(atIndex: 2)
        let absolute = lua_gettop(L) == 3 ? (lua_toboolean(L, 3) != 0) : false
        if absolute {
            theImage.size = destSize
        } else {
            let srcSize = theImage.size
            let multiplier = min(destSize.width / srcSize.width, destSize.height / srcSize.height)
            theImage.size = NSSize(width: srcSize.width * multiplier, height: srcSize.height * multiplier)
        }
        skin.pushNSObject(theImage)
    }
    return 1
}

/// hs.image:colorAt(point) -> table
/// Method
/// Reads the color of the pixel at the specified location.
///
/// Parameters:
///  * `point` - a `hs.geometry.point`
///
/// Returns:
///  * A `hs.drawing.color` object
private func colorAt(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, unsafeBitCast(USERDATA_TAG, to: UnsafePointer<CChar>.self), LS_TTABLE, LS_TBREAK)

    let theImage = skin.luaObject(atIndex: 1, toClass: "NSImage") as! NSImage
    let point = skin.tableToPoint(atIndex: 2)

    var pixelColor: NSColor?
    autoreleasepool {
        let cgImage = theImage.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let rep = NSBitmapImageRep(cgImage: cgImage)
        let imageSize = theImage.size
        let bitmapSize = rep.size
        let xScale = bitmapSize.width / imageSize.width
        let yScale = bitmapSize.height / imageSize.height
        pixelColor = rep.colorAt(x: Int(point.x * xScale), y: Int(point.y * yScale))
    }

    skin.pushNSObject(pixelColor)
    return 1
}

/// hs.image:croppedCopy(rectangle) -> object
/// Method
/// Returns a copy of the portion of the image specified by the rectangle specified.
///
/// Parameters:
///  * rectangle - a table with 'x', 'y', 'h', and 'w' keys specifying the portion of the image to return in the new image.
///
/// Returns:
///  * a copy of the portion of the image specified
private func croppedCopy(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, unsafeBitCast(USERDATA_TAG, to: UnsafePointer<CChar>.self), LS_TTABLE, LS_TBREAK)
    let theImage = skin.luaObject(atIndex: 1, toClass: "NSImage") as! NSImage
    let frame = skin.tableToRect(atIndex: 2)

    // size changes may not actually affect representations until the image is composited
    let targetRect = NSRect(origin: .zero, size: theImage.size)
    let newImage = NSImage(size: targetRect.size)
    newImage.lockFocus()
    theImage.draw(in: targetRect, from: targetRect, operation: .copy, fraction: 1.0)
    newImage.unlockFocus()

    let keys = [kCGImageSourceShouldCache]
    let values = [kCFBooleanFalse as Any]
    let options = NSDictionary(objects: values, forKeys: keys as [NSCopying]) as CFDictionary
    let source = CGImageSourceCreateWithData(newImage.tiffRepresentation! as CFData, options)!
    let maskRef = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    // correct for retina displays
    let actualSize = NSSize(width: CGFloat(maskRef.width), height: CGFloat(maskRef.height))
    let xFactor = actualSize.width / newImage.size.width
    let yFactor = actualSize.height / newImage.size.height
    let correctedFrame = NSRect(
        x: frame.origin.x * xFactor,
        y: frame.origin.y * yFactor,
        width: frame.size.width * xFactor,
        height: frame.size.height * yFactor
    )
    let imageRef = maskRef.cropping(to: correctedFrame)!
    let cropped = NSImage(cgImage: imageRef, size: frame.size)

    skin.pushNSObject(cropped)
    return 1
}

// Helper to parse file type label and return NSBitmapImageFileType
private func parseFileType(_ label: String) -> NSBitmapImageRep.FileType? {
    switch label.lowercased() {
    case "png":  return .png
    case "tiff": return .tiff
    case "bmp":  return .bmp
    case "gif":  return .gif
    case "jpeg", "jpg": return .jpeg
    default: return nil
    }
}

/// hs.image:encodeAsURLString([scale], [type]) -> string
/// Method
/// Returns a bitmap representation of the image as a base64 encoded URL string
///
/// Parameters:
///  * scale - an optional boolean, default false, which indicates that the image size (which macOS represents as points) should be scaled to pixels.  For images that have Retina scale representations, this may result in an encoded image which is scaled down from the original source.
///  * type  - optional case-insensitive string parameter specifying the bitmap image type for the encoded string (default PNG)
///    * PNG  - save in Portable Network Graphics (PNG) format
///    * TIFF - save in Tagged Image File Format (TIFF) format
///    * BMP  - save in Windows bitmap image (BMP) format
///    * GIF  - save in Graphics Image Format (GIF) format
///    * JPEG - save in Joint Photographic Experts Group (JPEG) format
///
/// Returns:
///  * the bitmap image representation as a Base64 encoded string
///
/// Notes:
///  * You can convert the string back into an image object with [hs.image.imageFromURL](#URL), e.g. `hs.image.imageFromURL(string)`
private func encodeAsString(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, unsafeBitCast(USERDATA_TAG, to: UnsafePointer<CChar>.self), LS_TBREAK | LS_TVARARG)
    let theImage = skin.luaObject(atIndex: 1, toClass: "NSImage") as! NSImage

    var scaleToPixels = false
    var typeLabel = "png"

    if lua_gettop(L) == 2 {
        if lua_type(L, 2) == LUA_TBOOLEAN {
            scaleToPixels = lua_toboolean(L, 2) != 0
        } else if lua_type(L, 2) == LUA_TSTRING {
            typeLabel = skin.toNSObject(atIndex: 2) as! String
        }
    } else if lua_gettop(L) > 2 {
        scaleToPixels = lua_toboolean(L, 2) != 0
        typeLabel = skin.toNSObject(atIndex: 3) as! String
    }

    guard let fileType = parseFileType(typeLabel) else {
        return luaL_error(L, "invalid image type specified")
    }

    let targetRect = NSRect(origin: .zero, size: theImage.size)
    let newImage = NSImage(size: targetRect.size)
    newImage.lockFocus()
    theImage.draw(in: targetRect, from: targetRect, operation: .copy, fraction: 1.0)
    newImage.unlockFocus()

    let rep: NSBitmapImageRep
    if scaleToPixels {
        rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetRect.size.width),
            pixelsHigh: Int(targetRect.size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = targetRect.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        newImage.draw(in: targetRect, from: .zero, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
    } else {
        guard let tiffRep = newImage.tiffRepresentation else {
            return luaL_error(L, "Unable to write image file: Can't create internal representation")
        }
        guard let r = NSBitmapImageRep(data: tiffRep) else {
            return luaL_error(L, "Unable to write image file: Can't wrap internal representation")
        }
        rep = r
    }

    guard let fileData = rep.representation(using: fileType, properties: [:]) else {
        return luaL_error(L, "Unable to write image file: Can't convert internal representation")
    }

    let result = fileData.base64EncodedString(options: .endLineWithLineFeed)
    skin.pushNSObject("data:image/\(typeLabel.lowercased());base64,\(result)" as NSString)
    return 1
}

/// hs.image:saveToFile(filename, [scale], [filetype]) -> boolean
/// Method
/// Save the hs.image object as an image of type `filetype` to the specified filename.
///
/// Parameters:
///  * filename - the path and name of the file to save.
///  * scale    - an optional boolean, default false, which indicates that the image size (which macOS represents as points) should be scaled to pixels.  For images that have Retina scale representations, this may result in a saved image which is scaled down from the original source.
///  * filetype - optional case-insensitive string parameter specifying the file type to save (default PNG)
///    * PNG  - save in Portable Network Graphics (PNG) format
///    * TIFF - save in Tagged Image File Format (TIFF) format
///    * BMP  - save in Windows bitmap image (BMP) format
///    * GIF  - save in Graphics Image Format (GIF) format
///    * JPEG - save in Joint Photographic Experts Group (JPEG) format
///
/// Returns:
///  * Status - a boolean value indicating success (true) or failure (false)
///
/// Notes:
///  * Saves image at the size in points (or pixels, if `scale` is true) as reported by [hs.image:size()](#size) for the image object
private func saveToFile(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, unsafeBitCast(USERDATA_TAG, to: UnsafePointer<CChar>.self), LS_TSTRING, LS_TBREAK | LS_TVARARG)

    let theImage = skin.luaObject(atIndex: 1, toClass: "NSImage") as! NSImage
    let filePath = skin.toNSObject(atIndex: 2) as! String

    var scaleToPixels = false
    var typeLabel = "png"

    if lua_gettop(L) == 3 {
        if lua_type(L, 3) == LUA_TBOOLEAN {
            scaleToPixels = lua_toboolean(L, 3) != 0
        } else if lua_type(L, 3) == LUA_TSTRING {
            typeLabel = skin.toNSObject(atIndex: 3) as! String
        }
    } else if lua_gettop(L) > 3 {
        scaleToPixels = lua_toboolean(L, 3) != 0
        typeLabel = skin.toNSObject(atIndex: 4) as! String
    }

    guard let fileType = parseFileType(typeLabel) else {
        return luaL_error(L, "hs.image:saveToFile:: invalid file type specified")
    }

    let targetRect = NSRect(origin: .zero, size: theImage.size)
    let newImage = NSImage(size: targetRect.size)
    newImage.lockFocus()
    theImage.draw(in: targetRect, from: targetRect, operation: .copy, fraction: 1.0)
    newImage.unlockFocus()

    let rep: NSBitmapImageRep
    if scaleToPixels {
        rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetRect.size.width),
            pixelsHigh: Int(targetRect.size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = targetRect.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        newImage.draw(in: targetRect, from: .zero, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
    } else {
        guard let tiffRep = newImage.tiffRepresentation else {
            return luaL_error(L, "Unable to write image file: Can't create internal representation")
        }
        guard let r = NSBitmapImageRep(data: tiffRep) else {
            return luaL_error(L, "Unable to write image file: Can't wrap internal representation")
        }
        rep = r
    }

    guard let fileData = rep.representation(using: fileType, properties: [:]) else {
        return luaL_error(L, "Unable to write image file: Can't convert internal representation")
    }

    do {
        try fileData.write(to: URL(fileURLWithPath: (filePath as NSString).expandingTildeInPath), options: .atomic)
        lua_pushboolean(L, 1)
    } catch {
        return luaL_error(L, "Unable to write image file: %s", error.localizedDescription)
    }
    return 1
}

/// hs.image:template([state]) -> imageObject | boolean
/// Method
/// Get or set whether the image is considered a template image.
///
/// Parameters:
///  * `state` - an optional boolean specifying whether or not the image should be a template.
///
/// Returns:
///  * if a parameter is provided, returns the hs.image object; otherwise returns the current value
///
/// Notes:
///  * Template images consist of black and clear colors (and an alpha channel). Template images are not intended to be used as standalone images and are usually mixed with other content to create the desired final appearance.
///  * Images with this flag set to true usually appear lighter than they would with this flag set to false.
private func imageTemplate(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, unsafeBitCast(USERDATA_TAG, to: UnsafePointer<CChar>.self), LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let theImage = skin.luaObject(atIndex: 1, toClass: "NSImage") as! NSImage
    if lua_gettop(L) == 1 {
        lua_pushboolean(L, theImage.isTemplate ? 1 : 0)
    } else {
        theImage.isTemplate = lua_toboolean(L, 2) != 0
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.image:copy() -> imageObject
/// Method
/// Returns a copy of the image
///
/// Parameters:
///  * None
///
/// Returns:
///  * a new hs.image object
private func copyImage(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, unsafeBitCast(USERDATA_TAG, to: UnsafePointer<CChar>.self), LS_TBREAK)
    let theImage = skin.luaObject(atIndex: 1, toClass: "NSImage") as! NSImage
    skin.pushNSObject(theImage.copy() as! NSImage)
    return 1
}

/// hs.image:toASCII([width, height]) -> string
/// Method
/// Converts an image to an ASCII representation of the image in the form of a string.
///
/// Parameters:
///  * width - An optional width in pixels (defaults to image width if nothing supplied).
///  * height - An optional height in pixels (defaults to image height if nothing supplied).
///
/// Returns:
///  * A string.
private func toASCII(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, unsafeBitCast(USERDATA_TAG, to: UnsafePointer<CChar>.self), LS_TNUMBER | LS_TOPTIONAL, LS_TNUMBER | LS_TOPTIONAL, LS_TBREAK)

    let theImage = skin.luaObject(atIndex: 1, toClass: "NSImage") as! NSImage

    let width: Int = (skin.toNSObject(atIndex: 2) as? NSNumber)?.intValue ?? Int(theImage.size.width)
    let height: Int = (skin.toNSObject(atIndex: 3) as? NSNumber)?.intValue ?? Int(theImage.size.height)

    let result = theImage.asciiArt(width: width, height: height)
    skin.pushNSObject(result as NSString?)
    return 1
}

/// hs.image:bitmapRepresentation([size], [gray]) -> imageObject
/// Method
/// Creates a new bitmap representation of the image and returns it as a new hs.image object
///
/// Parameters:
///  * `size` - an optional table specifying the height and width the image should be scaled to in the bitmap. The size is specified as table with `h` and `w` keys set. Defaults to the size of the source image object.
///  * `gray` - an optional boolean, default false, specifying whether or not the bitmap should be converted to grayscale (true) or left as RGB color (false).
///
/// Returns:
///  * a new hs.image object
///
/// Notes:
///  * a bitmap representation of an image is rendered at the specific size specified (or inherited) when it is generated -- if you later scale it to a different size, the bitmap will be scaled as larger or smaller pixels rather than smoothly.
///
///  * this method may be useful when preparing images for other devices (e.g. `hs.streamdeck`).
private func image_bitmapRepresentation(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, unsafeBitCast(USERDATA_TAG, to: UnsafePointer<CChar>.self), LS_TBREAK | LS_TVARARG)
    let theImage = skin.luaObject(atIndex: 1, toClass: "NSImage") as! NSImage

    var bitmapSize = theImage.size
    var colorSpaceName: NSColorSpaceName = .calibratedRGB
    let bps: Int = 8
    var alpha = true
    var spp: Int = 4

    switch lua_gettop(L) {
    case 1:
        break
    case 2:
        if lua_type(L, 2) == LUA_TTABLE {
            bitmapSize = skin.tableToSize(atIndex: 2)
        } else if lua_type(L, 2) == LUA_TBOOLEAN {
            colorSpaceName = lua_toboolean(L, 2) != 0 ? .calibratedWhite : .calibratedRGB
        } else {
            fallthrough
        }
    default:
        skin.checkArgs(LS_TUSERDATA, unsafeBitCast(USERDATA_TAG, to: UnsafePointer<CChar>.self), LS_TTABLE, LS_TBOOLEAN, LS_TBREAK)
        bitmapSize = skin.tableToSize(atIndex: 2)
        colorSpaceName = lua_toboolean(L, 3) != 0 ? .calibratedWhite : .calibratedRGB
    }

    if colorSpaceName == .calibratedRGB {
        spp = 3 + (alpha ? 1 : 0)
    } else if colorSpaceName == .deviceCMYK {
        spp = 4 + (alpha ? 1 : 0)
    } else if colorSpaceName == .calibratedWhite {
        spp = 1 + (alpha ? 1 : 0)
    }

    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(bitmapSize.width),
        pixelsHigh: Int(bitmapSize.height),
        bitsPerSample: bps,
        samplesPerPixel: spp,
        hasAlpha: alpha,
        isPlanar: false,
        colorSpaceName: colorSpaceName,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = bitmapSize

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    theImage.draw(
        in: NSRect(origin: .zero, size: bitmapSize),
        from: NSRect(origin: .zero, size: theImage.size),
        operation: .copy, fraction: 1.0
    )
    NSGraphicsContext.restoreGraphicsState()

    let newImage = NSImage(size: bitmapSize)
    newImage.addRepresentation(rep)
    skin.pushNSObject(newImage)
    return 1
}

// MARK: - Conversion Extensions

// [skin pushNSObject:NSImage]
// Pushes the provided NSImage onto the Lua Stack as a hs.image userdata object
private func NSImage_tolua(_ L: OpaquePointer!, _ obj: Any!) -> Int32 {
    let theImage = obj as! NSImage
    theImage.cacheMode = .never
    let imagePtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
    imagePtr.assumingMemoryBound(to: UnsafeMutableRawPointer?.self).pointee = Unmanaged.passRetained(theImage).toOpaque()
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

private func HSImage_toNSImage(_ L: OpaquePointer!, _ idx: Int32) -> Any? {
    guard let ptr = luaL_testudata(L, idx, USERDATA_TAG) else { return nil }
    let raw = ptr.assumingMemoryBound(to: UnsafeMutableRawPointer?.self).pointee!
    return Unmanaged<NSImage>.fromOpaque(raw).takeUnretainedValue()
}

// MARK: - Hammerspoon/Lua Infrastructure

private func image_userdata_tostring(_ L: OpaquePointer!) -> Int32 {
    let testImage = LuaSkin.shared(withState: L)!.luaObject(atIndex: 1, toClass: "NSImage") as! NSImage
    let theName = testImage.name()?.rawValue ?? ""
    lua_pushstring(L, "\(USERDATA_TAG): \(theName) (\(String(describing: lua_topointer(L, 1))))")
    return 1
}

private func image_userdata_eq(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    let image1 = skin.luaObject(atIndex: 1, toClass: "NSImage") as! NSImage
    let image2 = skin.luaObject(atIndex: 2, toClass: "NSImage") as! NSImage
    lua_pushboolean(L, image1 === image2 ? 1 : 0)
    return 1
}

private func image_userdata_gc(_ L: OpaquePointer!) -> Int32 {
    let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    if let raw = ptr.pointee {
        let image = Unmanaged<NSImage>.fromOpaque(raw).takeRetainedValue()
        image.setName(nil) // remove from image cache
        image.recache()    // invalidate image rep caches
    }
    return 0
}

private func image_meta_gc(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    backgroundCallbacks.enumerateObjects { ref, _ in
        if let num = ref as? NSNumber {
            skin.luaUnref(refTable, ref: num.int32Value)
        }
    }
    backgroundCallbacks.removeAllObjects()
    return 0
}

// MARK: - C-callable wrappers

private let getImageName_wrapper: lua_CFunction = { L in getImageName(L) }
private let getImageSize_wrapper: lua_CFunction = { L in getImageSize(L) }
private let imageTemplate_wrapper: lua_CFunction = { L in imageTemplate(L) }
private let copyImage_wrapper: lua_CFunction = { L in copyImage(L) }
private let croppedCopy_wrapper: lua_CFunction = { L in croppedCopy(L) }
private let saveToFile_wrapper: lua_CFunction = { L in saveToFile(L) }
private let encodeAsString_wrapper: lua_CFunction = { L in encodeAsString(L) }
private let colorAt_wrapper: lua_CFunction = { L in colorAt(L) }
private let toASCII_wrapper: lua_CFunction = { L in toASCII(L) }
private let bitmapRep_wrapper: lua_CFunction = { L in image_bitmapRepresentation(L) }
private let image_tostring_wrapper: lua_CFunction = { L in image_userdata_tostring(L) }
private let image_eq_wrapper: lua_CFunction = { L in image_userdata_eq(L) }
private let image_gc_wrapper: lua_CFunction = { L in image_userdata_gc(L) }
private let imageFromPath_wrapper: lua_CFunction = { L in imageFromPath(L) }
private let imageFromURL_wrapper: lua_CFunction = { L in imageFromURL(L) }
private let imageFromASCII_wrapper: lua_CFunction = { L in imageWithContextFromASCII(L) }
private let imageFromName_wrapper: lua_CFunction = { L in imageFromName(L) }
private let imageFromApp_wrapper: lua_CFunction = { L in imageFromApp(L) }
private let imageFromMediaFile_wrapper: lua_CFunction = { L in imageFromMediaFile(L) }
private let imageForFiles_wrapper: lua_CFunction = { L in imageForFiles(L) }
private let imageForFileType_wrapper: lua_CFunction = { L in imageForFileType(L) }
private let getExifFromPath_wrapper: lua_CFunction = { L in getExifFromPath(L) }
private let meta_gc_wrapper: lua_CFunction = { L in image_meta_gc(L) }

// MARK: - Registration Tables

// Metatable for userdata objects
private var userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("name"), func: getImageName_wrapper),
    luaL_Reg(name: strdup("size"), func: getImageSize_wrapper),
    luaL_Reg(name: strdup("template"), func: imageTemplate_wrapper),
    luaL_Reg(name: strdup("copy"), func: copyImage_wrapper),
    luaL_Reg(name: strdup("croppedCopy"), func: croppedCopy_wrapper),
    luaL_Reg(name: strdup("saveToFile"), func: saveToFile_wrapper),
    luaL_Reg(name: strdup("encodeAsURLString"), func: encodeAsString_wrapper),
    luaL_Reg(name: strdup("colorAt"), func: colorAt_wrapper),
    luaL_Reg(name: strdup("toASCII"), func: toASCII_wrapper),
    luaL_Reg(name: strdup("bitmapRepresentation"), func: bitmapRep_wrapper),
    luaL_Reg(name: strdup("__tostring"), func: image_tostring_wrapper),
    luaL_Reg(name: strdup("__eq"), func: image_eq_wrapper),
    luaL_Reg(name: strdup("__gc"), func: image_gc_wrapper),
    luaL_Reg(name: nil, func: nil),
]

// Functions for returned object when module loads
private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("imageFromPath"), func: imageFromPath_wrapper),
    luaL_Reg(name: strdup("imageFromURL"), func: imageFromURL_wrapper),
    luaL_Reg(name: strdup("imageFromASCII"), func: imageFromASCII_wrapper),
    luaL_Reg(name: strdup("imageFromName"), func: imageFromName_wrapper),
    luaL_Reg(name: strdup("imageFromAppBundle"), func: imageFromApp_wrapper),
    luaL_Reg(name: strdup("imageFromMediaFile"), func: imageFromMediaFile_wrapper),
    luaL_Reg(name: strdup("iconForFile"), func: imageForFiles_wrapper),
    luaL_Reg(name: strdup("iconForFileType"), func: imageForFileType_wrapper),
    luaL_Reg(name: strdup("getExifFromPath"), func: getExifFromPath_wrapper),
    luaL_Reg(name: nil, func: nil),
]

// Metatable for module
private var module_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: meta_gc_wrapper),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libimage")
public func luaopen_hs_libimage(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    refTable = skin.registerLibrary(withObject: USERDATA_TAG,
                                     functions: &moduleLib,
                                     metaFunctions: &module_metaLib,
                                     objectFunctions: &userdata_metaLib)

    pushNSImageNameTable(L); lua_setfield(L, -2, "systemImageNames")
    additionalImages(L);     lua_setfield(L, -2, "additionalImageNames")

    skin.registerPushNSHelper(NSImage_tolua, forClass: "NSImage")
    skin.registerLuaObjectHelper(HSImage_toNSImage, forClass: "NSImage", withUserdataMapping: USERDATA_TAG)

    if missingIconForFile == nil { missingIconForFile = NSWorkspace.shared.icon(forFile: "") }

    backgroundCallbacks = NSMutableSet()
    return 1
}
