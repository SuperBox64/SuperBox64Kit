#include "kit_stb.h"
#include <stdlib.h>

#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_NO_STDIO
#include "stb/stb_image.h"

#define STB_TRUETYPE_IMPLEMENTATION
#include "stb/stb_truetype.h"

unsigned char* kit_png_decode(const unsigned char* bytes, int len, int* w, int* h) {
    int comp = 0;
    return stbi_load_from_memory(bytes, len, w, h, &comp, 4);
}

/* SVG -> RGBA raster. The web host renders SVG through the browser; on native we
   rasterize at the SVG's intrinsic size. Returns malloc'd straight-alpha RGBA
   (free via kit_stb_free), 0 on failure.

   Two backends, selected at compile time:
   - resvg  (-DKIT_USE_RESVG): a FULL static-SVG renderer. Handles embedded raster
     <image> (base64 PNG), <mask> and <clipPath> — i.e. what the browser does.
     Required for UFO's PDF-derived emoji/effect/parallax SVGs (nanosvg renders
     those blank, which is why sprites showed as boxes and skyMtns came back 0x0).
   - nanosvg (default): minimal vector-path rasterizer. Fine for pure-vector SVGs;
     keeps games that don't link libresvg building unchanged. */
#include <string.h>
#ifdef KIT_USE_THORVG
#include "thorvg_capi.h"
/* Supersampled SVG raster. ss = device scale (e.g. 3 on a 1920px window of a 626px
   logical game). texW/texH = the ss-times pixel buffer that becomes the SDL texture;
   logW/logH = the SVG's intrinsic size. The host samples the hi-res texture through
   normalized UVs that use the LOGICAL size, so sprites are crisp at the screen
   resolution instead of upscaling a tiny declared-canvas raster (the soft grass/dirt).
   ThorVG renders at any size (tvg_picture_set_size), so this is the same
   1:1-with-screen trick canvas2d does. */
/* ThorVG's engine is process-global: the thread count is fixed on the first call and
   later calls are no-ops. Sprite decode runs at load time (not per-frame), so a small
   thread pool + the SIMD SW raster is plenty. */
