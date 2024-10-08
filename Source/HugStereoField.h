// (c) 2014-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import <Foundation/Foundation.h>

typedef struct HugStereoField HugStereoField;

extern HugStereoField *HugStereoFieldCreate(void);
extern void HugStereoFieldFree(HugStereoField *field);

extern void HugStereoFieldReset(HugStereoField *self, float balance, float width);
extern void HugStereoFieldProcess(HugStereoField *self, float *left, float *right, size_t frameCount, float balance, float width);

extern void HugStereoFieldSetMaxFrameCount(HugStereoField *field, size_t maxFrameCount);
extern size_t HugStereoFieldGetMaxFrameCount(const HugStereoField *field);
