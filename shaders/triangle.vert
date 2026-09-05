#version 450
// Hard-coded fullscreen-ish triangle, no vertex buffers: 3 vertices selected
// by gl_VertexIndex, covering most of the 64x64 offscreen viewport used by
// test/test_graphics.ml (DESIGN.md §12). Emits a per-vertex colour that
// triangle.frag interpolates and writes out.

layout(location = 0) out vec3 v_color;

const vec2 positions[3] = vec2[](
    vec2( 0.0, -0.8),
    vec2( 0.8,  0.8),
    vec2(-0.8,  0.8)
);

const vec3 colors[3] = vec3[](
    vec3(1.0, 0.0, 0.0),
    vec3(0.0, 1.0, 0.0),
    vec3(0.0, 0.0, 1.0)
);

void main() {
    gl_Position = vec4(positions[gl_VertexIndex], 0.0, 1.0);
    v_color = colors[gl_VertexIndex];
}
