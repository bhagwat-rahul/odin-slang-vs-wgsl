#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;

#line 1 "/Users/rahulbhagwat/Documents/git/work/tinyeda/odin-slang-vs-wgsl/src/slang/kernels/slang/vector_add.slang"
struct Params_0
{
    uint element_count_0;
};


#line 16
struct KernelContext_0
{
    Params_0 constant* params_0;
    float device* output_0;
    float device* lhs_0;
    float device* rhs_0;
};


#line 23
[[kernel]] void compute_main(uint3 id_0 [[thread_position_in_grid]], Params_0 constant* params_1 [[buffer(0)]], float device* output_1 [[buffer(3)]], float device* lhs_1 [[buffer(1)]], float device* rhs_1 [[buffer(2)]])
{

#line 23
    thread KernelContext_0 kernelContext_0;

#line 23
    (&kernelContext_0)->params_0 = params_1;

#line 23
    (&kernelContext_0)->output_0 = output_1;

#line 23
    (&kernelContext_0)->lhs_0 = lhs_1;

#line 23
    (&kernelContext_0)->rhs_0 = rhs_1;

    uint _S1 = id_0.x;

#line 25
    if(_S1 >= (params_1->element_count_0))
    {

#line 26
        return;
    }
    *((&kernelContext_0)->output_0+_S1) = (&kernelContext_0)->lhs_0[_S1] + (&kernelContext_0)->rhs_0[_S1];
    return;
}

