#version 440

// XMB ribbons, drawn per pixel on the GPU. Same math as the Canvas it
// replaces: each ribbon is a band between a two-sine top edge and that edge
// pushed down by a "breathing" thickness, filled with a vertical gradient
// that fades in to `alpha` at 36% and back out. Ribbons composite in order
// with source-over, premultiplied.
//
// Rebuild after editing: /usr/lib/qt6/bin/qsb --qt6 -o ribbons.frag.qsb ribbons.frag

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
  mat4 qt_Matrix;
  float qt_Opacity;
  vec2 resolution;  // item size in logical pixels
  float phase;
  float aa;         // one device pixel, in logical pixels
};

const float TAU = 6.28318530718;

vec4 ribbon(vec4 dst, vec2 p, float base, float amp, float cycles, float offs,
            float thick, vec3 rgb, float alpha) {
  float h = resolution.y;
  float y = p.y / h;
  // Both sines peak at amp, so the band never leaves this span.
  if (y < base - amp * 1.42 - 0.01 || y > base + amp * 1.42 + thick + 0.01) return dst;

  float t = p.x / resolution.x;
  float top = h * (base
    + amp * sin(t * TAU * cycles + phase + offs)
    + amp * 0.42 * sin(t * TAU * (cycles * 0.47) - phase * 0.62 + offs * 1.7));
  float breathing = 0.76 + 0.24 * sin(t * 3.14159265 * 3.0 - phase + offs);
  float bottom = top + h * thick * breathing;

  float cover = clamp((p.y - top) / aa + 0.5, 0.0, 1.0)
              * clamp((bottom - p.y) / aa + 0.5, 0.0, 1.0);

  float g = clamp((y - (base - amp)) / (2.0 * amp + thick), 0.0, 1.0);
  float a = alpha * cover * (g < 0.36 ? g / 0.36 : (1.0 - g) / 0.64);
  return vec4(rgb * a, a) + dst * (1.0 - a);
}

void main() {
  vec2 p = qt_TexCoord0 * resolution;
  vec4 c = vec4(0.0);
  c = ribbon(c, p, 0.53, 0.055, 0.92, 0.2, 0.055, vec3(72.0, 174.0, 255.0) / 255.0, 0.10);
  c = ribbon(c, p, 0.58, 0.040, 1.13, 2.3, 0.024, vec3(168.0, 220.0, 255.0) / 255.0, 0.13);
  c = ribbon(c, p, 0.62, 0.072, 0.71, 4.5, 0.060, vec3(35.0, 121.0, 232.0) / 255.0, 0.075);
  c = ribbon(c, p, 0.66, 0.045, 1.26, 1.1, 0.018, vec3(204.0, 235.0, 255.0) / 255.0, 0.12);
  c = ribbon(c, p, 0.70, 0.060, 0.84, 3.4, 0.075, vec3(49.0, 142.0, 238.0) / 255.0, 0.055);
  fragColor = c * qt_Opacity;
}
