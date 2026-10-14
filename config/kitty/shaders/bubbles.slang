#language slang 2026
// bubbles.slang — readable "chat bubbles" behind text, over any background shader.
//
// Used by the pipeline that `Shade` generates (active.pipeline):
//   STAGE 0  horizontal distance-to-nearest-text        -> texture a
//   STAGE 1  vertical pass, true 2D distance            -> texture b
//   (the background shader then renders into texture a)
//   STAGE 2  composite: background shader where empty, bubble behind text
//
// Any pixel that isn't kitty's default background (glyphs, cell backgrounds
// from vim/htop, the tab bar) counts as "text". Dense screens like cmatrix
// just merge into one big bubble, so they stay readable.
import kitty_custom_shader_types;

static const int STAGE = 2; // set by the pipeline, don't edit

// --- bubble shape (pixels) ---
static const float BUBBLE_PAD = 8.0f;      // how far a bubble reaches past the text
static const float BUBBLE_SOFT = 3.0f;     // edge feather (0 = hard edge)
static const float BUBBLE_OPACITY = 0.92f; // 1.0 = solid, lower lets the shader peek through

static const float BG_DIM = 0.6f;          // background shader brightness outside bubbles (0..1)

static const float THRESHOLD = 0.0015f;    // how different from bg a pixel must be to count as text
static const int TAPS = 8;                 // mask samples each side per pass

static const float RADIUS = BUBBLE_PAD + BUBBLE_SOFT;

bool
is_text(KittyTextures t, float2 pos, float3 bg) {
    return length(t.backbuffer.Sample(pos).rgb - bg) >= THRESHOLD;
}

public float4
fragment_main(float4 color, KittyTextures t, KittyCustomShaderData d) {
    float2 R = float2(d.viewport_size_pixels);
    float2 uv = t.pos;
    float3 bg = d.background.rgb;
    float step_px = RADIUS / float(TAPS);

    // pass 1: horizontal distance (px) to the nearest text pixel on this row
    if (STAGE == 0) {
        float best = RADIUS + 1.0f;
        for (int i = -TAPS; i <= TAPS; i++) {
            float dx = float(i) * step_px;
            if (is_text(t, uv + float2(dx / R.x, 0.0f), bg)) best = min(best, abs(dx));
        }
        return float4(best / (RADIUS + 1.0f), 0.0f, 0.0f, 1.0f);
    }

    // pass 2: combine with vertical offsets -> euclidean distance, rounded corners for free
    if (STAGE == 1) {
        float best = RADIUS + 1.0f;
        for (int j = -TAPS; j <= TAPS; j++) {
            float dy = float(j) * step_px;
            float h = t.a.Sample(uv + float2(0.0f, dy / R.y)).r * (RADIUS + 1.0f);
            if (h <= RADIUS) best = min(best, sqrt(h * h + dy * dy));
        }
        return float4(best / (RADIUS + 1.0f), 0.0f, 0.0f, 1.0f);
    }

    // pass 3: composite. Text is left exactly as kitty drew it; the bubble
    // behind it is kitty's own background colour, so anti-aliased glyph edges
    // blend correctly (no dark fringes/outlines).
    if (length(color.rgb - bg) >= THRESHOLD) return color;

    float dist = t.b.Sample(uv).r * (RADIUS + 1.0f);
    float bubble = 1.0f - smoothstep(BUBBLE_PAD - BUBBLE_SOFT, BUBBLE_PAD + BUBBLE_SOFT, dist);
    float k = bubble * BUBBLE_OPACITY;
    float3 fx = t.a.Sample(uv).rgb * BG_DIM; // the background shader's output
    return float4(lerp(fx, bg, k), color.a);
}
