extends Node

# Dictionary to store start times of currently running measures
var _start_times: Dictionary = {}

# Default thresholds (in milliseconds)
const THRESHOLD_FRAME_TIME = 20.0
const THRESHOLD_CHUNK_GEN = 3.0
const THRESHOLD_VEGETATION = 2.0

func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	print("[PerformanceMonitor] Initialized (Autoload)")

func start_measure(name: String) -> void:
	_start_times[name] = Time.get_ticks_usec()

func end_measure(name: String, threshold_ms: float = -1.0) -> void:
	if not _start_times.has(name):
		return
		
	var start_time = _start_times[name]
	var end_time = Time.get_ticks_usec()
	var duration_ms = (end_time - start_time) / 1000.0
	
	_start_times.erase(name)
	
	if threshold_ms > 0 and duration_ms > threshold_ms:
		log_spike(name, duration_ms, threshold_ms)

func log_spike(name: String, duration_ms: float, threshold_ms: float) -> void:
	var message = "[SPIKE] %s took %.2fms (Threshold: %.2fms)" % [name, duration_ms, threshold_ms]
	print(message)

func _process(delta):
	# Frame time monitoring
	var frame_ms = delta * 1000.0
	if frame_ms > THRESHOLD_FRAME_TIME:
		log_spike("Frame Time", frame_ms, THRESHOLD_FRAME_TIME)
		# Add Context: Rendering Stats
		var draw_calls = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		var objects = Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
		var video_mem = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / (1024.0 * 1024.0)
		var physics_time = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		print("[STATS] Draw Calls: %d, Objects: %d, VRAM: %.1f MB, Phys: %.2f ms" % [draw_calls, objects, video_mem, physics_time])
