package main
import "core:fmt"
import "gui"
import "vendor:raylib"
main :: proc() {
	raylib.InitWindow(1000, 1000, "gui")
	defer raylib.CloseWindow()
	raylib.SetTargetFPS(61)
	wid := gui.create_gui(200, 100, 600, 800)
	should_exit := false
	{
		gui_run(wid, &should_exit)
		fmt.printf("gui:\n")
		for i in wid.root.children[0].children {
			fmt.printf("\t%v\n", i)
		}
	}
	defer gui.destroy_gui(wid)

	if true {
		for !raylib.WindowShouldClose() {
			gui_run(wid, &should_exit)
			if should_exit {
				break
			}
			raylib.BeginDrawing()
			raylib.ClearBackground(raylib.BLACK)
			gui.gui_render(wid)
			raylib.EndDrawing()
		}
	}
}

gui_run :: proc(wid: ^gui.Gui, should_exit: ^bool) {
	gui.gui_begin_frame(wid)
	gui.begin_div(wid)
	gui.text(wid, "hello world!")
	if gui.button(wid, "testing 1 2 3 exit") {
		should_exit^ = true
	}
	gui.end_div(wid)
	gui.gui_end_frame(wid)
}
