package gui
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:unicode/utf8"
import "vendor:raylib"
Color :: raylib.Color
Boundary :: struct {
	x, y, width, height: i32,
}

DefaultWidgetId :: struct {
	loc: runtime.Source_Code_Location,
	idx: int,
}

WidgetId :: union {
	string,
	DefaultWidgetId,
}


WidgetStyle :: struct {
	smol_text:             i32,
	normal_text_size:      i32,
	large_text_size:       i32,
	background_color:      Color,
	border_color:          Color,
	text_color:            Color,
	widget_color:          Color,
	selected_widget_color: Color,
	padding:               i32,
}

ContainerKind :: enum {
	VerticalContainer,
	HorizontalContainer,
	ScrollBox,
}
WidgetType :: enum {
	None,
	Text,
	TextInput,
	Button,
	ButtonThumbNail,
	Image,
	Container,
}

Widget :: struct {
	lock:                sync.Mutex,
	id:                  WidgetId,
	type:                WidgetType,
	bounds:              Boundary,
	style:               ^WidgetStyle,
	text:                string,
	text_height:         i32,
	base_text_height:    i32,
	image_name:          string,
	children:            [dynamic]^Widget,
	custom_render:       proc(this: ^Widget, gui: ^Gui, data: ^CachedWidgetData, frame_time: f64),
	is_leaf:             bool,
	scroll_box_reversed: bool,
	container_kind:      ContainerKind,
}


CachedWidgetData :: struct {
	bounds:                 Boundary,
	scroll_height:          i32,
	scroll_amount:          i32,
	selected:               bool,
	was_drawn_this_frame:   bool,
	frame_time:             f64,
	user_data:              [32]u8,
	guess_max_child_height: i32,
	guess_max_child_width:  i32,
}

InputData :: struct {
	mouse_x:              i32,
	mouse_y:              i32,
	mouse_dx:             f32,
	mouse_dy:             f32,
	input_char:           rune,
	left_mouse_down:      bool,
	left_mouse_pressed:   bool,
	left_mouse_released:  bool,
	right_mouse_down:     bool,
	right_mouse_pressed:  bool,
	right_mouse_released: bool,
	mouse_wheel_delta:    f32,
}

MeasureTextCacheKey :: struct {
	text:        string,
	text_height: i32,
	max_width:   i32,
}

MeasureTextCacheValue :: struct {
	width:          i32,
	height:         i32,
	hit_this_frame: bool,
}

Gui :: struct {
	can_multithread:         bool,
	bounds:                  Boundary,
	root:                    ^Widget,
	panels:                  [dynamic]^Widget,
	current_widget:          ^Widget,
	prev_widget_stack:       [dynamic]^Widget,
	current_style:           ^WidgetStyle,
	prev_style_stack:        [dynamic]^WidgetStyle,
	arena:                   mem.Dynamic_Arena,
	alloc:                   mem.Allocator,
	data_table:              map[WidgetId]CachedWidgetData,
	font:                    raylib.Font,
	input_data:              InputData,
	default_style:           WidgetStyle,
	frame_over:              bool,
	measure_text_cache_lock: sync.RW_Mutex,
	measure_text_cache:      map[MeasureTextCacheKey]MeasureTextCacheValue,
	using_default_font:      bool,
}

make_widget_id :: proc(text: string, loc: runtime.Source_Code_Location, idx: int) -> WidgetId {
	if text != "" {
		return text
	} else {
		return DefaultWidgetId{loc, idx}
	}
}

@(rodata)
FONT_DATA: []u8 = #load("../Ac437_IBM_VGA_9x16.ttf")

create_gui :: proc(
	x: i32,
	y: i32,
	width: i32,
	height: i32,
	use_default_font := false,
	can_be_multithreaded := false,
) -> ^Gui {
	out := new(Gui)
	out.bounds = {x, y, width, height}
	out.using_default_font = use_default_font
	out.can_multithread = can_be_multithreaded
	if !out.using_default_font {
		out.font = raylib.LoadFontFromMemory(
			".ttf",
			&FONT_DATA[0],
			cast(i32)len(FONT_DATA),
			16,
			nil,
			0,
		)
	} else {
		out.font = raylib.GetFontDefault()
	}
	mem.dynamic_arena_init(&out.arena)
	out.alloc = mem.dynamic_arena_allocator(&out.arena)
	out.current_style = nil
	out.current_widget = nil
	out.prev_style_stack = make([dynamic]^WidgetStyle)
	out.prev_widget_stack = make([dynamic]^Widget)
	out.data_table = make(map[WidgetId]CachedWidgetData)
	out.default_style = create_default_style()
	return out

}

destroy_gui :: proc(this: ^Gui) {
	mem.dynamic_arena_destroy(&this.arena)
	delete(this.data_table)
	delete(this.prev_style_stack)
	delete(this.prev_widget_stack)
	delete(this.panels)
	for i in this.measure_text_cache {
		delete(i.text)
	}
	delete(this.measure_text_cache)
	if !this.using_default_font {
		raylib.UnloadFont(this.font)
	}
	free(this)
}

create_default_style :: proc() -> WidgetStyle {
	out: WidgetStyle
	out.smol_text = 16
	out.normal_text_size = 24
	out.large_text_size = 32
	out.background_color = raylib.DARKGRAY
	out.widget_color = raylib.GRAY
	out.selected_widget_color = raylib.DARKGRAY
	out.border_color = raylib.BLACK
	out.text_color = raylib.BLACK
	out.padding = 2
	return out
}

