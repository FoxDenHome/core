package tray

/*
#cgo CFLAGS: -x objective-c
#cgo LDFLAGS: -framework Cocoa
#include <stdlib.h>
#import <Cocoa/Cocoa.h>

// FoxdenExposeMode enables the field that goes with the chosen kind.
@interface FoxdenExposeMode : NSObject
@property (assign) NSSegmentedControl *mode;
@property (assign) NSTextField *name, *port;
- (void)changed:(id)sender;
@end

@implementation FoxdenExposeMode
- (void)changed:(id)sender {
	BOOL tcp = self.mode.selectedSegment == 1;
	self.name.enabled = !tcp;
	self.port.enabled = tcp;
}
@end

typedef struct {
	int ok, tcp;
	char *target, *name, *port;
} foxdenExposeResult;

static NSString *foxdenString(const char *s) {
	return [NSString stringWithUTF8String:s];
}

static char *foxdenCString(NSString *s) {
	return strdup(s.UTF8String ? s.UTF8String : "");
}

static NSTextField *foxdenLabel(NSString *s) {
	NSTextField *l = [NSTextField labelWithString:s];
	l.alignment = NSTextAlignmentRight;
	return l;
}

// foxdenExposeForm runs the form as a modal alert on the main thread.
static foxdenExposeResult foxdenExposeForm(const char *title, const char *message, const char *error,
	const char *target, int tcp, const char *name, const char *port, const char *domain) {
	__block foxdenExposeResult r = {0};
	dispatch_sync(dispatch_get_main_queue(), ^{ @autoreleasepool {
		NSAlert *alert = [[[NSAlert alloc] init] autorelease];
		alert.messageText = foxdenString(title);
		NSString *info = foxdenString(message);
		if (error[0]) {
			alert.alertStyle = NSAlertStyleWarning;
			info = [NSString stringWithFormat:@"%@\n\n%@", foxdenString(error), info];
		}
		alert.informativeText = info;
		[alert addButtonWithTitle:@"Publish"];
		[alert addButtonWithTitle:@"Cancel"];

		NSTextField *targetField = [NSTextField textFieldWithString:foxdenString(target)];
		targetField.placeholderString = @"Port, or host:port";
		NSSegmentedControl *mode = [NSSegmentedControl segmentedControlWithLabels:@[@"HTTPS", @"TCP"]
			trackingMode:NSSegmentSwitchTrackingSelectOne target:nil action:nil];
		mode.selectedSegment = tcp ? 1 : 0;
		NSTextField *nameField = [NSTextField textFieldWithString:foxdenString(name)];
		nameField.placeholderString = @"random";
		NSView *nameView = nameField;
		if (domain[0]) {
			NSTextField *suffix = [NSTextField labelWithString:[@"." stringByAppendingString:foxdenString(domain)]];
			NSStackView *stack = [NSStackView stackViewWithViews:@[nameField, suffix]];
			stack.spacing = 2;
			nameView = stack;
		}
		NSTextField *portField = [NSTextField textFieldWithString:foxdenString(port)];
		portField.placeholderString = @"random";

		NSGridView *grid = [NSGridView gridViewWithViews:@[
			@[foxdenLabel(@"Target:"), targetField],
			@[foxdenLabel(@"Publish as:"), mode],
			@[foxdenLabel(@"HTTPS name:"), nameView],
			@[foxdenLabel(@"TCP port:"), portField],
		]];
		grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
		grid.rowSpacing = 8;
		grid.columnSpacing = 6;
		[grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
		[targetField.widthAnchor constraintEqualToConstant:200].active = YES;
		[nameField.widthAnchor constraintEqualToConstant:110].active = YES;
		[portField.widthAnchor constraintEqualToConstant:70].active = YES;
		grid.translatesAutoresizingMaskIntoConstraints = YES;
		[grid setFrameSize:grid.fittingSize];

		FoxdenExposeMode *m = [[FoxdenExposeMode alloc] init];
		m.mode = mode;
		m.name = nameField;
		m.port = portField;
		mode.target = m;
		mode.action = @selector(changed:);
		[m changed:nil];

		alert.accessoryView = grid;
		[alert layout];
		alert.window.initialFirstResponder = target[0] ? (tcp ? portField : nameField) : targetField;
		[NSApp activateIgnoringOtherApps:YES];
		r.ok = [alert runModal] == NSAlertFirstButtonReturn;
		r.tcp = mode.selectedSegment == 1;
		r.target = foxdenCString(targetField.stringValue);
		r.name = foxdenCString(nameField.stringValue);
		r.port = foxdenCString(portField.stringValue);
		[m release];
	}});
	return r;
}
*/
import "C"

import "unsafe"

// showExposeForm shows the form as a native alert. ok is false if it was
// cancelled.
func showExposeForm(f exposeForm) (exposeForm, bool, error) {
	cs := func(s string) *C.char { return C.CString(s) }
	args := []*C.char{cs(f.Title), cs(f.Message), cs(f.Error), cs(f.Target), cs(f.Name), cs(f.Port), cs(f.Domain)}
	defer func() {
		for _, a := range args {
			C.free(unsafe.Pointer(a))
		}
	}()
	tcp := C.int(0)
	if f.TCP {
		tcp = 1
	}
	r := C.foxdenExposeForm(args[0], args[1], args[2], args[3], tcp, args[4], args[5], args[6])
	defer C.free(unsafe.Pointer(r.target))
	defer C.free(unsafe.Pointer(r.name))
	defer C.free(unsafe.Pointer(r.port))
	f.Target, f.TCP = C.GoString(r.target), r.tcp != 0
	f.Name, f.Port = C.GoString(r.name), C.GoString(r.port)
	return f, r.ok != 0, nil
}
