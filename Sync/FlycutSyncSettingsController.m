#import "FlycutSyncSettingsController.h"

static NSString * const ConfigurationKey = @"archiveSyncConfiguration";

@implementation FlycutSyncSettingsController {
    FlycutSyncController *_controller;
    NSPopUpButton *_backend;
    NSTextField *_folder;
    NSTextField *_url;
    NSTextField *_collection;
    NSTextField *_credentials;
    NSTextField *_container;
    NSData *_folderBookmark;
    NSData *_credentialBookmark;
    NSButton *_chooseFolder;
    NSButton *_chooseCredentials;
    NSButton *_share;
    NSButton *_tailnet;
    NSButton *_apply;
    NSButton *_sync;
    NSButton *_reset;
    NSTextField *_status;
    NSProgressIndicator *_progress;
    NSTextField *_instructions;
}

+ (id<FlycutSyncTransport>)transportForConfiguration:(NSMutableDictionary *)configuration error:(NSError **)error {
    NSString *backend = configuration[@"backend"];
    if ([backend isEqual:@"folder"]) {
        NSData *refreshed = nil;
        NSURL *url = FlycutSyncResolveFileURL(configuration[@"folder"] ?: @"", configuration[@"folderBookmark"], NO, &refreshed, error);
        if (refreshed) configuration[@"folderBookmark"] = refreshed;
        return url ? [[FlycutFolderSync alloc] initWithDirectoryURL:url] : nil;
    }
    if ([backend isEqual:@"server"]) {
        NSData *refreshed = nil;
        NSURL *url = FlycutSyncResolveFileURL(configuration[@"credentials"] ?: @"", configuration[@"credentialBookmark"], YES, &refreshed, error);
        if (refreshed) configuration[@"credentialBookmark"] = refreshed;
        return url ? [[FlycutServerSync alloc] initWithURL:[NSURL URLWithString:configuration[@"url"] ?: @""] collectionID:configuration[@"collection"] ?: @"" credentialFileURL:url securedTailnetHTTP:[configuration[@"securedTailnetHTTP"] boolValue]] : nil;
    }
#if FLYCUT_CLOUDKIT
    if ([backend isEqual:@"cloudkit"])
        return [[FlycutCloudKitSync alloc] initWithContainerIdentifier:configuration[@"container"] ?: @""];
#endif
    return nil;
}

+ (void)restoreSyncForController:(FlycutSyncController *)controller {
    NSMutableDictionary *configuration = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:ConfigurationKey] mutableCopy];
    NSError *error = nil;
    id<FlycutSyncTransport> transport = [self transportForConfiguration:configuration error:&error];
    if (error) [controller failConfiguration:error];
    else if (transport) [controller configureTransport:transport sharingExistingEvents:NO completion:^(NSError *failure) {
        if (!failure) [[NSUserDefaults standardUserDefaults] setObject:configuration forKey:ConfigurationKey];
    }];
}

- (NSTextField *)label:(NSString *)text frame:(NSRect)frame {
    NSTextField *label = [NSTextField labelWithString:text];
    label.frame = frame;
    label.font = [NSFont systemFontOfSize:13];
    [self.window.contentView addSubview:label];
    return label;
}

- (NSTextField *)field:(NSString *)title placeholder:(NSString *)placeholder y:(CGFloat)y {
    NSTextField *label = [self label:title frame:NSMakeRect(24, y + 3, 130, 20)];
    label.identifier = title;
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(158, y, 418, 25)];
    field.placeholderString = placeholder;
    field.font = [NSFont systemFontOfSize:13];
    field.accessibilityLabel = title;
    field.identifier = title;
    [self.window.contentView addSubview:field];
    return field;
}

- (NSButton *)button:(NSString *)title action:(SEL)action frame:(NSRect)frame {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.frame = frame;
    button.bezelStyle = NSBezelStyleRounded;
    [self.window.contentView addSubview:button];
    return button;
}

- (instancetype)initWithSyncController:(FlycutSyncController *)controller {
    CGFloat cloudRow = FLYCUT_CLOUDKIT ? 40 : 0;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 600, 550 + cloudRow) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    if ((self = [super initWithWindow:window])) {
        _controller = controller;
        window.title = @"History Sync";
        window.releasedWhenClosed = NO;
        [window center];
        [self label:@"Sync is optional. Only one backend is active at a time." frame:NSMakeRect(24, 506 + cloudRow, 552, 22)];
        [self label:@"Backend" frame:NSMakeRect(24, 468 + cloudRow, 130, 20)];
        _backend = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(158, 463 + cloudRow, 250, 28) pullsDown:NO];
        [_backend addItemsWithTitles:@[@"Off", @"Folder", @"Server"]];
