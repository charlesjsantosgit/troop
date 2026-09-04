class_name FrontierRemoteView
extends FrontierSim
## A client presentation of a personalized server snapshot. Vehicles may read
## fuel, but local physics cannot manufacture stock or spend the shared tank.

func tick(_dt: float) -> void:
	pass

func action(_kind: String, _payload: Dictionary = {}) -> Dictionary:
	return {"ok": false, "message": "Shared town changes must be confirmed by the server."}

func register_vehicle(id: String, _kind: int) -> Dictionary:
	return state.get("vehicle_fuel", {}).get(id, {})

func consume_vehicle_fuel(_id: String, _litres: float) -> float:
	return 0.0