gui_begin_frame :: proc(this: ^Gui, create_root := true) {
	clear(&this.prev_widget_stack)
	clear(&this.prev_style_stack)
	clear(&this.panels)
	mem.dynamic_arena_free_all(&this.arena)
	{
		this.input_data.input_char = raylib.GetCharPressed()
		this.input_data.left_mouse_down = raylib.IsMouseButtonDown(.LEFT)
		this.input_data.left_mouse_pressed = raylib.IsMouseButtonPressed(.LEFT)
		this.input_data.left_mouse_released = raylib.IsMouseButtonReleased(.LEFT)
		this.input_data.right_mouse_down = raylib.IsMouseButtonDown(.RIGHT)
		this.input_data.right_mouse_pressed = raylib.IsMouseButtonPressed(.RIGHT)
		this.input_data.right_mouse_released = raylib.IsMouseButtonReleased(.RIGHT)
		this.input_data.mouse_dx = raylib.GetMouseDelta().x
		this.input_data.mouse_dy = raylib.GetMouseDelta().y
		this.input_data.mouse_x = raylib.GetMouseX()
		this.input_data.mouse_y = raylib.GetMouseY()
		this.input_data.mouse_wheel_delta = raylib.GetMouseWheelMoveV().y
	}
	{
		this.current_style = new_clone(this.default_style, this.alloc)
		if create_root {
			root := create_widget(this, .Container, "ROOT")
			root.container_kind = .HorizontalContainer
			root.bounds = this.bounds
			this.root = root
			this.current_widget = root
		} else {
			this.root = nil
			this.current_widget = nil
		}
	}
	this.frame_over = false
	{
		for key, &value in this.measure_text_cache {
			value.hit_this_frame = false
		}
	}
}
create_widget :: proc(
	this: ^Gui,
	type: WidgetType,
	name: string,
	idx := 0,
	location := #caller_location,
) -> ^Widget {
	out := new(Widget, this.alloc)
	out.type = type
	out.id = make_widget_id(name, location, idx)
	out.style = this.current_style
	out.text = ""
	out.text_height = this.current_style.normal_text_size
	out.children = make([dynamic]^Widget, this.alloc)
	return out
}

get_cached_widget_data :: proc(this: ^Gui, widget: ^Widget) -> ^CachedWidgetData {
	if widget.id not_in this.data_table {
		tmp := CachedWidgetData{}
		tmp.bounds = this.bounds
		tmp.was_drawn_this_frame = true
		this.data_table[widget.id] = tmp
	}
	return &this.data_table[widget.id]
}

clone_string :: proc(this: ^Gui, text: string) -> string {
	return strings.clone(text, this.alloc)
}

gui_end_frame :: proc(this: ^Gui) {
	clear(&this.prev_widget_stack)
	clear(&this.prev_style_stack)
	this.current_style = nil
	this.current_widget = nil
	gui_determine_layout(this)
	gui_on_update(this)
	this.frame_over = true
	{
		delete_set := make([dynamic]MeasureTextCacheKey)
		for key, value in this.measure_text_cache {
			if !value.hit_this_frame {
				append(&delete_set, key)
			}
		}
		for i in delete_set {
			delete_key(&this.measure_text_cache, i)
			delete(i.text)
		}
	}
}

gui_begin_style :: proc(this: ^Gui, style: WidgetStyle) {
	append(&this.prev_style_stack, this.current_style)
	this.current_style = new_clone(style, this.alloc)
}

gui_end_style :: proc(this: ^Gui) {
	assert(len(this.prev_style_stack) > 0)
	this.current_style = pop(&this.prev_style_stack)
}

gui_begin_widget :: proc(this: ^Gui, widget: ^Widget) {
	append(&this.prev_widget_stack, this.current_widget)
	this.current_widget = widget
}

gui_end_widget :: proc(this: ^Gui) {
	assert(len(this.prev_widget_stack) > 0)
	this.current_widget = pop(&this.prev_widget_stack)
}

button :: proc(
	this: ^Gui,
	text: string,
	idx := 0,
	id: string = "",
	loc := #caller_location,
) -> bool {
	widget := create_widget(this, .Button, id, idx, loc)
	widget.is_leaf = true
	widget.text = clone_string(this, text)
	widget.text_height = widget.style.normal_text_size
	widget.base_text_height = widget.text_height
	append(&this.current_widget.children, widget)
	out := false
	data := get_cached_widget_data(this, widget)
	if data.selected {
		if this.input_data.left_mouse_released &&
		   this.input_data.mouse_x >= data.bounds.x &&
		   this.input_data.mouse_y >= data.bounds.y &&
		   this.input_data.mouse_x < data.bounds.x + data.bounds.width &&
		   this.input_data.mouse_y < data.bounds.y + data.bounds.height {
			out = true
		}
	}
	return out
}

button_thumbnail :: proc(
	this: ^Gui,
	thumbnail_name: string,
	text: string,
	idx := 0,
	id: string = "",
	loc := #caller_location,
) -> bool {
	widget := create_widget(this, .Button, id, idx, loc)
	widget.is_leaf = true
	widget.text = clone_string(this, text)
	widget.image_name = clone_string(this, thumbnail_name)
	widget.text_height = widget.style.normal_text_size
	widget.base_text_height = widget.text_height
	append(&this.current_widget.children, widget)
	out := false
	data := get_cached_widget_data(this, widget)
	if data.selected {
		if this.input_data.left_mouse_released &&
		   this.input_data.mouse_x >= data.bounds.x &&
		   this.input_data.mouse_y >= data.bounds.y &&
		   this.input_data.mouse_x < data.bounds.x + data.bounds.width &&
		   this.input_data.mouse_y < data.bounds.y + data.bounds.height {
			out = true
		}
	}
	return out
}

