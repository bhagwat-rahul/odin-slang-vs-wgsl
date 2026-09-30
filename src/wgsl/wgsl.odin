package wgsl

import "core:mem"
import "vendor:wgpu"

VECTOR_ADD_WGSL :: #load("kernels/vector_add.wgsl")

Vector_Add_Params :: struct {
	element_count: u32,
	_padding:      [3]u32,
}

Device :: struct {
	instance: wgpu.Instance,
	adapter:  wgpu.Adapter,
	handle:   wgpu.Device,
	queue:    wgpu.Queue,
}

Buffer_Usage :: enum {
	Storage,
	Uniform,
	Copy_Source,
	Copy_Destination,
}

Buffer_Usage_Set :: bit_set[Buffer_Usage]

Buffer :: struct {
	handle: wgpu.Buffer,
	size:   u64,
	usage:  Buffer_Usage_Set,
}

Kernel :: struct {
	module:            wgpu.ShaderModule,
	pipeline:          wgpu.ComputePipeline,
	bind_group_layout: wgpu.BindGroupLayout,
}

Error :: enum {
	None,
	Instance_Creation_Failed,
	Adapter_Request_Failed,
	Device_Request_Failed,
	Buffer_Creation_Failed,
	Kernel_Creation_Failed,
	Dispatch_Failed,
	Map_Failed,
}

Adapter_Request :: struct {
	adapter: wgpu.Adapter,
	status:  wgpu.RequestAdapterStatus,
	done:    bool,
}

Device_Request :: struct {
	device: wgpu.Device,
	status: wgpu.RequestDeviceStatus,
	done:   bool,
}

Map_Request :: struct {
	status: wgpu.MapAsyncStatus,
	done:   bool,
}

device_create :: proc() -> (device: Device, err: Error) {
	device.instance = wgpu.CreateInstance(nil)
	if device.instance == nil {
		return {}, .Instance_Creation_Failed
	}

	adapter_request: Adapter_Request
	wgpu.InstanceRequestAdapter(
		device.instance,
		nil,
		{mode = .AllowProcessEvents, callback = adapter_request_callback, userdata1 = &adapter_request},
	)
	for !adapter_request.done {
		wgpu.InstanceProcessEvents(device.instance)
	}
	if adapter_request.status != .Success || adapter_request.adapter == nil {
		wgpu.InstanceRelease(device.instance)
		return {}, .Adapter_Request_Failed
	}
	device.adapter = adapter_request.adapter

	device_request: Device_Request
	wgpu.AdapterRequestDevice(device.adapter, nil, {mode = .AllowProcessEvents, callback = device_request_callback, userdata1 = &device_request})
	for !device_request.done {
		wgpu.InstanceProcessEvents(device.instance)
	}
	if device_request.status != .Success || device_request.device == nil {
		wgpu.AdapterRelease(device.adapter)
		wgpu.InstanceRelease(device.instance)
		return {}, .Device_Request_Failed
	}
	device.handle = device_request.device
	device.queue = wgpu.DeviceGetQueue(device.handle)
	return device, .None
}

device_destroy :: proc(device: ^Device) {
	if device == nil {
		return
	}
	if device.queue != nil {
		wgpu.QueueRelease(device.queue)
	}
	if device.handle != nil {
		wgpu.DeviceRelease(device.handle)
	}
	if device.adapter != nil {
		wgpu.AdapterRelease(device.adapter)
	}
	if device.instance != nil {
		wgpu.InstanceRelease(device.instance)
	}
	device^ = {}
}

