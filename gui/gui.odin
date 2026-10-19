package gui
import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
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
	id:                  WidgetId,
	type:                WidgetType,
	bounds:              Boundary,
	style:               ^WidgetStyle,
	text:                string,
	text_height:         i32,
	base_text_height:    i32,
	image_name:          string,
	children:            [dynamic]^Widget,
	custom_render:       proc(this: ^Widget),
	destructor:          proc(this: ^Widget),
	is_leaf:             bool,
	scroll_box_reversed: bool,
	container_kind:      ContainerKind,
}

CachedWidgetData :: struct {
	bounds:               Boundary,
	scroll_height:        i32,
	scroll_amount:        i32,
	selected:             bool,
	was_drawn_this_frame: bool,
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
}

Gui :: struct {
	bounds:            Boundary,
	root:              ^Widget,
	current_widget:    ^Widget,
	prev_widget_stack: [dynamic]^Widget,
	current_style:     ^WidgetStyle,
	prev_style_stack:  [dynamic]^WidgetStyle,
	arena:             mem.Dynamic_Arena,
	alloc:             mem.Allocator,
	data_table:        map[WidgetId]CachedWidgetData,
	font:              raylib.Font,
	input_data:        InputData,
	default_style:     WidgetStyle,
	frame_over:        bool,
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

create_gui :: proc(x: i32, y: i32, width: i32, height: i32) -> ^Gui {
	out := new(Gui)
	out.bounds = {x, y, width, height}
	out.font = raylib.LoadFontFromMemory(
		".ttf",
		&FONT_DATA[0],
		cast(i32)len(FONT_DATA),
		16,
		nil,
		0,
	)
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

gui_begin_frame :: proc(this: ^Gui) {
	clear(&this.prev_widget_stack)
	clear(&this.prev_style_stack)
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
	}
	{
		this.current_style = new_clone(this.default_style, this.alloc)
		root := create_widget(this, .Container, "ROOT")
		root.container_kind = .HorizontalContainer
		root.bounds = this.bounds
		this.root = root
		this.current_widget = root
	}
	this.frame_over = false
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
	if widget.id in this.data_table {
		data := &this.data_table[widget.id]
		if data.selected {
			if this.input_data.left_mouse_released &&
			   this.input_data.mouse_x >= data.bounds.x &&
			   this.input_data.mouse_y >= data.bounds.y &&
			   this.input_data.mouse_x < data.bounds.x + data.bounds.width &&
			   this.input_data.mouse_y < data.bounds.y + data.bounds.height {
				out = true
			}
		}
	} else {
		t_data: CachedWidgetData
		this.data_table[widget.id] = t_data
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
	if widget.id in this.data_table {
		data := &this.data_table[widget.id]
		if data.selected {
			if this.input_data.left_mouse_released &&
			   this.input_data.mouse_x >= data.bounds.x &&
			   this.input_data.mouse_y >= data.bounds.y &&
			   this.input_data.mouse_x < data.bounds.x + data.bounds.width &&
			   this.input_data.mouse_y < data.bounds.y + data.bounds.height {
				out = true
			}
		}
	} else {
		t_data: CachedWidgetData
		this.data_table[widget.id] = t_data
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

begin_scrollbox :: proc(
	this: ^Gui,
	reversed := false,
	idx := 0,
	id: string = "",
	loc := #caller_location,
) {
	widget := create_widget(this, .Container, id, idx, loc)
	widget.is_leaf = false
	if !(widget.id in this.data_table) {
		t_data: CachedWidgetData
		this.data_table[widget.id] = t_data
	}
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
		gui_calculate_dimensions(this.root, this, this.bounds.width, this.bounds.height)
		gui_build_layout(this.root, this, this.bounds.x, this.bounds.y)
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
				if !(this.id in gui.data_table) {
					base := CachedWidgetData{}
					base.bounds = this.bounds
					base.scroll_amount = 0
					base.scroll_height = 0
					base.selected = false
				}
				data := &gui.data_table[this.id]
				data.scroll_height = this.style.padding
				if data.scroll_amount > data.scroll_height {
					data.scroll_amount = data.scroll_height
				}
				if data.scroll_amount < 0 {
					data.scroll_amount = 0
				}
				for i in this.children {
					data.scroll_height += i.bounds.height + this.style.padding
				}
				base_y := this.bounds.y + this.style.padding
				if this.scroll_box_reversed {
					base_y =
						this.bounds.y +
						this.bounds.height -
						this.style.padding -
						data.scroll_height
					if len(this.children) > 0 {
						base_y -= this.children[len(this.children) - 1].bounds.height
					}
				}
				for i in this.children {
					gui_build_layout(i, gui, base_x + dx, base_y + dy)
					dy += i.bounds.height + this.style.padding
				}
			}
		}
	}
}

gui_calculate_dimensions :: proc(
	this: ^Widget,
	gui: ^Gui,
	max_width: i32,
	max_height: i32,
	handle_assertions := false,
) {
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
				assert(this.bounds.width < max_width, "width< max_width")
				assert(this.bounds.height < max_height, "height< max_height")
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
			assert(this.bounds.width < max_width, "width< max_width")
			assert(this.bounds.height < max_height, "height< max_height")
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
			assert(this.bounds.width < width_base, "width< max_width")
			assert(this.bounds.height < height_base, "height< max_height")
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
			assert(this.bounds.width < width_base, "width< max_width")
			assert(this.bounds.height < height_base, "height< max_height")
		case .Image:
			this.bounds.height = max_height
			this.bounds.width = max_width
		case .Container:
			fallthrough
		case .None:
			assert(false, "containers, and cannot be marked leaf nodes")
		}
	} else {
		switch this.container_kind {
		case .VerticalContainer:
			{
				guess_max_height := max_height - this.style.padding * 2
				for {
					dx: i32 = 0
					dy: i32 = this.style.padding
					t_max_width := max_width - this.style.padding * 2
					t_max_height := guess_max_height
					for i in this.children {
						gui_calculate_dimensions(i, gui, t_max_width, t_max_height)
						if i.bounds.width + this.style.padding * 2 > dx {
							dx = i.bounds.width + this.style.padding * 2
						}
						dy += i.bounds.height + this.style.padding
					}
					if dy <= max_height {
						this.bounds.height = dy
						this.bounds.width = dx
						break
					} else {
						disp := (dy - guess_max_height)
						l := cast(i32)len(this.children)
						if l == 0 {
							l = 1
						}
						if disp < l {
							guess_max_height -= 1
						} else {
							guess_max_height -= disp / 2
						}
					}
				}
			}
		case .HorizontalContainer:
			{
				guess_max_width := max_width - this.style.padding * 2
				for {
					dx: i32 = 0
					dy: i32 = this.style.padding
					t_max_width := guess_max_width
					t_max_height := max_height - this.style.padding * 2
					for i in this.children {
						gui_calculate_dimensions(i, gui, t_max_width, t_max_height)
						if i.bounds.height + this.style.padding * 2 > dy {
							dy = i.bounds.height + this.style.padding * 2
						}
						dx += i.bounds.width + this.style.padding
					}
					if dx <= max_width {
						this.bounds.height = dy
						this.bounds.width = dx
						break
					} else {
						disp := (dx - guess_max_width)
						l := cast(i32)len(this.children)
						if l == 0 {
							l = 1
						}
						if disp < l {
							guess_max_width -= 1
						} else {
							guess_max_width -= disp / 2
						}
					}
				}
			}
		case .ScrollBox:
			this.bounds.width = max_width
			this.bounds.height = max_height
			guess_max_height := max_height - this.style.padding * 2
			guess_max_width := max_width - this.style.padding * 2
			tmax_height := guess_max_height
			for i in this.children {
				gui_calculate_dimensions(i, gui, guess_max_width, guess_max_height)
			}
		}
		assert(this.bounds.width < max_width, "width< max_width")
		assert(this.bounds.height < max_height, "height< max_height")
	}

}

