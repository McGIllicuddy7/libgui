package gui
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:unicode/utf8"
import "vendor:raylib"

SCROLL_BOX_SCROLLER_WIDTH :: 15
SCROLL_BOX_SCROLL_HEIGHT :: 30
Color :: raylib.Color
Boundary :: struct {
	x, y, width, height: i32,
}

WidgetId :: struct {
	name: string,
	loc:  runtime.Source_Code_Location,
	idx:  int,
}


WidgetStyle :: struct {
	smol_text:             i32,
	normal_text_size:      i32,
	large_text_size:       i32,
	padding:               i32,
	background_color:      Color,
	border_color:          Color,
	text_color:            Color,
	widget_color:          Color,
	selected_widget_color: Color,
	rounded_corners:       bool,
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
	max_width:           i32,
	max_height:          i32,
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
	tool_tip_text:       string,
	compact:             bool,
}


CachedWidgetData :: struct {
	frame_time:             f64,
	text_input:             strings.Builder,
	bounds:                 Boundary,
	scroll_height:          i32,
	scroll_amount:          i32,
	guess_max_child_height: i32,
	guess_max_child_width:  i32,
	selected:               bool,
	was_drawn_this_frame:   bool,
	text_input_cursor:      int,
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
	can_multithread:                            bool,
	bounds:                                     Boundary,
	root:                                       ^Widget,
	panels:                                     [dynamic]^Widget,
	current_widget:                             ^Widget,
	prev_widget_stack:                          [dynamic]^Widget,
	current_style:                              ^WidgetStyle,
	prev_style_stack:                           [dynamic]^WidgetStyle,
	arena:                                      virtual.Arena,
	alloc:                                      mem.Allocator,
	data_table:                                 map[WidgetId]CachedWidgetData,
	font:                                       raylib.Font,
	input_data:                                 InputData,
	default_style:                              WidgetStyle,
	frame_over:                                 bool,
	measure_text_cache_lock:                    sync.RW_Mutex,
	measure_text_cache:                         map[MeasureTextCacheKey]MeasureTextCacheValue,
	using_default_font:                         bool,
	debug_calculate_dimension_count:            int,
	debug_calculate_dimension_lock_yeah_i_know: sync.Mutex,
	image_table:                                map[string]raylib.Texture2D,
}

make_widget_id :: proc(text: string, loc: runtime.Source_Code_Location, idx: int) -> WidgetId {
	return WidgetId{text, loc, idx}
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
			24,
			nil,
			0,
		)
	} else {
		out.font = raylib.GetFontDefault()
	}
	err := virtual.arena_init_static(&out.arena, 16_777_216)
	assert(err == nil)
	out.alloc = virtual.arena_allocator(&out.arena)
	out.current_style = nil
	out.current_widget = nil
	out.prev_style_stack = make([dynamic]^WidgetStyle)
	out.prev_widget_stack = make([dynamic]^Widget)
	out.data_table = make(map[WidgetId]CachedWidgetData)
	out.default_style = create_default_style()
	return out

}

destroy_gui :: proc(this: ^Gui) {
	for name, texture in this.image_table {
		delete(name)
		raylib.UnloadTexture(texture)
	}
	virtual.arena_destroy(&this.arena)
	for _, &i in this.data_table {
		strings.builder_destroy(&i.text_input)
	}
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
	delete(this.image_table)
	free(this)
}

create_default_style :: proc() -> WidgetStyle {
	out: WidgetStyle
	out.smol_text = 16
	out.normal_text_size = 24
	out.large_text_size = 32
	out.background_color = {175, 175, 175, 255}
	out.widget_color = {170, 170, 170, 255}
	out.selected_widget_color = raylib.DARKGRAY
	out.border_color = raylib.BLACK
	out.text_color = raylib.BLACK
	out.padding = 2
	out.rounded_corners = true
	return out
}

