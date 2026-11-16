#version 330 core
// A fragment shader.
uniform sampler2D tex;
in vec2 uv;
out vec4 color;

void main() {
    color = texture(tex, uv) * vec4(1.0, 0.5, 0.0, 1.0); /* tint */
}
