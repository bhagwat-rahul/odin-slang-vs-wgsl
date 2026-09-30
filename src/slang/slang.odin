package slang

import "core:mem"
import "vendor:sdl3"

// Generated kernel binaries are repository assets. Slang is only needed when
// regenerating them; the Odin application embeds the native artifact for its
// target platform.
when ODIN_OS == .Darwin {
	@(rodata)
	VECTOR_ADD_MSL := #load("kernels/macos/vector_add.metal", []u8)

	VECTOR_ADD_ARTIFACTS := Shader_Artifacts {
		msl = VECTOR_ADD_MSL,
	}
} else when ODIN_OS == .Linux {
	@(rodata)
	VECTOR_ADD_SPIRV := #load("kernels/linux/vector_add.spv", []u8)

	VECTOR_ADD_ARTIFACTS := Shader_Artifacts {
		spirv = VECTOR_ADD_SPIRV,
	}
} else when ODIN_OS == .Windows {
	@(rodata)
	VECTOR_ADD_SPIRV := #load("kernels/windows/vector_add.spv", []u8)

	VECTOR_ADD_ARTIFACTS := Shader_Artifacts {
		spirv = VECTOR_ADD_SPIRV,
	}
} else {
	#panic("GPU compute is only configured for macOS, Linux, and Windows")
}

VECTOR_ADD_LAYOUT :: Kernel_Layout {
	readonly_storage_buffers  = 2,
	readwrite_storage_buffers = 1,
	uniform_buffers           = 1,
	threads_x                 = 256,
}

Device :: struct {
	handle:               ^sdl3.GPUDevice,
	shader_formats:       sdl3.GPUShaderFormat,
	owns_video_subsystem: bool,
}

Buffer_Usage :: enum {
	Read,
	Write,
	Indirect,
}

Buffer_Usage_Set :: bit_set[Buffer_Usage]

Buffer :: struct {
	handle: ^sdl3.GPUBuffer,
	size:   u32,
	usage:  Buffer_Usage_Set,
}

Shader_Artifacts :: struct {
	spirv: []u8,
	msl:   []u8,
}

Kernel_Layout :: struct {
	readonly_storage_buffers:   u32,
	readwrite_storage_buffers:  u32,
	readonly_storage_textures:  u32,
	readwrite_storage_textures: u32,
	samplers:                   u32,
	uniform_buffers:            u32,
	threads_x:                  u32,
	threads_y:                  u32,
	threads_z:                  u32,
}

Kernel :: struct {
	handle: ^sdl3.GPUComputePipeline,
	layout: Kernel_Layout,
	format: sdl3.GPUShaderFormatFlag,
}

Uniform_Data :: struct {
	data: rawptr,
	size: u32,
}

Error :: enum {
	None,
	Device_Creation_Failed,
	No_Compatible_Shader,
	Pipeline_Creation_Failed,
	Buffer_Creation_Failed,
	Transfer_Failed,
	Command_Creation_Failed,
	Command_Submission_Failed,
}

device_create :: proc(debug_mode := ODIN_DEBUG) -> (device: Device, err: Error) {
	if .VIDEO not_in sdl3.WasInit(sdl3.INIT_VIDEO) {
		if !sdl3.InitSubSystem(sdl3.INIT_VIDEO) {
			return {}, .Device_Creation_Failed
		}
		device.owns_video_subsystem = true
	}

	accepted_formats: sdl3.GPUShaderFormat
	when ODIN_OS == .Darwin {
		accepted_formats = {.MSL}
	} else {
		accepted_formats = {.SPIRV}
	}
	device.handle = sdl3.CreateGPUDevice(accepted_formats, debug_mode, nil)
	if device.handle == nil {
		if device.owns_video_subsystem {
			sdl3.QuitSubSystem(sdl3.INIT_VIDEO)
		}
		return {}, .Device_Creation_Failed
	}
	device.shader_formats = sdl3.GetGPUShaderFormats(device.handle)
	return device, .None
}

device_destroy :: proc(device: ^Device) {
	if device == nil || device.handle == nil {
		return
	}
	sdl3.DestroyGPUDevice(device.handle)
	if device.owns_video_subsystem {
		sdl3.QuitSubSystem(sdl3.INIT_VIDEO)
	}
	device^ = {}
}

device_driver :: proc(device: ^Device) -> string {
	if device == nil || device.handle == nil {
		return ""
	}
	return string(sdl3.GetGPUDeviceDriver(device.handle))
}

last_error :: proc() -> string {
	return string(sdl3.GetError())
}

