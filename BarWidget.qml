import QtQuick
import QtQuick.Shapes
import Quickshell
import "assets/icon.js" as Icon
import qs.Commons
import qs.Ui

// The bar half of AgentTalk: one icon that opens the panel.
//
// The panel is loaded from the start and never unloaded, because the icon has
// to say whether an agent is working even when the panel was never opened. That
// is also why a run survives closing the panel: the run lives in the process
// and the files `bin/agenttalk` keeps, not in this widget.

BarWidget {
  id: root
  moduleName: "io.github.ramackersjp.agenttalk"

  // A bar slot is exactly as big as the widget's implicit size, and a child
  // anchored to the root adds nothing to it: without these the slot is zero
  // pixels wide and the button is nowhere to be seen.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // The icon is the artwork the user picked: Flaticon's "artificial
  // intelligence" glyph, kept as the path data in assets/icon.js and generated
  // from the downloaded SVG by tools/svg2qml.py. Bar icons are monochrome, so
  // the paths are filled with whatever colour the bar is using for icons right
  // now. That is what makes the icon fit the theme instead of fighting it:
  // switch light/dark, change the accent, move the widget to another section,
  // and the icon follows, exactly like every Nerd Font icon next to it. There
  // is no raster and no shader involved, so nothing to go soft or off-colour.
  readonly property real artworkBox: Icon.box > 0 ? Icon.box : 512
  readonly property var artwork: Icon.paths
  readonly property bool hasArtwork: artwork.length > 0

  readonly property var panel: panelLoader.item
  readonly property bool anyRunning: panel ? panel.anyRunning : false
  readonly property bool opened: panel ? panel.opened === true : false
  readonly property bool popoutSwitchClosing: panel
    ? panel.popoutSwitchClosing === true
    : false

  // The shell routes `omarchy-shell shell summon/toggle/hide <id>` to these
  // three, which is also how the panel's keybinding opens the panel.
  function open() { if (panel) panel.open() }
  function close() { if (panel) panel.close() }
  function toggle() { if (panel) panel.toggle() }
  function closeForPopoutSwitch() { if (panel) panel.closeForPopoutSwitch() }

  function injectPanel() {
    if (!panel) return
    panel.bar = root.bar
    panel.anchorItem = button
    panel.hostWidget = root
    panel.moduleName = root.moduleName
    panel.settings = root.settings
  }

  onBarChanged: injectPanel()

  // One filled path from the artwork. `entry` is the index into the generated
  // path list; an index that is out of range simply draws nothing, which is how
  // a shorter icon needs no special casing.
  component ArtPath: ShapePath {
    property int entry: 0
    strokeWidth: 0
    strokeColor: "transparent"
    PathSvg { path: root.artwork[entry] !== undefined ? String(root.artwork[entry].d) : "" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // No `text`: the artwork is drawn as vector inside the optical canvas, so it
    // gets the same slot, centering and metrics as a glyph would.
    iconComponent: Component {
      Item {
        id: art

        Shape {
          id: shape
          visible: root.hasArtwork
          // The artwork is authored in its own coordinate square and scaled to
          // the optical canvas, so any bar size works without touching the data.
          width: root.artworkBox
          height: root.artworkBox
          anchors.centerIn: parent
          transformOrigin: Item.Center
          scale: art.width > 0 ? art.width / root.artworkBox : 1
          preferredRendererType: Shape.CurveRenderer
          antialiasing: true
          layer.enabled: true
          layer.samples: 4

          // The path data is data, not code: a fixed list of paths bound to
          // entries in assets/icon.js. Icons in this style are a handful of
          // filled shapes, and an entry that is not there draws nothing.
          ArtPath { entry: 0; fillColor: button.foreground }
          ArtPath { entry: 1; fillColor: button.foreground }
          ArtPath { entry: 2; fillColor: button.foreground }
          ArtPath { entry: 3; fillColor: button.foreground }
          ArtPath { entry: 4; fillColor: button.foreground }
          ArtPath { entry: 5; fillColor: button.foreground }
          ArtPath { entry: 6; fillColor: button.foreground }
          ArtPath { entry: 7; fillColor: button.foreground }
        }

        // Before the artwork is generated there is nothing to draw, so the
        // widget falls back to the Nerd Font agent glyph: same size, same
        // colour, never a blank slot.
        OpticalGlyph {
          anchors.fill: parent
          visible: !root.hasArtwork
          text: "\uf06a9"
          fontFamily: button.fontFamily
          fontSize: button.fontSize
          color: button.foreground
        }
      }
    }
    active: root.anyRunning
    tooltipText: root.anyRunning
      ? "AgentTalk — an agent is working"
      : "AgentTalk — talk to your agents"
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.LeftButton) root.toggle()
    }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }
}