buffer_create :: proc(device: ^Device, size: u64, usage: Buffer_Usage_Set) -> (buffer: Buffer, err: Error) {
	if device == nil || device.handle == nil {
		return {}, .Device_Request_Failed
	}

	wgpu_usage: wgpu.BufferUsageFlags
	if .Storage in usage {
		wgpu_usage += {.Storage}
	}
	if .Uniform in usage {
		wgpu_usage += {.Uniform}
	}
	if .Copy_Source in usage {
		wgpu_usage += {.CopySrc}
	}
	if .Copy_Destination in usage {
		wgpu_usage += {.CopyDst}
	}

	buffer.handle = wgpu.DeviceCreateBuffer(device.handle, &{usage = wgpu_usage, size = size})
	if buffer.handle == nil {
		return {}, .Buffer_Creation_Failed
	}
	buffer.size = size
	buffer.usage = usage
	return buffer, .None
}

buffer_destroy :: proc(buffer: ^Buffer) {
	if buffer == nil || buffer.handle == nil {
		return
	}
	wgpu.BufferDestroy(buffer.handle)
	wgpu.BufferRelease(buffer.handle)
	buffer^ = {}
}

buffer_upload :: proc(device: ^Device, buffer: ^Buffer, data: []u8, offset: u64 = 0) -> Error {
	if device == nil ||
	   device.queue == nil ||
	   buffer == nil ||
	   buffer.handle == nil ||
	   offset + u64(len(data)) > buffer.size ||
	   .Copy_Destination not_in buffer.usage {
		return .Buffer_Creation_Failed
	}
	wgpu.QueueWriteBuffer(device.queue, buffer.handle, offset, raw_data(data), len(data))
	return .None
}

buffer_download :: proc(device: ^Device, buffer: ^Buffer, data: []u8, offset: u64 = 0) -> Error {
	if device == nil ||
	   device.handle == nil ||
	   buffer == nil ||
	   buffer.handle == nil ||
	   offset + u64(len(data)) > buffer.size ||
	   .Copy_Source not_in buffer.usage {
		return .Map_Failed
	}

	staging := wgpu.DeviceCreateBuffer(device.handle, &{usage = {.CopyDst, .MapRead}, size = u64(len(data))})
	if staging == nil {
		return .Buffer_Creation_Failed
	}
	defer {
		wgpu.BufferDestroy(staging)
		wgpu.BufferRelease(staging)
	}

	encoder := wgpu.DeviceCreateCommandEncoder(device.handle, nil)
	if encoder == nil {
		return .Dispatch_Failed
	}
	defer wgpu.CommandEncoderRelease(encoder)
	wgpu.CommandEncoderCopyBufferToBuffer(encoder, buffer.handle, offset, staging, 0, u64(len(data)))
	command := wgpu.CommandEncoderFinish(encoder, nil)
	if command == nil {
		return .Dispatch_Failed
	}
	wgpu.QueueSubmit(device.queue, {command})
	wgpu.CommandBufferRelease(command)

	map_request: Map_Request
	wgpu.BufferMapAsync(staging, {.Read}, 0, len(data), {mode = .AllowProcessEvents, callback = map_callback, userdata1 = &map_request})
	for !map_request.done {
		wgpu.InstanceProcessEvents(device.instance)
	}
	if map_request.status != .Success {
		return .Map_Failed
	}
	mapped := wgpu.BufferGetConstMappedRange(staging, 0, len(data))
	if len(mapped) != len(data) {
		return .Map_Failed
	}
	mem.copy(raw_data(data), raw_data(mapped), len(data))
	wgpu.BufferUnmap(staging)
	return .None
}

kernel_create :: proc(device: ^Device, wgsl: []u8, entrypoint: string = "compute_main") -> (kernel: Kernel, err: Error) {
	if device == nil || device.handle == nil {
		return {}, .Device_Request_Failed
	}

	kernel.module = wgpu.DeviceCreateShaderModule(
		device.handle,
		&{nextInChain = &wgpu.ShaderSourceWGSL{sType = .ShaderSourceWGSL, code = string(wgsl)}},
	)
	if kernel.module == nil {
		return {}, .Kernel_Creation_Failed
	}

	// A nil layout asks wgpu to derive the bind-group layout from WGSL.
	kernel.pipeline = wgpu.DeviceCreateComputePipeline(device.handle, &{compute = {module = kernel.module, entryPoint = entrypoint}})
	if kernel.pipeline == nil {
		wgpu.ShaderModuleRelease(kernel.module)
		return {}, .Kernel_Creation_Failed
	}
	kernel.bind_group_layout = wgpu.ComputePipelineGetBindGroupLayout(kernel.pipeline, 0)
	if kernel.bind_group_layout == nil {
		wgpu.ComputePipelineRelease(kernel.pipeline)
		wgpu.ShaderModuleRelease(kernel.module)
		return {}, .Kernel_Creation_Failed
	}
	return kernel, .None
}

