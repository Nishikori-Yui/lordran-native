#include "dm_movie_avc.h"
#include "dm_movie_sps.h"
#include "dm_log.h"
#include <CoreMedia/CoreMedia.h>
#include <VideoToolbox/VideoToolbox.h>
#include <stdlib.h>
#include <string.h>

enum { AVC_QUEUE = 32, AVC_MAX_PACKET = 4 << 20 };
struct dm_avc {
    VTDecompressionSessionRef session;
    CMVideoFormatDescriptionRef format;
    uint8_t *sps, *pps;
    size_t sps_size, pps_size;
    int length_size, reorder, count, ended, callback_error;
    struct { CVPixelBufferRef image; int64_t pts; } frames[AVC_QUEUE];
};

static void clear_frames(dm_avc *d) {
    for (int i = 0; i < d->count; i++) CVPixelBufferRelease(d->frames[i].image);
    d->count = 0;
}
static void close_session(dm_avc *d) {
    if (d->session) {
        VTDecompressionSessionInvalidate(d->session);
        CFRelease(d->session); d->session = NULL;
    }
    if (d->format) { CFRelease(d->format); d->format = NULL; }
}
dm_avc *dm_avc_create(void) {
    dm_avc *d = calloc(1, sizeof *d);
    if (d) { d->length_size = 4; d->reorder = 16; }
    return d;
}
void dm_avc_destroy(dm_avc *d) {
    if (!d) return;
    close_session(d); clear_frames(d);
    free(d->sps); free(d->pps); free(d);
}
static int save_set(dm_avc *d, const uint8_t *p, size_t n) {
    if (!n || n > 65535) return -50;
    int type = p[0] & 31;
    uint8_t **data = type == 7 ? &d->sps : type == 8 ? &d->pps : NULL;
    size_t *size = type == 7 ? &d->sps_size : &d->pps_size;
    if (!data) return 0;
    if (*size == n && !memcmp(*data, p, n)) return 0;
    uint8_t *copy = malloc(n);
    if (!copy) return -108;
    memcpy(copy, p, n);
    close_session(d); clear_frames(d);
    free(*data); *data = copy; *size = n; d->ended = 0;
    if (type == 7) d->reorder = dm_movie_sps_reorder(p, n);
    return 0;
}
static size_t start_code(const uint8_t *p, size_t n, size_t at, size_t *width) {
    for (size_t i = at; i + 2 < n; i++) {
        if (p[i] || p[i + 1]) continue;
        if (p[i + 2] == 1) { *width = 3; return i; }
        if (i + 3 < n && p[i + 2] == 0 && p[i + 3] == 1) { *width = 4; return i; }
    }
    *width = 0; return n;
}
typedef int (*nal_fn)(void *, const uint8_t *, size_t);
static int walk_nals(const uint8_t *p, size_t n, int length_size, nal_fn fn, void *ctx) {
    if (!p || !n || n > AVC_MAX_PACKET) return -50;
    size_t check = 0;
    int prefixed = length_size >= 1 && length_size <= 4;
    while (prefixed && check < n) {
        if (n - check < (size_t)length_size) { prefixed = 0; break; }
        uint32_t size = 0;
        for (int i = 0; i < length_size; i++) size = size << 8 | p[check++];
        if (!size || size > n - check || (p[check] & 0x80)) { prefixed = 0; break; }
        check += size;
    }
    // A valid length prefix such as 00 00 01 06 is not a three-byte
    // Annex B start code. Validate the entire length stream first.
    size_t prefix = 0, first = start_code(p, n, 0, &prefix);
    int annex = !prefixed && first == 0;
    if (!prefixed && !annex) return -50;
    size_t pos = 0;
    while (pos < n) {
        size_t begin, end;
        if (annex) {
            size_t next_prefix;
            begin = pos + prefix;
            end = start_code(p, n, begin, &next_prefix);
            pos = end; prefix = next_prefix;
        } else {
            if (length_size < 1 || length_size > 4 || n - pos < (size_t)length_size) return -50;
            uint32_t size = 0;
            for (int i = 0; i < length_size; i++) size = size << 8 | p[pos++];
            if (!size || size > n - pos) return -50;
            begin = pos; end = pos + size; pos = end;
        }
        if (end <= begin || (p[begin] & 0x80)) return -50;
        int err = fn(ctx, p + begin, end - begin);
        if (err) return err;
    }
    return 0;
}
static int config_nal(void *ctx, const uint8_t *p, size_t n) { return save_set(ctx, p, n); }
int dm_avc_configure(dm_avc *d, const uint8_t *p, size_t n) {
    if (!d || !p || !n || n > AVC_MAX_PACKET) return -50;
    if (n >= 7 && p[0] == 1) {
        int ls = (p[4] & 3) + 1, ns = p[5] & 31;
        if (!ns || ls == 3) return -50;
        size_t pos = 6;
        for (int kind = 0; kind < 2; kind++) {
            int count = kind ? (pos < n ? p[pos++] : 0) : ns;
            if (!count) return -50;
            for (int i = 0; i < count; i++) {
                if (n - pos < 2) return -50;
                size_t size = (size_t)p[pos] << 8 | p[pos + 1]; pos += 2;
                if (!size || size > n - pos || (p[pos] & 31) != (kind ? 8 : 7)) return -50;
                int err = save_set(d, p + pos, size);
                if (err) return err;
                pos += size;
            }
        }
        d->length_size = ls; d->ended = 0;
        return 0;
    }
    if ((p[0] & 31) == 7 || (p[0] & 31) == 8) return save_set(d, p, n);
    return walk_nals(p, n, d->length_size, config_nal, d);
}
static void decoded(void *context, void *frame_context, OSStatus status, VTDecodeInfoFlags flags,
                    CVImageBufferRef image, CMTime pts, CMTime duration) {
    (void)frame_context; (void)flags; (void)duration;
    dm_avc *d = context;
    if (status) { d->callback_error = status; return; }
    if (!image) return;
    if (d->count == AVC_QUEUE || !CMTIME_IS_NUMERIC(pts)) { d->callback_error = -50; return; }
    int64_t timestamp = CMTimeConvertScale(pts, 1000000, kCMTimeRoundingMethod_RoundHalfAwayFromZero).value;
    int i = d->count++;
    while (i && d->frames[i - 1].pts > timestamp) { d->frames[i] = d->frames[i - 1]; i--; }
    CVPixelBufferRetain(image);
    d->frames[i].image = image; d->frames[i].pts = timestamp;
}
static int open_session(dm_avc *d) {
    if (d->session) return 0;
    if (!d->sps || !d->pps) return -12910;
    const uint8_t *sets[] = {d->sps, d->pps}; size_t sizes[] = {d->sps_size, d->pps_size};
    // Every submitted packet is normalized to four-byte NAL lengths.
    OSStatus err = CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL, 2, sets, sizes, 4, &d->format);
    if (err) return err;
    int32_t pixel_format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &pixel_format);
    const void *keys[] = {kCVPixelBufferPixelFormatTypeKey}, *values[] = {number};
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    VTDecompressionOutputCallbackRecord callback = {decoded, d};
    err = VTDecompressionSessionCreate(NULL, d->format, NULL, attrs, &callback, &d->session);
    CFRelease(attrs); CFRelease(number);
    if (err) { close_session(d); return err; }
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(d->format);
    DM_LOG_INFO("movie", "VideoToolbox AVC decoder ready: width=%d height=%d nal_length=%d reorder_frames=%d", dims.width, dims.height, d->length_size, d->reorder);
    return 0;
}
struct packet { dm_avc *decoder; uint8_t *bytes; size_t size, capacity; int vcl; };
static int append_nal(void *context, const uint8_t *p, size_t n) {
    struct packet *packet = context;
    int type = p[0] & 31;
    if (type == 7 || type == 8) return save_set(packet->decoder, p, n);
    if (type >= 1 && type <= 5) packet->vcl = 1;
    if (packet->size + 4 + n > packet->capacity) {
        size_t capacity = packet->size + 4 + n;
        uint8_t *bytes = realloc(packet->bytes, capacity);
        if (!bytes) return -108;
        packet->bytes = bytes; packet->capacity = capacity;
    }
    uint8_t *out = packet->bytes + packet->size;
    out[0] = (uint8_t)(n >> 24); out[1] = (uint8_t)(n >> 16); out[2] = (uint8_t)(n >> 8); out[3] = (uint8_t)n;
    memcpy(out + 4, p, n); packet->size += 4 + n;
    return 0;
}
int dm_avc_submit(dm_avc *d, const uint8_t *p, size_t n, int64_t pts_us) {
    if (!d || d->ended || d->count >= AVC_QUEUE - 1) return -50;
    struct packet packet = {.decoder = d};
    int err = walk_nals(p, n, d->length_size, append_nal, &packet);
    if (err || !packet.vcl) { free(packet.bytes); return err; }
    err = open_session(d);
    CMBlockBufferRef block = NULL; CMSampleBufferRef sample = NULL;
    if (!err) err = CMBlockBufferCreateWithMemoryBlock(NULL, NULL, packet.size, NULL, NULL, 0, packet.size, 0, &block);
    if (!err) err = CMBlockBufferReplaceDataBytes(packet.bytes, block, 0, packet.size);
    free(packet.bytes);
    CMSampleTimingInfo timing = {kCMTimeInvalid, CMTimeMake(pts_us, 1000000), kCMTimeInvalid};
    if (!err) err = CMSampleBufferCreateReady(NULL, block, d->format, 1, 1, &timing, 1, &packet.size, &sample);
    if (!err) {
        d->callback_error = 0;
        // Neither asynchronous nor temporal flags are set: the callback has
        // completed when DecodeFrame returns, including on Simulator.
        err = VTDecompressionSessionDecodeFrame(d->session, sample, 0, NULL, NULL);
        if (!err) err = d->callback_error;
    }
    if (sample) CFRelease(sample);
    if (block) CFRelease(block);
    return err;
}
int dm_avc_end(dm_avc *d) {
    if (!d) return -50;
    d->callback_error = 0;
    int err = d->session ? VTDecompressionSessionWaitForAsynchronousFrames(d->session) : 0;
    if (!err) err = d->callback_error;
    d->ended = 1;
    return err;
}
CVPixelBufferRef dm_avc_pop(dm_avc *d, int64_t *pts_us) {
    if (!dm_avc_ready(d)) return NULL;
    CVPixelBufferRef image = d->frames[0].image;
    *pts_us = d->frames[0].pts;
    memmove(d->frames, d->frames + 1, (size_t)--d->count * sizeof *d->frames);
    return image;
}
int dm_avc_ready(const dm_avc *d) {
    return d && d->count && (d->ended || d->count > d->reorder);
}
int dm_avc_copy(CVPixelBufferRef image, uint8_t *dst, int w, int h, int rgba) {
    if (!image || !dst || w <= 0 || h <= 0 || (w & 1) || (h & 1)) return -50;
    OSType format = CVPixelBufferGetPixelFormatType(image);
    int full = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    if (!full && format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) return -50;
    if (CVPixelBufferGetPlaneCount(image) != 2 || CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly)) return -50;
    int iw = (int)CVPixelBufferGetWidth(image), ih = (int)CVPixelBufferGetHeight(image);
    int cw = iw < w ? iw : w, ch = ih < h ? ih : h;
    const uint8_t *yp = CVPixelBufferGetBaseAddressOfPlane(image, 0), *uv = CVPixelBufferGetBaseAddressOfPlane(image, 1);
    size_t ys = CVPixelBufferGetBytesPerRowOfPlane(image, 0), uvs = CVPixelBufferGetBytesPerRowOfPlane(image, 1);
    if (!rgba) {
        memset(dst, 16, (size_t)w * h); memset(dst + (size_t)w * h, 128, (size_t)w * h / 2);
        for (int y = 0; y < ch; y++) memcpy(dst + (size_t)y * w, yp + (size_t)y * ys, cw);
        for (int y = 0; y < ch / 2; y++) memcpy(dst + (size_t)w * h + (size_t)y * w, uv + (size_t)y * uvs, cw & ~1);
    } else {
        CFTypeRef matrix = CVBufferCopyAttachment(image, kCVImageBufferYCbCrMatrixKey, NULL);
        int hd = matrix ? CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2) : ih >= 720;
        if (matrix) CFRelease(matrix);
        double ky = full ? 1 : 255.0 / 219, kc = full ? 1 : 255.0 / 224;
        int Y = (int)(ky * 65536), RV = (int)((hd ? 1.5748 : 1.402) * kc * 65536);
        int GU = (int)((hd ? 0.1873 : 0.3441) * kc * 65536), GV = (int)((hd ? 0.4681 : 0.7141) * kc * 65536), BU = (int)((hd ? 1.8556 : 1.772) * kc * 65536);
        for (size_t i = 0; i < (size_t)w * h; i++) ((uint32_t *)dst)[i] = 0xff000000;
        for (int y = 0; y < ch; y++) for (int x = 0; x < cw; x++) {
            int l = (yp[(size_t)y * ys + x] - (full ? 0 : 16)) * Y;
            int u = uv[(size_t)(y / 2) * uvs + (x & ~1)] - 128, v = uv[(size_t)(y / 2) * uvs + (x & ~1) + 1] - 128;
            int rgb[] = {(l + RV * v + 32768) >> 16, (l - GU * u - GV * v + 32768) >> 16, (l + BU * u + 32768) >> 16};
            for (int c = 0; c < 3; c++) dst[((size_t)y * w + x) * 4 + c] = (uint8_t)(rgb[c] < 0 ? 0 : rgb[c] > 255 ? 255 : rgb[c]);
        }
    }
    CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
    return 0;
}