static void kit_tvg_init(void) {
    static int inited = 0;
    if (!inited) { tvg_engine_init(2); inited = 1; }
}
unsigned char* kit_svg_decode_hi(const unsigned char* bytes, int len, int ss,
                                 int* texW, int* texH, int* logW, int* logH) {
    if (ss < 1) ss = 1;
    kit_tvg_init();
    Tvg_Paint pic = tvg_picture_new();
    if (!pic) return 0;
    /* load from the in-memory SVG bytes (the cart ships SVGs as data, not files).
       copy=1 so ThorVG owns its own buffer; rpath=NULL (no external image refs --
       the cart SVGs embed base64 PNGs inline). */
    if (tvg_picture_load_data(pic, (const char*)bytes, (uint32_t)len, "svg", 0, 1) != TVG_RESULT_SUCCESS) {
        tvg_paint_unref(pic, 1);   /* never added to a canvas: free directly */
        return 0;
    }
    float fw = 0, fh = 0;
    tvg_picture_get_size(pic, &fw, &fh);
    int iw = (int)(fw + 0.5f), ih = (int)(fh + 0.5f);
    if (iw < 1 || ih < 1) { tvg_paint_unref(pic, 1); return 0; }
    int tw = iw * ss, th = ih * ss;
    while (ss > 1 && (long)tw * th > 64L * 1024 * 1024) { ss--; tw = iw * ss; th = ih * ss; }
    if ((long)tw * th > 64L * 1024 * 1024) { tvg_paint_unref(pic, 1); return 0; }
    unsigned char* px = (unsigned char*)calloc((size_t)tw * th, 4);
    if (!px) { tvg_paint_unref(pic, 1); return 0; }
    Tvg_Canvas canvas = tvg_swcanvas_create(TVG_ENGINE_OPTION_DEFAULT);
    if (!canvas) { tvg_paint_unref(pic, 1); free(px); return 0; }
    /* ABGR8888S = un-alpha-premultiplied, memory R,G,B,A == SDL_PIXELFORMAT_ABGR8888
       the host uses (sdl3-backend). ThorVG writes straight alpha directly, so unlike
       resvg no un-premultiply pass is needed (edges don't darken under BLEND tint). */
    tvg_swcanvas_set_target(canvas, (uint32_t*)px, (uint32_t)tw, (uint32_t)tw, (uint32_t)th, TVG_COLORSPACE_ABGR8888S);
    tvg_picture_set_size(pic, (float)tw, (float)th);   /* scale the SVG up into the ss-times buffer */
    tvg_canvas_add(canvas, pic);
    tvg_canvas_draw(canvas, 1);
    tvg_canvas_sync(canvas);
    tvg_canvas_remove(canvas, pic);   /* canvas owns pic; remove releases+frees it */
    tvg_canvas_destroy(canvas);
    *texW = tw; *texH = th; *logW = iw; *logH = ih;
    return px;
}
unsigned char* kit_svg_decode(const unsigned char* bytes, int len, int* w, int* h) {
    int tw, th;   /* ss=1: texture == intrinsic, back-compat for non-supersampled callers */
    return kit_svg_decode_hi(bytes, len, 1, &tw, &th, w, h);
}
#else
#define NANOSVG_IMPLEMENTATION
#define NANOSVGRAST_IMPLEMENTATION
#include "nanosvg.h"
#include "nanosvgrast.h"
unsigned char* kit_svg_decode_hi(const unsigned char* bytes, int len, int ss,
                                 int* texW, int* texH, int* logW, int* logH) {
    if (ss < 1) ss = 1;
    char* src = (char*)malloc((size_t)len + 1);   /* nsvgParse mutates + needs NUL */
    if (!src) return 0;
    memcpy(src, bytes, (size_t)len);
    src[len] = 0;
    NSVGimage* img = nsvgParse(src, "px", 96.0f);
    free(src);
    if (!img) return 0;
    int iw = (int)(img->width + 0.5f), ih = (int)(img->height + 0.5f);
    if (iw < 1 || ih < 1) { nsvgDelete(img); return 0; }
    int tw = iw * ss, th = ih * ss;
    while (ss > 1 && (long)tw * th > 64L * 1024 * 1024) { ss--; tw = iw * ss; th = ih * ss; }
    if ((long)tw * th > 64L * 1024 * 1024) { nsvgDelete(img); return 0; }
    NSVGrasterizer* rast = nsvgCreateRasterizer();
    if (!rast) { nsvgDelete(img); return 0; }
    unsigned char* px = (unsigned char*)malloc((size_t)tw * th * 4);
    if (!px) { nsvgDeleteRasterizer(rast); nsvgDelete(img); return 0; }
    nsvgRasterize(rast, img, 0, 0, (float)ss, px, tw, th, tw * 4);   /* ss = render scale */
    nsvgDeleteRasterizer(rast);
    nsvgDelete(img);
    *texW = tw; *texH = th; *logW = iw; *logH = ih;
    return px;
}
unsigned char* kit_svg_decode(const unsigned char* bytes, int len, int* w, int* h) {
    int tw, th;
    return kit_svg_decode_hi(bytes, len, 1, &tw, &th, w, h);
}
#endif

void kit_stb_free(void* p) {
    free(p);
}

void* kit_font_init(const unsigned char* ttf, int len) {
    stbtt_fontinfo* info = malloc(sizeof(stbtt_fontinfo));
    if (!info) return NULL;
    if (!stbtt_InitFont(info, ttf, stbtt_GetFontOffsetForIndex(ttf, 0))) {
        free(info);
        return NULL;
    }
    return info;
}

float kit_font_scale_for_px(void* font, float px) {
    return stbtt_ScaleForMappingEmToPixels((stbtt_fontinfo*)font, px);
}

