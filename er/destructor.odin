package er

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:reflect"
import "core:slice"
import "core:strings"

BoxedState :: enum {
	Unowned,
	Shallow,
	Boxed,
}

PtrMaybeOwned :: struct($T: typeid) {
	ptr:          ^T,
	owning_state: BoxedState,
}

SliceMaybeOwned :: struct($T: typeid) {
	list:         []T,
	owning_state: BoxedState,
}

StringMaybeOwned :: struct {
	str:          string,
	owning_state: BoxedState,
}

PtrOwned :: struct($T: typeid) {
	ptr: ^T "owned",
}

SliceOwned :: struct($T: typeid) {
	list: []T "owned",
}

StringOwned :: struct {
	str: string "owned",
}

Ptr :: struct($T: typeid) {
	ptr: ^T,
}

Slice :: struct($T: typeid) {
	list: []T,
}

String :: struct {
	str: string,
}

AllocatorToDestruct :: union {
	mem.Dynamic_Arena,
	mem.Scratch,
	virtual.Arena,
}

ObjectKey :: struct {
	ptr: rawptr,
	id:  typeid,
}

run_destructor :: proc(value: any, debug := false) {
	to_free_set := make(map[rawptr]mem.Allocator)
	defer delete(to_free_set)
	reached_set := make(map[ObjectKey]u8)
	defer delete(reached_set)
	allocator_list := make([dynamic]AllocatorToDestruct)
	defer delete(allocator_list)
	run_destructor_inner(
		value,
		&to_free_set,
		&reached_set,
		.Boxed,
		debug,
		context.allocator,
		&allocator_list,
	)
	for i, all in to_free_set {
		free(i, all)
	}
	for &i in allocator_list {
		switch &v in i {
		case mem.Dynamic_Arena:
			mem.dynamic_arena_destroy(&v)
		case mem.Scratch:
			mem.scratch_destroy(&v)
		case virtual.Arena:
			virtual.arena_destroy(&v)
		}
	}
}


