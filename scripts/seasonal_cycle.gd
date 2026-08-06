class_name SeasonalCycle
extends RefCounted
## Calendar-driven seasons and accelerated civil time. A complete 24-hour day
## lasts one real hour. A session authority starts from its local civil hour,
## replicates that phase to joiners, and every peer advances it monotonically.
## The visual season follows the local calendar.

enum Season { SPRING, SUMMER, AUTUMN, WINTER }
enum Weather { RAIN, CLEAR, FALLING_LEAVES, SNOW }

const DAY_LENGTH_SECONDS := 3600.0
const HOURS_PER_SECOND := 24.0 / DAY_LENGTH_SECONDS

static var active_season := Season.SUMMER


static func season_for_month(month: int) -> Season:
	var wrapped_month := posmod(month - 1, 12) + 1
	if wrapped_month in [3, 4, 5]:
		return Season.SPRING
	if wrapped_month in [6, 7, 8]:
		return Season.SUMMER
	if wrapped_month in [9, 10, 11]:
		return Season.AUTUMN
	return Season.WINTER


static func season_from_system() -> Season:
	var date := Time.get_date_dict_from_system()
	return season_for_month(int(date.get("month", 6)))


static func local_hour_from_system() -> float:
	var clock := Time.get_time_dict_from_system()
	return wrapf(float(clock.get("hour", 12))
		+ float(clock.get("minute", 0)) / 60.0
		+ float(clock.get("second", 0)) / 3600.0, 0.0, 24.0)


static func synchronized_hour_from_system() -> float:
	return hour_for_unix_time(Time.get_unix_time_from_system())


static func hour_for_unix_time(unix_seconds: float) -> float:
	# Deterministic conversion helper used by calendar/cycle tests. Network games
	# replicate the authority's phase instead of trusting each client's clock.
	return wrapf(unix_seconds, 0.0, DAY_LENGTH_SECONDS) \
		/ DAY_LENGTH_SECONDS * 24.0


static func hour_after_elapsed(start_hour: float, elapsed_seconds: float) -> float:
	return wrapf(start_hour + elapsed_seconds * HOURS_PER_SECOND, 0.0, 24.0)


static func solar_elevation_for_hour(hour: float) -> float:
	# Sunrise is 06:00, solar noon 12:00, and sunset 18:00. The returned
	# normalized elevation is negative while the sun is below the horizon.
	return sin((wrapf(hour, 0.0, 24.0) - 6.0) / 24.0 * TAU)


static func weather_for_season(season: Season) -> Weather:
	match season:
		Season.SPRING:
			return Weather.RAIN
		Season.AUTUMN:
			return Weather.FALLING_LEAVES
		Season.WINTER:
			return Weather.SNOW
		_:
			return Weather.CLEAR


static func season_name(season: Season) -> String:
	return ["Spring", "Summer", "Autumn", "Winter"][clampi(int(season), 0, 3)]


static func weather_name(weather: Weather) -> String:
	return ["Rain", "Clear", "Falling leaves", "Snow"][clampi(int(weather), 0, 3)]