text :: proc(this: ^Gui, text: string, idx := 0, id: string = "", loc := #caller_location) {
	widget := create_widget(this, .Text, id, idx, loc)
	widget.is_leaf = true
	widget.text = clone_string(this, text)
	widget.text_height = widget.style.normal_text_size
	widget.base_text_height = widget.text_height
	append(&this.current_widget.children, widget)
}

image :: proc(this: ^Gui, img_name: string, idx := 0, id: string = "", loc := #caller_location) {
	widget := create_widget(this, .Text, id, idx, loc)
	widget.is_leaf = true
	widget.image_name = clone_string(this, img_name)
	append(&this.current_widget.children, widget)
}


begin_div :: proc(this: ^Gui, idx := 0, id: string = "", loc := #caller_location) {
	widget := create_widget(this, .Container, id, idx, loc)
	widget.is_leaf = false
	widget.container_kind = .VerticalContainer
	append(&this.current_widget.children, widget)
	gui_begin_widget(this, widget)
}

end_div :: proc(this: ^Gui) {
	gui_end_widget(this)
}

begin_panel :: proc(
	this: ^Gui,
	x, y, width, height: i32,
	use_cached_bounds := false,
	idx := 0,
	id: string = "",
	loc := #caller_location,
) {
	widget := create_widget(this, .Container, id, idx, loc)
	widget.is_leaf = false
	widget.bounds = {x, y, width, height}
	if use_cached_bounds {
		widget.bounds = get_cached_widget_data(this, widget).bounds
	}
	widget.container_kind = .VerticalContainer
	append(&this.panels, widget)
	gui_begin_widget(this, widget)
}

end_panel :: proc(this: ^Gui) {
	gui_end_widget(this)
}

begin_panel_horizontal :: proc(
	this: ^Gui,
	x, y, width, height: i32,
	use_cached_bounds: bool = false,
	idx := 0,
	id: string = "",
	loc := #caller_location,
) {
	widget := create_widget(this, .Container, id, idx, loc)
	widget.is_leaf = false
	widget.bounds = {x, y, width, height}
	if use_cached_bounds {
		widget.bounds = get_cached_widget_data(this, widget).bounds
	}
	widget.container_kind = .HorizontalContainer
	append(&this.panels, widget)
	gui_begin_widget(this, widget)
}

end_panel_horizontal :: proc(this: ^Gui) {
	gui_end_widget(this)
}

begin_panel_scrollbox :: proc(
	this: ^Gui,
	x, y, width, height: i32,
	idx := 0,
	id: string = "",
	loc := #caller_location,
) {
	widget := create_widget(this, .Container, id, idx, loc)
	widget.is_leaf = false
	widget.bounds = {x, y, width, height}
	widget.container_kind = .ScrollBox
	append(&this.panels, widget)
	gui_begin_widget(this, widget)
}

end_panel_scrollbox :: proc(this: ^Gui) {
	gui_end_widget(this)
}


begin_scrollbox :: proc(
	this: ^Gui,
	reversed := false,
	idx := 0,
	id: string = "",
	loc := #caller_location,
) {
	widget := create_widget(this, .Container, id, idx, loc)
	widget.is_leaf = false
	widget.container_kind = .ScrollBox
	widget.scroll_box_reversed = reversed
	append(&this.current_widget.children, widget)
	gui_begin_widget(this, widget)
}

end_scrollbox :: proc(this: ^Gui) {
	gui_end_widget(this)
}

begin_horizontal_div :: proc(this: ^Gui, idx := 0, id: string = "", loc := #caller_location) {
	widget := create_widget(this, .Container, id, idx, loc)
	widget.is_leaf = false
	widget.container_kind = .HorizontalContainer
	append(&this.current_widget.children, widget)
	gui_begin_widget(this, widget)
}

end_horizontal_div :: proc(this: ^Gui) {
	gui_end_widget(this)
}

gui_determine_layout :: proc(this: ^Gui) {
	if this.root != nil {
		gui_calculate_dimensions(this.root, this, this.bounds.width, this.bounds.height, 0)
		shift_x := (this.bounds.width - this.root.bounds.width) / 2
		shift_y := (this.bounds.height - this.root.bounds.height) / 2
		gui_build_layout(this.root, this, this.bounds.x + shift_x, this.bounds.y + shift_y)
	}
	for i in this.panels {
		gui_calculate_dimensions(i, this, i.bounds.width, i.bounds.height, 0)
		gui_build_layout(i, this, i.bounds.x, i.bounds.y)
	}
}


