package main
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "er"
Class :: enum {
	Fighter,
	Priest,
	Thief,
	MagicUser,
	Illusionist,
	Bard,
}
PlayerCharacter :: struct {
	name:         string "owned",
	class:        Class,
	level:        int,
	strength:     int,
	dexterity:    int,
	constitution: int,
	intelligence: int,
	wisdom:       int,
	charisma:     int,
	ac:           int,
	hp:           int,
	inventory:    []string "shallow",
}

main :: proc() {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	main_proc()
	for _, leak in track.allocation_map {
		fmt.printf("%v leaked %m\n", leak.location, leak.size)
	}
}

main_proc :: proc() {
	al := new(PlayerCharacter)
	al.name = strings.clone("Al Jenkins")
	al.class = .Fighter
	al.level = 5
	al.strength = 16
	al.dexterity = 14
	al.constitution = 18
	al.intelligence = 10
	al.wisdom = 10
	al.charisma = 8
	al.ac = 16
	al.hp = 10
	tmp_inventory: []string = {
		"longsword",
		"scale mail",
		"shield",
		"2 pairs of breeches",
		"2 pairs of trousers",
		"short bow",
		"10 days rations",
		"20 arrows",
	}
	list := make([dynamic]string)
	for i in tmp_inventory {
		append(&list, i)
	}
	al.inventory = list[:]
	fmt.printf("al:%v\n", al^)
	er.run_destructor(al)
}
