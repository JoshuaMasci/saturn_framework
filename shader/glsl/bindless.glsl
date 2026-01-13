#ifndef BINDLESS_SET_INDEX
#define BINDLESS_SET_INDEX 0
#endif

#define UBO_BINDING_INDEX 0
#define SSBO_BINDING 1
#define CIS_BINDING_INDEX 2

#define UboBinding uint
#define CisBinding uint

uint getBinding(uint handle)
{
    return handle & 0xFFFFu;
}

uint getIndex(uint handle)
{
    return (handle >> 16) & 0xFFFFu;
}

#define UNIFORM_BINDING(TYPE, NAME) \
layout(set = BINDLESS_SET_INDEX, binding = UBO_BINDING_INDEX) uniform TYPE##_Buffer { \
    TYPE data; \
} NAME[]

#define UNIFORM_LOAD(ARRAY, HANDLE) \
    ARRAY[getIndex(HANDLE)].data

#define NON_UNIFORM_LOAD(ARRAY, HANDLE) \
    ARRAY[nonuniformEXT(getIndex(HANDLE))].data

layout(set = BINDLESS_SET_INDEX, binding = CIS_BINDING_INDEX) uniform sampler2D sampled_textures[];

vec4 sampleTexture(CisBinding handle, vec2 uv)
{
    return texture(sampled_textures[getIndex(handle)], uv);
}