gui_build_layout :: proc(this: ^Widget, gui: ^Gui, base_x: i32, base_y: i32) {
	this.bounds.x = base_x
	this.bounds.y = base_y
	base_x := base_x
	base_y := base_y
	if !this.is_leaf {
		switch this.container_kind {
		case .VerticalContainer:
			{
				max_w: i32 = 0
				for i in this.children {
					if i.bounds.width > max_w {
						max_w = i.bounds.width
					}
				}
				base_x += (this.bounds.width - this.style.padding * 2 - max_w) / 2
				dy: i32 = this.style.padding
				dx: i32 = this.style.padding
				for i in this.children {
					gui_build_layout(i, gui, base_x + dx, base_y + dy)
					dy += i.bounds.height + this.style.padding
				}
			}
		case .HorizontalContainer:
			{
				max_h: i32 = 0
				for i in this.children {
					if i.bounds.height > max_h {
						max_h = i.bounds.height
					}
				}
				base_y += (this.bounds.height - this.style.padding * 2 - max_h) / 2
				dy: i32 = this.style.padding
				dx: i32 = this.style.padding
				for i in this.children {
					gui_build_layout(i, gui, base_x + dx, base_y + dy)
					dx += i.bounds.width + this.style.padding
				}
			}
		case .ScrollBox:
			{
				max_w: i32 = 0
				for i in this.children {
					if i.bounds.width > max_w {
						max_w = i.bounds.width
					}
				}
				base_x += (this.bounds.width - this.style.padding * 2 - max_w) / 2
				dy: i32 = this.style.padding
				dx: i32 = this.style.padding
				data := get_cached_widget_data(gui, this)
				data.scroll_height = this.style.padding
				data.scroll_height = 0
				for i in this.children {
					data.scroll_height += i.bounds.height + this.style.padding
				}
				if data.scroll_amount > data.scroll_height {
					data.scroll_amount = data.scroll_height
				}
				if data.scroll_amount < 0 {
					data.scroll_amount = 0
				}
				base_y := this.bounds.y + this.style.padding
				if this.scroll_box_reversed {
					base_y =
						this.bounds.y -
						data.scroll_height +
						this.style.padding +
						+this.bounds.height +
						data.scroll_amount -
						(this.style.padding * cast(i32)len(this.children))
					if len(this.children) > 0 {
						base_y += this.children[0].bounds.height
					}
					for idx in 1 ..= len(this.children) {
						i := this.children[len(this.children) - idx]
						gui_build_layout(i, gui, base_x + dx, base_y + dy)
						dy += i.bounds.height + this.style.padding * 2
					}
				} else {
					base_y -= data.scroll_amount
					if len(this.children) > 0 {
						base_y += this.children[len(this.children) - 1].bounds.height
					}
					for i in this.children {
						gui_build_layout(i, gui, base_x + dx, base_y + dy)
						dy += i.bounds.height + this.style.padding * 2
					}
				}
			}
		}
	}
	tmp := get_cached_widget_data(gui, this)
	tmp.bounds = this.bounds
}

