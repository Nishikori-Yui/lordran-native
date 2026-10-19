// Feed the production decoder the original MP4 samples, including B frames.
// Reference images come from a separate AVAssetReader decode of the same track.
#import <AVFoundation/AVFoundation.h>
#include "../dm_movie_avc.h"
#include "../dm_movie_sps.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int images, packets, reordered, different;
static int64_t previous_pts;
static NSArray<AVAssetTrackSegment *> *reference_segments;
static NSMutableSet<NSNumber *> *pending_pts;
static int first_output_packet, reorder_limit;
static double max_error;

static AVAssetReaderTrackOutput *reader(NSString *path, BOOL compressed, AVAssetReader **owner) {
    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:path]];
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    assert(track);
    if (!compressed) reference_segments = track.segments;
    NSError *error = nil;
    *owner = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    assert(*owner);
    NSDictionary *settings = compressed ? nil : @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};
    AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:settings];
    [*owner addOutput:output];
    assert([*owner startReading]);
    return output;
}
static void compare(CVPixelBufferRef image, int64_t pts, AVAssetReaderTrackOutput *reference) {
    assert([pending_pts containsObject:@(pts)]);
    [pending_pts removeObject:@(pts)];
    assert(!images || pts > previous_pts);
    previous_pts = pts;
    if (!first_output_packet) first_output_packet = packets;
    // Compressed samples use media time; decoded AVAssetReader samples use
    // the edit-list timeline. Map the original PTS before comparing images.
    int64_t reference_pts = INT64_MIN;
    for (AVAssetTrackSegment *segment in reference_segments) {
        if (segment.empty) continue;
        CMTimeMapping map = segment.timeMapping;
        double start = CMTimeGetSeconds(map.source.start) * 1000000;
        double end = CMTimeGetSeconds(CMTimeRangeGetEnd(map.source)) * 1000000;
        if (pts < start - 1 || pts >= end + 1) continue;
        CMTime target = CMTimeMapTimeFromRangeToRange(CMTimeMake(pts, 1000000), map.source, map.target);
        reference_pts = CMTimeConvertScale(target, 1000000, kCMTimeRoundingMethod_RoundHalfAwayFromZero).value;
        break;
    }
    assert(reference_pts != INT64_MIN);
    CMSampleBufferRef expected;
    // Empty edits may contribute samples without an image.
    while ((expected = [reference copyNextSampleBuffer])) {
        if (CMSampleBufferGetImageBuffer(expected) &&
            CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(expected)) * 1000000 >= reference_pts - 1) break;
        CFRelease(expected);
    }
    assert(expected);
    CVPixelBufferRef ref = CMSampleBufferGetImageBuffer(expected);
    assert(ref);
    int64_t ref_pts = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(expected), 1000000, kCMTimeRoundingMethod_RoundHalfAwayFromZero).value;
    if (llabs(reference_pts - ref_pts) > 1) fprintf(stderr, "timestamp mismatch: media=%lld mapped=%lld expected=%lld\n", (long long)pts, (long long)reference_pts, (long long)ref_pts);
    assert(llabs(reference_pts - ref_pts) <= 1);
    assert(CVPixelBufferGetWidth(image) == CVPixelBufferGetWidth(ref));
    assert(CVPixelBufferGetHeight(image) == CVPixelBufferGetHeight(ref));
    CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(ref, kCVPixelBufferLock_ReadOnly);
    uint64_t error = 0, samples = 0, light = 0;
    for (int plane = 0; plane < 2; plane++) {
        const uint8_t *a = CVPixelBufferGetBaseAddressOfPlane(image, plane), *b = CVPixelBufferGetBaseAddressOfPlane(ref, plane);
        size_t as = CVPixelBufferGetBytesPerRowOfPlane(image, plane), bs = CVPixelBufferGetBytesPerRowOfPlane(ref, plane);
        size_t width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeightOfPlane(image, plane);
        for (size_t y = 0; y < height; y += 8) for (size_t x = 0; x < width; x += 8) {
            error += (unsigned)abs(a[y * as + x] - b[y * bs + x]); samples++;
            if (!plane) light += a[y * as + x] > 32;
        }
    }
    double mean = (double)error / samples;
    if (mean > max_error) max_error = mean;
    if (mean > 2) fprintf(stderr, "pixel mismatch: frame=%d timestamp=%lld mean_absolute_error=%f\n", images, (long long)pts, mean);
    if (mean > 2) {
        fprintf(stderr, "formats: actual=%#x reference=%#x\n", (unsigned)CVPixelBufferGetPixelFormatType(image), (unsigned)CVPixelBufferGetPixelFormatType(ref));
        for (int plane = 0; plane < 2; plane++) {
            const uint8_t *a = CVPixelBufferGetBaseAddressOfPlane(image, plane), *b = CVPixelBufferGetBaseAddressOfPlane(ref, plane);
            size_t as = CVPixelBufferGetBytesPerRowOfPlane(image, plane), bs = CVPixelBufferGetBytesPerRowOfPlane(ref, plane);
            uint64_t sum = 0, count = 0, large = 0; int64_t bias = 0; int maximum = 0;
            for (size_t y = 0; y < CVPixelBufferGetHeightOfPlane(image, plane); y++)
                for (size_t x = 0; x < CVPixelBufferGetWidth(image); x++) {
                    int difference = a[y * as + x] - b[y * bs + x], absolute = abs(difference);
                    sum += absolute; bias += difference; count++; large += absolute > 8;
                    if (absolute > maximum) maximum = absolute;
                }
            fprintf(stderr, "plane=%d mean=%f bias=%f max=%d differences_over_8=%llu\n", plane, (double)sum/count, (double)bias/count, maximum, (unsigned long long)large);
        }
    }
    assert(mean <= 2);
    different += light > 8;
    CVPixelBufferUnlockBaseAddress(ref, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
    CFRelease(expected);
    images++;
}
static void drain(dm_avc *decoder, AVAssetReaderTrackOutput *reference) {
    int64_t pts;
    CVPixelBufferRef image;
    while ((image = dm_avc_pop(decoder, &pts))) {
        compare(image, pts, reference);
        CVPixelBufferRelease(image);
    }
}
static void copy_test(void) {
    CVPixelBufferRef image = NULL;
    assert(!CVPixelBufferCreate(NULL, 16, 10, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, NULL, &image));
    CVPixelBufferLockBaseAddress(image, 0);
    for (int plane = 0; plane < 2; plane++) {
        uint8_t *p = CVPixelBufferGetBaseAddressOfPlane(image, plane);
        size_t stride = CVPixelBufferGetBytesPerRowOfPlane(image, plane);
        size_t height = CVPixelBufferGetHeightOfPlane(image, plane);
        memset(p, 0xee, stride * height);
        for (size_t y = 0; y < height; y++) memset(p + y * stride, plane ? 128 : 80, 16);
    }
    CVPixelBufferUnlockBaseAddress(image, 0);
    uint8_t nv12[20 * 12 * 3 / 2], rgba[20 * 12 * 4];
    assert(!dm_avc_copy(image, nv12, 20, 12, 0));
    for (int y = 0; y < 12; y++) for (int x = 0; x < 20; x++) assert(nv12[y * 20 + x] == (x < 16 && y < 10 ? 80 : 16));
    for (size_t i = 20 * 12; i < sizeof nv12; i++) assert(nv12[i] == 128);
    assert(!dm_avc_copy(image, rgba, 20, 12, 1));
    for (int y = 0; y < 12; y++) for (int x = 0; x < 20; x++) {
        uint8_t *p = rgba + (y * 20 + x) * 4;
        assert(p[3] == 255);
        assert(p[0] == (x < 16 && y < 10 ? 75 : 0) && p[0] == p[1] && p[1] == p[2]);
    }
    assert(dm_avc_copy(image, rgba, 19, 12, 1));
    CVPixelBufferRelease(image);
}
static void run(NSString *path, BOOL annex) {
    AVAssetReader *input_owner, *reference_owner;
    AVAssetReaderTrackOutput *input = reader(path, YES, &input_owner);
    AVAssetReaderTrackOutput *reference = reader(path, NO, &reference_owner);
    dm_avc *decoder = dm_avc_create(); assert(decoder);
    uint8_t invalid[] = {1, 2, 3};
    assert(dm_avc_configure(decoder, invalid, sizeof invalid));
    images = packets = reordered = different = first_output_packet = 0; max_error = 0;
    pending_pts = [NSMutableSet new];
    int64_t last_input = INT64_MIN;
    CMSampleBufferRef sample;
    while ((sample = [input copyNextSampleBuffer])) { @autoreleasepool {
        if (!CMSampleBufferGetDataBuffer(sample) || !CMSampleBufferGetFormatDescription(sample) || !CMSampleBufferGetNumSamples(sample)) {
            CFRelease(sample); continue;
        }
        if (!packets) {
            CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
            const uint8_t *sps, *pps; size_t sn, pn, count; int length_size;
            OSStatus status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, &sps, &sn, &count, &length_size);
            if (status) { fprintf(stderr, "parameter-set lookup failed: status=%d\n", (int)status); CFShow(format); }
            assert(!status);
            reorder_limit = dm_movie_sps_reorder(sps, sn);
            assert(!CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 1, &pps, &pn, &count, &length_size));
            assert(sn >= 4 && sn <= 65535 && pn <= 65535 && length_size == 4);
            size_t size = 11 + sn + pn; uint8_t *avcc = malloc(size); assert(avcc);
            uint8_t header[] = {1, sps[1], sps[2], sps[3], 0xff, 0xe1, (uint8_t)(sn >> 8), (uint8_t)sn};
            memcpy(avcc, header, sizeof header); memcpy(avcc + 8, sps, sn);
            avcc[8 + sn] = 1; avcc[9 + sn] = (uint8_t)(pn >> 8); avcc[10 + sn] = (uint8_t)pn; memcpy(avcc + 11 + sn, pps, pn);
            assert(!dm_avc_configure(decoder, avcc, size)); free(avcc);
            uint8_t sei_only[] = {0, 0, 0, 1, 6, 0x80};
            assert(!dm_avc_submit(decoder, sei_only, sizeof sei_only, -1000000));
        }
        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
        size_t size = CMBlockBufferGetDataLength(block);
        uint8_t *data = malloc(size); assert(data);
        assert(!CMBlockBufferCopyDataBytes(block, 0, size, data));
        if (annex) {
            size_t pos = 0;
            while (pos < size) {
                assert(size - pos >= 4);
                uint32_t length = (uint32_t)data[pos] << 24 | (uint32_t)data[pos + 1] << 16 | (uint32_t)data[pos + 2] << 8 | data[pos + 3];
                assert(length && length <= size - pos - 4);
                data[pos] = data[pos + 1] = data[pos + 2] = 0; data[pos + 3] = 1;
                pos += 4 + length;
            }
        }
        int64_t pts = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample), 1000000, kCMTimeRoundingMethod_RoundHalfAwayFromZero).value;
        assert(![pending_pts containsObject:@(pts)]);
        [pending_pts addObject:@(pts)];
        reordered += pts < last_input; last_input = pts;
        int err = dm_avc_submit(decoder, data, size, pts);
        if (err) fprintf(stderr, "decode failure: packet=%d bytes=%zu status=%d\n", packets, size, err);
        assert(!err);
        free(data); CFRelease(sample); packets++;
        drain(decoder, reference);
    } }
    assert(input_owner.status == AVAssetReaderStatusCompleted);
    assert(!dm_avc_end(decoder)); drain(decoder, reference);
    assert(images == packets);
    assert(pending_pts.count == 0);
    assert(first_output_packet <= reorder_limit + 1);
    assert(different > 0);
    assert(![reference copyNextSampleBuffer]);
    assert(reference_owner.status == AVAssetReaderStatusCompleted);
    assert(!dm_avc_ready(decoder));
    dm_avc_destroy(decoder);
    printf("AVC PASS: %s input=%s packets=%d reference_matched_frames=%d first_output_packet=%d reorder_limit=%d reordered_packets=%d visible_frames=%d max_mean_error=%.6f\n",
           path.lastPathComponent.UTF8String, annex ? "Annex-B" : "AVCC", packets, images, first_output_packet, reorder_limit, reordered, different, max_error);
}
int main(int argc, const char **argv) { @autoreleasepool {
    copy_test();
    assert(argc > 1);
    for (int i = 1; i < argc; i++) {
        run(@(argv[i]), NO);
        run(@(argv[i]), YES);
    }
    return 0;
} }