gui_begin_frame :: proc(this: ^Gui, create_root := true) {
	clear(&this.prev_widget_stack)
	clear(&this.prev_style_stack)
	clear(&this.panels)
	virtual.arena_free_all(&this.arena)
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
		tmp.text_input = strings.builder_make_none()
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
	tool_tip: string = "",
	idx := 0,
	id: string = "",
	loc := #caller_location,
) -> bool {
	widget := create_widget(this, .Button, id, idx, loc)
	widget.is_leaf = true
	widget.text = clone_string(this, text)
	if tool_tip != "" {
		widget.tool_tip_text = clone_string(this, tool_tip)
	}
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
	tool_tip: string = "",
	idx := 0,
	id: string = "",
	loc := #caller_location,
) -> bool {
	widget := create_widget(this, .ButtonThumbNail, id, idx, loc)
	widget.is_leaf = true
	widget.text = clone_string(this, text)
	if tool_tip != "" {
		widget.tool_tip_text = clone_string(this, tool_tip)
	}
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

text :: proc(
	this: ^Gui,
	text: string,
	tool_tip: string = "",
	idx := 0,
	id: string = "",
	loc := #caller_location,
) {
	widget := create_widget(this, .Text, id, idx, loc)
	widget.is_leaf = true
	widget.text = clone_string(this, text)
	if tool_tip != "" {
		widget.tool_tip_text = clone_string(this, tool_tip)
	}
	widget.text_height = widget.style.normal_text_size
	widget.base_text_height = widget.text_height
	append(&this.current_widget.children, widget)
}

text_input :: proc(
	this: ^Gui,
	cfg_clear_on_new_line: bool = true,
	cfg_return_only_on_new_line: bool = true,
	max_width: i32 = -1,
	max_height: i32 = -1,
	idx := 0,
	id: string = "",
	loc := #caller_location,
) -> (
	string,
	bool,
) {
	widget := create_widget(this, .TextInput, id, idx, loc)
	widget.is_leaf = true
	widget.text_height = widget.style.normal_text_size
	widget.max_width = max_width
	widget.max_height = max_height
	widget.base_text_height = widget.text_height
	append(&this.current_widget.children, widget)
	data := get_cached_widget_data(this, widget)
	return_pressed := false
	if data.selected {
		if this.input_data.input_char != cast(rune)0 {
			strings.write_rune(&data.text_input, this.input_data.input_char)
		}
		if raylib.IsKeyPressed(.DELETE) ||
		   raylib.IsKeyPressed(.BACKSPACE) ||
		   raylib.IsKeyPressedRepeat(.DELETE) ||
		   raylib.IsKeyPressedRepeat(.BACKSPACE) {
			strings.pop_rune(&data.text_input)
		}
		if raylib.IsKeyPressed(.ENTER) {
			return_pressed = true
			if !cfg_clear_on_new_line {
				strings.write_rune(&data.text_input, '\n')
			}
		}
		if ((raylib.IsKeyDown(.LEFT_CONTROL) || raylib.IsKeyDown(.LEFT_SUPER)) &&
			   raylib.IsKeyPressed(.V)) ||
		   (raylib.IsMouseButtonPressed(.MIDDLE)) {
			buf := raylib.GetClipboardText()
			if buf != nil {
				st := cast(string)buf
				strings.write_string(&data.text_input, st)
			}
		}
		if data.selected {
			if (raylib.IsKeyDown(.LEFT_CONTROL) || raylib.IsKeyDown(.LEFT_SUPER)) &&
			   raylib.IsKeyPressed(.X) {
				raylib.SetClipboardText(
					strings.clone_to_cstring(
						strings.to_string(data.text_input),
						context.temp_allocator,
					),
				)
				strings.builder_reset(&data.text_input)
			}
		}
	}
	did_return_string := false
	widget.text = strings.clone(strings.to_string(data.text_input), this.alloc)
	returned_string := ""
	if (return_pressed || !(cfg_return_only_on_new_line)) {
		did_return_string = true
		returned_string = widget.text
	}
	if cfg_clear_on_new_line && return_pressed {
		strings.builder_reset(&data.text_input)
	}
	return returned_string, did_return_string
}

image :: proc(
	this: ^Gui,
	img_name: string,
	tool_tip: string = "",
	max_width: i32 = -1,
	max_height: i32 = -1,
	idx := 0,
	id: string = "",
	loc := #caller_location,
) {
	widget := create_widget(this, .Image, id, idx, loc)
	widget.is_leaf = true
	widget.max_width = max_width
	widget.max_height = max_height
	widget.image_name = clone_string(this, img_name)
	if tool_tip != "" {
		widget.tool_tip_text = clone_string(this, tool_tip)
	}
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
	compact := true,
	max_width: i32 = -1,
	max_height: i32 = -1,
	idx := 0,
	id: string = "",
	loc := #caller_location,
) {
	widget := create_widget(this, .Container, id, idx, loc)
	widget.is_leaf = false
	widget.compact = compact
	widget.max_height = max_height
	widget.max_width = max_width
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
		this.debug_calculate_dimension_count = 0
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

gui_register_texture :: proc(this: ^Gui, name: string, texture: raylib.Texture2D) {
	if name in this.image_table {
		raylib.UnloadTexture(this.image_table[name])
		this.image_table[name] = texture
	} else {
		this.image_table[strings.clone(name)] = texture
	}
}

gui_load_texture :: proc(this: ^Gui, name: string) {
	if name in this.image_table {
		return
	}

	texture := raylib.LoadTexture(strings.clone_to_cstring(name, context.temp_allocator))
	if !raylib.IsTextureValid(texture) {
		return
	}
	this.image_table[strings.clone(name)] = texture
}

gui_get_texture :: proc(this: ^Gui, name: string) -> (texture: raylib.Texture2D, is_valid: bool) {
	gui_load_texture(this, name)
	if name not_in this.image_table {
		return
	}
	texture = this.image_table[name]
	is_valid = true
	return
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
					for idx in 0 ..< len(this.children) {
						i := this.children[idx]
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
	{
		sync.mutex_lock(&gui.debug_calculate_dimension_lock_yeah_i_know)
		defer sync.mutex_unlock(&gui.debug_calculate_dimension_lock_yeah_i_know)
		gui.debug_calculate_dimension_count += 1
	}
	depth := depth
	if depth == 0 {
		if widget_count_children(this) < 1000 {
			depth = 512
		}
	}
	if this.is_leaf {
		width_base := max_width
		height_base := max_height
		switch this.type {
		case .TextInput:
			{
				this.bounds.height = max_height
				if this.max_height != -1 {
					this.bounds.height = clamp(this.bounds.height, 0, this.max_height)
				}
				this.bounds.width = max_width
				if this.max_width != -1 {
					this.bounds.width = clamp(this.bounds.width, 0, this.max_width)
				}
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
			if this.bounds.width > width_base {
				fmt.printf(
					"this.bounds.width:%d width_base:%d this.bounds.height:%d height_base:%d",
					this.bounds.width,
					width_base,
					this.bounds.height,
					height_base,
				)
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
			if this.max_height != -1 {
				this.bounds.height = clamp(this.bounds.height, 0, this.max_height)
			}
			this.bounds.width = max_width
			if this.max_width != -1 {
				this.bounds.width = clamp(this.bounds.width, 0, this.max_width)
			}
		/*if this.bounds.height < 20 || this.bounds.width < 20 {
				fmt.printf("width:%d, height:%d\n", this.bounds.width, this.bounds.height)
			}*/
		//	assert(this.bounds.height > 20)
		//assert(this.bounds.width > 20)

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
				gui_flex_box_calculations(this, gui, max_width, max_height, true, depth)
				assert(this.bounds.width <= max_width, "width< max_width")
				assert(this.bounds.height <= max_height, "height< max_height")
			}
		case .HorizontalContainer:
			{
				gui_flex_box_calculations(this, gui, max_width, max_height, false, depth)
				assert(this.bounds.width <= max_width, "width< max_width")
				assert(this.bounds.height <= max_height, "height< max_height")
			}
		case .ScrollBox:
			this.bounds.height = max_height
			if this.max_height != -1 {
				this.bounds.height = clamp(this.bounds.height, 0, this.max_height)
			}
			this.bounds.width = max_width
			if this.max_width != -1 {
				this.bounds.width = clamp(this.bounds.width, 0, this.max_width)
			}
			guess_max_height: i32 = 2 << 26
			guess_max_width := max_width - this.style.padding * 2 - SCROLL_BOX_SCROLLER_WIDTH
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
			if this.bounds.width > (3 * mx_x) / 2 + 10 && this.compact {
				this.bounds.width = (3 * mx_x) / 2 + 10
			}
			if this.bounds.height > gui.bounds.height - this.style.padding * 2 {
				this.bounds.height = gui.bounds.height - this.style.padding * 2
			}
		}
		assert(this.bounds.width <= max_width, "width< max_width")
		assert(this.bounds.height <= max_height, "height< max_height")
	}
}

gui_flex_box_calculations :: proc(
	this: ^Widget,
	gui: ^Gui,
	max_width: i32,
	max_height: i32,
	is_vertical: bool,
	depth: int,
) {
	max_height := max_height - this.style.padding * 2
	max_width := max_width - this.style.padding * 2
	done_set := make(map[int]u8)
	defer delete(done_set)
	reserve(&done_set, len(this.children))
	for i in this.children {
		i.bounds = {}
	}
	l: i32 = cast(i32)len(this.children) if len(this.children) > 0 else 1
	if is_vertical {
		max_height_guess :=
			((max_height - this.style.padding * 2) - (this.style.padding + 1) * l) / l
		max_width_guess := max_width - this.style.padding * 2
		for len(done_set) < len(this.children) {
			not_done_count: i32 = 0
			dy: i32 = this.style.padding
			for i, idx in this.children {
				base_height: i32 = i.bounds.height
				if idx in done_set {
					dy += base_height + this.style.padding
					continue
				}
				gui_calculate_dimensions(i, gui, max_width_guess, max_height_guess, depth + 1)
				tmp := i.bounds.height
				dy += tmp + this.style.padding
				if tmp == base_height {
					done_set[idx] = 0
				} else {
					not_done_count += 1
				}
			}
			if not_done_count == 0 {
				break
			}
			remainder := (max_height - dy) / (not_done_count)
			max_height_guess += remainder
			if remainder <= 0 {
				break
			}
		}
		max_width_measured: i32 = 0
		delta_height: i32 = this.style.padding
		for i in this.children {
			if i.bounds.width > max_width_measured {
				max_width_measured = i.bounds.width
			}
			delta_height += i.bounds.height + this.style.padding
		}
		this.bounds.width = max_width_measured + this.style.padding * 2
		this.bounds.height = delta_height
	} else {
		max_width_guess :=
			((max_width - this.style.padding * 2) - (this.style.padding + 1) * l) / l
		max_height_guess := max_height - this.style.padding * 2
		for len(done_set) < len(this.children) {
			not_done_count: i32 = 0
			dx: i32 = this.style.padding
			for i, idx in this.children {
				base_width: i32 = i.bounds.width
				if idx in done_set {
					dx += base_width + this.style.padding
					continue
				}
				gui_calculate_dimensions(i, gui, max_width_guess, max_height_guess, depth + 1)
				tmp := i.bounds.width
				dx += tmp + this.style.padding
				if tmp == base_width {
					done_set[idx] = 0
				} else {
					not_done_count += 1
				}
			}
			if not_done_count == 0 {
				break
			}
			remainder := (max_width - dx) / (not_done_count)
			max_width_guess += remainder
			if remainder <= 0 {
				break
			}
		}
		max_height_measured: i32 = 0
		delta_width: i32 = this.style.padding
		for i in this.children {
			if i.bounds.height > max_height_measured {
				max_height_measured = i.bounds.height
			}
			delta_width += i.bounds.width + this.style.padding
		}
		this.bounds.width = delta_width
		this.bounds.height = max_height_measured + this.style.padding * 2
	}
}

gui_render :: proc(this: ^Gui, draw_debug_info := false) {
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
	if this.root != nil {
		gui_render_widget_tooltip(this.root, this)
	}
	for i in this.panels {
		gui_render_widget_tooltip(i, this)
	}
	if draw_debug_info {
		raylib.DrawText(
			fmt.ctprintf("widget count:%d", count),
			this.bounds.x,
			this.bounds.y,
			16,
			raylib.GREEN,
		)
		raylib.DrawText(
			fmt.ctprintf("gui calculation call count:%d", this.debug_calculate_dimension_count),
			this.bounds.x,
			this.bounds.y + 16,
			16,
			raylib.GREEN,
		)
		byte_count := this.arena.total_used
		capacity := this.arena.total_reserved
		raylib.DrawText(
			fmt.ctprintf("current memory use:%d of %d", byte_count, capacity),
			this.bounds.x,
			this.bounds.y + 32,
			16,
			raylib.GREEN,
		)
	}
}

render_image :: proc(
	img: string,
	x: i32,
	y: i32,
	width: i32,
	height: i32,
	gui: ^Gui,
	tint: raylib.Color,
) {
	is_valid := false
	texture: raylib.Texture2D
	if img != "" {
		texture, is_valid = gui_get_texture(gui, img)
	}
	if !is_valid {
		raylib.DrawRectangle(x, y, width, height, raylib.VIOLET)
		return
	}
	src := raylib.Rectangle{0., 0., cast(f32)texture.width, cast(f32)texture.height}
	draw_width := width
	draw_height := cast(i32)((cast(f32)texture.height / cast(f32)texture.width) *
		cast(f32)draw_width)
	if draw_height > height {
		draw_height = height
		draw_width = cast(i32)((cast(f32)texture.width / cast(f32)texture.height) *
			cast(f32)draw_height)
	}
	dst := raylib.Rectangle{cast(f32)x, cast(f32)y, cast(f32)draw_width, cast(f32)draw_height}
	raylib.DrawTexturePro(texture, src, dst, {0., 0.}, 0., tint)

}

render_text :: proc(this: ^Widget, gui: ^Gui, x_off: i32 = 0, y_off: i32 = 0) {
	render_text_exp(
		this.text,
		this.text_height,
		this.bounds.width - this.style.padding * 2,
		this.bounds.x + x_off,
		this.bounds.y + y_off,
		this.style.text_color,
		gui,
	)
}

render_text_exp :: proc(
	text: string,
	text_height: i32,
	max_width: i32,
	x: i32,
	y: i32,
	color: raylib.Color,
	gui: ^Gui,
) {
	txt, _, _ := split_text_given_width(gui, text, text_height, max_width)
	defer (delete(txt))
	dy: i32 = y
	dx: i32 = x
	for i in txt {
		pos := raylib.Vector2{cast(f32)dx, cast(f32)dy}
		raylib.DrawTextEx(gui.font, fmt.ctprintf("%s", i), pos, cast(f32)text_height, 1., color)
		dy += text_height
	}
}

widget_count_children :: proc(this: ^Widget) -> int {
	out := len(this.children)
	for i in this.children {
		out += widget_count_children(i)
	}
	return out
}

gui_draw_rectangle :: proc(x, y, width, height: i32, rounded: bool, color: Color) {
	if rounded {
		radius: f32 = 0.08
		raylib.DrawRectangleRounded(
			{cast(f32)x, cast(f32)y, cast(f32)width, cast(f32)height},
			radius,
			64,
			color,
		)
	} else {
		raylib.DrawRectangle(x, y, width, height, color)
	}
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
				gui_draw_rectangle(
					this.bounds.x - 2,
					this.bounds.y - 2,
					this.bounds.width + 4,
					this.bounds.height + 4,
					this.style.rounded_corners,
					this.style.border_color,
				)
				gui_draw_rectangle(
					this.bounds.x,
					this.bounds.y,
					this.bounds.width,
					this.bounds.height,
					this.style.rounded_corners,
					this.style.widget_color,
				)
				{
					txt, _, _ := split_text_given_width(
						gui,
						this.text,
						this.text_height,
						this.bounds.width - this.style.padding * 2,
					)
					defer delete(txt)
					to_render_line_count :=
						((this.bounds.height - this.style.padding * 2) / (this.text_height))
					draw_txt := txt[:]
					if cast(int)to_render_line_count < len(txt) + 1 {
						draw_txt = txt[(len(txt) - cast(int)to_render_line_count):len(txt)]
					}
					dy: i32 = this.style.padding + this.bounds.y
					dx: i32 = this.style.padding + this.bounds.x
					dy0 := dy
					for i, idx in draw_txt {
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
					if selected {
						y0 :=
							dy0 +
							(this.text_height) *
								(cast(i32)(len(draw_txt) - 1) if len(draw_txt) > 0 else 0)
						w0: i32 = 0
						if len(draw_txt) > 0 {
							w0 = cast(i32)raylib.MeasureTextEx(gui.font, strings.clone_to_cstring(draw_txt[len(draw_txt) - 1], context.temp_allocator), cast(f32)this.text_height, 1.).x
						}
						if w0 > this.bounds.width - this.style.padding * 2 {
							w0 = this.style.padding
							y0 += this.text_height
						}
						gui_draw_rectangle(
							w0 + dx + 2,
							y0,
							4,
							this.text_height,
							this.style.rounded_corners,
							this.style.text_color,
						)
					}
				}
			}
		case .Button:
			{
				selected := gui.data_table[this.id].selected
				gui_draw_rectangle(
					this.bounds.x - 2,
					this.bounds.y - 2,
					this.bounds.width + 4,
					this.bounds.height + 4,
					this.style.rounded_corners,
					this.style.border_color,
				)
				gui_draw_rectangle(
					this.bounds.x,
					this.bounds.y,
					this.bounds.width,
					this.bounds.height,
					this.style.rounded_corners,
					this.style.widget_color if !selected else this.style.selected_widget_color,
				)
				render_text(this, gui, this.style.padding, this.style.padding)
			}
		case .ButtonThumbNail:
			selected := gui.data_table[this.id].selected
			gui_draw_rectangle(
				this.bounds.x - 2,
				this.bounds.y - 2,
				this.bounds.width + 4,
				this.bounds.height + 4,
				this.style.rounded_corners,
				this.style.border_color,
			)
			gui_draw_rectangle(
				this.bounds.x,
				this.bounds.y,
				this.bounds.width,
				this.bounds.height,
				this.style.rounded_corners,
				this.style.widget_color if !selected else this.style.selected_widget_color,
			)
			render_image(
				this.image_name,
				this.bounds.x + this.style.padding,
				this.bounds.y + this.style.padding,
				this.text_height,
				this.text_height,
				gui,
				raylib.WHITE,
			)
			render_text(
				this,
				gui,
				this.text_height + this.text_height / 2 + this.style.padding,
				this.style.padding,
			)
		case .Image:
			render_image(
				this.image_name,
				this.bounds.x,
				this.bounds.y,
				this.bounds.width,
				this.bounds.height,
				gui,
				raylib.WHITE,
			)
		case .Container:
			gui_draw_rectangle(
				this.bounds.x - 2,
				this.bounds.y - 2,
				this.bounds.width + 4,
				this.bounds.height + 4,
				false,
				this.style.border_color,
			)
			gui_draw_rectangle(
				this.bounds.x,
				this.bounds.y,
				this.bounds.width,
				this.bounds.height,
				false,
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
				data := get_cached_widget_data(gui, this)
				raylib.DrawLine(
					this.bounds.x + this.bounds.width - SCROLL_BOX_SCROLLER_WIDTH,
					this.bounds.y,
					this.bounds.x + this.bounds.width - SCROLL_BOX_SCROLLER_WIDTH,
					this.bounds.y + this.bounds.height,
					this.style.border_color,
				)
				dy := calculate_scroll_box_slider_position(
					data.scroll_amount,
					data.scroll_height,
					(this.bounds.height),
					this.scroll_box_reversed,
				)
				if this.scroll_box_reversed && len(this.children) == 0 {
					dy = this.bounds.height - SCROLL_BOX_SCROLL_HEIGHT
				}
				gui_draw_rectangle(
					this.bounds.x + this.bounds.width - SCROLL_BOX_SCROLLER_WIDTH,
					this.bounds.y + dy,
					SCROLL_BOX_SCROLLER_WIDTH,
					SCROLL_BOX_SCROLL_HEIGHT,
					this.style.rounded_corners,
					this.style.border_color,
				)
				gui_draw_rectangle(
					this.bounds.x + this.bounds.width - SCROLL_BOX_SCROLLER_WIDTH + 2,
					this.bounds.y + dy + 2,
					SCROLL_BOX_SCROLLER_WIDTH - 2,
					SCROLL_BOX_SCROLL_HEIGHT - 2,
					this.style.rounded_corners,
					this.style.selected_widget_color,
				)
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


gui_render_widget_tooltip :: proc(this: ^Widget, gui: ^Gui) {

	switch this.type {
	case .TextInput:
	case .Text:
		fallthrough
	case .Button:
		fallthrough
	case .ButtonThumbNail:
		fallthrough
	case .Image:
		if this.tool_tip_text == "" {
			return
		}
		if !gui.input_data.left_mouse_down &&
		   gui.input_data.mouse_x >= this.bounds.x &&
		   gui.input_data.mouse_x < this.bounds.x + this.bounds.width &&
		   gui.input_data.mouse_y >= this.bounds.y &&
		   gui.input_data.mouse_y < this.bounds.y + this.bounds.height {
			width, height := measure_text_given_width(
				gui,
				this.tool_tip_text,
				this.style.smol_text,
				this.bounds.width - this.style.padding * 2,
			)
			dx := (this.bounds.width - width - this.style.padding * 2) / 2
			dy := this.bounds.height - 4
			raylib.DrawRectangle(
				this.bounds.x + dx,
				this.bounds.y + dy,
				width + this.style.padding * 2,
				height + this.style.padding * 2,
				this.style.widget_color,
			)
			render_text_exp(
				this.tool_tip_text,
				this.style.smol_text,
				this.bounds.width,
				this.bounds.x + this.style.padding + dx,
				this.bounds.y + this.style.padding + dy,
				this.style.text_color,
				gui,
			)
		}
	case .Container:
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
				gui_render_widget_tooltip(i, gui)
			}
		}
		if this.container_kind == .ScrollBox {
			raylib.EndScissorMode()
		}

	case .None:
		assert(false)
	}
}
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
			if this.container_kind == .ScrollBox && mouse_intersecting {
				tmp.scroll_amount -= cast(i32)(gui.input_data.mouse_wheel_delta * 2.)
				if tmp.scroll_amount < 0 {
					tmp.scroll_amount = 0
				} else if tmp.scroll_amount > tmp.scroll_height {
					tmp.scroll_amount = tmp.scroll_height
				}
			}
			if this.container_kind == .ScrollBox && gui.input_data.left_mouse_down {
				amnt := calculate_scroll_box_slider_position(
					tmp.scroll_amount,
					tmp.scroll_height,
					this.bounds.height,
					this.scroll_box_reversed,
				)
				base_y := amnt + this.bounds.y
				base_x := this.bounds.x + this.bounds.width - SCROLL_BOX_SCROLLER_WIDTH / 2
				if (base_x <= gui.input_data.mouse_x &&
					   gui.input_data.mouse_x < base_x + SCROLL_BOX_SCROLLER_WIDTH &&
					   base_y <= gui.input_data.mouse_y &&
					   gui.input_data.mouse_y < base_y + SCROLL_BOX_SCROLL_HEIGHT) ||
				   tmp.selected {
					tmp.selected = true
					amnt = gui.input_data.mouse_y - this.bounds.y
					tmp.scroll_amount = calculate_scroll_amount_from_scroll_box_slide_position(
						amnt,
						tmp.scroll_height,
						this.bounds.height,
						this.scroll_box_reversed,
					)
				}
			} else {
				tmp.selected = false
			}
			if this.container_kind == .ScrollBox {
				tmp.scroll_amount = clamp(tmp.scroll_amount, 0, tmp.scroll_height)
			}
		}
	}
	for i in this.children {
		gui_update_widget(i, gui)
	}
	if this.is_leaf {
		mx := gui.input_data.mouse_x
		my := gui.input_data.mouse_y
		col :=
			(mx >= this.bounds.x &&
				mx < this.bounds.x + this.bounds.width &&
				my >= this.bounds.y &&
				my < this.bounds.y + this.bounds.height) ||
			get_cached_widget_data(gui, this).selected
		if col {
			if (raylib.IsKeyDown(.LEFT_CONTROL) || raylib.IsKeyDown(.LEFT_SUPER)) &&
			   raylib.IsKeyPressed(.C) {
				if this.type == .Image {
					raylib.SetClipboardText(
						strings.clone_to_cstring(this.image_name, context.temp_allocator),
					)
				} else {
					raylib.SetClipboardText(
						strings.clone_to_cstring(this.text, context.temp_allocator),
					)
				}
			}
		}
	}
}

gui_on_update :: proc(this: ^Gui) {
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
		ts := &this.data_table[i]
		strings.builder_destroy(&ts.text_input)
		delete_key(&this.data_table, i)
	}
}

calculate_scroll_box_slider_position :: proc(
	scroll_amount: i32,
	total_height: i32,
	widget_height: i32,
	is_reversed: bool,
) -> i32 {
	widget_height := widget_height - 20
	percentage := cast(f64)scroll_amount / cast(f64)total_height
	if is_reversed {
		return cast(i32)(cast(f64)widget_height - cast(f64)widget_height * percentage)
	} else {
		return cast(i32)(cast(f64)cast(f64)widget_height * percentage)
	}
}

calculate_scroll_amount_from_scroll_box_slide_position :: proc(
	slider_position: i32,
	total_height: i32,
	widget_height: i32,
	is_reversed: bool,
) -> i32 {
	widget_height := widget_height - 20
	percentage := cast(f64)slider_position / cast(f64)widget_height
	if is_reversed {
		return cast(i32)(cast(f64)(total_height) * (1 - percentage))
	} else {
		return cast(i32)(cast(f64)(total_height) * percentage)
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
