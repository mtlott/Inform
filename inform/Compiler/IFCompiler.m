//
//  IFCompiler.m
//  Inform
//
//  Created by Andrew Hunter on Mon Aug 18 2003.
//  Copyright (c) 2003 Andrew Hunter. All rights reserved.
//

#import "IFCompiler.h"

#import "IFPreferences.h"

#import "IFNaturalProblem.h"
#import "IFInform6Problem.h"
#import "IFCblorbProblem.h"
#import "IFUtility.h"
#import "IFProgress.h"
#import "IFCompilerSettings.h"

static int mod = 0;

NSString* IFCompilerClearConsoleNotification = @"IFCompilerClearConsoleNotification";
NSString* IFCompilerStartingNotification     = @"IFCompilerStartingNotification";
NSString* IFCompilerStdoutNotification       = @"IFCompilerStdoutNotification";
NSString* IFCompilerStderrNotification       = @"IFCompilerStderrNotification";
NSString* IFCompilerFinishedNotification     = @"IFCompilerFinishedNotification";

@implementation IFCompiler {
    // The task
    NSTask* theTask;						// Task where the compiler is running

    // Settings, input, output
    IFCompilerSettings* settings;			// Settings for the compiler
    BOOL release;							// YES if compiling for release
    BOOL releaseForTesting;                 // YES if compiling for releaseForTesting;
    NSString* inputFile;					// The input file for this compiler
    NSString* outputFile;					// The output filename for this compiler
    NSString* workingDirectory;				// The working directory for this stage
    BOOL deleteOutputFile;					// YES if the output file should be deleted when the compiler is dealloced

    NSURL* problemsURL;						// The URL of the problems page we should show
    NSObject<IFCompilerProblemHandler>* problemHandler;	// The current problem handler

    // Queue of processes to run
    NSMutableArray* runQueue;				// Queue of tasks to run to produce the end result

    // Output/input streams
    NSPipe* stdErr;							// stdErr pipe
    NSPipe* stdOut;							// stdOut pipe

    NSFileHandle* stdErrH;					// File handle for std err
    NSFileHandle* stdOutH;					// ... and for std out

    int finishCount;						// When =3, notify the delegate that the task is dead

    // Progress
    IFProgress* progress;					// Progress indicator for compilation
    NSString* endTextString;                // Message to show at end of tasks

    // Delegate
    id delegate;							// The delegate object.
}

// == Initialisation, etc ==

- (instancetype) init {
    self = [super init];

    if (self) {
        settings            = nil;
        inputFile           = nil;
        theTask             = nil;
        stdOut              = nil;
        stdErr              = nil;
        delegate            = nil;
        workingDirectory    = nil;
		release             = NO;
        releaseForTesting   = NO;
		
		progress = [[IFProgress alloc] initWithPriority: IFProgressPriorityCompiler
                                       showsProgressBar: YES
                                              canCancel: NO];

        deleteOutputFile = YES;
        runQueue = [[NSMutableArray alloc] init];
    }
    
    return self;
}

- (void) dealloc {
    if (deleteOutputFile) [self deleteOutput];

    theTask = nil;
    endTextString = nil;

	[[NSNotificationCenter defaultCenter] removeObserver: self];
}

// == Setup ==

- (void) setBuildForRelease: (BOOL) willRelease
                 forTesting: (BOOL) testing {
	release = willRelease;
    releaseForTesting = testing;
}

- (void) setSettings: (IFCompilerSettings*) set {
    settings = set;
}

- (void) setInputFile: (NSString*) path {
    inputFile = [path copy];
}

- (NSString*) inputFile {
    return inputFile;
}

- (IFCompilerSettings*) settings {
    return settings;
}

- (void) deleteOutput {
    if (outputFile) {
        if ([[NSFileManager defaultManager] fileExistsAtPath: outputFile]) {
            NSLog(@"Removing '%@'", outputFile);
            [[NSFileManager defaultManager] removeItemAtURL:[NSURL fileURLWithPath:outputFile isDirectory:FALSE] error: nil];
        } else {
            NSLog(@"Compiler produced no output");
            // Nothing to do
        }
        
        outputFile = nil;
    }
}

- (void) addCustomBuildStage: (NSString*) command
               withArguments: (NSArray*) arguments
              nextStageInput: (NSString*) file
				errorHandler: (NSObject<IFCompilerProblemHandler>*) handler
					   named: (NSString*) stageName {
    if (theTask) {
        // This starts a new build process, so we kill the old task if it's still
        // running
        if ([theTask isRunning]) {
            [theTask terminate];
        }
        theTask = nil;
    }

    if( handler )
    {
        [runQueue addObject: @[command,
                               arguments,
                               file,
                               stageName,
                               handler]];
    }
    else
    {
        [runQueue addObject: @[command,
                               arguments,
                               file,
                               stageName]];
    }
}

