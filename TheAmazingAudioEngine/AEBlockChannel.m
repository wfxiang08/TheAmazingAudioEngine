//
//  AEBlockChannel.m
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 20/12/2012.
//
//  This software is provided 'as-is', without any express or implied
//  warranty.  In no event will the authors be held liable for any damages
//  arising from the use of this software.
//
//  Permission is granted to anyone to use this software for any purpose,
//  including commercial applications, and to alter it and redistribute it
//  freely, subject to the following restrictions:
//
//  1. The origin of this software must not be misrepresented; you must not
//     claim that you wrote the original software. If you use this software
//     in a product, an acknowledgment in the product documentation would be
//     appreciated but is not required.
//
//  2. Altered source versions must be plainly marked as such, and must not be
//     misrepresented as being the original software.
//
//  3. This notice may not be removed or altered from any source distribution.
//

#import "AEBlockChannel.h"

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
@interface AEBlockChannel ()
@property (nonatomic, copy) AEBlockChannelBlock block;
@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
@implementation AEBlockChannel
@synthesize block = _block;

+ (AEBlockChannel*)channelWithBlock:(AEBlockChannelBlock)block {
    return [[AEBlockChannel alloc] initWithBlock:block];
}

- (id)initWithBlock:(AEBlockChannelBlock)block {
    if ( !(self = [super init]) ) self = nil;
    self.volume = 1.0;
    self.pan = 0.0;
    self.block = block;
    self.channelIsMuted = NO;
    self.channelIsPlaying = YES;
    return self;
}



static OSStatus renderCallback(__unsafe_unretained AEBlockChannel *THIS,
                               __unsafe_unretained AEAudioController *audioController,
                               const AudioTimeStamp     *time,
                               UInt32                    frames,
                               AudioBufferList          *audio) {
    // 对于Block, 环境不重要；中啊哟的是处理: time, frames, audio的请求
    THIS->_block(time, frames, audio);
    return noErr;
}

-(AEAudioRenderCallback)renderCallback {
    return renderCallback;
}

@end