buffer_create :: proc(
	device: ^Device,
	size: u32,
	usage: Buffer_Usage_Set,
) -> (
	buffer: Buffer,
	err: Error,
) {
	if device == nil || device.handle == nil {
		return {}, .Device_Creation_Failed
	}

	sdl_usage: sdl3.GPUBufferUsageFlags
	if .Read in usage {
		sdl_usage += {.COMPUTE_STORAGE_READ}
	}
	if .Write in usage {
		sdl_usage += {.COMPUTE_STORAGE_WRITE}
	}
	if .Indirect in usage {
		sdl_usage += {.INDIRECT}
	}

	buffer.handle = sdl3.CreateGPUBuffer(device.handle, {usage = sdl_usage, size = size})
	if buffer.handle == nil {
		return {}, .Buffer_Creation_Failed
	}
	buffer.size = size
	buffer.usage = usage
	return buffer, .None
}

buffer_destroy :: proc(device: ^Device, buffer: ^Buffer) {
	if device == nil || device.handle == nil || buffer == nil || buffer.handle == nil {
		return
	}
	sdl3.ReleaseGPUBuffer(device.handle, buffer.handle)
	buffer^ = {}
}

// buffer_upload waits for completion. Use explicit transfer buffers later for
// overlapping transfers with computation.
buffer_upload :: proc(device: ^Device, buffer: ^Buffer, data: []u8, offset: u32 = 0) -> Error {
	if device == nil ||
	   device.handle == nil ||
	   buffer == nil ||
	   buffer.handle == nil ||
	   uint(offset) + len(data) > uint(buffer.size) {
		return .Transfer_Failed
	}

	transfer := sdl3.CreateGPUTransferBuffer(
		device.handle,
		{usage = .UPLOAD, size = u32(len(data))},
	)
	if transfer == nil {
		return .Transfer_Failed
	}
	defer sdl3.ReleaseGPUTransferBuffer(device.handle, transfer)

	mapped := sdl3.MapGPUTransferBuffer(device.handle, transfer, false)
	if mapped == nil {
		return .Transfer_Failed
	}
	mem.copy(mapped, raw_data(data), len(data))
	sdl3.UnmapGPUTransferBuffer(device.handle, transfer)

	command := sdl3.AcquireGPUCommandBuffer(device.handle)
	if command == nil {
		return .Command_Creation_Failed
	}
	copy_pass := sdl3.BeginGPUCopyPass(command)
	sdl3.UploadToGPUBuffer(
		copy_pass,
		{transfer_buffer = transfer, offset = 0},
		{buffer = buffer.handle, offset = offset, size = u32(len(data))},
		false,
	)
	sdl3.EndGPUCopyPass(copy_pass)
	return submit_and_wait(device, command)
}

// buffer_download waits for completion and copies into caller-owned memory.
buffer_download :: proc(device: ^Device, buffer: ^Buffer, data: []u8, offset: u32 = 0) -> Error {
	if device == nil ||
	   device.handle == nil ||
	   buffer == nil ||
	   buffer.handle == nil ||
	   uint(offset) + len(data) > uint(buffer.size) {
		return .Transfer_Failed
	}

	transfer := sdl3.CreateGPUTransferBuffer(
		device.handle,
		{usage = .DOWNLOAD, size = u32(len(data))},
	)
	if transfer == nil {
		return .Transfer_Failed
	}
	defer sdl3.ReleaseGPUTransferBuffer(device.handle, transfer)

	command := sdl3.AcquireGPUCommandBuffer(device.handle)
	if command == nil {
		return .Command_Creation_Failed
	}
	copy_pass := sdl3.BeginGPUCopyPass(command)
	sdl3.DownloadFromGPUBuffer(
		copy_pass,
		{buffer = buffer.handle, offset = offset, size = u32(len(data))},
		{transfer_buffer = transfer, offset = 0},
	)
	sdl3.EndGPUCopyPass(copy_pass)
	if err := submit_and_wait(device, command); err != .None {
		return err
	}

	mapped := sdl3.MapGPUTransferBuffer(device.handle, transfer, false)
	if mapped == nil {
		return .Transfer_Failed
	}
	mem.copy(raw_data(data), mapped, len(data))
	sdl3.UnmapGPUTransferBuffer(device.handle, transfer)
	return .None
}

kernel_create :: proc(
	device: ^Device,
	artifacts: Shader_Artifacts,
	layout: Kernel_Layout,
	entrypoint: cstring = "compute_main",
) -> (
	kernel: Kernel,
	err: Error,
) {
	if device == nil || device.handle == nil {
		return {}, .Device_Creation_Failed
	}

	code, format, found := select_shader(device.shader_formats, artifacts)
	if !found {
		return {}, .No_Compatible_Shader
	}
	resolved_layout := layout
	if resolved_layout.threads_y == 0 {
		resolved_layout.threads_y = 1
	}
	if resolved_layout.threads_z == 0 {
		resolved_layout.threads_z = 1
	}

	create_info := sdl3.GPUComputePipelineCreateInfo {
		code_size                      = len(code),
		code                           = raw_data(code),
		entrypoint                     = entrypoint,
		format                         = {format},
		num_samplers                   = resolved_layout.samplers,
		num_readonly_storage_textures  = resolved_layout.readonly_storage_textures,
		num_readonly_storage_buffers   = resolved_layout.readonly_storage_buffers,
		num_readwrite_storage_textures = resolved_layout.readwrite_storage_textures,
		num_readwrite_storage_buffers  = resolved_layout.readwrite_storage_buffers,
		num_uniform_buffers            = resolved_layout.uniform_buffers,
		threadcount_x                  = resolved_layout.threads_x,
		threadcount_y                  = resolved_layout.threads_y,
		threadcount_z                  = resolved_layout.threads_z,
	}

	kernel.handle = sdl3.CreateGPUComputePipeline(device.handle, create_info)
	if kernel.handle == nil {
		return {}, .Pipeline_Creation_Failed
	}
	kernel.layout = resolved_layout
	kernel.format = format
	return kernel, .None
}

