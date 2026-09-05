class_name CityInfrastructure
extends RefCounted
## District-scale operational model. Service units represent aggregate capacity;
## they are never inserted into player bags or the conserved trade inventory.
const HEALTH_KEYS := ["power_health", "water_health", "sanitation_health", "roads_health"]
const RATIO_KEYS := ["power_ratio", "water_ratio", "clinic_ratio", "mobility_ratio"]
const STOCK_KEYS := ["water_reserve", "wastewater", "waste_backlog", "recycled", "disposed", "budget", "tax_received", "operating_spend", "unserved_water"]

static func create() -> Dictionary:
	return {"power_health":0.97,"water_health":0.96,"sanitation_health":0.96,"roads_health":0.97,
		"power_ratio":1.0,"water_ratio":1.0,"clinic_ratio":1.0,"mobility_ratio":1.0,
		"water_reserve":240.0,"wastewater":0.0,"waste_backlog":0.0,
		"recycled":0.0,"disposed":0.0,"budget":12000.0,"tax_received":0.0,
		"operating_spend":0.0,"unserved_water":0.0}

static func valid(value: Variant) -> bool:
	if not value is Dictionary or value.size() != HEALTH_KEYS.size() + RATIO_KEYS.size() + STOCK_KEYS.size(): return false
	for key in HEALTH_KEYS + RATIO_KEYS + STOCK_KEYS:
		var n: Variant = value.get(key)
		if not (n is float or n is int) or not is_finite(float(n)) or float(n) < 0.0: return false
		var ceiling := 1.0 if key in HEALTH_KEYS + RATIO_KEYS else 1000000000000.0
		if float(n) > ceiling: return false
	return float(value.water_reserve) <= 480.0 and float(value.wastewater) <= 10000.0 and float(value.waste_backlog) <= 10000.0

static func advance(district: Dictionary, intervals: int) -> void:
	var infra: Dictionary = district.infrastructure
	var load := maxf(1.0, float(district.population) / 10000.0)
	for step in range(clampi(intervals, 0, 60)):
		# Finite district tax receipts fund grid imports, treatment, clinic and
		# collection crews. This treasury is separate from player job payroll.
		var revenue := float(district.workforce) / 1000.0 * 3.6
		infra.tax_received = minf(1e12, float(infra.tax_received) + revenue)
		infra.budget = minf(1e12, float(infra.budget) + revenue)
		var cost := 12.0 * load
		var funded := minf(1.0, float(infra.budget) / cost)
		var spent := cost * funded
		infra.budget -= spent
		infra.operating_spend = minf(1e12, float(infra.operating_spend) + spent)
		for key in HEALTH_KEYS:
			# Funded planned work offsets ordinary wear; shocks/neglect still
			# require player repairs or a slow, budget-funded recovery.
			infra[key] = clampf(float(infra[key]) - 0.0007 + funded * 0.001, 0.0, 1.0)
		infra.power_ratio = clampf(float(infra.power_health) * 1.15 * funded, 0.0, 1.0)
		# Pumps and wastewater treatment stop if the electricity supply stops.
		var supply := load * 3.8 * float(infra.water_health) * float(infra.power_ratio)
		infra.water_reserve = minf(480.0, float(infra.water_reserve) + supply)
		var demand := load * 3.0
		var delivered := minf(float(infra.water_reserve), demand)
		infra.water_reserve -= delivered
		infra.water_ratio = delivered / demand
		infra.unserved_water = minf(1e12, float(infra.unserved_water) + demand - delivered)
		infra.wastewater = minf(10000.0, float(infra.wastewater) + delivered * 0.82)
		var treated := minf(float(infra.wastewater), load * 3.3 * float(infra.water_health) * float(infra.power_ratio))
		infra.wastewater -= treated
		infra.waste_backlog = minf(10000.0, float(infra.waste_backlog) + load * 1.7)
		infra.mobility_ratio = clampf(float(infra.roads_health) * (0.65 + 0.35 * float(infra.power_ratio)), 0.0, 1.0)
		var collected := minf(float(infra.waste_backlog), load * 2.2 * float(infra.sanitation_health) * float(infra.mobility_ratio) * funded)
		infra.waste_backlog -= collected
		infra.recycled = minf(1e12, float(infra.recycled) + collected * 0.42)
		infra.disposed = minf(1e12, float(infra.disposed) + collected * 0.58)
		var sanitation := 1.0 / (1.0 + (float(infra.waste_backlog) + float(infra.wastewater)) / (load * 24.0))
		infra.clinic_ratio = clampf(minf(float(infra.water_ratio), float(infra.power_ratio)) * sanitation * funded, 0.0, 1.0)

static func repair(district: Dictionary, service: String, job := "") -> void:
	var infra: Dictionary = district.infrastructure
	var key := "power_health"
	if service == "maintenance_site_east": key = "water_health"
	if job == "maintenance_roads": key = "roads_health"
	elif job == "maintenance_sanitation": key = "sanitation_health"
	infra[key] = minf(1.0, float(infra[key]) + 0.28)
	infra.sanitation_health = minf(1.0, float(infra.sanitation_health) + 0.08)

static func productive_fraction(district: Dictionary) -> float:
	var infra: Dictionary = district.infrastructure
	return clampf(minf(float(infra.power_ratio), float(infra.water_ratio)) * (0.7 + 0.3 * float(infra.clinic_ratio)) * (0.75 + 0.25 * float(infra.mobility_ratio)), 0.0, 1.0)