#if FLYCUT_CLOUDKIT
        [_backend addItemWithTitle:@"CloudKit"];
#endif
        _backend.target = self;
        _backend.action = @selector(backendChanged:);
        _backend.accessibilityLabel = @"Sync backend";
        [window.contentView addSubview:_backend];
        _folder = [self field:@"Folder" placeholder:@"Choose an existing sync folder" y:420 + cloudRow];
        _chooseFolder = [self button:@"Choose..." action:@selector(chooseFolder:) frame:NSMakeRect(478, 384 + cloudRow, 98, 28)];
        _url = [self field:@"Server URL" placeholder:@"https://sync.example.com" y:342 + cloudRow];
        _collection = [self field:@"Collection UUID" placeholder:@"Server's authorized collection UUID" y:304 + cloudRow];
        _credentials = [self field:@"Credential file" placeholder:@"/path/to/.env (FLYCUT_SYNC_TOKEN=...)" y:266 + cloudRow];
        _chooseCredentials = [self button:@"Choose..." action:@selector(chooseCredentials:) frame:NSMakeRect(478, 230 + cloudRow, 98, 28)];
        _container = [self field:@"iCloud container" placeholder:@"iCloud.net.nowaker.flycut" y:188 + cloudRow];
        _tailnet = [NSButton checkboxWithTitle:@"Allow HTTP to a secured tailnet IP (100.64.0.0/10 only)" target:nil action:nil];
        _tailnet.frame = NSMakeRect(24, 193, 552, 24);
        [window.contentView addSubview:_tailnet];
        _share = [NSButton checkboxWithTitle:@"Share all existing local history with the selected collection" target:nil action:nil];
        _share.frame = NSMakeRect(24, 164, 552, 24);
        [window.contentView addSubview:_share];
        _instructions = [self label:@"" frame:NSMakeRect(24, 100, 552, 56)];
        _instructions.maximumNumberOfLines = 3;
        _instructions.lineBreakMode = NSLineBreakByWordWrapping;
        _instructions.textColor = NSColor.secondaryLabelColor;
        _progress = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(24, 74, 16, 16)];
        _progress.style = NSProgressIndicatorStyleSpinning;
        _progress.displayedWhenStopped = NO;
        [window.contentView addSubview:_progress];
        _status = [self label:controller.status frame:NSMakeRect(46, 72, 530, 20)];
        _status.selectable = YES;
        _status.lineBreakMode = NSLineBreakByTruncatingTail;
        _apply = [self button:@"Apply" action:@selector(apply:) frame:NSMakeRect(478, 24, 98, 30)];
        _apply.keyEquivalent = @"\r";
        _sync = [self button:@"Sync Now" action:@selector(syncNow:) frame:NSMakeRect(24, 24, 100, 30)];
        _reset = [self button:@"Replay Events..." action:@selector(reset:) frame:NSMakeRect(136, 24, 142, 30)];
        NSDictionary *configuration = [[NSUserDefaults standardUserDefaults] dictionaryForKey:ConfigurationKey];
        NSString *backend = configuration[@"backend"];
        NSInteger index = [@[@"off", @"folder", @"server", @"cloudkit"] indexOfObject:backend ?: @"off"];
        [_backend selectItemAtIndex:index >= 0 && index < _backend.numberOfItems ? index : 0];
        _folder.stringValue = configuration[@"folder"] ?: @"";
        _url.stringValue = configuration[@"url"] ?: @"";
        _collection.stringValue = configuration[@"collection"] ?: @"";
        _credentials.stringValue = configuration[@"credentials"] ?: @"";
        _folderBookmark = configuration[@"folderBookmark"];
        _credentialBookmark = configuration[@"credentialBookmark"];
        _container.stringValue = configuration[@"container"] ?: @FLYCUT_ICLOUD_CONTAINER;
        _tailnet.state = [configuration[@"securedTailnetHTTP"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(statusChanged:) name:FlycutSyncStatusDidChangeNotification object:controller];
        [self backendChanged:nil];
        [self statusChanged:nil];
    }
    return self;
}

