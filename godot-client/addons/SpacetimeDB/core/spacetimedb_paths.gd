## Addon-layout paths shared by the editor plugin and the SDK runtime.
##
## The plugin script extends [EditorPlugin], a class that exists only in an editor
## build: export templates are compiled without the editor API, so a runtime script
## that names the plugin class — even only to read a constant off it — fails to parse
## in an exported game, and every script that depends on it fails with it. Paths the
## runtime needs therefore live here, on a plain [RefCounted] an export template can
## load, and the plugin reads them from here rather than the other way round.
##
## Static-only: never instantiated, referenced by class name.
class_name SpacetimeDBPaths
extends RefCounted

## Root of the installed addon.
##
## Runtime code resolves scripts underneath it by path — [SpacetimeDBSchema] walks
## [code]core_types/[/code] for the SDK's own types, and [SpacetimeDBServerMessage]
## maps a wire tag to the script that decodes it — so installing the addon anywhere
## other than [code]res://addons/SpacetimeDB[/code] means changing this.
const ADDON_PATH: String = "res://addons/SpacetimeDB"
