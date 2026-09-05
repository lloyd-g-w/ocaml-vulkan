#version 450
// Writes the colour interpolated from triangle.vert's 3 per-vertex colours.

layout(location = 0) in vec3 v_color;
layout(location = 0) out vec4 out_color;

void main() {
    out_color = vec4(v_color, 1.0);
}
