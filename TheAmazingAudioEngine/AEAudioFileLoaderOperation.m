//
//  AEAudioFileLoaderOperation.m
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 17/04/2012.
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

#import "AEAudioFileLoaderOperation.h"
#import "AEUtilities.h"

static const int kIncrementalLoadBufferSize = 4096;
static const int kMaxAudioFileReadSize = 16384;

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
@interface AEAudioFileLoaderOperation ()
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, assign) AudioStreamBasicDescription targetAudioDescription;
@property (nonatomic, readwrite) AudioBufferList *bufferList;
@property (nonatomic, readwrite) UInt32 lengthInFrames;
@property (nonatomic, strong, readwrite) NSError *error;
@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
@implementation AEAudioFileLoaderOperation
@synthesize url = _url, targetAudioDescription = _targetAudioDescription, audioReceiverBlock = _audioReceiverBlock,
            completedBlock=_completedBlock, bufferList = _bufferList, lengthInFrames = _lengthInFrames, error = _error;

// 获取Information
+ (BOOL)infoForFileAtURL:(NSURL*)url audioDescription:(AudioStreamBasicDescription*)audioDescription
          lengthInFrames:(UInt32*)lengthInFrames error:(NSError**)error {
    if ( audioDescription ) memset(audioDescription, 0, sizeof(AudioStreamBasicDescription));
    
    ExtAudioFileRef audioFile;
    OSStatus status;
    
    // 1. Open file
    status = ExtAudioFileOpenURL((__bridge CFURLRef)url, &audioFile);
    if ( !AECheckOSStatus(status, "ExtAudioFileOpenURL") ) {
        if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                              userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Couldn't open the audio file", @"")}];
        return NO;
    }
    
    // 2. 读取AudioStreamBasicDescription
    if ( audioDescription ) {
        // Get data format
        UInt32 size = sizeof(AudioStreamBasicDescription);
        status = ExtAudioFileGetProperty(audioFile, kExtAudioFileProperty_FileDataFormat, &size, audioDescription);
        if ( !AECheckOSStatus(status, "ExtAudioFileGetProperty") ) {
            if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                                  userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Couldn't read the audio file", @"")}];
            return NO;
        }
    }    
    
    // 3. 读取文件的Frames
    if ( lengthInFrames ) {
        // Get length
        UInt64 fileLengthInFrames = 0;
        UInt32 size = sizeof(fileLengthInFrames);
        status = ExtAudioFileGetProperty(audioFile, kExtAudioFileProperty_FileLengthFrames, &size, &fileLengthInFrames);
        if ( !AECheckOSStatus(status, "ExtAudioFileGetProperty(kExtAudioFileProperty_FileLengthFrames)") ) {
            ExtAudioFileDispose(audioFile);
            if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                                  userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Couldn't read the audio file", @"")}];
            return NO;
        }
        *lengthInFrames = (UInt32)fileLengthInFrames;
    }
    
    // 4. 释放文件资源
    ExtAudioFileDispose(audioFile);
    
    return YES;
}

-(id)initWithFileURL:(NSURL *)url targetAudioDescription:(AudioStreamBasicDescription)audioDescription {
    if ( !(self = [super init]) ) return nil;
    
    self.url = url;
    self.targetAudioDescription = audioDescription;
    
    return self;
}


