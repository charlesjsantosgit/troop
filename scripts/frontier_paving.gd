extends RefCounted
## Authored paving owns disjoint horizontal regions. Subtracting convex masks
## produces convex pieces, including around enclosed pads, without hole rings
## that a simple polygon triangulator could accidentally fill back in.
const TILE_SIZE := 16.0
const AREA_EPSILON := 0.000001
var requests: Array[Dictionary] = []
var pieces: Array[Dictionary] = []
var _tiles: Dictionary = {}
var _masks: Array[Dictionary] = []
var _cursor := 0
var _started := false

func add(polygon: PackedVector2Array, color: Color, lift: float,
		priority: int, label: String) -> void:
	if polygon.size() < 3 or absf(area(polygon)) <= AREA_EPSILON:
		return
	if area(polygon) < 0:
		polygon.reverse()
	requests.append({"polygon":polygon,"color":color,"lift":lift,
		"priority":priority,"label":label,"order":requests.size()})

func pending() -> bool:
	return _cursor < requests.size()

## One request per streaming work unit; the spatial index avoids comparing a
## distant farm aisle with every industrial street and sidewalk.
func next() -> Array[Dictionary]:
	if not _started:
		requests.sort_custom(func(a: Dictionary,b: Dictionary):
			return a.priority > b.priority if a.priority != b.priority else a.order < b.order)
		_started = true
	if not pending():
		return []
	var request: Dictionary = requests[_cursor]
	_cursor += 1
	var remaining: Array[PackedVector2Array] = [request.polygon]
	var bounds := polygon_bounds(request.polygon)
	var candidates: Dictionary = {}
	for tile in _cells(bounds):
		for index: int in _tiles.get(tile,[]):
			candidates[index] = true
	for index: int in candidates:
		var mask: Dictionary = _masks[index]
		if not bounds.intersects(mask.bounds):
			continue
		var trimmed: Array[PackedVector2Array] = []
		for polygon in remaining:
			trimmed.append_array(subtract(polygon,mask.polygon))
		remaining = trimmed
		if remaining.is_empty():
			break
	var result: Array[Dictionary] = []
	for polygon in remaining:
		if absf(area(polygon)) <= AREA_EPSILON:
			continue
		var piece := request.duplicate()
		piece.polygon = polygon
		pieces.append(piece)
		result.append(piece)
	if not result.is_empty():
		var index := _masks.size()
		_masks.append({"polygon":request.polygon,"bounds":bounds})
		for tile in _cells(bounds):
			if not _tiles.has(tile): _tiles[tile] = []
			_tiles[tile].append(index)
	return result

static func area(polygon: PackedVector2Array) -> float:
	var sum := 0.0
	for index in range(polygon.size()):
		sum += polygon[index].cross(polygon[(index+1)%polygon.size()])
	return sum * 0.5

static func polygon_bounds(polygon: PackedVector2Array) -> Rect2:
	var bounds := Rect2(polygon[0],Vector2.ZERO)
	for point in polygon: bounds = bounds.expand(point)
	return bounds

static func _cells(bounds: Rect2) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for x in range(floori(bounds.position.x/TILE_SIZE),floori(bounds.end.x/TILE_SIZE)+1):
		for y in range(floori(bounds.position.y/TILE_SIZE),floori(bounds.end.y/TILE_SIZE)+1):
			cells.append(Vector2i(x,y))
	return cells

static func subtract(polygon: PackedVector2Array, mask: PackedVector2Array) -> Array[PackedVector2Array]:
	var result: Array[PackedVector2Array] = []
	var inside := polygon
	for index in range(mask.size()):
		var a := mask[index]
		var b := mask[(index+1)%mask.size()]
		var outside := _half_plane(inside,a,b,false)
		if outside.size() >= 3 and absf(area(outside)) > AREA_EPSILON:
			result.append(outside)
		inside = _half_plane(inside,a,b,true)
		if inside.size() < 3:
			break
	return result

static func _half_plane(polygon: PackedVector2Array, a: Vector2,
		b: Vector2, keep_left: bool) -> PackedVector2Array:
	var result := PackedVector2Array()
	if polygon.is_empty(): return result
	var edge := b-a
	var previous := polygon[-1]
	var previous_distance := edge.cross(previous-a)
	var previous_inside := previous_distance >= 0.0 if keep_left else previous_distance <= 0.0
	for current in polygon:
		var distance := edge.cross(current-a)
		var current_inside := distance >= 0.0 if keep_left else distance <= 0.0
		if current_inside != previous_inside:
			result.append(previous.lerp(current,previous_distance/(previous_distance-distance)))
		if current_inside:
			result.append(current)
		previous = current
		previous_distance = distance
		previous_inside = current_inside
	return result