run_destructor_inner :: proc(
	value: any,
	to_free_set: ^map[rawptr]mem.Allocator,
	reached_set: ^map[ObjectKey]u8,
	owned: BoxedState,
	debug: bool,
	base_allocator: mem.Allocator,
	allocator_list: ^[dynamic]AllocatorToDestruct,
) {
	alloc := base_allocator
	info := type_info_of(value.id)
	vk := ObjectKey {
		ptr = value.data,
		id  = value.id,
	}
	if vk in reached_set {
		return
	}
	reached_set[vk] = 0
	if reflect.is_pointer(info) {
		pt, _ := reflect.as_pointer(value)
		if pt == nil {
			return
		}
		if owned != .Unowned {
			to_run := owned
			if owned == .Shallow {
				to_run = .Unowned
			}
			ans := reflect.deref(value)
			run_destructor_inner(
				ans,
				to_free_set,
				reached_set,
				to_run,
				debug,
				alloc,
				allocator_list,
			)
			to_free_set^[ans.data] = alloc
		}
	} else if reflect.is_array(info) {
		id := 0
		for i, idx in reflect.iterate_array(value, &id) {
			run_destructor_inner(i, to_free_set, reached_set, owned, debug, alloc, allocator_list)
		}
	} else if reflect.is_slice(info) {
		id := 0
		if owned != .Unowned {
			to_run := owned
			if owned == .Shallow {
				to_run = .Unowned
			}
			for i, idx in reflect.iterate_array(value, &id) {
				run_destructor_inner(
					i,
					to_free_set,
					reached_set,
					to_run,
					debug,
					alloc,
					allocator_list,
				)
			}
			slc: ^runtime.Raw_Slice = cast(^runtime.Raw_Slice)value.data
			(to_free_set^)[slc.data] = alloc
		}
	} else if reflect.is_dynamic_array(info) {
		id := 0
		to_run := owned
		if owned == .Shallow {
			to_run = .Unowned
		}
		for i, idx in reflect.iterate_array(value, &id) {
			run_destructor_inner(i, to_free_set, reached_set, to_run, debug, alloc, allocator_list)
		}
		slc: ^runtime.Raw_Dynamic_Array = cast(^runtime.Raw_Dynamic_Array)value.data
		(to_free_set^)[slc.data] = slc.allocator
	} else if reflect.is_dynamic_map(info) {
		id := 0
		to_run := owned
		if owned == .Shallow {
			to_run = .Unowned
		}
		for key, val in reflect.iterate_map(value, &id) {
			run_destructor_inner(
				key,
				to_free_set,
				reached_set,
				to_run,
				debug,
				alloc,
				allocator_list,
			)
			run_destructor_inner(
				val,
				to_free_set,
				reached_set,
				to_run,
				debug,
				alloc,
				allocator_list,
			)
		}
		mp: ^runtime.Raw_Map = cast(^runtime.Raw_Map)value.data
		(to_free_set^)[cast(rawptr)mp.data] = mp.allocator
	} else if reflect.is_string(info) {
		st, _ := reflect.as_string(value)
		if debug {
			fmt.printf("string:%s\n", st)
		}
		if owned != .Unowned {
			if len(st) > 0 {
				bytes := transmute([]u8)st
				ptr := &bytes[0]
				to_free_set[ptr] = alloc
			}
		}
	} else if reflect.is_struct(info) {
		if info.id == mem.Dynamic_Arena {
			value_ptr := cast(^mem.Dynamic_Arena)value.data
			append(allocator_list, value_ptr^)
			return
		} else if info.id == mem.Scratch_Allocator {
			value_ptr := cast(^mem.Scratch_Allocator)value.data
			append(allocator_list, value_ptr^)
			return
		} else if info.id == virtual.Arena {
			value_ptr := cast(^virtual.Arena)value.data
			append(allocator_list, value_ptr^)
			return
		} else if info.id == mem.Stack ||
		   info.id == mem.Buddy_Allocator ||
		   info.id == mem.Tracking_Allocator ||
		   info.id == mem.Arena ||
		   info.id == mem.Compat_Allocator {
			return
		}
		fields := reflect.struct_fields_zipped(value.id)
		t_alloc: mem.Allocator = alloc
		for i in fields {
			if i.type.id == mem.Allocator {
				t_alloc = (cast(^mem.Allocator)reflect.struct_field_value(value, i).data)^
			}
		}
		name := ""
		#partial switch v in info.variant {
		case (reflect.Type_Info_Named):
			name = v.name
		case:
		}
		if debug {
			fmt.printf("struct:%v\n", name)
		}
		is_dynamic_owning, owning_state, ptr_value := determine_if_dynamic_owning_ptr(
			value,
			fields,
		)
		if !is_dynamic_owning {
			for i in fields {
				field := reflect.struct_field_value(value, i)
				if debug {
					fmt.printf("\tfield:%v\n", i)
				}
				field_info := type_info_of(field.id)
				owned :=
					string_contains_as_distinct_word(cast(string)i.tag, "owned") ||
					string_contains_as_distinct_word(cast(string)i.tag, "Owned")
				shallow :=
					string_contains_as_distinct_word(cast(string)i.tag, "shallow") ||
					string_contains_as_distinct_word(cast(string)i.tag, "Shallow")
				state: BoxedState = .Unowned
				if shallow {
					state = .Shallow
				}
				if owned {
					state = .Boxed
				}
				run_destructor_inner(
					field,
					to_free_set,
					reached_set,
					state,
					debug,
					t_alloc,
					allocator_list,
				)
			}
		} else {
			run_destructor_inner(
				ptr_value,
				to_free_set,
				reached_set,
				owning_state,
				debug,
				t_alloc,
				allocator_list,
			)
		}
	} else if reflect.is_union(info) {
		v := reflect.get_union_variant(value)
		run_destructor_inner(v, to_free_set, reached_set, .Boxed, debug, alloc, allocator_list)
	} else if reflect.is_fixed_capacity_dynamic_array(info) {
		id := 0
		to_run := owned
		if owned == .Shallow {
			to_run = .Unowned
		}
		for i, idx in reflect.iterate_array(value, &id) {
			run_destructor_inner(i, to_free_set, reached_set, to_run, debug, alloc, allocator_list)
		}
	} else {
		return
	}
}

string_contains_as_distinct_word :: proc(base: string, substring: string) -> bool {
	if base == substring {
		return true
	}
	t0 := fmt.aprintf(" %s ", substring)
	t1 := t0[1:]
	t2 := t0[:len(t0) - 1]
	defer delete(t0)
	if strings.starts_with(base, t1) {
		return true
	}
	if strings.ends_with(base, t2) {
		return true
	}
	if strings.contains(base, t0) {
		return true
	}
	return false
}

determine_if_dynamic_owning_ptr :: proc(
	value: any,
	fields: #soa[]reflect.Struct_Field,
) -> (
	is_owning: bool,
	owning_state: BoxedState,
	pointer: any,
) {
	if len(fields) != 2 {
		return
	}
	has_state := false
	has_pointer := false
	tmp_state: BoxedState
	tmp_ptr: any
	for i in fields {
		field := reflect.struct_field_value(value, i)
		field_info := type_info_of(field.id)
		if field.id == BoxedState {
			has_state = true
			v := cast(^BoxedState)field.data
			tmp_state = v^
		} else if reflect.is_pointer(field_info) ||
		   reflect.is_slice(field_info) ||
		   reflect.is_string(field_info) {
			has_pointer = true
			tmp_ptr = field
		}
	}
	if has_pointer && has_state {
		is_owning = true
		owning_state = tmp_state
		pointer = tmp_ptr
	}
	return
}
