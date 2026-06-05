extends Node
class_name RLE_decoder

@export_file("*.rle") var rle_world : String

func _ready() -> void:
	var pattern_file = FileAccess.open(rle_world, FileAccess.READ)
	var content = pattern_file.get_as_text()
	var header : String
	var data : String
	
	#var start_time = Time.get_ticks_usec()
	
	
	var comments = RegEx.create_from_string(r'#.+\s|x.+\n|!')
	data = comments.sub(content, "", true)
	
	#for line in content.split("\n"):
		#if line.length() > 0 and line[0] != "#":
			#if line[0] == "x":
				#pass
				##header = line
			#else:
				#data += line
	
	#print("Execution took: ", Time.get_ticks_usec() - start_time, " microseconds")

	var pattern : String
	for row in data.split("$"):
		var count : String
		print(row)
		for c in row:
			if c == "b":
				pattern += "■".repeat(int(count))
				count = ""
			elif c == "o":
				pattern += " ".repeat(int(count))
				count = ""
			elif c != "\n":
				count += c
		pattern += "\n"
	#print(pattern)
