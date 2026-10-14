#version 440
// "Singularity" by @XorDev (golfed by FabriceNeyret2, dean_the_coder, iq),
// monochrome port of ~/Documents/shaders/singularity-mono.slang for a Qt ShaderEffect.
// Compile: /usr/lib/qt6/bin/qsb --glsl "330,300 es,150,120,100 es" --hlsl 50 --msl 12 -o blackhole.frag.qsb blackhole.frag

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float iTime;      // seconds
    float size;       // black hole size (bigger = larger), kitty version used 0.7
    float gain;       // overall brightness
    float fadeStart;  // radius (0..1 of the item) where the edge fade begins
};

void main() {
    // shadertoy coordinates: origin bottom-left, square item so r.x == r.y
    vec2 uv = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y);
    vec2 p = (uv * 2.0 - 1.0) / size;

    float i = 0.2;
    vec2 dg = vec2(-1.0, 1.0);
    vec2 b = p - i * dg;
    float k = 0.1 + i / dot(b, b);
    vec2 c = vec2(p.x + p.y, dot(p, dg / k));
    float a = dot(c, c);
    vec4 m = cos(0.5 * log(a) + iTime * i + vec4(0.0, 33.0, 11.0, 0.0));
    vec2 v = vec2(dot(c, m.xy), dot(c, m.zw)) / i;
    vec2 w = vec2(0.0);
    for (int n = 0; n < 9; n++) {
        i = 1.2 + float(n);
        v += 0.7 * sin(v.yx * i + iTime) / i + 0.5;
        w += 1.0 + sin(v);
    }
    i = length(sin(v / 0.3) * 0.4 + c * (3.0 + dg));
    vec4 O = 1.0 - exp(-exp(c.x * vec4(0.6, -0.4, -1.0, 0.0))
                       / w.xyyx
                       / (2.0 + i * i / 4.0 - i)
                       / (0.5 + 1.0 / a)
                       / (0.03 + abs(length(p) - 0.7)));
    vec3 o = clamp(O.rgb, 0.0, 1.0);
    float y = dot(o, vec3(0.2126, 0.7152, 0.0722)) * gain;   // black & white

    // round, soft edge so the square item blends into the lock background
    float d = length(uv * 2.0 - 1.0);
    float mask = 1.0 - smoothstep(fadeStart, 1.0, d);

    // premultiplied: the dark core stays opaque black (the "hole"), edges fade out
    fragColor = vec4(vec3(y), 1.0) * mask * qt_Opacity;
}
