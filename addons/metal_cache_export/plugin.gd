@tool
extends EditorPlugin

const CacheExport = preload("res://addons/metal_cache_export/export_plugin.gd")

var _cache_export: EditorExportPlugin


func _enter_tree() -> void:
	_cache_export = CacheExport.new()
	add_export_plugin(_cache_export)


func _exit_tree() -> void:
	if _cache_export != null:
		remove_export_plugin(_cache_export)
		_cache_export = null