gui_calculate_dimensions :: proc(
	this: ^Widget,
	gui: ^Gui,
	max_width: i32,
	max_height: i32,
	depth: int,
) {
	depth := depth
	if depth == 0 {
		count := widget_count_children(this)
		if count < 1000 {
			depth = 512
		}
	}
	if this.is_leaf {
		width_base := max_width
		height_base := max_height
		switch this.type {
		case .TextInput:
			{
				this.text_height = this.base_text_height
				for this.text_height >= 12 {
					width, height := measure_text_given_width(
						gui,
						this.text,
						this.text_height,
						width_base - this.text_height * 2,
					)
					this.bounds.height = height + this.style.padding * 2
					if this.bounds.height < height_base {
						this.bounds.height = height_base
					}
					this.bounds.width = width + this.style.padding * 2
					if this.bounds.height <= max_height && this.bounds.width <= max_width {
						break
					}
					this.text_height -= 1
				}
				assert(this.bounds.width <= width_base, "width< max_width")
				assert(this.bounds.height <= height_base, "height< max_height")
			}
		case .Text:
			this.text_height = this.base_text_height
			for this.text_height >= 12 {
				width, height := measure_text_given_width(
					gui,
					this.text,
					this.text_height,
					width_base - this.text_height * 2,
				)
				this.bounds.height = height + this.style.padding * 2
				this.bounds.width = width + this.style.padding * 2
				if this.bounds.height <= max_height && this.bounds.width <= max_width {
					break
				}
				this.text_height -= 1
			}
			assert(this.bounds.width <= width_base, "width< max_width")
			assert(this.bounds.height <= height_base, "height< max_height")
		case .Button:
			this.text_height = this.base_text_height
			for this.text_height >= 12 {
				width, height := measure_text_given_width(
					gui,
					this.text,
					this.text_height,
					width_base - this.text_height * 2,
				)
				this.bounds.height = height + this.style.padding * 2
				this.bounds.width = width + this.style.padding * 2
				if this.bounds.height <= height_base && this.bounds.width <= width_base {
					break
				}
				this.text_height -= 1
			}
			assert(this.bounds.width <= width_base, "width<= max_width")
			assert(this.bounds.height <= height_base, "height< max_height")
		case .ButtonThumbNail:
			for this.text_height >= 12 {
				width, height := measure_text_given_width(
					gui,
					this.text,
					this.text_height,
					width_base - this.text_height * 4,
				)
				this.bounds.height = height + this.style.padding * 2
				this.bounds.width = width + this.text_height * 2 + this.style.padding * 2
				if this.bounds.height < height_base && this.bounds.width < width_base {
					break
				}
				this.text_height -= 1
			}
			assert(this.bounds.width <= width_base, "width< max_width")
			assert(this.bounds.height <= height_base, "height< max_height")
		case .Image:
			this.bounds.height = max_height
			this.bounds.width = max_width
		case .Container:
			fallthrough
		case .None:
			assert(false, "containers, and cannot be marked leaf nodes")
		}
	} else {
		calculate_child_dimensions :: proc(
			gui: ^Gui,
			widgets: []^Widget,
			t_max_width, t_max_height: i32,
			depth: int,
		) {
			ThreadArgs :: struct {
				widgets:      []^Widget,
				gui:          ^Gui,
				t_max_width:  i32,
				t_max_height: i32,
				depth:        int,
			}
			thread_proc :: proc(data: ThreadArgs) {
				for i in data.widgets {
					gui_calculate_dimensions(
						i,
						data.gui,
						data.t_max_width,
						data.t_max_height,
						data.depth + 1,
					)
				}
			}
			if depth <= 3 && depth > 0 && len(widgets) > 4 && gui.can_multithread {
				@(static) THREAD_COUNT_LOCK: sync.Mutex
				@(static) THREAD_COUNT: int = -1
				{
					sync.mutex_lock(&THREAD_COUNT_LOCK)
					defer sync.mutex_unlock(&THREAD_COUNT_LOCK)
					if THREAD_COUNT == -1 {
						THREAD_COUNT = os.get_processor_core_count()
					}
				}
				join_list := make([dynamic]^thread.Thread)
				reserve_dynamic_array(&join_list, THREAD_COUNT)
				defer {
					for i in join_list {
						thread.join(i)
					}
					delete(join_list)
				}
				if len(widgets) < THREAD_COUNT {
					for i in 0 ..< len(widgets) {
						list: []^Widget = widgets[i:i + 1]
						ag := ThreadArgs{list, gui, t_max_width, t_max_height, 512}
						if i != len(widgets) - 1 {
							t := thread.create_and_start_with_poly_data(ag, thread_proc)
							append(&join_list, t)
						} else {
							thread_proc(ag)
						}
					}
				} else {
					heighest_idx := -1
					for i in 0 ..< THREAD_COUNT {
						base_idx := (i * len(widgets)) / THREAD_COUNT
						assert(base_idx > heighest_idx)
						end_idx := ((i + 1) * len(widgets)) / THREAD_COUNT
						heighest_idx = end_idx - 1
						if i == THREAD_COUNT - 1 {
							end_idx = len(widgets)
						}
						list: []^Widget = widgets[base_idx:end_idx]
						ag := ThreadArgs{list, gui, t_max_width, t_max_height, 512}
						if i < THREAD_COUNT - 1 {
							t := thread.create_and_start_with_poly_data(
								ag,
								proc(data: ThreadArgs) {
									for i in data.widgets {
										gui_calculate_dimensions(
											i,
											data.gui,
											data.t_max_width,
											data.t_max_height,
											data.depth + 1,
										)
									}
								},
							)
							append(&join_list, t)
						} else {
							thread_proc(ag)
						}
					}
				}

			} else {
				for i in widgets {
					gui_calculate_dimensions(i, gui, t_max_width, t_max_height, depth + 1)
				}
			}
		}
		l := cast(i32)len(this.children)
		if l == 0 {
			l = 1
		}
		switch this.container_kind {
		case .VerticalContainer:
			{
				base_guess_max_height :=
					(2 * (max_height - this.style.padding * 2)) / (l) -
					(this.style.padding + 1) * l
				guess_max_height := base_guess_max_height
				{
					data := get_cached_widget_data(gui, this)
					if data.guess_max_child_width != 0 {
						guess_max_height = data.guess_max_child_height
					}
				}
				assert(guess_max_height > 0)
				count := -1
				for {
					dx: i32 = 0
					dy: i32 = this.style.padding
					t_max_width := max_width - this.style.padding * 2
					t_max_height := guess_max_height
					calculate_child_dimensions(
						gui,
						this.children[:],
						t_max_width,
						t_max_height,
						depth,
					)
					for i in this.children {
						if i.bounds.width + this.style.padding * 2 > dx {
							dx = i.bounds.width + this.style.padding * 2
						}
						dy += i.bounds.height + this.style.padding
					}
					if count == -1 {
						if dy <= max_height && math.abs(dy - max_height) < 40 {
							this.bounds.height = dy
							this.bounds.width = dx
							{
								tmp := get_cached_widget_data(gui, this)
								tmp.guess_max_child_height = t_max_height
							}
							break
						} else {
							guess_max_height = base_guess_max_height
						}
					} else {
						if dy <= max_height {
							this.bounds.height = dy
							this.bounds.width = dx
							{
								tmp := get_cached_widget_data(gui, this)
								tmp.guess_max_child_height = t_max_height
							}
							break
						} else {
							disp := (dy - guess_max_height - this.style.padding * (l + 1))
							delta: i32 = 8
							if count == 0 {
								delta = disp / (l)
							} else if count < 3 {
								delta = disp / (l * 8)
							} else {
								delta = disp / l
							}
							if delta < 0 {
								delta = 1
							}
							guess_max_height -= delta
						}
					}
					count += 1
				}
			}
		case .HorizontalContainer:
			{
				count := -1
				base_guess_max_width :=
					(2 * (max_width - this.style.padding * 2)) / (l) - (this.style.padding + 1) * l
				guess_max_width := base_guess_max_width
				{
					data := get_cached_widget_data(gui, this)
					if data.guess_max_child_width != 0 {
						guess_max_width = data.guess_max_child_width
					}
				}
				assert(guess_max_width > 0)
				for {
					dx: i32 = 0
					dy: i32 = this.style.padding
					t_max_width := guess_max_width
					t_max_height := max_height - this.style.padding * 2
					calculate_child_dimensions(
						gui,
						this.children[:],
						t_max_width,
						t_max_height,
						depth,
					)
					for i in this.children {
						if i.bounds.height + this.style.padding * 2 > dy {
							dy = i.bounds.height + this.style.padding * 2
						}
						tmp_w := i.bounds.width
						dx += tmp_w + this.style.padding
					}
					if count == -1 {
						if dx <= max_width && (max_width - dx) <= 40 {
							this.bounds.height = dy
							this.bounds.width = dx
							{
								tmp := get_cached_widget_data(gui, this)
								tmp.guess_max_child_width = t_max_width
							}
							break
						} else {
							guess_max_width = base_guess_max_width
						}
					} else {
						if dx <= max_width && (math.abs(dx - max_width) < 20 || count > 4) {
							this.bounds.height = dy
							this.bounds.width = dx
							{
								tmp := get_cached_widget_data(gui, this)
								tmp.guess_max_child_width = t_max_width
							}
							break
						} else {
							disp := (dx - guess_max_width - this.style.padding * (l + 1))
							delta: i32 = 8
							if count == 0 {
								delta = disp / (l)
							} else if count < 3 {
								delta = disp / (l * 8)
							} else {
								delta = disp / l
							}
							if delta < 0 {
								delta = 1
							}
							guess_max_width -= delta
						}
					}
					count += 1
				}
			}
		case .ScrollBox:
			this.bounds.width = max_width
			this.bounds.height = max_height
			guess_max_height: i32 = 2 << 24
			guess_max_width := max_width - this.style.padding * 2
			tmax_height := guess_max_height
			calculate_child_dimensions(
				gui,
				this.children[:],
				guess_max_width,
				guess_max_height,
				depth,
			)
			mx_x: i32 = 0
			mx_y: i32 = this.style.padding
			for i in this.children {
				if i.bounds.width + this.style.padding * 2 > mx_x {
					mx_x = i.bounds.width + this.style.padding * 2
				}
				mx_y += i.bounds.height + this.style.padding
			}
			if this.bounds.width > 4 * mx_x {
				this.bounds.width = 4 * mx_x
			}
			if this.bounds.height > gui.bounds.height - this.style.padding * 2 {
				this.bounds.height = gui.bounds.height - this.style.padding * 2
			}
		}
		assert(this.bounds.width <= max_width, "width< max_width")
		assert(this.bounds.height <= max_height, "height< max_height")
	}
	/*if this.bounds.width <= max_width {
		cond_nv :=
			max_width - this.style.padding * 4 if this.bounds.width * 2 > max_width - this.style.padding * 4 else this.bounds.width * 2
		this.bounds.width = cond_nv
	}*/

}

