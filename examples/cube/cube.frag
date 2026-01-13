#version 450
#extension GL_EXT_nonuniform_qualifier : enable

#include "bindless.glsl"

layout(location = 0) in vec2 inUV;
layout(location = 0) out vec4 outColor;

layout(push_constant) uniform PushConstants
{
    UboBinding uniform_binding;
    CisBinding texture_binding;
} push_constants;

void main() {
    outColor = vec4(sampleTexture(push_constants.texture_binding, inUV).xyz, 1.0);
}
