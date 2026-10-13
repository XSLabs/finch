/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * OSAKit: the script controller, Finch's. It ties a script view (the source) to a script and
 * a result view: compiling replaces the view's text with the styled compiled source (an
 * undoable edit), running shows the result's display form, and errors select their range
 * and come up as a sheet on the view's window.
 */
#import "OSAKit_Finch.h"

@implementation OSAScriptController {
    OSAScript *_script;
    OSALanguage *_language;
    OSAScriptState _state;
    BOOL _compiling, _cancel, _sourceDirty;
    NSUndoManager *_undo;
    NSAppleEventDescriptor *_target;
    NSString *_shown; /* the text the view had when the script was last shown or compiled */
}

- (instancetype)init
{
    if ((self = [super init]))
        _language = [OSALanguage defaultLanguage];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super initWithCoder:coder]))
        _language = [OSALanguage defaultLanguage];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder { [super encodeWithCoder:coder]; }

- (void)awakeFromNib
{
    if ([NSController instancesRespondToSelector:@selector(awakeFromNib)])
        [super awakeFromNib];
    if (scriptView)
        [scriptView setController:self];
}

- (OSAScriptView *)scriptView { return scriptView; }

- (void)setScriptView:(OSAScriptView *)view
{
    if (scriptView == view)
        return;
    if ([scriptView controller] == self)
        [scriptView setController:nil];
    scriptView = view;
    [view setController:self];
    if (_script)
        [self _showScript];
}

- (NSTextView *)resultView { return resultView; }
- (void)setResultView:(NSTextView *)view { resultView = view; }
- (OSAScript *)script { return _script; }

- (void)setScript:(OSAScript *)script
{
    _script = [script copy];
    if (script.language)
        _language = script.language;
    _sourceDirty = NO;
    [self _showScript];
}

- (OSALanguage *)language { return _language ?: [OSALanguage defaultLanguage]; }
- (void)setLanguage:(OSALanguage *)language { _language = language; }
- (OSAScriptState)scriptState { return _state; }

- (void)setScriptState:(OSAScriptState)state
{
    [self willChangeValueForKey:@"scriptState"];
    _state = state;
    [self didChangeValueForKey:@"scriptState"];
}

- (BOOL)isCompiling { return _compiling; }

- (void)setIsCompiling:(BOOL)compiling
{
    [self willChangeValueForKey:@"compiling"];
    _compiling = compiling;
    [self didChangeValueForKey:@"compiling"];
}

- (BOOL)isRunning { return _state == OSAScriptRunning; }
- (BOOL)isStopped { return _state == OSAScriptStopped; }
- (BOOL)isRecording { return _state == OSAScriptRecording; }
- (NSUndoManager *)undoManager { return _undo ?: scriptView.undoManager; }
- (void)setUndoManager:(NSUndoManager *)undo { _undo = undo; }
- (NSAppleEventDescriptor *)defaultTarget { return _target; }
- (void)setDefaultTarget:(NSAppleEventDescriptor *)target { _target = target; }
- (BOOL)shouldCancelExecution { return _cancel; }
- (void)setShouldCancelExecution:(BOOL)cancel { _cancel = cancel; }

/* the view's text was edited: the script no longer matches it */
- (void)_sourceEdited { _sourceDirty = YES; }

- (BOOL)_isDirty
{
    if (_sourceDirty || !_script)
        return YES;
    return scriptView && !(_shown && [scriptView.string isEqualToString:_shown]);
}

/* the script's source, styled, into the view */
- (void)_showScript
{
    if (!scriptView || !_script)
        return;
    NSAttributedString *rich = _script.richTextSource;
    if (!rich)
        return;
    NSTextStorage *ts = scriptView.textStorage;
    NSRange sel = scriptView.selectedRange;
    [ts beginEditing];
    [ts replaceCharactersInRange:NSMakeRange(0, ts.length) withAttributedString:rich];
    [ts endEditing];
    _sourceDirty = NO;
    _shown = [ts.string copy];
    if (NSMaxRange(sel) <= ts.length)
        [scriptView setSelectedRange:sel];
}

- (OSAScript *)scriptFromSource
{
    if (_script && !self._isDirty)
        return _script;
    NSString *src = scriptView ? scriptView.string : _script.source;
    OSAScript *s = [[OSAScript alloc] initWithSource:src ?: @"" fromURL:_script.url languageInstance:self.language.sharedLanguageInstance
                                usingStorageOptions:OSANull];
    if (_target)
        s.defaultTarget = _target;
    return s;
}

