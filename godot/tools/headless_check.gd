extends SceneTree

## Headless validation harness. Run with:
##   godot --headless --path godot --script tools/headless_check.gd
## Exercises the pure-data generator + acceptance tests across many seeds and
## room counts, checks invariants, and reports timing. No rendering.

func _init() -> void:
	var fail := 0
	var att_hist := {}
	var worst_ms := 0.0
	var worst_desc := ""

	# Determinism: same seed+params must reproduce an identical checksum.
	var d1 := DungeonGen.generate({"seed": 42, "roomCount": 42})
	var d2 := DungeonGen.generate({"seed": 42, "roomCount": 42})
	if DungeonTests.checksum(d1) != DungeonTests.checksum(d2):
		push_error("DETERMINISM FAIL: seed 42 checksums differ")
		fail += 1
	else:
		print("determinism ok: seed42 checksum = %x" % DungeonTests.checksum(d1))

	# Sweep seeds x room counts, verifying invariants.
	for seed_i in range(1, 61):
		for rc in [10, 25, 42, 60, 80]:
			var t0 := Time.get_ticks_usec()
			var d := DungeonGen.generate({"seed": seed_i * 7919, "roomCount": rc})
			var ms := float(Time.get_ticks_usec() - t0) / 1000.0
			if ms > worst_ms:
				worst_ms = ms
				worst_desc = "seed %d rc %d" % [seed_i * 7919, rc]
			att_hist[d.stats.attempt] = att_hist.get(d.stats.attempt, 0) + 1

			# reachability
			var un := 0
			for i in range(d.grid.size()):
				if d.grid[i] == 1 and d.bfs[i] < 0:
					un += 1
			if un != 0:
				push_error("REACH FAIL seed %d rc %d: %d unreachable" % [seed_i * 7919, rc, un])
				fail += 1
			# cyclomatic >= 1
			var cyclo: int = d.edges.size() - d.rooms.size() + 1
			if cyclo < 1 or d.stats.loops != cyclo:
				push_error("LOOP FAIL seed %d rc %d: cyclo %d loops %d" % [seed_i * 7919, rc, cyclo, d.stats.loops])
				fail += 1
			# entrance degree 1, not boss-adjacent
			var ent: Dictionary = d.rooms[d.debug.entrance]
			var badj := false
			for e in d.edges:
				if (e.a == d.debug.entrance and e.b == d.debug.boss) or (e.a == d.debug.boss and e.b == d.debug.entrance):
					badj = true
			if ent.degree != 1 or badj:
				push_error("ENTRANCE FAIL seed %d rc %d: deg %d badj %s" % [seed_i * 7919, rc, ent.degree, str(badj)])
				fail += 1
			# placement validity
			var door_set := {}
			for c in d.doorways:
				door_set[c.y * d.W + c.x] = true
			for p in d.props:
				var idx: int = p.y * d.W + p.x
				if d.grid[idx] != 1 or door_set.has(idx):
					push_error("PROP PLACEMENT FAIL seed %d rc %d kind %s" % [seed_i * 7919, rc, p.kind])
					fail += 1
					break
			for s in d.spawns:
				var idx: int = s.y * d.W + s.x
				if d.grid[idx] != 1 or door_set.has(idx):
					push_error("SPAWN PLACEMENT FAIL seed %d rc %d" % [seed_i * 7919, rc])
					fail += 1
					break

	print("sweep: 300 dungeons, attempts histogram = %s" % str(att_hist))
	print("worst gen time: %.1f ms (%s)" % [worst_ms, worst_desc])

	# 60-room timing sample.
	var t0 := Time.get_ticks_usec()
	DungeonGen.generate({"seed": 12345, "roomCount": 60})
	print("single 60-room gen: %.1f ms" % (float(Time.get_ticks_usec() - t0) / 1000.0))

	if fail == 0:
		print("ALL INVARIANTS PASSED")
	else:
		print("FAILURES: %d" % fail)
	quit(fail)