gui_render :: proc(this: ^Gui) {
	raylib.DrawRectangle(
		this.bounds.x,
		this.bounds.y,
		this.bounds.width,
		this.bounds.height,
		this.default_style.background_color,
	)
	count := 0
	if this.root != nil {
		gui_render_widget(this.root, this)
		count += widget_count_children(this.root)
	}
	for i in this.panels {
		gui_render_widget(i, this)
		count += widget_count_children(i)
	}
	raylib.DrawText(
		fmt.ctprintf("widget count:%d", count),
		this.bounds.x,
		this.bounds.y,
		16,
		raylib.GREEN,
	)
}

render_image :: proc(img: string, x: i32, y: i32, width: i32, height: i32, gui: ^Gui) {
	raylib.DrawRectangle(x, y, width, height, raylib.VIOLET)
}

render_text :: proc(this: ^Widget, gui: ^Gui, x_off: i32 = 0, y_off: i32 = 0) {
	txt, _, _ := split_text_given_width(
		gui,
		this.text,
		this.text_height,
		this.bounds.width - this.style.padding * 2,
	)
	defer (delete(txt))
	dy: i32 = this.style.padding + this.bounds.y + y_off
	dx: i32 = this.style.padding + this.bounds.x + x_off
	for i in txt {
		pos := raylib.Vector2{cast(f32)dx, cast(f32)dy}
		raylib.DrawTextEx(
			gui.font,
			fmt.ctprintf("%s", i),
			pos,
			cast(f32)this.text_height,
			1.,
			this.style.text_color,
		)
		dy += this.text_height
	}
}

widget_count_children :: proc(this: ^Widget) -> int {
	out := len(this.children)
	for i in this.children {
		out += widget_count_children(i)
	}
	return out
}
gui_render_widget :: proc(this: ^Widget, gui: ^Gui) {

	if this.custom_render == nil {
		switch this.type {
		case .Text:
			{
				render_text(this, gui)
			}
		case .TextInput:
			{
				selected := gui.data_table[this.id].selected
				raylib.DrawRectangle(
					this.bounds.x - 2,
					this.bounds.y - 2,
					this.bounds.width + 4,
					this.bounds.height + 4,
					this.style.border_color,
				)
				raylib.DrawRectangle(
					this.bounds.x,
					this.bounds.y,
					this.bounds.width,
					this.bounds.height,
					this.style.widget_color if !selected else this.style.selected_widget_color,
				)
				render_text(this, gui)
			}
		case .Button:
			{
				selected := gui.data_table[this.id].selected
				raylib.DrawRectangle(
					this.bounds.x - 2,
					this.bounds.y - 2,
					this.bounds.width + 4,
					this.bounds.height + 4,
					this.style.border_color,
				)
				raylib.DrawRectangle(
					this.bounds.x,
					this.bounds.y,
					this.bounds.width,
					this.bounds.height,
					this.style.widget_color if !selected else this.style.selected_widget_color,
				)
				render_text(this, gui)
			}
		case .ButtonThumbNail:
			selected := gui.data_table[this.id].selected
			raylib.DrawRectangle(
				this.bounds.x - 2,
				this.bounds.y - 2,
				this.bounds.width + 4,
				this.bounds.height + 4,
				this.style.border_color,
			)
			raylib.DrawRectangle(
				this.bounds.x,
				this.bounds.y,
				this.bounds.width,
				this.bounds.height,
				this.style.widget_color if !selected else this.style.selected_widget_color,
			)
			render_image(
				this.image_name,
				this.bounds.x + this.style.padding,
				this.bounds.y + this.style.padding,
				this.text_height,
				this.text_height,
				gui,
			)
			render_text(this, gui, this.text_height * 2)
		case .Image:
			render_image(
				this.image_name,
				this.bounds.x,
				this.bounds.y,
				this.bounds.width,
				this.bounds.height,
				gui,
			)
		case .Container:
			raylib.DrawRectangle(
				this.bounds.x - 2,
				this.bounds.y - 2,
				this.bounds.width + 4,
				this.bounds.height + 4,
				this.style.border_color,
			)
			raylib.DrawRectangle(
				this.bounds.x,
				this.bounds.y,
				this.bounds.width,
				this.bounds.height,
				this.style.background_color,
			)
			if this.container_kind == .ScrollBox {
				raylib.BeginScissorMode(
					this.bounds.x,
					this.bounds.y,
					this.bounds.width,
					this.bounds.height,
				)
			}
			p_bds := raylib.Rectangle {
				cast(f32)this.bounds.x,
				cast(f32)this.bounds.y,
				cast(f32)this.bounds.width,
				cast(f32)this.bounds.height,
			}
			for i in this.children {
				bds := raylib.Rectangle {
					cast(f32)i.bounds.x,
					cast(f32)i.bounds.y,
					cast(f32)i.bounds.width,
					cast(f32)i.bounds.height,
				}
				if raylib.CheckCollisionRecs(p_bds, bds) {
					gui_render_widget(i, gui)
				}
			}
			if this.container_kind == .ScrollBox {
				raylib.EndScissorMode()
			}

		case .None:
			assert(false)
		}
	} else {
		ptr: ^CachedWidgetData = nil
		if this.id in gui.data_table {
			ptr = &gui.data_table[this.id]
		}
		ft := cast(f64)raylib.GetFrameTime()
		this.custom_render(this, gui, ptr, ft)
	}
}

