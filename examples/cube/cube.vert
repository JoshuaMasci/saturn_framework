#version 450
#extension GL_EXT_nonuniform_qualifier : enable

#include "bindless.glsl"

struct UniformData {
    mat4 mvp;
};
UNIFORM_BINDING(UniformData, uniform_data);

layout(location = 0) in vec3 inPos;
layout(location = 1) in vec2 inUV;

layout(location = 0) out vec2 outUV;

layout(push_constant) uniform PushConstants
{
    UboBinding uniform_binding;
    CisBinding texture_binding;
} push_constants;

void main() {
    const mat4 mvp_matrix = UNIFORM_LOAD(uniform_data, push_constants.uniform_binding).mvp;
    gl_Position = mvp_matrix * vec4(inPos, 1.0);
    outUV = inUV;
}