void kit_font_vmetrics(void* font, int* ascent, int* descent, int* lineGap) {
    stbtt_GetFontVMetrics((stbtt_fontinfo*)font, ascent, descent, lineGap);
}

void kit_font_hmetrics(void* font, int codepoint, int* advance, int* lsb) {
    stbtt_GetCodepointHMetrics((stbtt_fontinfo*)font, codepoint, advance, lsb);
}

int kit_font_kern(void* font, int cp1, int cp2) {
    return stbtt_GetCodepointKernAdvance((stbtt_fontinfo*)font, cp1, cp2);
}

unsigned char* kit_font_glyph_bitmap(void* font, float scale, int codepoint,
                                     int* w, int* h, int* xoff, int* yoff) {
    return stbtt_GetCodepointBitmap((stbtt_fontinfo*)font, scale, scale, codepoint, w, h, xoff, yoff);
}

int kit_font_glyph_index(void* font, int codepoint) {
    return stbtt_FindGlyphIndex((stbtt_fontinfo*)font, codepoint);
}

/* CBDT/CBLC color emoji: each glyph in the strike is a PNG. cmap lookup     */
/* rides stb_truetype; the strike index walks CBLC to find the PNG slice in  */
/* CBDT. Covers indexFormat 1/2/3 and imageFormat 17/18/19 (Noto uses 1+17). */

typedef struct {
    const unsigned char* cmap;
    int cmapFormat;
    const unsigned char* cblc;
    const unsigned char* cbdt;
    const unsigned char* strike;
    int ppem;
    const unsigned char* sbixStrike;
    int sbixPpem;
    int sbixDescentPx;
    int numGlyphs;
    const unsigned char* fileBase;
    int fileLen;
} KitEmoji;

/* A glyph slice must lie wholly inside the font file, or a malformed/
   misparsed offset would hand back a pointer that reads (and the caller
   then decodes) out of bounds. Reject anything that escapes the buffer. */
static int kit_slice_ok(const KitEmoji* e, const unsigned char* p, uint32_t len) {
    return p >= e->fileBase && len > 0 && len <= (uint32_t)e->fileLen
        && p + len <= e->fileBase + e->fileLen;
}

