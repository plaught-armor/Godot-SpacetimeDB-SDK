extends Resource
class_name SpacetimeDBPluginConfig

@export var autoload_name: String = "SpacetimeDB"
@export var uri: String = "http://127.0.0.1:3000"
@export var module_configs: Dictionary[String, SpacetimeDBModuleConfig] = {}
