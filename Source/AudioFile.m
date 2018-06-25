// (c) 2014-2018 Ricci Adams.  All rights reserved.

#import "AudioFile.h"
#import "Log.h"
#import "URLExtensions.h"

#import <AVFoundation/AVFoundation.h>


@implementation AudioFile {
    NSURL *_fileURL;
    NSURL *_exportedURL;
    ExtAudioFileRef _audioFile;
}


- (id) initWithFileURL:(NSURL *)fileURL
{
    if ((self = [super init])) {
        _fileURL = fileURL;
        
        if (![_fileURL embrace_startAccessingResourceWithKey:@"audio-file"]) {
            EmbraceLog(@"AudioFile", @"%@, -embrace_startAccessingResource failed", self);
        }
    }

    return self;
}


- (void) dealloc
{
    [_fileURL embrace_stopAccessingResourceWithKey:@"audio-file"];

    if (_exportedURL) {
        NSError *error;
        [[NSFileManager defaultManager] removeItemAtURL:_exportedURL error:&error];
    }

    [self _clearAudioFile];
}


- (NSString *) description
{
    NSString *friendlyString = [_fileURL path];

    if ([friendlyString length]) {
        return [NSString stringWithFormat:@"<%@: %p, \"%@\">", [self class], self, friendlyString];
    } else {
        return [super description];
    }
}


- (void) _clearAudioFile
{
    if (_audioFile) {
        ExtAudioFileDispose(_audioFile);
        _audioFile = NULL;
    }
}


- (OSStatus) _reopenAudioFileWithURL:(NSURL *)url
{
    AudioStreamBasicDescription fileDataFormat   = {0};
    AudioStreamBasicDescription clientDataFormat = {0};
    
    OSStatus err = noErr;

    if (err == noErr) {
        err = [self getClientDataFormat:&clientDataFormat];
    }

    [self _clearAudioFile];

    if (err == noErr) {
        err = ExtAudioFileOpenURL((__bridge CFURLRef)_exportedURL, &_audioFile);
        if (err != noErr) EmbraceLog(@"AudioFile", @"%@, ExtAudioFileOpenURL() failed %ld", self, (long)err);
    }
    
    if (err == noErr) {
        err = [self setClientDataFormat:&clientDataFormat];
    }

    if (err == noErr) {
        err = [self getFileDataFormat:&fileDataFormat];
    }

    if (err != noErr) EmbraceLog(@"AudioFile", @"%@, -_reopenAudioFileWithURL: error %ld", self, (long)err);
    
    return err;
}


- (OSStatus) open
{
    OSStatus err = noErr;

    if (!_audioFile) {
        err = ExtAudioFileOpenURL((__bridge CFURLRef)_fileURL, &_audioFile);
    }
    
    if (err != noErr) {
        EmbraceLog(@"AudioFile", @"ExtAudioFileOpenURL() returned %ld", (long)err);
        _audioFileError = AudioFileErrorOpenFailed;
    }
    
    return err;
}


- (BOOL) canRead
{
    SInt64 fileLengthFrames = 0;
    OSStatus err = noErr;
    
    if (err == noErr) {
        err = [self getFileLengthFrames:&fileLengthFrames];
    }
    
    AudioStreamBasicDescription clientDataFormat = {0};
    
    if (err == noErr) {
        err = [self getClientDataFormat:&clientDataFormat];
    }

    UInt32 channelCount = clientDataFormat.mChannelsPerFrame;
    if (!channelCount) return NO;

    AudioBufferList *bufferList = alloca(sizeof(AudioBufferList) * channelCount);

    bufferList->mNumberBuffers = channelCount;

    UInt32 framesToRead = 1024;

    for (NSInteger i = 0; i < channelCount; i++) {
        bufferList->mBuffers[i].mNumberChannels = 1;
        bufferList->mBuffers[i].mDataByteSize = framesToRead * sizeof(float);
        bufferList->mBuffers[i].mData = alloca(framesToRead * sizeof(float));
    }

    SInt64 frameOffset = 0;
    if (err == noErr) {
        err = ExtAudioFileTell(_audioFile, &frameOffset);
    }

    if (err == noErr) {
        err = ExtAudioFileRead(_audioFile, &framesToRead, bufferList);
    }
    
    if (err == noErr) {
        err = ExtAudioFileSeek(_audioFile, frameOffset);
    }
    
    return err == noErr;
}


