--!nonstrict

local PANEL_ID = "tharusha-gunarathne/hotspot:panel"
local COMMAND_KEY = "hotspot_command"

local status = noctalia.state.get("hotspot_status") or {
  active = false,
  busy = false,
  available = true,
  clients = {},
  clientCount = 0,
  uplink = { connected = false },
}

local glyph = noctalia.getConfig("glyph") or "router"

local function sendCommand(action)
  noctalia.state.set(COMMAND_KEY, { action = action })
end

local function render()
  if status.available == false then
    barWidget.setGlyph("wifi-off")
    barWidget.setGlyphColor("error")
    barWidget.setText("")
    barWidget.setTooltip(status.error ~= "" and status.error or noctalia.tr("tooltip.unavailable"))
  elseif status.busy == true then
    barWidget.setGlyph("loader-2")
    barWidget.setGlyphColor("primary")
    barWidget.setText("")
    barWidget.setTooltip(noctalia.tr("tooltip.changing"))
  elseif status.active == true then
    barWidget.setGlyph(glyph)
    barWidget.setGlyphColor("tertiary")
    local count = status.clientCount or #(status.clients or {})
    barWidget.setText(count > 0 and tostring(count) or "")
    barWidget.setTooltip(noctalia.tr("tooltip.active", {
      ssid = status.ssid ~= "" and status.ssid or "?",
      count = tostring(count),
      channel = tostring(status.channel or 0),
    }))
  else
    barWidget.setGlyph(glyph)
    barWidget.setText("")
    -- Dim the glyph further when the uplink is down: the hotspot cannot be
    -- started at all in that state, so the bar should say so at a glance.
    local uplink = status.uplink
    if type(uplink) == "table" and uplink.connected ~= true then
      barWidget.setGlyphColor("on_surface_variant/0.5")
      barWidget.setTooltip(noctalia.tr("tooltip.no_uplink"))
    else
      barWidget.setGlyphColor("on_surface_variant")
      barWidget.setTooltip(noctalia.tr("tooltip.inactive"))
    end
  end
end

noctalia.state.watch("hotspot_status", function(value)
  if type(value) == "table" then
    status = value
    render()
  end
end)

render()

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
  if status.available == false then
    noctalia.notifyError(noctalia.tr("title"), status.error or noctalia.tr("error.missing_dependencies"))
    return
  end
  if status.busy == true then return end
  sendCommand("toggle")
end

function onMiddleClick()
  sendCommand("refresh")
end

function onConfigChanged()
  glyph = noctalia.getConfig("glyph") or "router"
  render()
end