- (void) addNaturalInformStageUsingTestCase:(NSString*) testCase {
    // Prepare the arguments
    NSMutableArray* args = [NSMutableArray arrayWithArray: [settings naturalInformCommandLineArguments]];

    [args addObject: @"-project"];
    [args addObject: [NSString stringWithString: [self currentStageInput]]];
	[args addObject: [NSString stringWithFormat: @"-format=%@", [settings fileExtension]]];
	
	if (release && !releaseForTesting) {
		[args addObject: @"-release"];
	}

	if ([settings nobbleRng] && !release) {
		[args addObject: @"-rng"];
	}

    if(( testCase != nil ) && ([testCase length] > 0))
    {
        [args addObject: @"-case"];
        [args addObject: [NSString stringWithFormat:@"%@", testCase]];
    }
	
    [self addCustomBuildStage: [settings naturalInformCompilerToUse]
                withArguments: args
               nextStageInput: [NSString stringWithFormat: @"%@/Build/auto.inf", [self currentStageInput]]
				 errorHandler: [[IFNaturalProblem alloc] init]
						named: [IFUtility localizedString: @"Compiling Natural Inform source"]];
}

- (void) addStandardInformStage: (BOOL) usingNaturalInform {
    if (!outputFile) [self outputFile];
    
    // Prepare the arguments
    NSMutableArray* args = [NSMutableArray arrayWithArray: [settings commandLineArgumentsForRelease: release
                                                                                         forTesting: releaseForTesting]];

    // [args addObject: @"-x"];
   
    [args addObject: [NSString stringWithString: [self currentStageInput]]];
    [args addObject: [NSString stringWithString: outputFile]];

    [self addCustomBuildStage: [settings compilerToUse]
                withArguments: args
               nextStageInput: outputFile
				 errorHandler: usingNaturalInform ? [[IFInform6Problem alloc] init] : nil
						named: [IFUtility localizedString: @"Compiling Inform 6 source"]];
}

- (NSString*) currentStageInput {
    NSString* inFile = inputFile;
    if ([runQueue count] > 0) inFile = [runQueue lastObject][2];

    return inFile;
}

- (BOOL) isRunning {
	return (theTask != nil) ? [theTask isRunning] : NO;
}

- (void) sendTaskDetails: (NSTask*) task {
	NSMutableString* taskMessage = [NSMutableString stringWithFormat: @"Launching: %@", [[task launchPath] lastPathComponent]];
	
	for( NSString* arg in [task arguments] ) {
		[taskMessage appendFormat: @" \"%@\"", arg];
	}

	[taskMessage appendString: @"\n"];
	[self sendStdOut: taskMessage];
}

-(void) prepareNext {
    NSString* stageName = runQueue[0][3];
    [progress setMessage: stageName];

    NSArray* args     = runQueue[0][1];
    NSString* command = runQueue[0][0];

    problemHandler = nil;
    if ([runQueue[0] count] > 4) {
        problemHandler = runQueue[0][4];
    }

    [runQueue removeObjectAtIndex: 0];

    // Prepare the task
    theTask = [[NSTask alloc] init];
    finishCount = 0;

    if ([settings debugMemory]) {
        NSMutableDictionary* newEnvironment = [[theTask environment] mutableCopy];
        if (!newEnvironment) newEnvironment = [[NSMutableDictionary alloc] init];

        newEnvironment[@"MallocGuardEdges"]     = @"1";
        newEnvironment[@"MallocScribble"]       = @"1";
        newEnvironment[@"MallocBadFreeAbort"]   = @"1";
        newEnvironment[@"MallocCheckHeapStart"] = @"512";
        newEnvironment[@"MallocCheckHeapEach"]  = @"256";
        newEnvironment[@"MallocStackLogging"]   = @"1";

        [theTask setEnvironment: newEnvironment];
    }

    NSMutableString* executeString = [@"" mutableCopy];

    [executeString appendString: command];
    [executeString appendString: @" \\\n\t"];

    for( NSString* arg in args ) {
        [executeString appendString: arg];
        [executeString appendString: @" "];
    }

    [executeString appendString: @"\n"];
    [self sendStdOut: executeString];
    executeString = nil;

    [theTask setArguments:  args];
    [theTask setLaunchPath: command];
    if (workingDirectory)
        [theTask setCurrentDirectoryPath: workingDirectory];
    else
        [theTask setCurrentDirectoryPath: NSTemporaryDirectory()];

    // Prepare the task's IO
    [[NSNotificationCenter defaultCenter] removeObserver: self];

    stdErr = [[NSPipe alloc] init];
    stdOut = [[NSPipe alloc] init];

    [theTask setStandardOutput: stdOut];
    [theTask setStandardError:  stdErr];

    stdErrH = [stdErr fileHandleForReading];
    stdOutH = [stdOut fileHandleForReading];

    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(stdOutWaiting:)
                                                 name: NSFileHandleDataAvailableNotification
                                               object: stdOutH];

    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(stdErrWaiting:)
                                                 name: NSFileHandleDataAvailableNotification
                                               object: stdErrH];

    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(taskDidFinish:)
                                                 name: NSTaskDidTerminateNotification
                                               object: theTask];
    
    [stdOutH waitForDataInBackgroundAndNotify];
    [stdErrH waitForDataInBackgroundAndNotify];
}