gui_on_update :: proc(this: ^Gui) {
	gui_update_widget :: proc(this: ^Widget, gui: ^Gui) {
		if this.id in gui.data_table {
			tmp := &gui.data_table[this.id]
			tmp.bounds = this.bounds
			tmp.was_drawn_this_frame = true
			mouse_intersecting :=
				this.bounds.x <= gui.input_data.mouse_x &&
				this.bounds.y <= gui.input_data.mouse_y &&
				this.bounds.x + this.bounds.width > gui.input_data.mouse_x &&
				this.bounds.y + this.bounds.height > gui.input_data.mouse_y
			if this.is_leaf {
				if mouse_intersecting {
					if this.type == .TextInput && gui.input_data.left_mouse_released {
						tmp.selected = true
					} else if this.type == .Button || this.type == .ButtonThumbNail {
						if gui.input_data.left_mouse_pressed {
							tmp.selected = true
						} else if gui.input_data.left_mouse_released {
							tmp.selected = false
						}
					}
				} else {
					if gui.input_data.left_mouse_released {
						tmp.selected = false
					}
				}
			} else {
				tmp.selected = false
				if this.container_kind == .ScrollBox && mouse_intersecting {
					tmp.scroll_amount -= cast(i32)(gui.input_data.mouse_wheel_delta * 2.)
					if tmp.scroll_amount < 0 {
						tmp.scroll_amount = 0
					} else if tmp.scroll_amount > tmp.scroll_height {
						tmp.scroll_amount = tmp.scroll_height
					}
				}
			}
		}
		for i in this.children {
			gui_update_widget(i, gui)
		}
	}
	for _, &i in this.data_table {
		i.was_drawn_this_frame = false
	}
	if this.root != nil {
		gui_update_widget(this.root, this)
	}
	for i in this.panels {
		gui_update_widget(i, this)
	}
	delete_count_set := make([dynamic]WidgetId)
	defer delete(delete_count_set)
	for key, i in this.data_table {
		if !i.was_drawn_this_frame {
			append(&delete_count_set, key)
		}
	}
	for i in delete_count_set {
		delete_key(&this.data_table, i)
	}
}

measure_text_given_width :: proc(
	this: ^Gui,
	text: string,
	text_height: i32,
	max_width: i32,
) -> (
	width, height: i32,
) {
	key := MeasureTextCacheKey{strings.clone(text), text_height, max_width}
	{
		sync.rw_mutex_shared_lock(&this.measure_text_cache_lock)
		defer sync.rw_mutex_shared_unlock(&this.measure_text_cache_lock)
		if key in this.measure_text_cache {
			tmp := &this.measure_text_cache[key]
			delete(key.text)
			tmp.hit_this_frame = true
			width = tmp.width
			height = tmp.height
			return
		}
	}
	dy: i32 = 0
	max_dx: i32 = 0
	base_idx := 0
	dx: i32 = 0
	text_height_f := cast(f32)text_height
	tmp_buffer := make_slice([]u8, len(text) + 1)
	defer delete(tmp_buffer)
	tmp_buffer_idx := 0
	for i, idx in text {
		byte_count := utf8.rune_size(i)
		if i == '\n' {
			sz := cast([2]i32)raylib.MeasureTextEx(
				this.font,
				fmt.ctprintf("%s", text[base_idx:idx]),
				cast(f32)text_height,
				1,
			)
			base_idx = idx + byte_count
			dy += 1
			dx = 0
			if sz.x > max_dx {
				max_dx = sz.x
			}
			mem.set(&tmp_buffer[0], 0, len(tmp_buffer))
			tmp_buffer_idx = 0
		} else {
			{
				for j in idx ..< idx + byte_count {
					tmp_buffer[tmp_buffer_idx] = text[j]
					tmp_buffer_idx += 1
				}
			}
			sz := cast([2]i32)raylib.MeasureTextEx(
				this.font,
				transmute(cstring)&tmp_buffer[0],
				cast(f32)text_height,
				1,
			)
			if sz.x > max_dx {
				max_dx = sz.x
			}
			dx = cast(i32)sz.x
			if dx > max_width {
				base_idx = idx
				dy += 1
				dx = 0
				tmp_buffer_idx = 0
				mem.set(&tmp_buffer[0], 0, len(tmp_buffer))
			}
			if dx > max_dx {
				max_dx = dx
			}
		}
	}
	if base_idx < len(text) {
		sz := cast([2]i32)raylib.MeasureTextEx(
			this.font,
			fmt.ctprintf("%s", text[base_idx:len(text)]),
			cast(f32)text_height,
			1,
		)
		if sz.x > max_dx {
			max_dx = sz.x
		}
	}
	width = max_dx
	height = (dy + 1) * text_height
	{
		sync.rw_mutex_lock(&this.measure_text_cache_lock)
		defer sync.rw_mutex_unlock(&this.measure_text_cache_lock)
		this.measure_text_cache[key] = {width, height, true}
	}
	return
}