- (BOOL) convert
{
    AVAssetExportSession *session;
    BOOL hasProtectedContent = NO;

@autoreleasepool {
    AVAsset *asset = [AVAsset assetWithURL:_fileURL];
    hasProtectedContent = [asset hasProtectedContent];
    
    session = [AVAssetExportSession exportSessionWithAsset:asset presetName:AVAssetExportPresetPassthrough];
}

    NSString *typeToUse;
    NSString *extension;
    
    NSString *temporaryFilePath = NSTemporaryDirectory();
    temporaryFilePath = [temporaryFilePath stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    
    NSArray *fileTypes = [session supportedFileTypes];
    
    if ([fileTypes containsObject:AVFileTypeCoreAudioFormat]) {
        typeToUse = AVFileTypeCoreAudioFormat;
        extension = @"caf";

    } else if ([fileTypes containsObject:@"com.apple.m4a-audio"]) {
        typeToUse = @"com.apple.m4a-audio";
        extension = @"m4a";

    } else if ([fileTypes containsObject:@"public.mp3"]) {
        typeToUse = @"public.mp3";
        extension = @"mp3";

    } else {
        return NO;
    }
    
    temporaryFilePath = [temporaryFilePath stringByAppendingPathExtension:extension];
    _exportedURL = [NSURL fileURLWithPath:temporaryFilePath];

    [session setOutputFileType:typeToUse];
    [session setOutputURL:_exportedURL];
    
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    [session exportAsynchronouslyWithCompletionHandler:^{
        dispatch_semaphore_signal(semaphore);
    }];

    int64_t fifteenSecondsInNs = 15l * 1000 * 1000 * 1000;
    if (dispatch_semaphore_wait(semaphore, dispatch_time(0, fifteenSecondsInNs))) {
        EmbraceLog(@"AudioFile", @"%@ dispatch_semaphore_wait() timed out!", self);
        [session cancelExport];
        return NO;
    }

    if ([session error]) {
        if (hasProtectedContent) {
            _audioFileError = AudioFileErrorProtectedContent;
        } else {
            _audioFileError = AudioFileErrorConversionFailed;
        }
    
        return NO;
    }
    
    OSStatus err = [self _reopenAudioFileWithURL:_exportedURL];

    return err == noErr;
}


- (OSStatus) readFrames:(inout UInt32 *)ioNumberFrames intoBufferList:(inout AudioBufferList *)bufferList
{
    OSStatus err = ExtAudioFileRead(_audioFile, ioNumberFrames, bufferList);
    if (err != noErr) EmbraceLog(@"AudioFile", @"%@, -readFrames:intoBufferList: error %ld", self, (long)err);
    return err;
}


- (OSStatus) seekToFrame:(SInt64)startFrame
{
    OSStatus err = ExtAudioFileSeek(_audioFile, startFrame);
    if (err != noErr) EmbraceLog(@"AudioFile", @"%@, -seekToFrame: error %ld", self, (long)err);
    return err;
}


- (OSStatus) getFileDataFormat:(AudioStreamBasicDescription *)fileDataFormat
{
    UInt32 size = sizeof(AudioStreamBasicDescription);
    OSStatus err = ExtAudioFileGetProperty(_audioFile, kExtAudioFileProperty_FileDataFormat, &size, fileDataFormat);

    if (err != noErr) EmbraceLog(@"AudioFile", @"%@, -getFileDataFormat: error %ld", self, (long)err);

    return err;
}


- (OSStatus) getFileLengthFrames:(SInt64 *)fileLengthFrames
{
    UInt32 size = sizeof(SInt64);
    OSStatus err = ExtAudioFileGetProperty(_audioFile, kExtAudioFileProperty_FileLengthFrames, &size, fileLengthFrames);

    if (err != noErr) EmbraceLog(@"AudioFile", @"%@, -getFileLengthFrames: error %ld", self, (long)err);

    return err;
}


- (OSStatus) setClientDataFormat:(AudioStreamBasicDescription *)clientDataFormat
{
    UInt32 size = sizeof(AudioStreamBasicDescription);
    OSStatus err = ExtAudioFileSetProperty(_audioFile, kExtAudioFileProperty_ClientDataFormat, size, clientDataFormat);

    if (err != noErr) EmbraceLog(@"AudioFile", @"%@, -setClientDataFormat: error %ld", self, (long)err);

    return err;
}


- (OSStatus) getClientDataFormat:(AudioStreamBasicDescription *)clientDataFormat
{
    UInt32 size = sizeof(AudioStreamBasicDescription);
    OSStatus err = ExtAudioFileGetProperty(_audioFile, kExtAudioFileProperty_ClientDataFormat, &size, clientDataFormat);
    
    if (err != noErr) EmbraceLog(@"AudioFile", @"%@, -getClientDataFormat: returned %ld", self, (long)err);

    return err;
}


@end
