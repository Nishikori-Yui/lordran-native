// Feed the production decoder the original MP4 samples, including B frames.
// References use AVAssetReader, or byte-exact software-decoded NV12 fixtures.
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
static int mismatches;
static FILE *nv12_reference;
static double max_mean[3];
static unsigned max_absolute[3];
static uint64_t total_error[3], total_samples[3];

typedef struct {
    const uint8_t *plane[2];
    size_t stride[2], width, height;
} pixels;
typedef struct { uint64_t sum, count; unsigned maximum; } pixel_error;

static pixel_error measure(pixels a, pixels b, int component) {
    assert(a.width == b.width && a.height == b.height);
    int plane = component != 0;
    size_t width = a.width >> plane, height = a.height >> plane;
    size_t step = plane ? 2 : 1, offset = component == 2;
    pixel_error error = {0};
    for (size_t y = 0; y < height; y++) for (size_t x = 0; x < width; x++) {
        unsigned difference = (unsigned)abs(a.plane[plane][y * a.stride[plane] + x * step + offset] -
                                             b.plane[plane][y * b.stride[plane] + x * step + offset]);
        error.sum += difference; error.count++;
        if (difference > error.maximum) error.maximum = difference;
    }
    return error;
}
static pixels view(CVPixelBufferRef image) {
    assert(CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    assert(CVPixelBufferGetPlaneCount(image) == 2);
    size_t width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image);
    assert(width && height && !(width & 1) && !(height & 1));
    assert(CVPixelBufferGetWidthOfPlane(image, 0) == width);
    assert(CVPixelBufferGetHeightOfPlane(image, 0) == height);
    assert(CVPixelBufferGetWidthOfPlane(image, 1) == width / 2);
    assert(CVPixelBufferGetHeightOfPlane(image, 1) == height / 2);
    pixels p = {{CVPixelBufferGetBaseAddressOfPlane(image, 0), CVPixelBufferGetBaseAddressOfPlane(image, 1)},
                {CVPixelBufferGetBytesPerRowOfPlane(image, 0), CVPixelBufferGetBytesPerRowOfPlane(image, 1)}, width, height};
    assert(p.plane[0] && p.plane[1] && p.stride[0] >= width && p.stride[1] >= width);
    return p;
}
static void measure_test(void) {
    uint8_t a[32 * 15], b[48 * 15];
    memset(a, 0xee, sizeof a); memset(b, 0x11, sizeof b);
    pixels av = {{a, a + 32 * 10}, {32, 32}, 16, 10};
    pixels bv = {{b, b + 48 * 10}, {48, 48}, 16, 10};
    for (int plane = 0; plane < 2; plane++) for (size_t y = 0; y < (10u >> plane); y++) {
        memset((uint8_t *)av.plane[plane] + y * av.stride[plane], 80, 16);
        memset((uint8_t *)bv.plane[plane] + y * bv.stride[plane], 80, 16);
    }
    // Distinct padding must be ignored; every visible byte must be measured,
    // including V and the final chroma pair missed by the old sparse loop.
    for (int plane = 0; plane < 2; plane++) for (size_t y = 0; y < (10u >> plane); y++) for (size_t x = 0; x < 16; x++) {
        uint8_t *sample = (uint8_t *)bv.plane[plane] + y * bv.stride[plane] + x;
        *sample += 17;
        for (int c = 0; c < 3; c++) {
            int changed = c == (plane ? 1 + (int)(x & 1) : 0);
            pixel_error error = measure(av, bv, c);
            assert(error.count == (c ? 40 : 160));
            assert(error.sum == (changed ? 17u : 0u));
            assert(error.maximum == (changed ? 17u : 0u));
        }
        *sample -= 17;
    }
}

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
    assert(!CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly));
    assert(!CVPixelBufferLockBaseAddress(ref, kCVPixelBufferLock_ReadOnly));
    pixels actual = view(image), expected_pixels = view(ref);
    uint8_t *raw = NULL;
    if (nv12_reference) {
        size_t size = actual.width * actual.height * 3 / 2;
        raw = malloc(size); assert(raw);
        assert(fread(raw, 1, size, nv12_reference) == size);
        expected_pixels = (pixels){{raw, raw + actual.width * actual.height},
                                  {actual.width, actual.width}, actual.width, actual.height};
    }
    int mismatch = 0;
    for (int c = 0; c < 3; c++) {
        pixel_error error = measure(actual, expected_pixels, c);
        double mean = (double)error.sum / error.count;
        total_error[c] += error.sum; total_samples[c] += error.count;
        if (mean > max_mean[c]) max_mean[c] = mean;
        if (error.maximum > max_absolute[c]) max_absolute[c] = error.maximum;
        // Software fixtures require exact equality. The diagnostic Apple
        // reference retains 2 code values MAE, now enforced per component.
        if (nv12_reference ? error.maximum != 0 : mean > 2) {
            fprintf(stderr, "pixel mismatch: frame=%d timestamp=%lld component=%c mean=%f max=%u actual_stride=%zu reference_stride=%zu\n",
                    images, (long long)pts, "YUV"[c], mean, error.maximum, actual.stride[c != 0], expected_pixels.stride[c != 0]);
            mismatch = 1;
        }
    }
    mismatches += mismatch;
    free(raw);
    unsigned light = 0;
    for (size_t y = 0; y < actual.height; y++) for (size_t x = 0; x < actual.width; x++)
        light += actual.plane[0][y * actual.stride[0] + x] > 32;
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
    assert(!CVPixelBufferLockBaseAddress(image, 0));
    uint8_t *uv = CVPixelBufferGetBaseAddressOfPlane(image, 1);
    size_t stride = CVPixelBufferGetBytesPerRowOfPlane(image, 1);
    for (int y = 0; y < 5; y++) for (int x = 0; x < 8; x++) {
        uv[y * stride + 2 * x] = (uint8_t)(40 + y * 8 + x);
        uv[y * stride + 2 * x + 1] = (uint8_t)(200 - y * 8 - x);
    }
    CVPixelBufferUnlockBaseAddress(image, 0);
    assert(!dm_avc_copy(image, nv12, 20, 12, 0));
    for (int y = 0; y < 6; y++) for (int x = 0; x < 10; x++) {
        const uint8_t *p = nv12 + 20 * 12 + y * 20 + 2 * x;
        assert(p[0] == (x < 8 && y < 5 ? 40 + y * 8 + x : 128));
        assert(p[1] == (x < 8 && y < 5 ? 200 - y * 8 - x : 128));
    }
    CVPixelBufferRelease(image);
}
static int run(NSString *path, BOOL annex, const char *raw_path) {
    AVAssetReader *input_owner, *reference_owner;
    AVAssetReaderTrackOutput *input = reader(path, YES, &input_owner);
    AVAssetReaderTrackOutput *reference = reader(path, NO, &reference_owner);
    dm_avc *decoder = dm_avc_create(); assert(decoder);
    uint8_t invalid[] = {1, 2, 3};
    assert(dm_avc_configure(decoder, invalid, sizeof invalid));
    images = packets = reordered = different = first_output_packet = mismatches = 0;
    memset(max_mean, 0, sizeof max_mean); memset(max_absolute, 0, sizeof max_absolute);
    memset(total_error, 0, sizeof total_error); memset(total_samples, 0, sizeof total_samples);
    nv12_reference = raw_path ? fopen(raw_path, "rb") : NULL;
    assert(!raw_path || nv12_reference);
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
    if (nv12_reference) {
        assert(fgetc(nv12_reference) == EOF && !ferror(nv12_reference));
        assert(!fclose(nv12_reference)); nv12_reference = NULL;
    }
    assert(!dm_avc_ready(decoder));
    dm_avc_destroy(decoder);
    printf("AVC %s: %s input=%s reference=%s packets=%d reference_matched_frames=%d first_output_packet=%d reorder_limit=%d reordered_packets=%d visible_frames=%d mismatched_frames=%d\n",
           mismatches ? "FAIL" : "PASS", path.lastPathComponent.UTF8String, annex ? "Annex-B" : "AVCC", raw_path ? "software-NV12-exact" : "AVAssetReader", packets, images, first_output_packet, reorder_limit, reordered, different, mismatches);
    for (int c = 0; c < 3; c++)
        printf("component=%c samples=%llu mean=%.6f max_frame_mean=%.6f max=%u\n", "YUV"[c], (unsigned long long)total_samples[c], (double)total_error[c] / total_samples[c], max_mean[c], max_absolute[c]);
    return mismatches != 0;
}
int main(int argc, const char **argv) { @autoreleasepool {
    measure_test();
    copy_test();
    assert(argc > 1);
    int failed = 0;
    if (!strcmp(argv[1], "--nv12-reference")) {
        assert(argc == 4);
        failed |= run(@(argv[3]), NO, argv[2]);
        failed |= run(@(argv[3]), YES, argv[2]);
        return failed;
    }
    for (int i = 1; i < argc; i++) {
        failed |= run(@(argv[i]), NO, NULL);
        failed |= run(@(argv[i]), YES, NULL);
    }
    return failed;
} }
