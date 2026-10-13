/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* OSAKit, Finch's: the private classes apps link (Script Editor subclasses several) and the
   pieces the files share. */
#import <OSAKit/OSAKit.h>
#import <Carbon/Carbon.h>

@interface OSALanguage (Finch)
+ (ComponentInstance)defaultAppleScriptComponentInstance;
+ (OSALanguage *)languageForSubType:(OSType)subType;
+ (OSALanguage *)languageForScript:(OSAScript *)script;
- (Component)component;
@end

@interface OSALanguageInstance (Finch)
- (instancetype)_initWithLanguage:(OSALanguage *)language instance:(ComponentInstance)instance;
@end

@interface OSAScript (Finch)
+ (NSDictionary *)defaultTextAttributes;
+ (void)sourceStylesChanged;
- (ComponentInstance)_componentInstance;
- (OSAID)_scriptID;
- (NSString *)sourceAndReturnError:(NSError **)error;
- (NSString *)name;
- (void)setURL:(NSURL *)url;
- (NSDate *)date;
- (void)setDate:(NSDate *)date;
- (NSAppleEventDescriptor *)defaultTarget;
- (void)setDefaultTarget:(NSAppleEventDescriptor *)target;
- (BOOL)hasOpenHandler;
@end

/* the OSA error of the last call, as OSAKit's error dictionary */
NSDictionary *FinchOSAErrorInfo(ComponentInstance ci, OSAError err);

/* Text storage over an attributed string, with tab stops for the script's tab width. */
@interface OSATextStorage : NSTextStorage
+ (NSFont *)defaultPlainTextFont;
+ (void)sourceStylesChanged;
- (instancetype)initWithOwnedMutableAttributedString:(NSMutableAttributedString *)s;
@property (copy) NSAttributedString *contents;
@property (strong) NSDate *date;
@property BOOL usesTabs;
@property (nonatomic) NSUInteger tabWidth;
@property BOOL wrapsLines;
@property BOOL indentsWrappedLines;
@property NSUInteger indentWidth;
- (void)fixTabStopsInRange:(NSRange)range;
- (void)fixWrappedLineIndentsInRange:(NSRange)range;
- (void)replaceCharactersInRange:(NSRange)range withString:(NSString *)s withUndoManager:(NSUndoManager *)undo;
- (void)replaceCharactersInRange:(NSRange)range withAttributedString:(NSAttributedString *)s withUndoManager:(NSUndoManager *)undo;
@end

@class OSAScriptController;
/* A script view's storage: typing is uncompiled text, and edits tell the controller. */
@interface OSAScriptTextStorage : OSATextStorage
- (instancetype)initWithController:(OSAScriptController *)controller;
@property (weak) OSAScriptController *controller;
@end

@interface OSAScriptController (Finch)
- (OSAScript *)scriptFromSource;
- (BOOL)compileScript:(id)sender withUndo:(BOOL)undo;
- (NSAppleEventDescriptor *)runScriptReturningResult:(id)sender;
- (BOOL)isRunning;
- (BOOL)isStopped;
- (BOOL)isRecording;
- (NSUndoManager *)undoManager;
- (void)setUndoManager:(NSUndoManager *)undo;
- (NSAppleEventDescriptor *)defaultTarget;
- (void)setDefaultTarget:(NSAppleEventDescriptor *)target;
- (BOOL)shouldCancelExecution;
- (void)setShouldCancelExecution:(BOOL)cancel;
- (void)setScriptState:(OSAScriptState)state;
- (void)setIsCompiling:(BOOL)compiling;
- (void)_sourceEdited;
@end

@interface OSAScriptView (Finch)
- (id)controller;
- (void)setController:(id)controller;
- (void)replaceTextStorage:(NSTextStorage *)storage;
@end

/* the outline of a script: handlers, properties, globals, script objects */
@interface OSAScriptElement : NSObject <NSCoding>
+ (instancetype)element;
@property (copy) NSString *name;
@property (copy) NSString *text;
@property NSRange range;
@property NSRange nameRange;
@property NSRange rangeOfSubElements;
@property (strong) NSMutableArray<OSAScriptElement *> *subElements;
- (NSString *)title;
@end
@interface OSAPropertyElement : OSAScriptElement
@end
@interface OSAGlobalElement : OSAScriptElement
@end
@interface OSAScriptObjectElement : OSAScriptElement
@end
@interface OSAHandlerElement : OSAScriptElement
@end
@interface OSAEventHandlerElement : OSAHandlerElement
@end
@interface OSACommandHandlerElement : OSAHandlerElement
@end

@interface OSAScriptParser : NSObject
+ (NSArray<NSString *> *)keywords;
+ (instancetype)parserWithText:(NSString *)text;
+ (instancetype)parserWithScript:(OSAScript *)script;
- (instancetype)initWithText:(NSString *)text;
- (instancetype)initWithScript:(OSAScript *)script;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, strong) OSAScript *script;
@property (nonatomic, strong) OSAScriptElement *element;
@property BOOL needsParsed;
- (BOOL)parse;
- (NSArray<NSString *> *)eventHandlerNames;
@end

@interface OSATerminologyManager : NSObject
+ (instancetype)sharedTerminologyManager;
@property (strong) NSMutableArray *terms;
- (void)addTerms:(NSArray *)terms;
- (void)readTerms;
- (void)writeTerms;
@end

@interface OSARecordingController : NSObject
+ (instancetype)sharedRecordingController;
@property (weak) OSAScriptController *controller;
- (void)startRecordingForController:(OSAScriptController *)controller;
- (void)stopRecordingForController:(OSAScriptController *)controller;
@end
