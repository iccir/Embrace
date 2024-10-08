// (c) 2018-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct HugRingBuffer HugRingBuffer;

extern HugRingBuffer *HugRingBufferCreate(CFIndex capacity);
extern void HugRingBufferFree(HugRingBuffer *buffer);

extern void HugRingBufferConfirmReadAll(HugRingBuffer *buffer);

extern void *HugRingBufferGetReadPtr(HugRingBuffer *buffer, CFIndex neededLength);
extern void  HugRingBufferConfirmRead(HugRingBuffer *buffer, CFIndex length);

extern void *HugRingBufferGetWritePtr(HugRingBuffer *buffer, CFIndex neededLength);
extern void  HugRingBufferConfirmWrite(HugRingBuffer *buffer, CFIndex length);

extern BOOL HugRingBufferRead( HugRingBuffer *self, void *buffer, CFIndex length);
extern BOOL HugRingBufferWrite(HugRingBuffer *self, void *buffer, CFIndex length);

extern CFIndex HugRingBufferGetCapacity(HugRingBuffer *buffer);

#ifdef __cplusplus
}
#endif