// Operation的主体
-(void)main {
    ExtAudioFileRef audioFile;
    OSStatus status;
    
    // 1. Open file
    status = ExtAudioFileOpenURL((__bridge CFURLRef)_url, &audioFile);
    if ( !AECheckOSStatus(status, "ExtAudioFileOpenURL") ) {
        self.error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                     userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Couldn't open the audio file", @"")}];
        return;
    }
    
    // 2. Get file data format
    AudioStreamBasicDescription fileAudioDescription;
    UInt32 size = sizeof(fileAudioDescription);
    status = ExtAudioFileGetProperty(audioFile, kExtAudioFileProperty_FileDataFormat, &size, &fileAudioDescription);
    if ( !AECheckOSStatus(status, "ExtAudioFileGetProperty(kExtAudioFileProperty_FileDataFormat)") ) {
        ExtAudioFileDispose(audioFile);
        self.error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                     userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Couldn't read the audio file", @"")}];
        return;
    }
    
    // 3. Apply client format
    //    注意两个不同的类型: kExtAudioFileProperty_FileDataFormat
    //                     kExtAudioFileProperty_ClientDataFormat
    //    如果SampleRate不一样，如何处理呢?
    status = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientDataFormat, sizeof(_targetAudioDescription), &_targetAudioDescription);
    if ( !AECheckOSStatus(status, "ExtAudioFileSetProperty(kExtAudioFileProperty_ClientDataFormat)") ) {
        ExtAudioFileDispose(audioFile);
        int fourCC = CFSwapInt32HostToBig(status);
        self.error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Couldn't convert the audio file (error %d/%4.4s)", @""), status, (char*)&fourCC]}];
        return;
    }
    
    // 4. Channels如何处理呢?
    //    输出的Channels多怎么办?
    if ( _targetAudioDescription.mChannelsPerFrame > fileAudioDescription.mChannelsPerFrame ) {
        // More channels in target format than file format - set up a map to duplicate channel
        SInt32 channelMap[_targetAudioDescription.mChannelsPerFrame];
        AudioConverterRef converter;
        AECheckOSStatus(ExtAudioFileGetProperty(audioFile, kExtAudioFileProperty_AudioConverter, &size, &converter),
                    "ExtAudioFileGetProperty(kExtAudioFileProperty_AudioConverter)");
        
        for ( int outChannel=0, inChannel=0; outChannel < _targetAudioDescription.mChannelsPerFrame; outChannel++ ) {
            channelMap[outChannel] = inChannel;
            // 如何映射恩?
            // 0 --> 0
            // 1 --> 1
            // 1 --> 2
            if ( inChannel+1 < fileAudioDescription.mChannelsPerFrame ) inChannel++;
        }
        // 设置文件的Conveter属性
        AECheckOSStatus(AudioConverterSetProperty(converter, kAudioConverterChannelMap, sizeof(SInt32)*_targetAudioDescription.mChannelsPerFrame, channelMap),
                    "AudioConverterSetProperty(kAudioConverterChannelMap)");
        
        // Config设置为NULL
        CFArrayRef config = NULL;
        AECheckOSStatus(ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ConverterConfig, sizeof(CFArrayRef), &config),
                    "ExtAudioFileSetProperty(kExtAudioFileProperty_ConverterConfig)");
    }
    
    // 5. Determine length in frames (in original file's sample rate)
    UInt64 fileLengthInFrames;
    size = sizeof(fileLengthInFrames);
    status = ExtAudioFileGetProperty(audioFile, kExtAudioFileProperty_FileLengthFrames, &size, &fileLengthInFrames);
    if ( !AECheckOSStatus(status, "ExtAudioFileGetProperty(kExtAudioFileProperty_FileLengthFrames)") ) {
        ExtAudioFileDispose(audioFile);
        self.error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                     userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Couldn't read the audio file", @"")}];
        return;
    }
    
    // 6. Calculate the true length in frames, given the original and target sample rates
    //    读取文件时就能实现SampleRate的转换
    fileLengthInFrames = ceil(fileLengthInFrames * (_targetAudioDescription.mSampleRate / fileAudioDescription.mSampleRate));
    
    // Prepare buffers
    // kAudioFormatFlagIsNonInterleaved 非交错的，每一个channel的samples是放在一起的
    int bufferCount = (_targetAudioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? _targetAudioDescription.mChannelsPerFrame : 1;
    int channelsPerBuffer = (_targetAudioDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 1 : _targetAudioDescription.mChannelsPerFrame;
    
    // 创建: AudioBufferList
    AudioBufferList *bufferList = AEAudioBufferListCreate(_targetAudioDescription, _audioReceiverBlock ? kIncrementalLoadBufferSize : (UInt32)fileLengthInFrames);
    
    if ( !bufferList ) {
        ExtAudioFileDispose(audioFile);
        self.error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOMEM 
                                     userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Not enough memory to open file", @"")}];
        return;
    }
    
    // 注意: scratchBufferList
    //      它只是一个带有头部信息的BufferList, 具体实现依赖于: bufferList
    AudioBufferList *scratchBufferList = AEAudioBufferListCreate(_targetAudioDescription, 0);
    
    // Perform read in multiple small chunks (otherwise ExtAudioFileRead crashes when performing sample rate conversion)
    // 文件读取如何和NSOperation集成在一起呢?
    UInt64 readFrames = 0;
    while ( readFrames < fileLengthInFrames && ![self isCancelled] ) {
        // 两种处理模式
        if ( _audioReceiverBlock ) {
            memcpy(scratchBufferList, bufferList, sizeof(AudioBufferList)+(bufferCount-1)*sizeof(AudioBuffer));
            for ( int i=0; i<scratchBufferList->mNumberBuffers; i++ ) {
                scratchBufferList->mBuffers[i].mDataByteSize = (UInt32)MIN(kIncrementalLoadBufferSize * _targetAudioDescription.mBytesPerFrame,
                                                                   (fileLengthInFrames-readFrames) * _targetAudioDescription.mBytesPerFrame);
            }
        } else {
            // 配置: scratchBufferList
            // 如果是: Interleaved，则该如何处理呢?
            for ( int i=0; i<scratchBufferList->mNumberBuffers; i++ ) {
                scratchBufferList->mBuffers[i].mNumberChannels = channelsPerBuffer;
                // ((mBitsPerSample / 8) * mChannelsPerFrame) == mBytesPerFrame
                // 如果是: interleaved, 则 mBytesPerFrame 可能是: 4 * N
                scratchBufferList->mBuffers[i].mData = (char*)bufferList->mBuffers[i].mData + readFrames*_targetAudioDescription.mBytesPerFrame;
                scratchBufferList->mBuffers[i].mDataByteSize = (UInt32)MIN(kMaxAudioFileReadSize, (fileLengthInFrames-readFrames) * _targetAudioDescription.mBytesPerFrame);
            }
        }
        
        // 从文件读取数据
        // Perform read
        UInt32 numberOfPackets = (UInt32)(scratchBufferList->mBuffers[0].mDataByteSize / _targetAudioDescription.mBytesPerFrame);
        status = ExtAudioFileRead(audioFile, &numberOfPackets, scratchBufferList);
        
        if ( status != noErr ) {
            ExtAudioFileDispose(audioFile);
            int fourCC = CFSwapInt32HostToBig(status);
            self.error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status 
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Couldn't read the audio file (error %d/%4.4s)", @""), status, (char*)&fourCC]}];
            return;
        }
        
        // 读取完毕
        if ( numberOfPackets == 0 ) {
            // Termination condition
            break;
        }
        
        // 通过: _audioReceiverBlock 来处理
        if ( _audioReceiverBlock ) {
            _audioReceiverBlock(bufferList, numberOfPackets);
        }
        
        readFrames += numberOfPackets;
    }
    
    // bufferList需要当前函数处理
    if ( _audioReceiverBlock ) {
        AEAudioBufferListFree(bufferList);
        bufferList = NULL;
    }
    
    free(scratchBufferList);
    
    // Clean up        
    ExtAudioFileDispose(audioFile);
    
    if ( [self isCancelled] ) {
        if ( bufferList ) {
            for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
                free(bufferList->mBuffers[i].mData);
            }
            free(bufferList);
            bufferList = NULL;
        }
    } else {
        // 如果没有取消，则需要记录状态
        _bufferList = bufferList;
        _lengthInFrames = (UInt32)fileLengthInFrames;
    }

    // 回调完成
    if ( _completedBlock ) {
        _completedBlock();
    }
}

@end
