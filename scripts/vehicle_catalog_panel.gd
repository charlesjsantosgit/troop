class_name VehicleCatalogPanel
extends Control
## Searchable delivery catalog. Authority and pause/mouse ownership remain with
## AdminController; thumbnails are isolated renders of actual vehicle geometry.
signal close_requested
const Fleet = preload("res://scripts/city_vehicle_models.gd")
const Style = preload("res://scripts/menu_theme.gd")
static var _thumbnails: Dictionary = {}
var controller: Node
var _search: LineEdit
var _grid: GridContainer
var _count: Label
var _status: Label
var _cards: Dictionary = {}
var _buttons: Dictionary = {}
var _preview: SubViewport
var _preview_root: Node3D
var _preview_camera: Camera3D
var _thumbnail_queue: Array[Dictionary] = []
var _thumbnail_busy := false
var _closed := false

func configure(admin_controller: Node) -> void: controller = admin_controller

static func catalog_entries() -> Array[Dictionary]:
	var result: Array[Dictionary] = [
		{"id":"boat","label":"Airboat","category":"Watercraft","description":"Shallow-water exploration","script":"res://scripts/airboat.gd","span":5.0},
		{"id":"jet","label":"Fighter Jet","category":"Aircraft","description":"Supersonic flight","script":"res://scripts/fighter_jet.gd","span":15.0},
		{"id":"park_rowboat","label":"Lake Rowboat","category":"Watercraft","description":"Human-powered park boating","script":"res://scripts/park_rowboat.gd","span":5.8},
		{"id":"bike","label":"Motorcycle","category":"Motorcycle","description":"Lightweight two-wheel travel","script":"res://scripts/motorcycle.gd","span":3.0},
		{"id":"jeep","label":"Safari Jeep","category":"Off-road","description":"Four-wheel-drive exploration","script":"res://scripts/safari_jeep.gd","span":4.2},
	]
	for index in range(Fleet.CATALOG.size()):
		var spec := Fleet.spec(index)
		result.append({"id":spec.id,"label":spec.label,"category":str(spec.id).replace("_"," ").capitalize(),"description":"%.2f m long · %.2f m wide" % [float(spec.length),float(spec.width)],"model":index,"span":float(spec.length)})
	result.sort_custom(func(a,b): return str(a.label).naturalnocasecmp_to(str(b.label)) < 0)
	return result