static uint16_t kit_rd16(const unsigned char* p) { return (uint16_t)((p[0] << 8) | p[1]); }
static uint32_t kit_rd32(const unsigned char* p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

static const unsigned char* kit_find_table(const unsigned char* ttf, const char tag[4]) {
    uint16_t numTables = kit_rd16(ttf + 4);
    for (uint16_t i = 0; i < numTables; i++) {
        const unsigned char* rec = ttf + 12 + 16 * i;
        if (rec[0] == tag[0] && rec[1] == tag[1] && rec[2] == tag[2] && rec[3] == tag[3]) {
            return ttf + kit_rd32(rec + 8);
        }
    }
    return 0;
}

/* bitmap-only fonts have no glyf table, so stb_truetype refuses them;       */
/* a format 12 (or 4) cmap walk is all the glyph lookup an emoji font needs */
static const unsigned char* kit_pick_cmap(const unsigned char* ttf, int* format) {
    const unsigned char* cmap = kit_find_table(ttf, "cmap");
    if (!cmap) return 0;
    uint16_t numTables = kit_rd16(cmap + 2);
    const unsigned char* best = 0;
    int bestFormat = 0;
    for (uint16_t i = 0; i < numTables; i++) {
        const unsigned char* rec = cmap + 4 + 8 * i;
        const unsigned char* sub = cmap + kit_rd32(rec + 4);
        uint16_t fmt = kit_rd16(sub);
        if (fmt == 12 && bestFormat != 12) { best = sub; bestFormat = 12; }
        if (fmt == 4 && bestFormat == 0) { best = sub; bestFormat = 4; }
    }
    *format = bestFormat;
    return best;
}

static int kit_cmap_lookup(const KitEmoji* e, uint32_t cp) {
    if (!e->cmap) return 0;
    if (e->cmapFormat == 12) {
        if (!kit_slice_ok(e, e->cmap + 12, 4)) return 0;
        uint32_t nGroups = kit_rd32(e->cmap + 12);
        const unsigned char* groups = e->cmap + 16;
        uint32_t lo = 0, hi = nGroups;
        while (lo < hi) {
            uint32_t mid = (lo + hi) / 2;
            const unsigned char* g = groups + 12 * mid;
            if (!kit_slice_ok(e, g, 12)) return 0;
            uint32_t start = kit_rd32(g);
            uint32_t end = kit_rd32(g + 4);
            if (cp < start) { hi = mid; }
            else if (cp > end) { lo = mid + 1; }
            else { return (int)(kit_rd32(g + 8) + (cp - start)); }
        }
        return 0;
    }
    if (e->cmapFormat == 4 && cp <= 0xFFFF) {
        if (!kit_slice_ok(e, e->cmap + 6, 2)) return 0;
        uint16_t segCountX2 = kit_rd16(e->cmap + 6);
        const unsigned char* endCodes = e->cmap + 14;
        const unsigned char* startCodes = endCodes + segCountX2 + 2;
        const unsigned char* idDeltas = startCodes + segCountX2;
        const unsigned char* idRangeOffsets = idDeltas + segCountX2;
        for (uint16_t i = 0; i < segCountX2; i += 2) {
            if (!kit_slice_ok(e, endCodes + i, 2) || !kit_slice_ok(e, startCodes + i, 2)
             || !kit_slice_ok(e, idDeltas + i, 2) || !kit_slice_ok(e, idRangeOffsets + i, 2)) return 0;
            if (cp > kit_rd16(endCodes + i)) continue;
            uint16_t start = kit_rd16(startCodes + i);
            if (cp < start) return 0;
            uint16_t rangeOff = kit_rd16(idRangeOffsets + i);
            if (rangeOff == 0) return (int)((cp + kit_rd16(idDeltas + i)) & 0xFFFF);
            const unsigned char* p = idRangeOffsets + i + rangeOff + 2 * (cp - start);
            if (!kit_slice_ok(e, p, 2)) return 0;
            uint16_t g = kit_rd16(p);
            if (g == 0) return 0;
            return (int)((g + kit_rd16(idDeltas + i)) & 0xFFFF);
        }
    }
    return 0;
}

/* Table offsets in the sfnt directory are file-relative even inside a TTC,  */
/* so the directory moves to the collection's first font but data stays      */
/* rooted at the file start (Apple Color Emoji ships as a .ttc).             */
static const unsigned char* kit_font_dir(const unsigned char* file) {
    if (file[0] == 't' && file[1] == 't' && file[2] == 'c' && file[3] == 'f') {
        return file + kit_rd32(file + 12);
    }
    return file;
}

static const unsigned char* kit_find_table2(const unsigned char* file, const unsigned char* dir, const char tag[4]) {
    uint16_t numTables = kit_rd16(dir + 4);
    for (uint16_t i = 0; i < numTables; i++) {
        const unsigned char* rec = dir + 12 + 16 * i;
        if (rec[0] == tag[0] && rec[1] == tag[1] && rec[2] == tag[2] && rec[3] == tag[3]) {
            return file + kit_rd32(rec + 8);
        }
    }
    return 0;
}

void* kit_emoji_init(const unsigned char* ttf, int len) {
    KitEmoji* e = malloc(sizeof(KitEmoji));
    if (!e) return 0;
    e->fileBase = ttf;
    e->fileLen = len;
    const unsigned char* dir = kit_font_dir(ttf);

    const unsigned char* cmapTable = kit_find_table2(ttf, dir, "cmap");
    e->cmap = 0;
    e->cmapFormat = 0;
    if (cmapTable) {
        uint16_t numTables = kit_rd16(cmapTable + 2);
        for (uint16_t i = 0; i < numTables; i++) {
            const unsigned char* rec = cmapTable + 4 + 8 * i;
            const unsigned char* sub = cmapTable + kit_rd32(rec + 4);
            uint16_t fmt = kit_rd16(sub);
            if (fmt == 12 && e->cmapFormat != 12) { e->cmap = sub; e->cmapFormat = 12; }
            if (fmt == 4 && e->cmapFormat == 0) { e->cmap = sub; e->cmapFormat = 4; }
        }
    }
    if (!e->cmap) {
        free(e);
        return 0;
    }

    const unsigned char* maxp = kit_find_table2(ttf, dir, "maxp");
    e->numGlyphs = maxp ? kit_rd16(maxp + 4) : 0;

    e->cblc = kit_find_table2(ttf, dir, "CBLC");
    e->cbdt = kit_find_table2(ttf, dir, "CBDT");
    e->strike = 0;
    e->ppem = 0;
    if (e->cblc && e->cbdt) {
        uint32_t numSizes = kit_rd32(e->cblc + 4);
        for (uint32_t i = 0; i < numSizes; i++) {
            const unsigned char* s = e->cblc + 8 + 48 * i;
            int ppem = s[44];
            if (ppem > e->ppem) {
                e->ppem = ppem;
                e->strike = s;
            }
        }
    }

    const unsigned char* sbix = kit_find_table2(ttf, dir, "sbix");
    e->sbixStrike = 0;
    e->sbixPpem = 0;
    e->sbixDescentPx = 0;
    if (sbix && e->numGlyphs > 0) {
        uint32_t numStrikes = kit_rd32(sbix + 4);
        for (uint32_t i = 0; i < numStrikes; i++) {
            const unsigned char* s = sbix + kit_rd32(sbix + 8 + 4 * i);
            int ppem = kit_rd16(s);
            if (ppem > e->sbixPpem) {
                e->sbixPpem = ppem;
                e->sbixStrike = s;
            }
        }
        const unsigned char* head = kit_find_table2(ttf, dir, "head");
        const unsigned char* hhea = kit_find_table2(ttf, dir, "hhea");
        if (head && hhea && e->sbixPpem > 0) {
            int upem = kit_rd16(head + 18);
            int16_t desc = (int16_t)kit_rd16(hhea + 6);
            if (upem > 0) e->sbixDescentPx = (int)((long)e->sbixPpem * desc / upem);
        }
    }

    if (!e->strike && !e->sbixStrike) {
        free(e);
        return 0;
    }
    return e;
}

static uint32_t kit_png_height(const unsigned char* png, uint32_t len) {
    if (len < 24) return 0;
    return kit_rd32(png + 20);
}

const unsigned char* kit_emoji_glyph_png(void* handle, int codepoint, uint32_t* pngLen,
                                         int* ppem, int* bearingX, int* bearingY, int* advance) {
    KitEmoji* e = (KitEmoji*)handle;
    if (!e) return 0;
    int glyph = kit_cmap_lookup(e, (uint32_t)codepoint);
    if (glyph == 0) return 0;

    if (e->sbixStrike) {
        for (int hop = 0; hop < 4; hop++) {
            if (glyph >= e->numGlyphs) return 0;
            const unsigned char* offsets = e->sbixStrike + 4;
            uint32_t o1 = kit_rd32(offsets + 4 * glyph);
            uint32_t o2 = kit_rd32(offsets + 4 * (glyph + 1));
            if (o2 <= o1 + 8) return 0;
            const unsigned char* data = e->sbixStrike + o1;
            int16_t originX = (int16_t)kit_rd16(data);
            int16_t originY = (int16_t)kit_rd16(data + 2);
            if (data[4] == 'd' && data[5] == 'u' && data[6] == 'p' && data[7] == 'e') {
                glyph = kit_rd16(data + 8);
                continue;
            }
            if (data[4] != 'p' || data[5] != 'n' || data[6] != 'g' || data[7] != ' ') return 0;
            *pngLen = o2 - o1 - 8;
            if (!kit_slice_ok(e, data + 8, *pngLen)) return 0;
            *ppem = e->sbixPpem;
            *bearingX = originX;
            *bearingY = originY + (int)(kit_png_height(data + 8, *pngLen) * 79 / 100);
            *advance = e->sbixPpem;
            return data + 8;
        }
        return 0;
    }

    const unsigned char* s = e->strike;
    uint32_t arrayOff = kit_rd32(s);
    uint32_t numSub = kit_rd32(s + 8);
    const unsigned char* array = e->cblc + arrayOff;

    for (uint32_t i = 0; i < numSub; i++) {
        const unsigned char* rec = array + 8 * i;
        if (!kit_slice_ok(e, rec, 8)) return 0;
        uint16_t first = kit_rd16(rec);
        uint16_t last = kit_rd16(rec + 2);
        if (glyph < first || glyph > last) continue;

        const unsigned char* sub = array + kit_rd32(rec + 4);
        if (!kit_slice_ok(e, sub, 8)) return 0;
        uint16_t indexFormat = kit_rd16(sub);
        uint16_t imageFormat = kit_rd16(sub + 2);
        uint32_t imageDataOffset = kit_rd32(sub + 4);
        uint32_t off = 0;
        uint32_t size = 0;

        if (indexFormat == 1) {
            const unsigned char* offsets = sub + 8;
            if (!kit_slice_ok(e, offsets + 4 * (glyph - first), 8)) return 0;
            uint32_t o1 = kit_rd32(offsets + 4 * (glyph - first));
            uint32_t o2 = kit_rd32(offsets + 4 * (glyph - first + 1));
            off = o1;
            size = o2 - o1;
        } else if (indexFormat == 2) {
            uint32_t imageSize = kit_rd32(sub + 8);
            off = imageSize * (glyph - first);
            size = imageSize;
        } else if (indexFormat == 3) {
            const unsigned char* offsets = sub + 8;
            uint16_t o1 = kit_rd16(offsets + 2 * (glyph - first));
            uint16_t o2 = kit_rd16(offsets + 2 * (glyph - first + 1));
            off = o1;
            size = o2 - o1;
        } else {
            return 0;
        }
        if (size == 0) return 0;

        const unsigned char* data = e->cbdt + imageDataOffset + off;
        if (!kit_slice_ok(e, data, size)) return 0;
        *ppem = e->ppem;
        /* Scale the glyph by its OWN bitmap height (smallGlyphMetrics.height,
           data[0]), not the strike's ppemX: a CBDT emoji bitmap overshoots the
           em (Noto's are ~136px in a 109 strike), so using ppemX renders it
           oversized and hanging below the baseline. Height = the bitmap's pixel
           rows, so ppem=height renders it at exactly the requested size and the
           font's own bearingY lands the baseline. Font-derived, no constant. */
        if (imageFormat == 17) {
            if (data[0] > 0) *ppem = data[0];
            *bearingX = (signed char)data[2];
            *bearingY = (signed char)data[3];
            *advance = data[4];
            *pngLen = kit_rd32(data + 5);
            if (!kit_slice_ok(e, data + 9, *pngLen)) return 0;
            return data + 9;
        } else if (imageFormat == 18) {
            if (data[0] > 0) *ppem = data[0];
            *bearingX = (signed char)data[2];
            *bearingY = (signed char)data[3];
            *advance = data[4];
            *pngLen = kit_rd32(data + 8);
            if (!kit_slice_ok(e, data + 12, *pngLen)) return 0;
            return data + 12;
        } else if (imageFormat == 19) {
            *bearingX = 0;
            *bearingY = e->ppem;
            *advance = e->ppem;
            *pngLen = kit_rd32(data);
            if (!kit_slice_ok(e, data + 4, *pngLen)) return 0;
            return data + 4;
        }
        return 0;
    }
    return 0;
}
