package main
import "core:fmt"
import "core:strings"
import "gui"
import "vendor:raylib"

main :: proc() {
	raylib.InitWindow(1600, 1000, "gui")
	defer raylib.CloseWindow()
	//	raylib.SetTargetFPS(61)
	wid := gui.create_gui(0, 0, 1600, 1000)
	should_exit := false
	show_debug_info := false
	list := make([dynamic]string)
	{
		gui_run(wid, &should_exit, &show_debug_info, &list)

	}
	defer gui.destroy_gui(wid)
	if true {
		for !raylib.WindowShouldClose() {
			gui_run(wid, &should_exit, &show_debug_info, &list)
			if should_exit {
				break
			}
			raylib.BeginDrawing()
			raylib.ClearBackground(raylib.BLACK)
			gui.gui_render(wid, show_debug_info)
			raylib.DrawFPS(950, 50)
			raylib.EndDrawing()
		}
	}
}

gui_run :: proc(gi: ^gui.Gui, should_exit: ^bool, draw_debug: ^bool, list: ^[dynamic]string) {
	gui.gui_begin_frame(gi)
	gui.begin_div(gi)
	if gui.button(gi, "exit") {
		should_exit^ = true
	}
	gui.text(gi, "HI TOAST I LOVE YOU <3", "testing 1 2 3")
	gui.text(gi, "hello world!")

	if draw_debug^ {
		if gui.button(gi, "hide debug info") {
			draw_debug^ = false
		}
	} else {
		if gui.button(gi, "show debug info") {
			draw_debug^ = true
		}
	}
	gui.image(gi, "kenku.png", "kenku.png")
	text, entered := gui.text_input(gi)
	if entered && text != "" {
		append(list, strings.clone(text))
	}

	gui.begin_scrollbox(gi, true, false)
	for i, idx in list^ {
		gui.text(gi, i, idx = idx)
	}
	gui.end_scrollbox(gi)
	if gui.button(gi, "reset list") {
		for i in list^ {
			delete(i)
		}
		clear(list)
	}
	gui.end_div(gi)
	gui.begin_scrollbox(gi, reversed = true)
	for i in 0 ..< 100 {
		gui.text(gi, "HELLO WORLD!")
		if gui.button_thumbnail(gi, "kenku.png", fmt.tprintf("exit:%d", i), idx = i) {
			//should_exit^ = true
			append(list, fmt.aprintf("clicked button:%d", i))
		}
	}
	gui.end_scrollbox(gi)
	gui.begin_scrollbox(gi)
	for i in 0 ..< 50 {
		gui.text(gi, fmt.tprintf("%s: %d", gui.LOREM_IPSUM, i))
		if gui.button(gi, fmt.tprintf("TESTING 1 2 3 exit:%d", i), idx = i) {
			//should_exit^ = true
			append(list, fmt.aprintf("second clicked button:%d", i))
		}
	}
	gui.end_scrollbox(gi)
	gui.begin_scrollbox(gi)
	for i in 0 ..< 100 {
		gui.text(gi, "HELLO WORLD 2! ELECTRIC BOOGALOO!")
		if gui.button(gi, fmt.tprintf("enter:%d", i), idx = i) {
			append(list, fmt.aprintf("clicked button 3:%d", i))
		}
	}
	gui.end_scrollbox(gi)
	gui.gui_end_frame(gi)
}
