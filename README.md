# Comparison of slang and wgsl in an Odin codebase

Install the odin compiler and run `odin run src -o:speed` to run a benchmark of vector addition and compare speeds between slang and wgsl shaders.
Slang shaders are compiled down to platform specific (dxil, metal, spirv) via `compile.sh` and wgsl shaders are just compiled via odin's vendored wgpu runtime.

In my testing on an M3 Pro Mac I have found slang to be faster (180 ms vs 187ms for wgsl)

All code in this repo is fully LLM written and this benchmark may hence be useless, it is only for my personal experimentation / learning purposes.

The purpose of this was to explore the ergonomics of using slang vs wgsl in an Odin codebase specially for writing compute shaders for GPGPU workloads (don't care much about rendering / graphics workloads)
