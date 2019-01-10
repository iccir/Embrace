// (c) 2014-2019 Ricci Adams.  All rights reserved.

#import <Foundation/Foundation.h>

typedef struct HugLinearRamper HugLinearRamper;

extern HugLinearRamper *HugLinearRamperCreate(void);
extern void HugLinearRamperFree(HugLinearRamper *meter);

extern void HugLinearRamperSetMaxFrameCount(HugLinearRamper *ramper, size_t maxFrameCount);
extern size_t HugLinearRamperGetMaxFrameCount(HugLinearRamper *ramper);

extern void HugLinearRamperReset(HugLinearRamper *ramper, float level);
void HugLinearRamperProcess(HugLinearRamper *self, float *left, float *right, size_t frameCount, float level);
