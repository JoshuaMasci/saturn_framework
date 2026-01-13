#version 450
#extension GL_EXT_nonuniform_qualifier : enable

#include "bindless.glsl"

struct UniformData {
    float rotation;
};
UNIFORM_BINDING(UniformData, uniform_data);

layout(location = 0) out vec3 outColor;

layout(push_constant) uniform PushConstants
{
    UboBinding uniform_binding;
} push_constants;

void main() {
    const float rot = -UNIFORM_LOAD(uniform_data, push_constants.uniform_binding).rotation;

    vec2 pos[3] = vec2[3](
        vec2(0.0, -0.5),
        vec2(0.5, 0.5),
        vec2(-0.5, 0.5)
    );
    vec3 color[3] = vec3[3](
        vec3(1.0, 0.0, 0.0),
        vec3(0.0, 1.0, 0.0),
        vec3(0.0, 0.0, 1.0)
    );

    //Rotation is super wonky cause this is in NDC space
    mat2 rot_mat = mat2(
        cos(rot), sin(rot),
        -sin(rot), cos(rot)
    );

    vec2 rot_pos = rot_mat * pos[gl_VertexIndex];
    gl_Position = vec4(rot_pos, 0.0, 1.0);
    outColor = color[gl_VertexIndex];
}
