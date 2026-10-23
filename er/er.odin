package er

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:reflect"
import "core:strings"


@(private)
RegisterInt :: struct #raw_union {
	signed:   i64,
	unsigned: u64,
}

@(private)
ErrEnum :: struct {
	type:     typeid,
	value:    RegisterInt,
	location: runtime.Source_Code_Location,
}

@(private)
ErrString :: struct {
	content:   string,
	allocator: mem.Allocator,
	location:  runtime.Source_Code_Location,
}

@(private)
ErrStaticString :: struct {
	content:  string,
	location: runtime.Source_Code_Location,
}

@(private)
ErrInteger :: struct {
	v:        i64,
	location: runtime.Source_Code_Location,
}

ErrorToString :: #type proc(ptr: rawptr, allocator: mem.Allocator) -> string
ErrorDestructor :: #type proc(ptr: rawptr)

@(private)
ErrAny :: struct {
	value:      rawptr,
	to_string:  ErrorToString,
	destructor: ErrorDestructor,
	allocator:  mem.Allocator,
	location:   runtime.Source_Code_Location,
}

@(private)
ErrCopOut :: struct {
	location: runtime.Source_Code_Location,
}

Error :: union {
	ErrEnum,
	ErrString,
	ErrInteger,
	ErrStaticString,
	ErrAny,
	ErrCopOut,
}

@(private)
print_err_enum :: proc(value: ErrEnum, allocator: mem.Allocator) -> string {
	info := type_info_of(value.type)
	v: any
	switch reflect.size_of_typeid(value.type) {
	case 1:
		if reflect.is_signed(info) {
			x: i8 = cast(i8)value.value.signed
			v.id = value.type
			v.data = &x
		} else {
			x: u8 = cast(u8)value.value.unsigned
			v.id = value.type
			v.data = &x
		}
	case 2:
		if reflect.is_signed(info) {
			x: i16 = cast(i16)value.value.signed
			v.id = value.type
			v.data = &x
		} else {
			x: u16 = cast(u16)value.value.unsigned
			v.id = value.type
			v.data = &x
		}
	case 4:
		if reflect.is_signed(info) {
			x: i32 = cast(i32)value.value.signed
			v.id = value.type
			v.data = &x
		} else {
			x: u32 = cast(u32)value.value.unsigned
			v.id = value.type
			v.data = &x
		}
	case 8:
		if reflect.is_signed(info) {
			x: i64 = cast(i64)value.value.signed
			v.id = value.type
			v.data = &x
		} else {
			x: u64 = cast(u64)value.value.unsigned
			v.id = value.type
			v.data = &x
		}
	case:
		assert(false, "cannot under any circumstances print err enum for a non integer sized_type")
	}
	return fmt.aprint(v, allocator = allocator)
}

@(private)
unsafe_runtime_launder_value :: proc($T: typeid, value: $U) -> T {
	assert(size_of(U) == size_of(T))
	value := value
	outs := (cast(^T)cast(rawptr)&value)^
	return outs
}

@(private)
dynamic_error :: proc(
	value: $T,
	to_string_func: ErrorToString = nil,
	destructor: ErrorDestructor = nil,
	allocator := context.allocator,
	location := #caller_location,
) -> Error {
	info := type_info_of(T)
	if reflect.is_enum(info) {
		type_erased_value: RegisterInt
		switch reflect.size_of_typeid(T) {
		case 1:
			if reflect.is_signed(info) {
				v: i8 = unsafe_runtime_launder_value(i8, value)
				type_erased_value.signed = cast(i64)v
			} else {
				v: u8 = unsafe_runtime_launder_value(u8, value)
				type_erased_value.unsigned = cast(u64)v
			}
		case 2:
			if reflect.is_signed(info) {
				v: i16 = unsafe_runtime_launder_value(i16, value)
				type_erased_value.signed = cast(i64)v
			} else {
				v: u16 = unsafe_runtime_launder_value(u16, value)
				type_erased_value.unsigned = cast(u64)v
			}
		case 4:
			if reflect.is_signed(info) {
				v: i32 = unsafe_runtime_launder_value(i32, value)
				type_erased_value.signed = cast(i64)v
			} else {
				v: u32 = unsafe_runtime_launder_value(u32, value)
				type_erased_value.unsigned = cast(u64)v
			}
		case 8:
			if reflect.is_signed(info) {
				v: i64 = unsafe_runtime_launder_value(i64, value)
				type_erased_value.signed = cast(i64)v
			} else {
				v: u64 = unsafe_runtime_launder_value(u64, value)
				type_erased_value.unsigned = cast(u64)v
			}
		case:
			assert(false, "cannot under any circumstances handle non integer sized enums")
		}
		return ErrEnum{T, type_erased_value, location}
	} else if (T == string) {
		s: string = unsafe_runtime_launder_value(string, value)
		return ErrString{strings.clone(s), allocator, location}
	} else if reflect.is_integer(info) {
		type_erased_value: i64
		switch reflect.size_of_typeid(T) {
		case 1:
			if reflect.is_signed(info) {
				v: i8 = unsafe_runtime_launder_value(i8, value)
				type_erased_value = cast(i64)v
			} else {
				v: u8 = unsafe_runtime_launder_value(u8, value)
				type_erased_value = cast(i64)v
			}
		case 2:
			if reflect.is_signed(info) {
				v: i16 = unsafe_runtime_launder_value(i16, value)
				type_erased_value = cast(i64)v
			} else {
				v: u16 = unsafe_runtime_launder_value(u16, value)
				type_erased_value = cast(i64)v
			}
		case 4:
			if reflect.is_signed(info) {
				v: i32 = unsafe_runtime_launder_value(i32, value)
				type_erased_value = cast(i64)v
			} else {
				v: u32 = unsafe_runtime_launder_value(u32, value)
				type_erased_value = cast(i64)v
			}
		case 8:
			if reflect.is_signed(info) {
				v: i64 = unsafe_runtime_launder_value(i64, value)
				type_erased_value = cast(i64)v
			} else {
				v: u64 = unsafe_runtime_launder_value(u64, value)
				type_erased_value = cast(i64)v
			}
		case:
			assert(false, "cannot under any circumstances handle non integer sized integers")
		}
		return ErrInteger{type_erased_value, location}
	} else if T == Error {
		v := unsafe_runtime_launder_value(Error, value)
		return v
	} else {
		e: ErrAny
		out_ptr: rawptr = new_clone(value, allocator)
		e.destructor = destructor
		e.value = out_ptr
		e.allocator = allocator
		e.to_string = to_string_func
		if to_string_func == nil {
			show_prc :: proc(rw: rawptr, allocator: mem.Allocator) -> string {
				s := cast(^T)rw
				if s == nil {
					return fmt.aprintf("nil", allocator = allocator)
				} else {
					return fmt.aprintf("%v", s^, allocator = allocator)
				}
			}
			e.to_string = show_prc
		}
		e.location = location
		return e
	}
}