split_text_given_width :: proc(
	this: ^Gui,
	text: string,
	text_height: i32,
	max_width: i32,
	allocator := context.allocator,
) -> (
	lines: [dynamic]string,
	width, height: i32,
) {
	lines = make([dynamic]string, allocator)
	{
		new_line_count := strings.count(text, "\n")
		reserve(&lines, new_line_count * 2)
	}
	dy: i32 = 0
	max_dx: i32 = 0
	base_idx := 0
	dx: i32 = 0
	text_height_f := cast(f32)text_height
	tmp_buffer := make_slice([]u8, len(text) + 1)
	defer delete(tmp_buffer)
	tmp_buffer_idx := 0
	for i, idx in text {
		byte_count := utf8.rune_size(i)
		if i == '\n' {
			sz := cast([2]i32)raylib.MeasureTextEx(
				this.font,
				fmt.ctprintf("%s", text[base_idx:idx]),
				cast(f32)text_height,
				1,
			)
			if sz.x > max_dx {
				max_dx = sz.x
			}
			s := text[base_idx:idx]
			append(&lines, s)
			base_idx = idx + byte_count
			dy += 1
			dx = 0
			mem.set(&tmp_buffer[0], 0, len(tmp_buffer))
			tmp_buffer_idx = 0
		} else {
			{
				for j in idx ..< idx + byte_count {
					tmp_buffer[tmp_buffer_idx] = text[j]
					tmp_buffer_idx += 1
				}
			}
			sz := cast([2]i32)raylib.MeasureTextEx(
				this.font,
				transmute(cstring)&tmp_buffer[0],
				cast(f32)text_height,
				1,
			)
			if sz.x > max_dx {
				max_dx = sz.x
			}
			dx = cast(i32)sz.x
			if dx > max_width {
				s := text[base_idx:idx]
				append(&lines, s)
				base_idx = idx
				dy += 1
				dx = 0
				mem.set(&tmp_buffer[0], 0, len(tmp_buffer))
				tmp_buffer_idx = 0
			}
			if dx > max_dx {
				max_dx = dx
			}
		}
	}
	if base_idx < len(text) {
		sz := cast([2]i32)raylib.MeasureTextEx(
			this.font,
			fmt.ctprintf("%s", text[base_idx:len(text)]),
			cast(f32)text_height,
			1,
		)
		if sz.x > max_dx {
			max_dx = sz.x
		}
		s := text[base_idx:len(text)]
		append(&lines, s)
	}
	width = max_dx
	height = (dy + 1) * text_height
	return
}

LOREM_IPSUM :: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Quisque non convallis purus. Mauris iaculis rhoncus lobortis. Donec ac porttitor lectus, ut ullamcorper turpis. Etiam purus nulla, tincidunt ac fermentum vel, pharetra vel nisi. Aliquam egestas molestie ipsum a condimentum. Curabitur volutpat justo gravida, maximus massa ut, euismod mauris. Ut imperdiet, odio non laoreet tincidunt, leo enim mattis lectus, et volutpat purus libero ultricies mauris.\n\n\tNunc et nisl in sapien vestibulum faucibus ut pellentesque sapien. Sed in felis id urna gravida elementum. Vestibulum feugiat arcu eu mi pellentesque convallis. Curabitur tempor, massa sed ornare bibendum, nulla velit laoreet elit, vel scelerisque turpis mi scelerisque leo. Phasellus pulvinar vel mauris sed sollicitudin. Vestibulum quis commodo nisi. Proin semper tellus dolor, nec porta sem mattis et.\n\n\tIn egestas dolor luctus dolor malesuada, id finibus ex blandit. Sed varius vestibulum metus eget cursus. Suspendisse in dui posuere, tincidunt dolor at, pharetra arcu. Morbi maximus odio in faucibus auctor. Ut in laoreet justo. Integer eu leo ut ipsum interdum aliquam eu eget quam. Aliquam non velit vestibulum, accumsan elit ut, porttitor massa. Fusce eleifend convallis ex, vitae vestibulum elit fringilla in. Nunc sit amet tellus id ex eleifend pharetra. Integer id faucibus ex. Integer in mi sit amet augue mattis venenatis ac quis turpis. Nulla lacus risus, placerat ut sem non, feugiat convallis metus. Nam eu pulvinar orci. Vivamus eget leo in est efficitur fermentum vel sit amet eros.\n\n\tPellentesque sapien eros, scelerisque in nulla sit amet, commodo rhoncus nunc. Mauris eget pharetra justo. Integer sem mi, finibus fringilla dictum in, sollicitudin posuere magna. In ullamcorper elit quis velit scelerisque maximus. In pulvinar metus eu lorem maximus imperdiet. Aliquam vulputate elit at nunc elementum consectetur. Suspendisse mauris nulla, semper eget facilisis ut, pellentesque eu turpis.\n\n\tEtiam placerat mi et vehicula dictum. Nulla eu sagittis mi. Nullam efficitur interdum vulputate. Cras eu metus in enim tristique vulputate. Phasellus sit amet bibendum quam. Pellentesque est nibh, feugiat et venenatis id, scelerisque vel eros. Donec pretium, leo ac sagittis pulvinar, nunc mi iaculis lorem, et sollicitudin arcu nulla et nisi. Vestibulum a sem vitae nibh bibendum dictum a eu ipsum. Nulla placerat sapien eget massa vehicula aliquet. Donec id ante eu leo ullamcorper porta nec sit amet nisi. "