/* an error: select where it happened, then a sheet with the message */
- (void)_presentErrorInfo:(NSDictionary *)info
{
    NSValue *r = info[OSAScriptErrorRangeKey];
    if (r && scriptView && NSMaxRange(r.rangeValue) <= scriptView.string.length) {
        [scriptView setSelectedRange:r.rangeValue];
        [scriptView scrollRangeToVisible:r.rangeValue];
    }
    NSString *message = info[OSAScriptErrorMessageKey] ?: @"An error occurred.";
    NSWindow *w = scriptView.window;
    NSAlert *alert = [NSAlert new];
    alert.messageText = message;
    NSNumber *n = info[OSAScriptErrorNumberKey];
    if (n.integerValue == -2741 || n.integerValue == -2740)
        alert.messageText = [@"Syntax Error: " stringByAppendingString:message];
    if (w)
        [alert beginSheetModalForWindow:w completionHandler:nil];
    else
        [alert runModal];
}

- (BOOL)compileScript:(id)sender withUndo:(BOOL)undo { return [self compileScript:sender withUndo:undo withErrorDisplay:YES]; }

/* (Script Editor compiles quietly before saving) */
- (BOOL)compileScript:(id)sender withUndo:(BOOL)undo withErrorDisplay:(BOOL)display
{
    if (_script && !self._isDirty && _script.isCompiled)
        return YES;
    [self setIsCompiling:YES];
    OSAScript *s = [self scriptFromSource];
    NSDictionary *info = nil;
    BOOL ok = [s compileAndReturnError:&info];
    [self setIsCompiling:NO];
    if (!ok) {
        if (display)
            [self _presentErrorInfo:info];
        return NO;
    }
    NSString *before = scriptView.string;
    _script = s;
    if (scriptView) {
        NSAttributedString *rich = s.richTextSource;
        NSTextStorage *ts = scriptView.textStorage;
        NSRange all = NSMakeRange(0, ts.length);
        if (rich && undo && [scriptView shouldChangeTextInRange:all replacementString:rich.string]) {
            [ts replaceCharactersInRange:all withAttributedString:rich];
            [scriptView didChangeText];
        } else if (rich) {
            [ts replaceCharactersInRange:all withAttributedString:rich];
        }
        /* keep the insertion point near where it was */
        NSRange sel = scriptView.selectedRange;
        if (NSMaxRange(sel) > ts.length || ![before isEqualToString:ts.string])
            [scriptView setSelectedRange:NSMakeRange(MIN(sel.location, ts.length), 0)];
    }
    _sourceDirty = NO;
    _shown = [scriptView.string copy];
    return YES;
}

- (IBAction)compileScript:(id)sender { [self compileScript:sender withUndo:YES]; }

- (NSAppleEventDescriptor *)runScriptReturningResult:(id)sender
{
    if (![self compileScript:sender withUndo:YES])
        return nil;
    _cancel = NO;
    [self setScriptState:OSAScriptRunning];
    NSDictionary *info = nil;
    NSAttributedString *display = nil;
    NSAppleEventDescriptor *r = [_script executeAndReturnDisplayValue:&display error:&info];
    [self setScriptState:OSAScriptStopped];
    if (!r) {
        [self _presentErrorInfo:info];
        return nil;
    }
    if (resultView)
        [resultView.textStorage setAttributedString:display ?: [[NSAttributedString alloc] initWithString:@""]];
    return r;
}

- (IBAction)runScript:(id)sender { [self runScriptReturningResult:sender]; }

- (IBAction)stopScript:(id)sender
{
    _cancel = YES;
    if (_state == OSAScriptRecording)
        [[OSARecordingController sharedRecordingController] stopRecordingForController:self];
    [self setScriptState:OSAScriptStopped];
}

/* recording needs applications that send recordable events; none do on Finch yet */
- (IBAction)recordScript:(id)sender
{
    [[OSARecordingController sharedRecordingController] startRecordingForController:self];
}
@end

@implementation OSARecordingController

+ (instancetype)sharedRecordingController
{
    static OSARecordingController *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [OSARecordingController new];
    });
    return shared;
}

- (void)startRecordingForController:(OSAScriptController *)controller
{
    self.controller = controller;
    NSBeep();
}

- (void)stopRecordingForController:(OSAScriptController *)controller
{
    if (self.controller == controller)
        self.controller = nil;
}

- (void)handleRecordedTextAppleEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)reply
{
}
@end