@(private)
static_error :: proc($text: string, location := #caller_location) -> Error {
	return ErrStaticString{text, location}
}

@(private)
cop_out_error :: proc(location := #caller_location) -> Error {
	return ErrCopOut{location}
}

error :: proc {
	dynamic_error,
	static_error,
	cop_out_error,
}


destroy :: proc(e: Error) {
	switch v in e {
	case ErrEnum:
		break
	case ErrString:
		delete(v.content, v.allocator)
		break
	case ErrStaticString:
		break
	case ErrAny:
		if v.destructor != nil {
			v.destructor(v.value)
		}
		free(v.value, v.allocator)
	case ErrCopOut:
		break
	case ErrInteger:
		break
	case:
	}
}

to_string :: proc(e: Error, dbg_info := true, allocator := context.allocator) -> string {
	text: string = "suffer?"
	allocated: bool = false
	defer if allocated {
		delete(text, allocator)
	}
	location: runtime.Source_Code_Location
	switch v in e {
	case ErrEnum:
		text = print_err_enum(v, context.allocator)
		allocated = true
		location = v.location
	case ErrString:
		text = v.content
		location = v.location
	case ErrStaticString:
		text = v.content
		location = v.location
	case ErrAny:
		if v.to_string != nil {
			text = v.to_string(v.value, context.allocator)
			allocated = true
		} else {
			text = "unprintable good luck"
		}
		location = v.location
	case ErrCopOut:
		text = "COP OUT:The person who wrote this code is lazy and has declined to provide a reason for this error. The experienced user will know what is wrong"
		location = v.location
	case ErrInteger:
		text = fmt.aprintf(
			"%d(the experienced user will know what is wrong)",
			v.v,
			allocator = allocator,
		)
		allocated = true
		location = v.location
	case:
		return strings.clone("nil", allocator)
	}
	if dbg_info {
		return fmt.aprintf(
			"ERROR %s\n\tat file:%s procedure:%s line:%d column:%d",
			text,
			location.file_path,
			location.procedure,
			location.line,
			location.column,
			allocator = allocator,
		)
	} else {
		return strings.clone(text, allocator)
	}
}

log :: proc(e: Error, to := os.stderr, dbg_info := true) {
	v := to_string(e, dbg_info)
	defer delete(v)
	fmt.fprintf(to, "%s\n", v)
}

@(private)
frd_try_nullable :: proc(
	t: $T,
	u: $U,
	allocator := context.allocator,
	location := #caller_location,
) -> (
	T,
	Error,
) where !(intrinsics.type_is_integer(U) || intrinsics.type_is_string(U)) {
	if u != nil {
		return t, error(u, location = location, allocator = allocator)
	} else {
		return t, nil
	}
}

@(private)
frd_try_integer :: proc(
	t: $T,
	u: $U,
	allocator := context.allocator,
	location := #caller_location,
) -> (
	T,
	Error,
) where intrinsics.type_is_integer(U) {
	if u != 0 {
		return t, error(u, location = location, allocator = allocator)
	} else {
		return t, nil
	}
}


@(private)
frd_try_string :: proc(
	t: $T,
	u: string,
	allocator := context.allocator,
	location := #caller_location,
) -> (
	T,
	Error,
) {
	if u != "" {
		return t, error(u, location = location, allocator = allocator)
	} else {
		return t, nil
	}
}

try :: proc {
	frd_try_integer,
	frd_try_nullable,
	frd_try_string,
}

@(private)
frd_throw_dynamic_error :: proc(
	value: $T,
	to_string_func: ErrorToString = nil,
	destructor: ErrorDestructor = nil,
	allocator := context.allocator,
	location := #caller_location,
) -> Error {
	return dynamic_error(value, to_string_func, destructor, allocator, location)
}

@(private)
frd_throw_static_error :: proc($text: string, location := #caller_location) -> Error {
	return ErrStaticString{text, location}
}

@(private)
frd_throw_cop_out_error :: proc(location := #caller_location) -> Error {
	return ErrCopOut{location}
}

throw :: proc {
	frd_throw_dynamic_error,
	frd_throw_static_error,
	frd_throw_cop_out_error,
}