kernel_destroy :: proc(device: ^Device, kernel: ^Kernel) {
	if device == nil || device.handle == nil || kernel == nil || kernel.handle == nil {
		return
	}
	sdl3.ReleaseGPUComputePipeline(device.handle, kernel.handle)
	kernel^ = {}
}

// dispatch submits one compute pass and returns immediately. Buffers remain
// GPU-resident; call device_wait_idle only at a CPU/GPU synchronization point.
dispatch :: proc(
	device: ^Device,
	kernel: ^Kernel,
	readonly_buffers: []Buffer,
	readwrite_buffers: []Buffer,
	uniforms: []Uniform_Data,
	groups_x: u32,
	groups_y: u32 = 1,
	groups_z: u32 = 1,
) -> Error {
	if device == nil || device.handle == nil || kernel == nil || kernel.handle == nil {
		return .Command_Creation_Failed
	}
	if len(readonly_buffers) != int(kernel.layout.readonly_storage_buffers) ||
	   len(readwrite_buffers) != int(kernel.layout.readwrite_storage_buffers) ||
	   len(uniforms) != int(kernel.layout.uniform_buffers) {
		return .Command_Creation_Failed
	}

	command := sdl3.AcquireGPUCommandBuffer(device.handle)
	if command == nil {
		return .Command_Creation_Failed
	}

	for uniform, slot in uniforms {
		sdl3.PushGPUComputeUniformData(command, u32(slot), uniform.data, uniform.size)
	}

	readwrite_bindings := make(
		[]sdl3.GPUStorageBufferReadWriteBinding,
		len(readwrite_buffers),
		context.temp_allocator,
	)
	for buffer, index in readwrite_buffers {
		readwrite_bindings[index] = {
			buffer = buffer.handle,
		}
	}
	compute_pass := sdl3.BeginGPUComputePass(
		command,
		nil,
		0,
		raw_data(readwrite_bindings),
		u32(len(readwrite_bindings)),
	)
	if compute_pass == nil {
		_ = sdl3.CancelGPUCommandBuffer(command)
		return .Command_Creation_Failed
	}

	sdl3.BindGPUComputePipeline(compute_pass, kernel.handle)
	if len(readonly_buffers) > 0 {
		readonly_handles := make([]^sdl3.GPUBuffer, len(readonly_buffers), context.temp_allocator)
		for buffer, index in readonly_buffers {
			readonly_handles[index] = buffer.handle
		}
		sdl3.BindGPUComputeStorageBuffers(
			compute_pass,
			0,
			raw_data(readonly_handles),
			u32(len(readonly_handles)),
		)
	}
	sdl3.DispatchGPUCompute(compute_pass, groups_x, groups_y, groups_z)
	sdl3.EndGPUComputePass(compute_pass)

	if !sdl3.SubmitGPUCommandBuffer(command) {
		return .Command_Submission_Failed
	}
	return .None
}

device_wait_idle :: proc(device: ^Device) -> bool {
	return device != nil && device.handle != nil && sdl3.WaitForGPUIdle(device.handle)
}

select_shader :: proc(
	formats: sdl3.GPUShaderFormat,
	artifacts: Shader_Artifacts,
) -> (
	code: []u8,
	format: sdl3.GPUShaderFormatFlag,
	found: bool,
) {
	if .SPIRV in formats && len(artifacts.spirv) > 0 {
		return artifacts.spirv, .SPIRV, true
	}
	if .MSL in formats && len(artifacts.msl) > 0 {
		return artifacts.msl, .MSL, true
	}
	return nil, {}, false
}

submit_and_wait :: proc(device: ^Device, command: ^sdl3.GPUCommandBuffer) -> Error {
	fence := sdl3.SubmitGPUCommandBufferAndAcquireFence(command)
	if fence == nil {
		return .Command_Submission_Failed
	}
	defer sdl3.ReleaseGPUFence(device.handle, fence)
	fences := [1]^sdl3.GPUFence{fence}
	if !sdl3.WaitForGPUFences(device.handle, true, raw_data(fences[:]), 1) {
		return .Transfer_Failed
	}
	return .None
}
