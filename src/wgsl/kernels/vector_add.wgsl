@group(0) @binding(0)
var<storage, read> lhs: array<f32>;

@group(0) @binding(1)
var<storage, read> rhs: array<f32>;

@group(0) @binding(2)
var<storage, read_write> output: array<f32>;

@group(0) @binding(3)
var<uniform> params: vec4<u32>;

@compute @workgroup_size(256, 1, 1)
fn compute_main(@builtin(global_invocation_id) id: vec3<u32>) {
    if id.x >= params.x {
        return;
    }

    output[id.x] = lhs[id.x] + rhs[id.x];
}
