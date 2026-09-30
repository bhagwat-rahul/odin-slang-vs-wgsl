struct Params
{
    uint element_count;
};

// SDL_GPU's Vulkan ABI uses set 0 for read-only storage, set 1 for
// read-write storage, and set 2 for uniforms. Declaration order also gives
// Metal the required uniform/read-only/read-write buffer ordering.
[[vk::binding(0, 2)]]
ConstantBuffer<Params> params;

[[vk::binding(0, 0)]]
StructuredBuffer<float> lhs;

[[vk::binding(1, 0)]]
StructuredBuffer<float> rhs;

[[vk::binding(0, 1)]]
RWStructuredBuffer<float> output;

[shader("compute")]
[numthreads(256, 1, 1)]
void compute_main(uint3 id : SV_DispatchThreadID)
{
    if (id.x >= params.element_count)
        return;

    output[id.x] = lhs[id.x] + rhs[id.x];
}
