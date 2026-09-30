package main

import "core:fmt"
import "core:mem"
import "core:time"
import "slang"
import "wgsl"

ELEMENT_COUNT :: 4 * 1024 * 1024
DISPATCH_COUNT :: 500
TRIAL_COUNT :: 10
WORKGROUP_SIZE :: 256
WORKGROUPS :: u32((ELEMENT_COUNT + WORKGROUP_SIZE - 1) / WORKGROUP_SIZE)

Benchmark_Times :: [TRIAL_COUNT]time.Duration

run_slang :: proc(a, b, result: []f32) -> (times: Benchmark_Times) {
	device, err := slang.device_create(false)
	assert(err == .None, "SDL_GPU device creation failed")
	defer slang.device_destroy(&device)
	kernel, kernel_err := slang.kernel_create(
		&device,
		slang.VECTOR_ADD_ARTIFACTS,
		slang.VECTOR_ADD_LAYOUT,
	)
	assert(kernel_err == .None, "Slang pipeline creation failed")
	defer slang.kernel_destroy(&device, &kernel)

	size := u32(len(a) * size_of(f32))
	a_buffer, e0 := slang.buffer_create(&device, size, {.Read})
	b_buffer, e1 := slang.buffer_create(&device, size, {.Read})
	out_buffer, e2 := slang.buffer_create(&device, size, {.Write})
	assert(e0 == .None && e1 == .None && e2 == .None, "SDL_GPU buffer creation failed")
	defer slang.buffer_destroy(&device, &a_buffer)
	defer slang.buffer_destroy(&device, &b_buffer)
	defer slang.buffer_destroy(&device, &out_buffer)
	assert(slang.buffer_upload(&device, &a_buffer, mem.slice_to_bytes(a)) == .None)
	assert(slang.buffer_upload(&device, &b_buffer, mem.slice_to_bytes(b)) == .None)

	params := struct {
		element_count: u32,
	}{u32(len(a))}
	assert(
		slang.dispatch(
			&device,
			&kernel,
			{a_buffer, b_buffer},
			{out_buffer},
			{{&params, size_of(params)}},
			WORKGROUPS,
		) ==
		.None,
	)
	assert(slang.buffer_download(&device, &out_buffer, mem.slice_to_bytes(result)) == .None)

	for _, trial in times {
		start := time.tick_now()
		assert(slang.dispatch(
			&device,
			&kernel,
			{a_buffer, b_buffer},
			{out_buffer},
			{{&params, size_of(params)}},
			groups_x = WORKGROUPS,
			dispatch_count = DISPATCH_COUNT,
		) == .None)
		assert(slang.buffer_download(&device, &out_buffer, mem.slice_to_bytes(result)) == .None)
		times[trial] = time.tick_since(start)
	}
	return
}

run_wgsl :: proc(a, b, result: []f32) -> (times: Benchmark_Times) {
	device, err := wgsl.device_create()
	assert(err == .None, "WebGPU device creation failed")
	defer wgsl.device_destroy(&device)
	kernel, kernel_err := wgsl.kernel_create(&device, wgsl.VECTOR_ADD_WGSL)
	assert(kernel_err == .None, "WGSL pipeline creation failed")
	defer wgsl.kernel_destroy(&kernel)

	size := u64(len(a) * size_of(f32))
	a_buffer, e0 := wgsl.buffer_create(&device, size, {.Storage, .Copy_Destination})
	b_buffer, e1 := wgsl.buffer_create(&device, size, {.Storage, .Copy_Destination})
	out_buffer, e2 := wgsl.buffer_create(&device, size, {.Storage, .Copy_Source})
	params_buffer, e3 := wgsl.buffer_create(
		&device,
		size_of(wgsl.Vector_Add_Params),
		{.Uniform, .Copy_Destination},
	)
	assert(
		e0 == .None && e1 == .None && e2 == .None && e3 == .None,
		"WebGPU buffer creation failed",
	)
	defer wgsl.buffer_destroy(&a_buffer)
	defer wgsl.buffer_destroy(&b_buffer)
	defer wgsl.buffer_destroy(&out_buffer)
	defer wgsl.buffer_destroy(&params_buffer)
	assert(wgsl.buffer_upload(&device, &a_buffer, mem.slice_to_bytes(a)) == .None)
	assert(wgsl.buffer_upload(&device, &b_buffer, mem.slice_to_bytes(b)) == .None)
	params := wgsl.Vector_Add_Params {
		element_count = u32(len(a)),
	}
	assert(
		wgsl.buffer_upload(&device, &params_buffer, mem.byte_slice(&params, size_of(params))) ==
		.None,
	)

	assert(
		wgsl.dispatch(
			&device,
			&kernel,
			{a_buffer, b_buffer, out_buffer, params_buffer},
			WORKGROUPS,
		) ==
		.None,
	)
	assert(wgsl.buffer_download(&device, &out_buffer, mem.slice_to_bytes(result)) == .None)

	for _, trial in times {
		start := time.tick_now()
		assert(wgsl.dispatch(
			&device,
			&kernel,
			{a_buffer, b_buffer, out_buffer, params_buffer},
			groups_x = WORKGROUPS,
			dispatch_count = DISPATCH_COUNT,
		) == .None)
		assert(wgsl.buffer_download(&device, &out_buffer, mem.slice_to_bytes(result)) == .None)
		times[trial] = time.tick_since(start)
	}
	return
}

validate :: proc(a, b, result: []f32) {
	for value, i in result {
		assert(value == a[i] + b[i], "GPU result mismatch")
	}
}

report :: proc(name: string, times: Benchmark_Times) {
	bytes := f64(ELEMENT_COUNT * DISPATCH_COUNT * 3 * size_of(f32))
	total: time.Duration
	best := times[0]
	fmt.printf("\n%s\n", name)
	for elapsed, trial in times {
		total += elapsed
		best = min(best, elapsed)
		gb_per_second := bytes / time.duration_seconds(elapsed) / 1e9
		fmt.printf(
			"  %d: %.2f ms  %.2f GB/s\n",
			trial + 1,
			time.duration_milliseconds(elapsed),
			gb_per_second,
		)
	}
	average := total / TRIAL_COUNT
	fmt.printf(
		"  avg: %.2f ms  %.2f GB/s | best: %.2f ms\n",
		time.duration_milliseconds(average),
		bytes / time.duration_seconds(average) / 1e9,
		time.duration_milliseconds(best),
	)
}

main :: proc() {
	a := make([]f32, ELEMENT_COUNT)
	b := make([]f32, ELEMENT_COUNT)
	result := make([]f32, ELEMENT_COUNT)
	defer delete(a)
	defer delete(b)
	defer delete(result)
	for _, i in a {
		a[i] = f32(i % 1024)
		b[i] = f32((i * 3) % 1024)
	}

	fmt.printf(
		"%d elements x %d dispatches x %d trials (%.2f GB per trial)\n",
		ELEMENT_COUNT,
		DISPATCH_COUNT,
		TRIAL_COUNT,
		f64(ELEMENT_COUNT * DISPATCH_COUNT * 3 * size_of(f32)) / 1e9,
	)
	slang_times := run_slang(a, b, result)
	validate(a, b, result)
	wgsl_times := run_wgsl(a, b, result)
	validate(a, b, result)
	report("Slang", slang_times)
	report("WGSL", wgsl_times)
}
