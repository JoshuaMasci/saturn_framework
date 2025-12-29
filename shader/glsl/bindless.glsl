#ifndef BINDLESS_SET
#define BINDLESS_SET 0
#endif

#define UBO_BINDING_INDEX 0
#define SSBO_BINDING 1

#define UboBinding uint

uint getBinding(uint handle)
{
    return handle & 0xFFFFu;
}

uint getIndex(uint handle)
{
    return (handle >> 16) & 0xFFFFu;
}

#define UNIFORM_BINDING(TYPE, NAME)          \
layout(set = BINDLESS_SET, binding = UBO_BINDING_INDEX) uniform TYPE##_Buffer {   \
    TYPE data;                                                  \
} NAME[]

#define UNIFORM_LOAD(ARRAY, HANDLE) \
    ARRAY[nonuniformEXT(getIndex(HANDLE))].data
