//
//  SongTableViewCell.h
//  Embrace
//
//  Created by Ricci Adams on 2014-01-05.
//  Copyright (c) 2014 Ricci Adams. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TrackTableCellView.h"

@class ActionButton, BorderedView;

@interface AudioFileTableCellView : TrackTableCellView

- (void) showEndTime;

@property (nonatomic, weak) IBOutlet NSTextField *artistField;
@property (nonatomic, weak) IBOutlet NSTextField *tonalityAndBPMField;

@end
