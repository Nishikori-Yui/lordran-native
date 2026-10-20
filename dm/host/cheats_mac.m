#import "cheats_mac.h"
#import <QuartzCore/QuartzCore.h>
#include "cheats.h"
#include <stdlib.h>
#include <string.h>

@interface DmCheatPanel : NSPanel
@end
@implementation DmCheatPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end
@interface DmMacCheats () <NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate>
@end
@implementation DmMacCheats {
    __weak NSWindow *_gameWindow;
    NSTableView *_table;
    NSScrollView *_scroll;
    NSMenuItem *_showItem;
    NSMutableArray<NSMenuItem *> *_items;
    NSTextField *_empty;
}

- (NSColor *)accentColor {
    return [NSColor colorWithRed:0.45 green:1.0 blue:0.16 alpha:1.0];
}
- (BOOL)usesChinese {
    const char *language = getenv("DM_LANG");
    return language && !strncasecmp(language, "zh", 2);
}
- (NSString *)text:(NSString *)english chinese:(NSString *)chinese {
    return [self usesChinese] ? chinese : english;
}

- (instancetype)initWithWindow:(NSWindow *)window {
    if (!(self = [super init])) return nil;
    _gameWindow = window;
    _items = [NSMutableArray new];
    _panel = [[DmCheatPanel alloc] initWithContentRect:NSMakeRect(0, 0, 460, 400)
                                          styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                            backing:NSBackingStoreBuffered defer:NO];
    _panel.title = @"Cheats";
    _panel.opaque = NO; _panel.backgroundColor = NSColor.clearColor;
    _panel.hasShadow = NO; _panel.hidesOnDeactivate = YES; _panel.releasedWhenClosed = NO;
    _panel.movableByWindowBackground = YES;
    _panel.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorIgnoresCycle;
    NSView *surface = [NSView new];
    surface.wantsLayer = YES; surface.layer.backgroundColor = NSColor.clearColor.CGColor;
    _panel.contentView = surface;
    NSTextField *title = [NSTextField labelWithString:[self text:@"Cheats" chinese:@"金手指"]];
    title.font = [NSFont systemFontOfSize:18 weight:NSFontWeightBold];
    title.textColor = [self accentColor];
    NSTextField *hint = [NSTextField labelWithString:[self text:@"F7 Previous   F8 Next   F9 Toggle   F6 Close"
                                                          chinese:@"F7 上一个   F8 下一个   F9 开关   F6 关闭"]];
    hint.font = [NSFont systemFontOfSize:12]; hint.textColor = NSColor.secondaryLabelColor;
    NSTextField *warning = [NSTextField wrappingLabelWithString:[self text:@"Keep cheats off before entering the game. Enable them after gameplay starts."
                                                               chinese:@"进入游戏前请保持关闭，进入游戏后再开启。"]];
    warning.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold]; warning.textColor = [self accentColor];
    _scroll = [NSScrollView new];
    _scroll.hasVerticalScroller = YES; _scroll.drawsBackground = NO;
    _scroll.scrollerStyle = NSScrollerStyleOverlay;
    _table = [NSTableView new];
    _table.dataSource = self; _table.delegate = self;
    _table.rowHeight = 32; _table.allowsEmptySelection = NO;
    _table.headerView = nil; _table.backgroundColor = NSColor.clearColor;
    _table.gridStyleMask = NSTableViewGridNone; _table.intercellSpacing = NSMakeSize(0, 2);
    _table.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    _table.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    _table.allowsColumnResizing = NO; _table.allowsColumnReordering = NO;
    NSTableColumn *row = [[NSTableColumn alloc] initWithIdentifier:@"row"];
    row.width = 420; [row setResizingMask:NSTableColumnAutoresizingMask];
    [_table addTableColumn:row];
    _scroll.documentView = _table;
    _empty = [NSTextField wrappingLabelWithString:[self text:@"No switchable cheats are included in this build."
                                                       chinese:@"此版本未包含可即时切换的金手指。"]];
    _empty.font = [NSFont systemFontOfSize:12]; _empty.hidden = dm_cheat_count() != 0;
    for (NSView *view in @[title, hint, warning, _scroll, _empty]) {
        view.translatesAutoresizingMaskIntoConstraints = NO; [surface addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:surface.leadingAnchor constant:14],
        [title.topAnchor constraintEqualToAnchor:surface.topAnchor constant:12],
        [hint.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [hint.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:6],
        [warning.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [warning.trailingAnchor constraintEqualToAnchor:_scroll.trailingAnchor],
        [warning.topAnchor constraintEqualToAnchor:hint.bottomAnchor constant:8],
        [_scroll.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:surface.trailingAnchor constant:-14],
        [_scroll.topAnchor constraintEqualToAnchor:warning.bottomAnchor constant:10],
        [_scroll.bottomAnchor constraintEqualToAnchor:surface.bottomAnchor constant:-12],
        [_empty.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [_empty.trailingAnchor constraintEqualToAnchor:_scroll.trailingAnchor],
        [_empty.topAnchor constraintEqualToAnchor:_scroll.topAnchor constant:28]
    ]];
    [self installMenu];
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    for (NSNotificationName event in @[NSWindowDidResizeNotification, NSWindowDidMiniaturizeNotification, NSWindowDidDeminiaturizeNotification])
        [nc addObserver:self selector:@selector(updatePanel:) name:event object:window];
    [nc addObserver:self selector:@selector(parentClosed:) name:NSWindowWillCloseNotification object:window];
    [nc addObserver:self selector:@selector(updatePanel:) name:NSApplicationDidBecomeActiveNotification object:NSApp];
    return self;
}
- (NSInteger)selectedIndex { return _table.selectedRow; }
- (void)installMenu {
    if (!NSApp.mainMenu) {
        NSMenu *main = [NSMenu new];
        NSMenuItem *app = [NSMenuItem new]; app.submenu = [NSMenu new];
        [app.submenu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
        [main addItem:app]; NSApp.mainMenu = main;
    }
    NSString *cheatsTitle = [self text:@"Cheats" chinese:@"金手指"];
    NSMenuItem *root = [[NSMenuItem alloc] initWithTitle:cheatsTitle action:nil keyEquivalent:@""];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:cheatsTitle]; menu.delegate = self; root.submenu = menu;
    _showItem = [[NSMenuItem alloc] initWithTitle:[self text:@"Show Cheats" chinese:@"显示金手指"] action:@selector(toggleMenu:)
                                 keyEquivalent:[NSString stringWithFormat:@"%C", (unichar)NSF6FunctionKey]];
    _showItem.keyEquivalentModifierMask = 0; _showItem.target = self;
    [menu addItem:_showItem]; [menu addItem:NSMenuItem.separatorItem];
    for (unsigned i = 0; i < dm_cheat_count(); i++) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@(dm_cheat_name(i)) action:@selector(toggleNamedCheat:) keyEquivalent:@""];
        item.tag = i; item.target = self; [menu addItem:item]; [_items addObject:item];
    }
    if (!dm_cheat_count()) [menu addItemWithTitle:@"No switchable cheats in this build" action:nil keyEquivalent:@""];
    [NSApp.mainMenu addItem:root];
}
- (void)menuNeedsUpdate:(NSMenu *)menu {
    (void)menu;
    _showItem.state = _visible ? NSControlStateValueOn : NSControlStateValueOff;
    for (NSMenuItem *item in _items) item.state = dm_cheat_enabled((unsigned)item.tag) ? NSControlStateValueOn : NSControlStateValueOff;
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { (void)tableView; return dm_cheat_count(); }
- (void)reloadCheats {
    NSInteger selected = _table.selectedRow;
    [_table reloadData];
    if (selected >= 0 && (unsigned)selected < dm_cheat_count())
        [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)selected] byExtendingSelection:NO];
}
- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    (void)tableView;
    NSString *name = @(dm_cheat_name((unsigned)row));
    (void)column;
    NSTableCellView *cell = [NSTableCellView new];
    cell.identifier = @"cheat-row";
    NSTextField *label = [NSTextField labelWithString:name];
    label.font = [NSFont systemFontOfSize:14 weight:NSFontWeightMedium];
    label.textColor = row == _table.selectedRow ? [self accentColor] : NSColor.labelColor;
    label.lineBreakMode = NSLineBreakByTruncatingTail; label.toolTip = name;
    NSTextField *state = [NSTextField labelWithString:dm_cheat_enabled((unsigned)row) ? @"●" : @"○"];
    state.alignment = NSTextAlignmentCenter; state.font = [NSFont systemFontOfSize:14 weight:NSFontWeightBold];
    state.textColor = dm_cheat_enabled((unsigned)row) ? [self accentColor] : NSColor.secondaryLabelColor;
    state.accessibilityLabel = name;
    state.accessibilityValue = dm_cheat_enabled((unsigned)row) ? @"Enabled" : @"Disabled";
    for (NSView *view in @[label, state]) { view.translatesAutoresizingMaskIntoConstraints = NO; [cell addSubview:view]; }
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:10],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:state.leadingAnchor constant:-8],
        [label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        [state.widthAnchor constraintEqualToConstant:32],
        [state.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-20],
        [state.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor]
    ]];
    return cell;
}
- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    (void)notification;
    if (dm_cheat_count())
        [_table reloadDataForRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, dm_cheat_count())]
                          columnIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, _table.numberOfColumns)]];
}
- (void)toggleNamedCheat:(id)sender {
    unsigned index = (unsigned)[sender tag];
    dm_cheat_set(index, !dm_cheat_enabled(index));
    [self reloadCheats];
}
- (void)toggleMenu:(id)sender {
    (void)sender; _visible = !_visible;
    if (_visible) {
        _empty.hidden = dm_cheat_count() != 0;
        [self reloadCheats];
        if (dm_cheat_count() && _table.selectedRow < 0) [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    }
    [self updatePanel:nil];
}
- (void)updatePanel:(NSNotification *)notification {
    (void)notification;
    _showItem.state = _visible ? NSControlStateValueOn : NSControlStateValueOff;
    NSWindow *window = _gameWindow;
    if (!_visible || !window.visible || window.miniaturized || !NSApp.active) { [_panel orderOut:nil]; return; }
    NSRect area = [window convertRectToScreen:window.contentView.bounds];
    const CGFloat width = fmin(460, fmax(1, area.size.width - 24));
    const CGFloat minimumHeight = fmin(150, fmax(1, area.size.height - 16));
    const CGFloat topReserve = fmin(124, fmax(0, area.size.height - minimumHeight - 16));
    const CGFloat availableHeight = fmax(minimumHeight, area.size.height - topReserve - 16);
    CGFloat height = fmin(fmax(minimumHeight, 100 + dm_cheat_count() * 34), availableHeight);
    [_panel setContentSize:NSMakeSize(width, height)];
    CGFloat x = fmax(area.origin.x + 12, NSMaxX(area) - width - 12);
    CGFloat y = fmax(area.origin.y + 8, NSMaxY(area) - height - topReserve);
    [_panel.contentView layoutSubtreeIfNeeded];
    CGFloat tableWidth = NSWidth(_scroll.contentView.bounds);
    CGFloat tableHeight = fmax(NSHeight(_scroll.contentView.bounds),
                               dm_cheat_count() * (_table.rowHeight + _table.intercellSpacing.height));
    _table.frame = NSMakeRect(0, 0, tableWidth, tableHeight);
    [_table sizeLastColumnToFit];
    [_panel setFrameOrigin:NSMakePoint(x, y)];
    if (_panel.parentWindow != window) [window addChildWindow:_panel ordered:NSWindowAbove];
    [_panel orderFront:nil];
}
- (BOOL)handleKeyEvent:(NSEvent *)event {
    NSEventModifierFlags shortcuts = NSEventModifierFlagCommand | NSEventModifierFlagControl |
                                     NSEventModifierFlagOption | NSEventModifierFlagShift;
    if (event.modifierFlags & shortcuts) return NO;
    unsigned short code = event.keyCode;
    if (code != 97 && (!_visible || (code != 98 && code != 100 && code != 101))) return NO;
    if (event.type != NSEventTypeKeyDown) return YES;
    if (code == 97) { if (!event.isARepeat) [self toggleMenu:nil]; return YES; }
    unsigned count = dm_cheat_count();
    if (!count) return YES;
    NSInteger row = MAX(0, _table.selectedRow);
    if (code == 98 || code == 100) {
        row = (row + count + (code == 98 ? -1 : 1)) % count;
        [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
        [_table scrollRowToVisible:row];
    } else if (!event.isARepeat) {
        dm_cheat_set((unsigned)row, !dm_cheat_enabled((unsigned)row));
        [self reloadCheats];
    }
    return YES;
}
- (void)parentClosed:(NSNotification *)notification {
    (void)notification; _visible = NO;
    [_gameWindow removeChildWindow:_panel]; [_panel orderOut:nil]; _gameWindow = nil;
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_gameWindow removeChildWindow:_panel]; [_panel orderOut:nil];
}
@end
