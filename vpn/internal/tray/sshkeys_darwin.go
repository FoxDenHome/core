package tray

/*
#cgo CFLAGS: -x objective-c
#cgo LDFLAGS: -framework Cocoa
#include <stdlib.h>
#import <Cocoa/Cocoa.h>

typedef struct {
	int ok;
	char *text;
} foxdenSSHKeysResult;

// foxdenKeysView is a scrolling, plain-text, monospaced text view: keys must
// not get smart quotes or dashes.
static NSScrollView *foxdenKeysView(NSRect frame, NSString *text, BOOL editable) {
	NSScrollView *scroll = [NSTextView scrollableTextView];
	scroll.frame = frame;
	scroll.borderType = NSBezelBorder;
	NSTextView *view = scroll.documentView;
	view.richText = NO;
	view.editable = editable;
	view.selectable = YES;
	view.automaticQuoteSubstitutionEnabled = NO;
	view.automaticDashSubstitutionEnabled = NO;
	view.automaticTextReplacementEnabled = NO;
	view.automaticSpellingCorrectionEnabled = NO;
	view.continuousSpellCheckingEnabled = NO;
	view.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
	view.string = text;
	if (!editable)
		view.textColor = NSColor.secondaryLabelColor;
	return scroll;
}

// foxdenSSHKeysForm runs the dialog as a modal alert on the main thread:
// the reference keys above, the file to edit below.
static foxdenSSHKeysResult foxdenSSHKeysForm(const char *title, const char *message, const char *error,
	const char *reference, const char *path, const char *text, int readOnly) {
	__block foxdenSSHKeysResult r = {0};
	dispatch_sync(dispatch_get_main_queue(), ^{ @autoreleasepool {
		NSAlert *alert = [[[NSAlert alloc] init] autorelease];
		alert.messageText = [NSString stringWithUTF8String:title];
		NSString *info = [NSString stringWithUTF8String:message];
		if (error[0]) {
			alert.alertStyle = NSAlertStyleWarning;
			info = [NSString stringWithFormat:@"%@\n\n%@", [NSString stringWithUTF8String:error], info];
		}
		alert.informativeText = info;
		if (!readOnly)
			[alert addButtonWithTitle:@"Save"];
		[alert addButtonWithTitle:readOnly ? @"Close" : @"Cancel"];

		const CGFloat width = 640, refHeight = 120, fileHeight = 220, label = 20, gap = 8;
		const CGFloat height = label + refHeight + gap + label + fileHeight;
		NSView *box = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)] autorelease];
		NSTextField *refLabel = [NSTextField labelWithString:@"For reference, not changed here:"];
		refLabel.frame = NSMakeRect(0, height - label, width, label - 4);
		[box addSubview:refLabel];
		[box addSubview:foxdenKeysView(NSMakeRect(0, fileHeight + label + gap, width, refHeight),
			[NSString stringWithUTF8String:reference], NO)];
		NSTextField *fileLabel = [NSTextField labelWithString:[NSString stringWithUTF8String:path]];
		fileLabel.frame = NSMakeRect(0, fileHeight, width, label - 4);
		fileLabel.font = [NSFont boldSystemFontOfSize:0];
		[box addSubview:fileLabel];
		NSScrollView *file = foxdenKeysView(NSMakeRect(0, 0, width, fileHeight),
			[NSString stringWithUTF8String:text], !readOnly);
		[box addSubview:file];

		alert.accessoryView = box;
		[alert layout];
		alert.window.initialFirstResponder = file.documentView;
		[NSApp activateIgnoringOtherApps:YES];
		NSModalResponse response = [alert runModal];
		r.ok = !readOnly && response == NSAlertFirstButtonReturn;
		NSString *s = ((NSTextView *)file.documentView).string;
		r.text = strdup(s.UTF8String ? s.UTF8String : "");
	}});
	return r;
}
*/
import "C"

import "unsafe"

// showSSHKeysForm shows the dialog as a native alert, with the file as text.
// ok is false if it was cancelled.
func showSSHKeysForm(f sshKeysForm) (sshKeysAnswer, bool, error) {
	cs := func(s string) *C.char { return C.CString(s) }
	message := f.Message
	if f.ReadOnly != "" {
		message += "\n\n" + f.Path + ": " + f.ReadOnly
	}
	args := []*C.char{cs(f.Title), cs(message), cs(f.Error), cs(f.reference()), cs(f.Path), cs(f.Text)}
	defer func() {
		for _, a := range args {
			C.free(unsafe.Pointer(a))
		}
	}()
	readOnly := C.int(0)
	if f.ReadOnly != "" {
		readOnly = 1
	}
	r := C.foxdenSSHKeysForm(args[0], args[1], args[2], args[3], args[4], args[5], readOnly)
	defer C.free(unsafe.Pointer(r.text))
	text := C.GoString(r.text)
	a := sshKeysAnswer{OK: r.ok != 0, Text: &text}
	return a, a.OK, nil
}