- (void)backendChanged:(id)sender {
    NSInteger index = _backend.indexOfSelectedItem;
    _folder.enabled = index == 1;
    _url.enabled = _collection.enabled = _credentials.enabled = index == 2;
    _container.enabled = index == 3;
    _container.hidden = !FLYCUT_CLOUDKIT;
    for (NSView *view in self.window.contentView.subviews) {
        if ([view.identifier isEqual:@"iCloud container"]) view.hidden = !FLYCUT_CLOUDKIT;
    }
    _tailnet.enabled = index == 2;
    _share.enabled = index > 0;
    _chooseFolder.enabled = _folder.enabled && !_controller.busy;
    _chooseCredentials.enabled = _credentials.enabled && !_controller.busy;
    for (NSTextField *field in @[_folder, _url, _collection, _credentials, _container]) {
        for (NSView *view in self.window.contentView.subviews) {
            if ([view isKindOfClass:NSTextField.class] && ![(NSTextField *)view isEditable] && [view.identifier isEqual:field.identifier])
                [(NSTextField *)view setTextColor:field.enabled ? NSColor.labelColor : NSColor.disabledControlTextColor];
        }
    }
    _instructions.stringValue = index == 1 ? @"Events are immutable files. Existing folder collections require an explicit sharing choice; symlinks are rejected." :
        index == 2 ? @"Credentials stay in the selected .env file, never preferences. Use FLYCUT_SYNC_TOKEN without quotes. HTTP is limited to loopback or explicitly allowed tailnet IPs; use HTTPS elsewhere." :
        index == 3 ? @"Uses a private iCloud zone. Your signed app must be provisioned for this exact container. Apple account access is required." : @"History stays local. Disabling sync does not erase events already shared with a backend.";
}

- (void)chooseFolder:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSModalResponseOK) {
            NSError *error = nil;
            self->_folderBookmark = [panel.URL bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope includingResourceValuesForKeys:nil relativeToURL:nil error:&error];
            if (!self->_folderBookmark && FlycutSyncIsSandboxed()) [self->_controller failConfiguration:error];
            else self->_folder.stringValue = panel.URL.path;
        }
    }];
}

- (void)chooseCredentials:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = NO;
    panel.showsHiddenFiles = YES;
    panel.allowsMultipleSelection = NO;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSModalResponseOK) {
            NSError *error = nil;
            self->_credentialBookmark = [panel.URL bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope | NSURLBookmarkCreationSecurityScopeAllowOnlyReadAccess includingResourceValuesForKeys:nil relativeToURL:nil error:&error];
            if (!self->_credentialBookmark && FlycutSyncIsSandboxed()) [self->_controller failConfiguration:error];
            else self->_credentials.stringValue = panel.URL.path;
        }
    }];
}

- (void)apply:(id)sender {
    NSArray *names = @[@"off", @"folder", @"server", @"cloudkit"];
    NSString *backend = names[_backend.indexOfSelectedItem];
    if ([backend isEqual:@"off"]) {
        [_controller stop];
        [[NSUserDefaults standardUserDefaults] setObject:@{@"backend":@"off"} forKey:ConfigurationKey];
        return;
    }
    NSMutableDictionary *configuration = [@{@"backend":backend, @"folder":_folder.stringValue, @"url":_url.stringValue, @"collection":_collection.stringValue,
        @"credentials":_credentials.stringValue, @"container":_container.stringValue, @"securedTailnetHTTP":@(_tailnet.state == NSControlStateValueOn)} mutableCopy];
    if (_folderBookmark) configuration[@"folderBookmark"] = _folderBookmark;
    if (_credentialBookmark) configuration[@"credentialBookmark"] = _credentialBookmark;
    NSError *error = nil;
    id<FlycutSyncTransport> transport = [[self class] transportForConfiguration:configuration error:&error];
    if (error) { [_controller failConfiguration:error]; return; }
    [_controller configureTransport:transport sharingExistingEvents:_share.state == NSControlStateValueOn completion:^(NSError *error) {
        if (!error) {
            [[NSUserDefaults standardUserDefaults] setObject:configuration forKey:ConfigurationKey];
            self->_share.state = NSControlStateValueOff;
        }
    }];
}

- (void)syncNow:(id)sender { [_controller synchronize]; }

- (void)reset:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Replay all retained sync events?";
    alert.informativeText = @"Only this backend's checkpoints are reset. History, favorites, and tombstones remain intact; equivalent immutable events are safe to replay.";
    [alert addButtonWithTitle:@"Replay Events"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) [self->_controller resetCheckpoint];
    }];
}

- (void)statusChanged:(NSNotification *)notification {
    _status.stringValue = _controller.status;
    _status.toolTip = _controller.status;
    _sync.enabled = _reset.enabled = !_controller.busy && _controller.connected;
    _apply.enabled = !_controller.busy;
    if (_controller.busy) [_progress startAnimation:nil]; else [_progress stopAnimation:nil];
    [self backendChanged:nil];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
@end
