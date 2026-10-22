package main
import "core:fmt"
import "gui"
import "vendor:raylib"

main :: proc() {
	raylib.InitWindow(1000, 1000, "gui")
	defer raylib.CloseWindow()
	//	raylib.SetTargetFPS(61)
	wid := gui.create_gui(20, 20, 960, 960)
	should_exit := false
	{
		gui_run(wid, &should_exit)

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
			raylib.DrawFPS(950, 50)
			raylib.EndDrawing()
		}
	}
}

gui_run :: proc(gi: ^gui.Gui, should_exit: ^bool) {
	gui.gui_begin_frame(gi)
	gui.begin_div(gi)
	gui.text(gi, "HI TOAST I LOVE YOU <3")
	gui.text(gi, "hello world!")
	gui.end_div(gi)
	/*
	gui.begin_scrollbox(gi, true)
	for i in 0 ..< 50 {
		gui.text(gi, "HELLO WORLD!")
		if gui.button(gi, fmt.tprintf("exit:%d", i), idx = i) {
			//should_exit^ = true
			fmt.printf("clicked button:%d\n", i)
		}
	}
	gui.end_scrollbox(gi)*/
	gui.begin_scrollbox(gi)
	for i in 0 ..< 100 {
		gui.text(gi, fmt.tprintf("%s: %d", gui.LOREM_IPSUM, i))
		if gui.button(gi, fmt.tprintf("TESTING 1 2 3 exit:%d", i), idx = i) {
			//should_exit^ = true
			fmt.printf("second clicked button:%d\n", i)
		}
	}
	gui.end_scrollbox(gi)
	gui.gui_end_frame(gi)
}