- (void) prepareForLaunchWithBlorbStage: (BOOL) makeBlorb testCase:(NSString*) testCase {
    // Kill off any old tasks...
    if (theTask) {
        if ([theTask isRunning]) {
            [theTask terminate];
        }
        theTask = nil;		
    }

	// There are no problems
	problemsURL = nil;

    if (deleteOutputFile) [self deleteOutput];

    // Prepare the arguments
    if ([runQueue count] <= 0) {
        if ([[IFPreferences sharedPreferences] runBuildSh] && ![IFUtility isSandboxed]) {
            NSString* buildsh;

            buildsh = [@"~/build.sh" stringByExpandingTildeInPath];
            
			[self addCustomBuildStage: buildsh
						withArguments: @[]
					   nextStageInput: [self currentStageInput]
						 errorHandler: nil
								named: @"Debug build stage"];
        }

        if ([settings usingNaturalInform]) {
            [self addNaturalInformStageUsingTestCase: testCase];
        }

        if (![settings usingNaturalInform] || [settings compileNaturalInformOutput]) {
            [self addStandardInformStage: [settings usingNaturalInform]];
        }

		if (makeBlorb && [settings usingNaturalInform]) {
			// Blorb files kind of create an exception: we change our output file, for instance,
            // and the input file is determined by the blurb file output by NI
			NSString* extension;

			if ([settings zcodeVersion] > 128) {
				extension = @"gblorb";
			} else {
				extension = @"zblorb";
			}

			// Work out the new output file
			NSString* oldOutput  = [self outputFile];
			NSString* newOutput  = [NSString stringWithFormat: @"%@.%@", [oldOutput stringByDeletingPathExtension], extension];

			// Work out where the blorb is coming from
            NSString* buildDir   = [[self currentStageInput] stringByDeletingLastPathComponent];
            NSString* projectdir = [buildDir stringByDeletingLastPathComponent];
			NSString* blorbFile  = [NSString stringWithFormat: @"%@/Release.blurb", projectdir];

			// Add a cBlorb stage
            NSString *cBlorbLocation = [[[[NSBundle mainBundle] executablePath] stringByDeletingLastPathComponent] stringByAppendingPathComponent: @"cBlorb"];

			[self addCustomBuildStage: cBlorbLocation
						withArguments: @[blorbFile, newOutput]
					   nextStageInput: newOutput
						 errorHandler: [[IFCblorbProblem alloc] initWithBuildDir: buildDir]
								named: @"cBlorb build stage"];

			// Change the output file
			[self setOutputFile: newOutput];
		}
    }

    endTextString = nil;
    [progress startProgress];

    [self prepareNext];
}

- (void) clearConsole {
    [[NSNotificationCenter defaultCenter] postNotificationName: IFCompilerClearConsoleNotification
                                                        object: self];
}

- (void) launch {
    [[NSNotificationCenter defaultCenter] postNotificationName: IFCompilerStartingNotification
                                                        object: self];
	[self sendTaskDetails: theTask];
    [theTask launch];
}

- (NSURL*) problemsURL {
	return problemsURL;
}

- (NSString*) outputFile {
    if (outputFile == nil) {
        outputFile = [NSString stringWithFormat: @"%@/Inform-%x-%x.%@",
            NSTemporaryDirectory(), (int) time(NULL), ++mod, [settings fileExtension]];
        deleteOutputFile = YES;
    }

    return [NSString stringWithString: outputFile];
}

- (void) setOutputFile: (NSString*) file {
    outputFile = [file copy];
    deleteOutputFile = NO;
}

- (void) setDeletesOutput: (BOOL) deletes {
    deleteOutputFile = deletes;
}

- (void) setDelegate: (id<NSObject>) dg {
	delegate = dg;
}

- (id) delegate {
    return delegate;
}

- (void) setDirectory: (NSString*) path {
    workingDirectory = [path copy];
}

- (NSString*) directory {
    return [workingDirectory copy];
}