gui_render :: proc(this: ^Gui) {
	raylib.DrawRectangle(
		this.bounds.x,
		this.bounds.y,
		this.bounds.width,
		this.bounds.height,
		this.default_style.background_color,
	)
	if this.root != nil {
		gui_render_widget(this.root, this)
	}
}

gui_render_widget :: proc(this: ^Widget, gui: ^Gui) {
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
		for i in this.children {
			gui_render_widget(i, gui)
		}
	case .None:
		assert(false)
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
					tmp.scroll_amount -= cast(i32)gui.input_data.mouse_dy
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
	dy: i32 = 0
	max_dx: i32 = 0
	base_idx := 0
	dx: i32 = 0
	text_height_f := cast(f32)text_height
	for i, idx in text {
		byte_count := utf8.rune_size(i)
		if i == '\n' {
			base_idx = idx + byte_count
			dy += 1
			dx = 0
			sz := cast([2]i32)raylib.MeasureTextEx(
				this.font,
				fmt.ctprintf("%s", text[base_idx:idx]),
				cast(f32)text_height,
				1,
			)
			if sz.x > max_dx {
				max_dx = sz.x
			}
		} else {
			sz := cast([2]i32)raylib.MeasureTextEx(
				this.font,
				fmt.ctprintf("%s", text[base_idx:idx + byte_count]),
				cast(f32)text_height,
				1,
			)
			dx = sz.x
			if sz.x >= max_width {
				base_idx = idx
				dy += 1
			}
			if sz.x > max_dx {
				max_dx = sz.x
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
		} else {
			sz := cast([2]i32)raylib.MeasureTextEx(
				this.font,
				fmt.ctprintf("%s", text[base_idx:idx + byte_count]),
				cast(f32)text_height,
				1,
			)
			dx = sz.x
			if sz.x > max_width {
				s := text[base_idx:idx]
				append(&lines, s)
				base_idx = idx
				dy += 1
			}
			if sz.x > max_dx {
				max_dx = sz.x
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
