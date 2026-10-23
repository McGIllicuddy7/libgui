package er

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:reflect"
import "core:slice"
import "core:strings"

ObjectKey :: struct {
	ptr: rawptr,
	id:  typeid,
}
run_destructor :: proc(value: any) {
	to_free_set := make(map[rawptr]u8)
	defer delete(to_free_set)
	reached_set := make(map[ObjectKey]u8)
	defer delete(reached_set)
	run_destructor_inner(value, &to_free_set, &reached_set, true)
	for i in to_free_set {
		free(i)
	}
}

run_destructor_inner :: proc(
	value: any,
	to_free_set: ^map[rawptr]u8,
	reached_set: ^map[ObjectKey]u8,
	owned: bool,
) {
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
		if owned {
			ans := reflect.deref(value)
			run_destructor_inner(ans, to_free_set, reached_set, owned)
			to_free_set^[ans.data] = 0
		}
	} else if reflect.is_array(info) {
		id := 0
		for i, idx in reflect.iterate_array(value, &id) {
			run_destructor_inner(i, to_free_set, reached_set, owned)
		}
	} else if reflect.is_slice(info) {
		id := 0
		if owned {
			for i, idx in reflect.iterate_array(value, &id) {
				run_destructor_inner(i, to_free_set, reached_set, owned)
			}
			slc: ^runtime.Raw_Slice = cast(^runtime.Raw_Slice)value.data
			(to_free_set^)[slc.data] = 0
		}
	} else if reflect.is_dynamic_array(info) {
		id := 0
		for i, idx in reflect.iterate_array(value, &id) {
			run_destructor_inner(i, to_free_set, reached_set, owned)
		}
		slc: ^runtime.Raw_Dynamic_Array = cast(^runtime.Raw_Dynamic_Array)value.data
		(to_free_set^)[slc.data] = 0
	} else if reflect.is_dynamic_map(info) {
		id := 0
		for key, val in reflect.iterate_map(value, &id) {
			run_destructor_inner(key, to_free_set, reached_set, owned)
			run_destructor_inner(val, to_free_set, reached_set, owned)
		}
	} else if reflect.is_string(info) {
		st, _ := reflect.as_string(value)
		fmt.printf("string:%s\n", st)
		if owned {
			if len(st) > 0 {
				bytes := transmute([]u8)st
				ptr := &bytes[0]
				to_free_set[ptr] = 0
			}
		}
	} else if reflect.is_struct(info) {
		fields := reflect.struct_fields_zipped(value.id)
		name := ""
		#partial switch v in info.variant {
		case (reflect.Type_Info_Named):
			name = v.name
		case:
		}
		//		fmt.printf("struct:%v\n", name)
		for i in fields {
			field := reflect.struct_field_value(value, i)
			//		fmt.printf("\tfield:%v\n", i)
			field_info := type_info_of(field.id)
			owned :=
				string_contains_as_distinct_word(cast(string)i.tag, "owned") ||
				string_contains_as_distinct_word(cast(string)i.tag, "Owned")
			run_destructor_inner(field, to_free_set, reached_set, owned)
		}
	} else if reflect.is_union(info) {
		v := reflect.get_union_variant(value)
		run_destructor_inner(v, to_free_set, reached_set, true)
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