- (void) taskHasReallyFinished {
	int exitCode = [theTask terminationStatus];
    ECompilerProblemType problemType = EProblemTypeNone;

    if( exitCode != 0 ) {
        if ([problemHandler isKindOfClass: [IFNaturalProblem class]]) {
            problemType = EProblemTypeInform7;
        } else if ([problemHandler isKindOfClass: [IFInform6Problem class]]) {
            problemType = EProblemTypeInform6;
        } else if ([problemHandler isKindOfClass: [IFCblorbProblem class]]) {
            problemType = EProblemTypeCBlorb;
        } else if (problemHandler != nil) {
            problemType = EProblemTypeUnknown;
        }
    }

    if ([runQueue count] == 0) {
        if (exitCode != 0 && problemHandler) {
			problemsURL = [[problemHandler urlForProblemWithErrorCode: exitCode] copy];
		} else if (exitCode == 0 && problemHandler) {
			if ([problemHandler respondsToSelector: @selector(urlForSuccess)]) {
				problemsURL = [[problemHandler urlForSuccess] copy];
			}
		}

        if (delegate &&
            [delegate respondsToSelector: @selector(taskFinished:)]) {
            [delegate taskFinished: exitCode];
        }

		[progress stopProgress];
        
        // Show final message from compiler
        if( endTextString ) {
            [progress setMessage: endTextString];
            endTextString = nil;
        }
        NSDictionary* uiDict = @{@"exitCode": @(exitCode),
                                 @"problemType": @(problemType)};
        [[NSNotificationCenter defaultCenter] postNotificationName: IFCompilerFinishedNotification
                                                            object: self
                                                          userInfo: uiDict];
    } else {
        if (exitCode != 0) {
			if (problemHandler) {
				problemsURL = [[problemHandler urlForProblemWithErrorCode: exitCode] copy];
			}
			
            // The task failed
            if (delegate &&
                [delegate respondsToSelector: @selector(taskFinished:)]) {
                [delegate taskFinished: exitCode];
            }
            [progress stopProgress];
            
            // Show final message from compiler
            if( endTextString ) {
                [progress setMessage: endTextString];
                endTextString = nil;
            }
            
            // Notify everyone of the failure
            NSDictionary* uiDict = @{@"exitCode": @(exitCode),
                                     @"problemType": @(problemType)};
            [[NSNotificationCenter defaultCenter] postNotificationName: IFCompilerFinishedNotification
                                                                object: self
                                                              userInfo: uiDict];
            
            // Give up
            [runQueue removeAllObjects];
            theTask = nil;
            
            return;
        }
        
        // Prepare the next task for launch
        if (theTask) {
            if ([theTask isRunning]) {
                [theTask terminate];
            }
            theTask = nil;
        }

        [self prepareNext];

        // Launch it
		[self sendTaskDetails: theTask];
        [theTask launch];
    }
}

// == Notifications ==
- (void) sendStdOut: (NSString*) data {
	if (delegate &&
		[delegate respondsToSelector: @selector(receivedFromStdOut:)]) {
		[delegate receivedFromStdOut: data]; 
	}
	
	NSDictionary* uiDict = @{@"string": data};
	[[NSNotificationCenter defaultCenter] postNotificationName: IFCompilerStdoutNotification
														object: self
													  userInfo: uiDict];
}

- (void) stdOutWaiting: (NSNotification*) not {
	if (finishCount >= 3) return;

    NSData* inData = [stdOutH availableData];

    if ([inData length]) {
        NSString* newStr = [[NSString alloc] initWithData: inData
                                                 encoding: NSISOLatin1StringEncoding];
		[self sendStdOut:newStr];

        [stdOutH waitForDataInBackgroundAndNotify];
    } else {
        finishCount++;

        if (finishCount == 3) {
            [self taskHasReallyFinished];
        }
    }
}

- (void) stdErrWaiting: (NSNotification*) not {
	if (finishCount >= 3) return;
	
    NSData* inData = [stdErrH availableData];

    if ([inData length]) {
        NSString* newStr = [[NSString alloc] initWithData:inData
                                                  encoding:NSISOLatin1StringEncoding];
        if (delegate &&
            [delegate respondsToSelector: @selector(receivedFromStdErr:)]) {
            [delegate receivedFromStdErr: newStr];
        }

        NSDictionary* uiDict = @{@"string": newStr};
        [[NSNotificationCenter defaultCenter] postNotificationName: IFCompilerStderrNotification
                                                            object: self
                                                          userInfo: uiDict];
        
        [stdErrH waitForDataInBackgroundAndNotify];
    } else {
        finishCount++;

        if (finishCount == 3) {
            [self taskHasReallyFinished];
        }
    }
}

- (void) taskDidFinish: (NSNotification*) not {
    finishCount++;

    if (finishCount == 3) {
        [self taskHasReallyFinished];
    }
}

- (IFProgress*) progress {
	return progress;
}

- (void) setEndTextString: (NSString*) aEndTextString {
    endTextString = aEndTextString;
}

@end