kernel_destroy :: proc(kernel: ^Kernel) {
	if kernel == nil {
		return
	}
	if kernel.bind_group_layout != nil {
		wgpu.BindGroupLayoutRelease(kernel.bind_group_layout)
	}
	if kernel.pipeline != nil {
		wgpu.ComputePipelineRelease(kernel.pipeline)
	}
	if kernel.module != nil {
		wgpu.ShaderModuleRelease(kernel.module)
	}
	kernel^ = {}
}

// Bindings are passed in WGSL @binding order. Unlike SDL_GPU, read/write
// access is declared by WGSL rather than split into separate host-side lists.
dispatch :: proc(device: ^Device, kernel: ^Kernel, buffers: []Buffer, groups_x: u32, groups_y: u32 = 1, groups_z: u32 = 1, dispatch_count: u32 = 1) -> Error {
	if device == nil || device.handle == nil || kernel == nil || kernel.pipeline == nil {
		return .Dispatch_Failed
	}

	entries := make([]wgpu.BindGroupEntry, len(buffers), context.temp_allocator)
	for buffer, index in buffers {
		entries[index] = {
			binding = u32(index),
			buffer  = buffer.handle,
			size    = buffer.size,
		}
	}
	bind_group := wgpu.DeviceCreateBindGroup(
		device.handle,
		&{layout = kernel.bind_group_layout, entryCount = len(entries), entries = raw_data(entries)},
	)
	if bind_group == nil {
		return .Dispatch_Failed
	}
	defer wgpu.BindGroupRelease(bind_group)

	encoder := wgpu.DeviceCreateCommandEncoder(device.handle, nil)
	if encoder == nil {
		return .Dispatch_Failed
	}
	defer wgpu.CommandEncoderRelease(encoder)
	compute_pass := wgpu.CommandEncoderBeginComputePass(encoder, nil)
	if compute_pass == nil {
		return .Dispatch_Failed
	}
	wgpu.ComputePassEncoderSetPipeline(compute_pass, kernel.pipeline)
	wgpu.ComputePassEncoderSetBindGroup(compute_pass, 0, bind_group)
	for _ in 0 ..< dispatch_count {
		wgpu.ComputePassEncoderDispatchWorkgroups(compute_pass, groups_x, groups_y, groups_z)
	}
	wgpu.ComputePassEncoderEnd(compute_pass)
	wgpu.ComputePassEncoderRelease(compute_pass)

	command := wgpu.CommandEncoderFinish(encoder, nil)
	if command == nil {
		return .Dispatch_Failed
	}
	wgpu.QueueSubmit(device.queue, {command})
	wgpu.CommandBufferRelease(command)
	return .None
}

adapter_request_callback :: proc "c" (status: wgpu.RequestAdapterStatus, adapter: wgpu.Adapter, message: string, userdata1, userdata2: rawptr) {
	request := (^Adapter_Request)(userdata1)
	request.status = status
	request.adapter = adapter
	request.done = true
}

device_request_callback :: proc "c" (status: wgpu.RequestDeviceStatus, device: wgpu.Device, message: string, userdata1, userdata2: rawptr) {
	request := (^Device_Request)(userdata1)
	request.status = status
	request.device = device
	request.done = true
}

map_callback :: proc "c" (status: wgpu.MapAsyncStatus, message: string, userdata1, userdata2: rawptr) {
	request := (^Map_Request)(userdata1)
	request.status = status
	request.done = true
}
