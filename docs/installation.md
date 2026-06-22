# Installation

The SDK provides the necessary tools to integrate your Godot Engine project with a SpacetimeDB backend, enabling real-time data synchronization and server interaction directly from your Godot client.

## Install from the Godot Asset Store (recommended)

The SDK is published on the [Godot Asset Store](https://store.godotengine.org/asset/plaught-armor/spacetimedb-sdk/) as **SpacetimeDB Godot SDK** (Godot 4.4+).

From inside the editor:

1. Open the **AssetLib** tab in your Godot project.
2. Search for "SpacetimeDB Godot SDK".
3. Click the SpacetimeDB Godot SDK plugin from the results.
4. Click **Download**, then **Install** to place the `addons/SpacetimeDB/` folder into your project.
5. Follow the instructions to [enable the plugin](#enable-the-plugin).

Or download the package directly from the [store page](https://store.godotengine.org/asset/plaught-armor/spacetimedb-sdk/) and extract the `addons/SpacetimeDB/` folder into your project root.

## Install from a GitHub release

1. Download the latest `SpacetimeDB-SDK-x.x.x.zip` from the [GitHub releases page](https://github.com/plaught-armor/Godot-SpacetimeDB-SDK/releases).
2. Extract the zip into your Godot project's root directory. The zip contains an `addons/SpacetimeDB/` folder that will be placed automatically.

## Install from source

1. Clone or download the repository:
    - `git clone https://github.com/plaught-armor/Godot-SpacetimeDB-SDK.git`
    - or download the [latest main branch build](https://github.com/plaught-armor/Godot-SpacetimeDB-SDK/archive/refs/heads/main.zip) and extract it
2. Copy the `godot-client/addons/SpacetimeDB` folder to your Godot project's `addons/` directory.

## Enable the plugin

To enable the SpacetimeDB SDK plugin:

1. Open your project plugin settings by going to `Project -> Project Settings -> Plugins`.
2. Find the "SpacetimeDB" plugin and check the "Enable" checkbox.
3. Once activated, the SpacetimeDB panel will be displayed in the bottom dock of the Godot editor.

> It is recommended to restart Godot after installing and enabling the plugin.

---

### Continue reading

-   [Generate module bindings](codegen.md)
-   [Quick Start guide](quickstart.md)
-   [API Reference](api.md)