static func matching_entries(query: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var terms := query.strip_edges().to_lower().split(" ",false)
	for entry in catalog_entries():
		var haystack := (str(entry.label)+" "+str(entry.id).replace("_"," ")+" "+str(entry.category)+" "+str(entry.description)).to_lower()
		var matches := true
		for term in terms: matches = matches and haystack.contains(term)
		if matches: result.append(entry)
	return result

func _ready() -> void:
	name = "VehicleCatalog"
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	theme = Style.build()
	var scrim := ColorRect.new()
	scrim.color = Color(.025,.035,.05,.84)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(scrim)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left","right","top","bottom"]: margin.add_theme_constant_override("margin_"+side,28)
	add_child(margin)
	var shell := PanelContainer.new()
	shell.add_theme_stylebox_override("panel",Style.panel(Color("192129"),Color("607385"),24,16))
	margin.add_child(shell)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation",14)
	shell.add_child(column)
	var header := HBoxContainer.new()
	column.add_child(header)
	var heading := VBoxContainer.new()
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(heading)
	heading.add_child(Style.label("VEHICLE CATALOG",27))
	heading.add_child(Style.label("Choose a machine to have it delivered nearby.",15,Style.MUTED))
	var close := Button.new()
	close.text = "Close  Esc"
	close.pressed.connect(_request_close)
	header.add_child(close)
	var tools := HBoxContainer.new()
	column.add_child(tools)
	_search = LineEdit.new()
	_search.name = "VehicleSearch"
	_search.placeholder_text = "Search names or types — sedan, boat, jet…"
	_search.clear_button_enabled = true
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.custom_minimum_size.y = 44
	_search.text_changed.connect(_filter)
	_search.text_submitted.connect(_submit_search)
	tools.add_child(_search)
	tools.add_child(Style.label("A–Z",15,Style.SECONDARY))
	_count = Style.label("",14,Style.MUTED)
	_count.custom_minimum_size.x = 100
	tools.add_child(_count)
	var scroll := ScrollContainer.new()
	scroll.name = "VehicleTileScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)
	_grid = GridContainer.new()
	_grid.name = "AlphabeticalVehicleTiles"
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.columns = maxi(2,mini(5,int((get_viewport_rect().size.x-110)/240.0)))
	_grid.add_theme_constant_override("h_separation",12)
	_grid.add_theme_constant_override("v_separation",12)
	scroll.add_child(_grid)
	for entry in catalog_entries(): _add_card(entry)
	_status = Style.label("Enter selects a single search result. Tab and arrow keys move between controls.",14,Style.MUTED)
	column.add_child(_status)
	_filter("")
	_search.grab_focus.call_deferred()
	if DisplayServer.get_name() != "headless":
		_setup_preview()
		_render_next.call_deferred()

func _add_card(entry: Dictionary) -> void:
	var card := Button.new()
	card.name = "VehicleTile_"+str(entry.id)
	card.custom_minimum_size = Vector2(218,240)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.tooltip_text = str(entry.label)+"\n"+str(entry.description)+"\nClick to deliver"
	card.pressed.connect(func(): _deliver(entry))
	Style.style_button(card)
	_grid.add_child(card)
	_buttons[entry.id] = card
	var inset := MarginContainer.new()
	inset.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inset.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left","right","top","bottom"]: inset.add_theme_constant_override("margin_"+side,10)
	card.add_child(inset)
	var content := VBoxContainer.new()
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inset.add_child(content)
	var thumbnail := TextureRect.new()
	thumbnail.name = "RenderedVehicleThumbnail"
	thumbnail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	thumbnail.custom_minimum_size = Vector2(190,112)
	thumbnail.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumbnail.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	thumbnail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(thumbnail)
	_cards[entry.id] = thumbnail
	if _thumbnails.has(entry.id): thumbnail.texture = _thumbnails[entry.id]
	else: _thumbnail_queue.append(entry)
	content.add_child(Style.label(str(entry.label),17))
	content.add_child(Style.label(str(entry.category),13,Style.ACCENT))
	content.add_child(Style.label(str(entry.description),12,Style.MUTED))

func _filter(query: String) -> void:
	var shown := {}
	for entry in matching_entries(query): shown[entry.id] = true
	for id in _buttons: _buttons[id].visible = shown.has(id)
	_count.text = "%d vehicles" % shown.size()
	if is_instance_valid(_status): _status.text = "No vehicles match that search. Try a name or vehicle type." if shown.is_empty() else "Enter selects a single search result. Tab and arrow keys move between controls."

func _submit_search(query: String) -> void:
	var matches := matching_entries(query)
	if matches.size() == 1: _deliver(matches[0])
	elif not matches.is_empty(): _buttons[matches[0].id].grab_focus()

func _deliver(entry: Dictionary) -> void:
	if not is_instance_valid(controller): return
	if controller.spawn_vehicle(str(entry.id)):
		_request_close()
	else:
		_status.text = "Delivery was unavailable. Check the game message and try again."
		_status.add_theme_color_override("font_color",Style.DANGER)

func _request_close() -> void:
	if _closed: return
	_closed = true
	close_requested.emit()

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo: return
	if event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		_request_close()
	elif event.keycode == KEY_F and (event.ctrl_pressed or event.meta_pressed):
		get_viewport().set_input_as_handled()
		_search.grab_focus()
		_search.select_all()

func _setup_preview() -> void:
	_preview = SubViewport.new()
	_preview.name = "SingleReusableThumbnailStudio"
	_preview.size = Vector2i(440,260)
	_preview.own_world_3d = true
	_preview.transparent_bg = false
	_preview.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_preview.msaa_3d = Viewport.MSAA_2X
	add_child(_preview)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("2a3642")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color("d8e6ed")
	environment.environment.ambient_light_energy = .7
	environment.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	_preview.add_child(environment)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-42,-32,0)
	light.light_energy = 1.8
	_preview.add_child(light)
	_preview_camera = Camera3D.new()
	_preview_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_preview_camera.far = 100
	_preview.add_child(_preview_camera)
	_preview_camera.make_current()

func _render_next() -> void:
	if _closed or _thumbnail_queue.is_empty() or not is_instance_valid(_preview): return
	if _thumbnail_busy: return
	_thumbnail_busy = true
	var entry: Dictionary = _thumbnail_queue.pop_front()
	_preview_root = Node3D.new()
	_preview.add_child(_preview_root)
	if entry.has("model"):
		Fleet.build(_preview_root,int(entry.model),Fleet.paint_for(int(entry.model)*7,int(entry.model)),true,false)
	else:
		# Build visual children off-tree: no vehicle physics, sounds, gameplay
		# registration or world collision is created in a thumbnail viewport.
		var prototype: Node3D = load(entry.script).new()
		prototype.call("_build_hull" if entry.id == "park_rowboat" else "_build_body")
		for child in prototype.get_children():
			prototype.remove_child(child)
			_preview_root.add_child(child)
		prototype.free()
	var span := float(entry.span)
	_preview_camera.size = span*.80
	_preview_camera.position = Vector3(-span*.85,span*.60,-span*.95)
	_preview_camera.look_at(Vector3(0,span*.12,0))
	_preview.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	if not is_instance_valid(_preview) or _closed: return
	var image := _preview.get_texture().get_image()
	if image != null and not image.is_empty():
		var texture := ImageTexture.create_from_image(image)
		_thumbnails[entry.id] = texture
		if is_instance_valid(_cards.get(entry.id)):_cards[entry.id].texture = texture
	_preview_root.queue_free()
	_thumbnail_busy = false
	_render_next.call_deferred()

func test_report() -> Dictionary:
	var visible_ids: Array[String] = []
	for entry in catalog_entries():
		if _buttons.has(entry.id) and _buttons[entry.id].visible: visible_ids.append(str(entry.id))
	return {"catalog_count":catalog_entries().size(),"visible_ids":visible_ids,"cached_thumbnails":_thumbnails.size(),"thumbnail_viewports":1 if is_instance_valid(_preview) else 0,"closed":_closed}
