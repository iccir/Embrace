/*
    This file is not available under a 1-clause BSD License.
    SPDX-License-Identifier: MIT

    LoudnessMeasurer
    Copyright (c) 2014-2020 Ricci Adams

    Heavily based on libebur128
    Copyright (c) 2011 Jan Kokemüller

    Permission is hereby granted, free of charge, to any person obtaining a copy of
    this software and associated documentation files (the "Software"), to deal in
    the Software without restriction, including without limitation the rights to
    use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
    the Software, and to permit persons to whom the Software is furnished to do so,
    subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
    FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
    COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
    IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
    CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>
#import  <Foundation/Foundation.h>
#include <AudioToolbox/AudioToolbox.h>

typedef struct LoudnessMeasurer LoudnessMeasurer;

extern LoudnessMeasurer *LoudnessMeasurerCreate(unsigned int channels, double sampleRate, size_t totalFrames);
extern void LoudnessMeasurerFree(LoudnessMeasurer *measurer);

extern void LoudnessMeasurerScanAudioBuffer(LoudnessMeasurer *st, AudioBufferList *bufferList, size_t frames);

extern NSData *LoudnessMeasurerGetOverview(LoudnessMeasurer *st);

extern double LoudnessMeasurerGetLoudness(LoudnessMeasurer *st);
extern double LoudnessMeasurerGetPeak(LoudnessMeasurer *st);


#ifdef __cplusplus
}
#endif
