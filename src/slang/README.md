# Slang compute

The Slang package uses SDL3 GPU as the host runtime and Slang as the compute
kernel language:

```text
Odin -> SDL_GPU -> Vulkan / Metal
Slang -> SPIR-V / MSL
```

The host-side example is kept in one `slang.odin` file. Separating device,
buffer, kernel, and dispatch code is an organizational choice, not an SDL_GPU
or Slang requirement.

SDL selects an installed runtime backend. The package then selects a compatible
artifact from `Shader_Artifacts`; EDA code does not branch on the platform or
GPU vendor. NVIDIA and AMD use the same SPIR-V artifact through Vulkan on
Linux and Windows. Apple uses MSL through Metal.

## Compiling a shader

Normal Odin builds use the checked-in artifacts and do not need Slang. To
regenerate them, install a matching Slang release so `slangc` is on `PATH` and
run:

```sh
# macOS
src/slang/kernels/compile.sh macos

# Linux
src/slang/kernels/compile.sh linux

# Windows
src/slang/kernels/compile.sh windows
```

The script compiles every file in `kernels/slang` into the selected platform
directory. Every compute shader currently uses `compute_main`. Release
automation should execute the script before `odin build`. Both source and
generated artifacts are checked in so normal Odin builds do not require Slang.

Artifacts can be embedded into a kernel registry with `#load`:

```odin
when ODIN_OS == .Darwin {
	VECTOR_ADD_ARTIFACTS := slang.Shader_Artifacts {
		msl = #load("kernels/macos/vector_add.metal", []u8),
	}
} else when ODIN_OS == .Linux {
	VECTOR_ADD_ARTIFACTS := slang.Shader_Artifacts {
		spirv = #load("kernels/linux/vector_add.spv", []u8),
	}
} else when ODIN_OS == .Windows {
	VECTOR_ADD_ARTIFACTS := slang.Shader_Artifacts {
		spirv = #load("kernels/windows/vector_add.spv", []u8),
	}
}
```

## SDL resource ABI

Slang source must follow SDL's compute resource layout:

- SPIR-V set 0: samplers, read-only textures, read-only buffers.
- SPIR-V set 1: read-write textures, read-write buffers.
- SPIR-V set 2: uniform buffers.
- Metal buffer indices: uniforms, read-only buffers, read-write buffers.
- Bindings in each category are dense and start at zero.

Use explicit `[[vk::binding(binding, set)]]` attributes and keep declarations in
Metal's required order. Do not add HLSL `register` annotations: Metal ignores
register spaces, which can make unlike resource classes collide at the same
buffer index. `kernels/slang/vector_add.slang` is the reference layout.

`Kernel_Layout` must exactly match the shader's resource counts and
`numthreads` declaration.

## Lifetime and synchronization

Destroy kernels and buffers before destroying their device. `buffer_upload`
and `buffer_download` are deliberately synchronous setup/convenience paths.
`dispatch` is asynchronous; keep its buffers alive and call `device_wait_idle`
or perform a download only when the CPU requires the result.
