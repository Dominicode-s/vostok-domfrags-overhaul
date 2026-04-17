extends Node

const MOD_ID: String = "SecureContainer"
const FILE_PATH: String = "user://MCM/SecureContainer/"
const CONFIG_FILE: String = FILE_PATH + "config.ini"

var _config: ConfigFile = ConfigFile.new()

# ── Exposed values (read by Main.gd) ─────────────────────────────────────────
var open_button: int        = MOUSE_BUTTON_MIDDLE
var open_button_type: String = "MouseButton"
var drop_on_unequip: bool   = true
var slots_small: int        = 2
var slots_medium: int       = 4
var slots_large: int        = 6
var spawn_in_loot: bool     = true
var allow_weapons: bool     = true
var weapons_pistol_only: bool = false
var cash_bridge: bool       = true

# ── Init ──────────────────────────────────────────────────────────────────────

func _ready() -> void:
	Engine.set_meta("SecureContainerConfig", self)
	_build_defaults()
	_load_or_create()
	_apply()
	_register_mcm()

func _build_defaults() -> void:
	_config.set_value("Category", "Behaviour",       {"menu_pos": 1})
	_config.set_value("Category", "Container Sizes", {"menu_pos": 2})
	_config.set_value("Category", "Restrictions",    {"menu_pos": 3})
	_config.set_value("Category", "Integrations",    {"menu_pos": 4})
	_config.set_value("Category", "Loot",            {"menu_pos": 5})

	_config.set_value("Keycode", "open_button", {
		"name":         "Open Button",
		"tooltip":      "Mouse button or key used to open and close the secure container panel.",
		"category":     "Behaviour",
		"menu_pos":     1,
		"default":      MOUSE_BUTTON_MIDDLE,
		"default_type": "Mouse",
		"value":        MOUSE_BUTTON_MIDDLE,
		"type":         "Mouse",
	})

	_config.set_value("Bool", "drop_on_unequip", {
		"name":     "Drop Items on Unequip",
		"tooltip":  "When the container is moved out of the equipment slot, drop secured items on the ground. If disabled, items are returned to inventory instead.",
		"category": "Behaviour",
		"menu_pos": 2,
		"default":  true,
		"value":    true,
	})

	_config.set_value("Int", "slots_small", {
		"name":     "Field Pouch Slots",
		"tooltip":  "Number of item slots in the Field Pouch (Common tier).",
		"category": "Container Sizes",
		"menu_pos": 1,
		"default":  2,
		"value":    2,
		"minRange": 1,
		"maxRange": 9,
	})

	_config.set_value("Int", "slots_medium", {
		"name":     "Secure Pouch Slots",
		"tooltip":  "Number of item slots in the Secure Pouch (Rare tier).",
		"category": "Container Sizes",
		"menu_pos": 2,
		"default":  4,
		"value":    4,
		"minRange": 1,
		"maxRange": 9,
	})

	_config.set_value("Int", "slots_large", {
		"name":     "Secure Case Slots",
		"tooltip":  "Number of item slots in the Secure Case (Legendary tier).",
		"category": "Container Sizes",
		"menu_pos": 3,
		"default":  6,
		"value":    6,
		"minRange": 1,
		"maxRange": 9,
	})

	_config.set_value("Bool", "allow_weapons", {
		"name":     "Allow Weapons",
		"tooltip":  "Allow firearms to be placed inside the container. Disable to restrict the pouch to ammo, meds, cash, and similar items.",
		"category": "Restrictions",
		"menu_pos": 1,
		"default":  true,
		"value":    true,
	})

	_config.set_value("Bool", "weapons_pistol_only", {
		"name":     "Pistols Only",
		"tooltip":  "When weapons are allowed, restrict them to pistols only. Rifles, shotguns, and SMGs will be rejected.",
		"category": "Restrictions",
		"menu_pos": 2,
		"default":  false,
		"value":    false,
	})

	_config.set_value("Bool", "cash_bridge", {
		"name":     "Cash System Bridge",
		"tooltip":  "When trading, treat cash stored in the pouch as spendable. Sell proceeds refill the pouch afterwards. Requires Cash System mod. NOTE: cash in transit is briefly held in inventory while trading — it is unprotected from death during that window.",
		"category": "Integrations",
		"menu_pos": 1,
		"default":  true,
		"value":    true,
	})

	_config.set_value("Bool", "spawn_in_loot", {
		"name":     "Spawn in Loot",
		"tooltip":  "Allow secure containers to appear in world loot pools.",
		"category": "Loot",
		"menu_pos": 1,
		"default":  true,
		"value":    true,
	})

func _load_or_create() -> void:
	var mcm: Resource = load("res://ModConfigurationMenu/Scripts/Doink Oink/MCM_Helpers.tres") \
		if ResourceLoader.exists("res://ModConfigurationMenu/Scripts/Doink Oink/MCM_Helpers.tres") \
		else null

	if not FileAccess.file_exists(CONFIG_FILE):
		DirAccess.open("user://").make_dir_recursive(FILE_PATH)
		_config.save(CONFIG_FILE)
	else:
		if mcm:
			mcm.CheckConfigurationHasUpdated(MOD_ID, _config, CONFIG_FILE)
		_config.load(CONFIG_FILE)

func _apply() -> void:
	var kb: Dictionary = _config.get_value("Keycode", "open_button", {})
	open_button      = kb.get("value", MOUSE_BUTTON_MIDDLE)
	open_button_type = kb.get("type",  "Mouse")
	drop_on_unequip  = _config.get_value("Bool", "drop_on_unequip", {}).get("value", true)
	slots_small      = int(_config.get_value("Int",  "slots_small",     {}).get("value", 2))
	slots_medium     = int(_config.get_value("Int",  "slots_medium",    {}).get("value", 4))
	slots_large      = int(_config.get_value("Int",  "slots_large",     {}).get("value", 6))
	spawn_in_loot    = _config.get_value("Bool", "spawn_in_loot",   {}).get("value", true)
	allow_weapons       = _config.get_value("Bool", "allow_weapons",       {}).get("value", true)
	weapons_pistol_only = _config.get_value("Bool", "weapons_pistol_only", {}).get("value", false)
	cash_bridge         = _config.get_value("Bool", "cash_bridge",         {}).get("value", true)

func _register_mcm() -> void:
	if not ResourceLoader.exists("res://ModConfigurationMenu/Scripts/Doink Oink/MCM_Helpers.tres"):
		return
	var mcm: Resource = load("res://ModConfigurationMenu/Scripts/Doink Oink/MCM_Helpers.tres")
	if not mcm:
		return
	mcm.RegisterConfiguration(
		MOD_ID,
		"Secure Container",
		FILE_PATH,
		"Configure slot counts, behaviour, and loot settings for Secure Container.",
		UpdateConfigProperties,
		self
	)

# Called by MCM when the player saves changes
func UpdateConfigProperties(config: ConfigFile) -> void:
	_config = config
	_apply()
	var sc: Node = Engine.get_meta("SecureContainer", null)
	if sc:
		sc._on_config_changed()
