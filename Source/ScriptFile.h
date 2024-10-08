// (c) 2017-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import <Foundation/Foundation.h>


@interface ScriptFile : NSObject

- (instancetype) initWithURL:(NSURL *)URL;

@property (nonatomic, readonly) NSURL *URL;
@property (nonatomic, readonly) NSString *fileName;
@property (nonatomic, readonly) NSString *displayName;

@property (nonatomic, readonly) NSAppleScript *appleScript;


@end
