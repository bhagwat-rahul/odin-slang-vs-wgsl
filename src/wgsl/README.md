# WebGPU setup

This package demonstrates the WebGPU/WGSL alternative to `src/slang`:

```text
Odin -> wgpu-native -> Metal / Vulkan / D3D12
                  WGSL ^
```

There is one checked-in WGSL kernel and no shader compilation build step or
platform-specific shader artifact. `wgpu-native` validates and translates WGSL
for the selected native backend when the application creates a shader module.
The host-side example intentionally lives in one `wgsl.odin` file; splitting
device, buffer, kernel, and dispatch code is an organizational choice, not a
WebGPU requirement.

The vector-add flow is:

1. `device_create` requests the default adapter and device.
2. `kernel_create` loads `VECTOR_ADD_WGSL` and derives its binding layout.
3. Create two storage input buffers, one storage output buffer, and one uniform
   buffer containing `Vector_Add_Params`.
4. Upload inputs with `buffer_upload`.
5. Call `dispatch` with buffers in WGSL binding order.
6. Call `buffer_download` to synchronize and read the output.

The Odin distribution bundles wgpu-native for some platforms. Additional
platform libraries must be placed in Odin's `vendor/wgpu/lib` using the layout
described by `vendor:wgpu/doc.odin`.

Compared with SDL_GPU + Slang, this is a smaller shader/toolchain setup and one
shader artifact works everywhere. The tradeoff is WebGPU's more conservative
feature model and less access to backend-specific compute functionality.
