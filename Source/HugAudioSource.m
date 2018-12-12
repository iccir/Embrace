// (c) 2014-2018 Ricci Adams.  All rights reserved.

#import "HugAudioSource.h"

#import "HugAudioFile.h"
#import "HugProtectedBuffer.h"
#import "HugError.h"
#import "HugUtils.h"


typedef struct {
    NSInteger frameIndex;
    NSInteger totalFrames;
    double sampleRate;
    AudioBufferList *bufferList;
} RenderContext;


@implementation HugAudioSource {
    HugAudioFile *_audioFile;
    RenderContext *_context;
    NSArray<HugProtectedBuffer *> *_protectedBuffers;
}


- (instancetype) initWithAudioFile:(HugAudioFile *)audioFile settings:(NSDictionary *)settings
{
    if ((self = [super init])) {
        _audioFile = audioFile;
        _settings = settings;
    }
    
    return self;
}


- (void) dealloc
{
    [_audioFile close];

    if (_context) {
        AudioBufferList *list = _context->bufferList;

        for (NSInteger i = 0; i < list->mNumberBuffers; i++) {
            list->mBuffers[i].mData = NULL;
        }

        free(_context->bufferList);
        free(_context);
    }
}


#pragma mark - Private Methods

- (BOOL) _makeContextWithStartTime: (NSTimeInterval) startTime
                          stopTime: (NSTimeInterval) stopTime
                           padding: (NSTimeInterval) padding
{
    if (![_audioFile open]) {
        NSError *error = [_audioFile error];
        HugLog(@"HugAudioSource", @"Could not open %@. Error %@", _audioFile, error);
        _error = [_audioFile error];
        
        return NO;
    }

    SInt64 fileFrames = [_audioFile fileLengthFrames];
    AudioStreamBasicDescription format = [_audioFile format];

    NSInteger totalFrames = fileFrames;

    // Apply startTime/stopTime
    {
        NSInteger startFrame  = startTime * format.mSampleRate;
        NSInteger stopFrame   = 0;

        if (startFrame < 0) startFrame = 0;
        if (startFrame > totalFrames) startFrame = totalFrames;

        if (stopTime) {
            stopFrame  = stopTime * format.mSampleRate;
            if (stopFrame < 0) stopFrame = 0;
            if (stopFrame > totalFrames) stopFrame = totalFrames;

            totalFrames = (stopFrame - startFrame);
        } else {
            totalFrames -= startFrame;
        }

        HugLog(@"HugAudioSource", @"%@ fileFrames: %ld, totalFrames: %ld, startFrame: %ld, stopFrame: %ld", _audioFile, (long)fileFrames, (long)totalFrames, (long)startFrame, (long)stopFrame);

        if (startFrame) {
            if (![_audioFile seekToFrame:startFrame]) {
                HugLog(@"HugAudioSource", @"seekToFrame %ld failed for %@", (long)startFrame, _audioFile);
                _error = [_audioFile error];
                return NO;
            }
        }
        
        if ((totalFrames < 0) || (totalFrames > UINT32_MAX)) {
            _error = [NSError errorWithDomain:HugErrorDomain code:HugErrorInvalidFrameCount userInfo:nil];
            return NO;
        }
    }

    // Setup _context and _protectedBuffers
    {
        UInt32 bufferCount = format.mChannelsPerFrame;
        UInt32 totalBytes  = (UInt32)totalFrames * format.mBytesPerFrame;

        AudioBufferList *list = malloc(sizeof(AudioBufferList) * MAX(bufferCount, 2));

        list->mNumberBuffers = bufferCount;

        NSMutableArray *protectedBuffers = [NSMutableArray array];

        for (NSInteger i = 0; i < bufferCount; i++) {
            HugProtectedBuffer *protectedBuffer = [[HugProtectedBuffer alloc] initWithCapacity:totalBytes];
        
            list->mBuffers[i].mNumberChannels = 1;
            list->mBuffers[i].mDataByteSize = (UInt32)totalBytes;
            list->mBuffers[i].mData = (void *)[protectedBuffer bytes];

            [protectedBuffers addObject:protectedBuffer];
        }

        _context = calloc(1, sizeof(RenderContext));
        _context->sampleRate = format.mSampleRate;
        _context->frameIndex = format.mSampleRate * -padding;
        _context->totalFrames = (UInt32)totalFrames;
        _context->bufferList = list;

        _protectedBuffers = protectedBuffers;
    }

    return YES;
}


- (void) _finishFillBuffer
{
    if (!_error) {
        _error = [_audioFile error];
    }
    
    if (!_error) {
        for (HugProtectedBuffer *protectedBuffer in _protectedBuffers) {
            [protectedBuffer lock];
        }
    }
}


