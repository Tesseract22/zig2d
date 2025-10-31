#version 330 core
out vec4 FragColor;
in vec4 vertexColor;
in vec2 texCoord;

void main() {
    vec2 p = (texCoord - vec2(0.5, 0.5)) * 2;
    float dist = sqrt(p.x*p.x + p.y*p.y);
    // float glow = 2-exp(l);
    // float glow = 1-sqrt(l);
    FragColor = vec4(vertexColor.rgb, 1-dist);
}
