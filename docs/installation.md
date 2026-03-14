# Installation

The SDK provides the necessary tools to integrate your Godot Engine project with a SpacetimeDB backend, enabling real-time data synchronization and server interaction directly from your Godot client.

## Install from the Godot AssetLib

_Not currently available_

<!-- TODO: Uncomment this block once uploaded to AssetLib

To install the SpacetimeDB SDK from the AssetLib, follow these steps:

1. Open the AssetLib tab in your Godot project.
2. Search for "SpacetimeDB SDK".
3. Click the SpacetimeDB SDK plugin from the results
4. Click the "Download" button to automatically download and install the plugin.
5. Follow the instructions to [enable the plugin](#enable-the-plugin). -->

## Install from a GitHub release (recommended)

1. Download the latest `SpacetimeDB-SDK-x.x.x.zip` from the [GitHub releases page](https://github.com/flametime/Godot-SpacetimeDB-SDK/releases).
2. Extract the zip into your Godot project's root directory. The zip contains an `addons/SpacetimeDB/` folder that will be placed automatically.

## Install from source

1. Clone or download the repository:
    - `git clone https://github.com/flametime/Godot-SpacetimeDB-SDK.git`
    - or download the [latest main branch build](https://github.com/flametime/Godot-SpacetimeDB-SDK/archive/refs/heads/main.zip) and extract it
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