- (BOOL) _fillBuffer
{
    RenderContext *context = _context;

    AudioStreamBasicDescription format = [_audioFile format];

    NSInteger bytesPerFrame = format.mBytesPerFrame;
    NSInteger totalFrames   = _context->totalFrames;
    NSInteger primeAmount   = (format.mSampleRate * 10);
    if (totalFrames < primeAmount) primeAmount = totalFrames;

    dispatch_semaphore_t primeSemaphore = dispatch_semaphore_create(0);

    __block BOOL shouldCancel = NO;
    __weak id weakSelf = self;

    NSTimeInterval startTime = [NSDate timeIntervalSinceReferenceDate];

    dispatch_async(dispatch_get_global_queue(0, 0), ^{

//!graph: 
//        PlayerShouldUseCrashPad = 0;

        NSInteger framesRemaining = totalFrames;
        NSInteger bytesRemaining = framesRemaining * bytesPerFrame;

        NSInteger bytesRead = 0;
        NSInteger framesAvailable = 0;

        UInt32 bufferCount = context->bufferList->mNumberBuffers;
        
        AudioBufferList *fillBufferList = alloca(sizeof(AudioBufferList) * bufferCount);
        fillBufferList->mNumberBuffers = (UInt32)bufferCount;
        
        BOOL ok = YES;
        BOOL needsSignal = YES;
        
        while (ok) {
            if (shouldCancel) break;
        
            UInt32 maxFrames  = 32768;
            UInt32 frameCount = (UInt32)framesRemaining;
            if (frameCount > maxFrames) frameCount = maxFrames;

            for (NSInteger i = 0; i < bufferCount; i++) {
                fillBufferList->mBuffers[i].mNumberChannels = 1;
                fillBufferList->mBuffers[i].mDataByteSize = (UInt32)bytesRemaining;
                
                UInt8 *data = (UInt8 *)context->bufferList->mBuffers[i].mData;
                data += bytesRead;
                fillBufferList->mBuffers[i].mData = data;
            }

            if (frameCount > 0) {
                ok = [_audioFile readFrames:&frameCount intoBufferList:fillBufferList];
            }

            // ExtAudioFileRead() is documented to return 0 when the end of the file is reached.
            //
            if ((frameCount == 0) || (framesRemaining == 0)) {
                break;
            }
       
            framesAvailable += frameCount;
            
            if ((framesAvailable >= primeAmount) && needsSignal) {
                dispatch_semaphore_signal(primeSemaphore);
                needsSignal = NO;
            }

            framesRemaining -= frameCount;
        
            bytesRead       += frameCount * bytesPerFrame;
            bytesRemaining  -= frameCount * bytesPerFrame;
        }

//!graph: 
//        PlayerShouldUseCrashPad = 1;

        if (needsSignal) {
            dispatch_semaphore_signal(primeSemaphore);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
            
            HugLog(@"HugAudioSource", @"Read finished in %ldms", (long)((now - startTime) * 1000));
        
            [weakSelf _finishFillBuffer];
        });
    });

    // Wait for the prime semaphore, this should be very fast.  If we can't decode at least 10 seconds
    // of audio in 5 seconds, something is wrong, and flip the error to "read too slow"
    //
    int64_t fiveSecondsInNs = 5l * 1000 * 1000 * 1000;
    if (dispatch_semaphore_wait(primeSemaphore, dispatch_time(0, fiveSecondsInNs))) {
        HugLog(@"HugAudioSource", @"dispatch_semaphore_wait() timed out for %@", _audioFile);
        _error = [NSError errorWithDomain:HugErrorDomain code:HugErrorReadTooSlow userInfo:nil];
        shouldCancel = YES;

        return NO;

    } else {
        HugLog(@"HugAudioSource", @"%@ primed!", _audioFile);
        
        return YES;
    }
}


#pragma mark - Public Methods

- (BOOL) prepareWithStartTime: (NSTimeInterval) startTime
                     stopTime: (NSTimeInterval) stopTime
                      padding: (NSTimeInterval) padding
{
    if (![self _makeContextWithStartTime:startTime stopTime:stopTime padding:padding]) {
        return NO;
    }
    
    if (![self _fillBuffer]) {
        return NO;
    }
    
    RenderContext *context = _context;

    _inputBlock = [^(
        AUAudioFrameCount frameCount,
        AudioBufferList *ioData,
        HugPlaybackInfo *outInfo
    ) {
        NSInteger offset = 0;

        // Zero pad if needed
        if (context->frameIndex < 0) {
            NSInteger padCount     = -context->frameIndex;
            NSInteger framesToCopy = MIN(frameCount, padCount);
        
            for (NSInteger b = 0; b < ioData->mNumberBuffers; b++) {
                memset(ioData->mBuffers[b].mData, 0, sizeof(float) * framesToCopy);
            }

            offset = framesToCopy;
            context->frameIndex += framesToCopy;
        }

        // Copy track data
        {
            NSUInteger framesToCopy = MIN(frameCount - offset, context->totalFrames - context->frameIndex);
            
            for (NSInteger b = 0; b < ioData->mNumberBuffers; b++) {
                float *inSamples  = (float *)context->bufferList->mBuffers[b].mData;
                float *outSamples = (float *)ioData->mBuffers[b].mData;
                
                inSamples  += context->frameIndex;
                outSamples += offset;

                memcpy(outSamples, inSamples, sizeof(float) * framesToCopy);
                
                NSInteger remaining = framesToCopy - frameCount;
                if (remaining > 0) {
                    memset(&outSamples[remaining], 0, sizeof(float) * remaining);
                }
            }

            context->frameIndex += framesToCopy;
        }
        
        if (outInfo) {
            double sampleRate  = context->sampleRate;

            if (context->frameIndex < 0) {
                outInfo->status = HugPlaybackStatusWaiting;
                outInfo->timeElapsed   = context->frameIndex  / sampleRate;
                outInfo->timeRemaining = context->totalFrames / sampleRate;

            } else if (context->frameIndex >= context->totalFrames) {
                outInfo->status = HugPlaybackStatusFinished;
                outInfo->timeElapsed   = context->totalFrames / sampleRate;
                outInfo->timeRemaining = 0;

            } else {
                outInfo->status = HugPlaybackStatusPlaying;
                outInfo->timeElapsed   =  context->frameIndex / sampleRate;
                outInfo->timeRemaining = (context->totalFrames - context->frameIndex) / sampleRate;
            }
        }
    } copy];

    return YES;
}


@end
