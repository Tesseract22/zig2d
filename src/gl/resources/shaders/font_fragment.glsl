#version 330 core
out vec4 FragColor;

in vec4 vertexColor;
in vec2 texCoord;

uniform sampler2D text;

void main() {
    FragColor = vec4(texture(text, texCoord).r) * vertexColor;
    // FragColor = vertexColor;
}
