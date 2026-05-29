extends Label

func _process(_delta):
	if Simulation.sim_paused:
		text = "PAUSED"
		return
	text = "FPS: " + str(int(Engine.get_frames_per_second()))
