--!nonstrict

local COMMAND_KEY = "hotspot_command"

local status = noctalia.state.get("hotspot_status") or {
  active = false,
  busy = false,
  available = true,
  uplink = { connected = false },
}

local function sendCommand(action)
  noctalia.state.set(COMMAND_KEY, { action = action })
end

local function canToggle()
  if status.available == false or status.busy == true then return false end
  -- Stopping is always allowed; starting needs a live uplink to borrow a
  -- channel from.
  if status.active == true then return true end
  local uplink = status.uplink
  return type(uplink) == "table" and uplink.connected == true
end

local function render()
  local active = status.active == true
  shortcut.setLabel(if active then noctalia.tr("shortcut.active") else noctalia.tr("shortcut.inactive"))
  shortcut.setIcon("router", "wifi-off")
  shortcut.setActive(active)
  shortcut.setEnabled(canToggle())
end

noctalia.state.watch("hotspot_status", function(value)
  if type(value) == "table" then
    status = value
    render()
  end
end)

render()

function onClick()
  if not canToggle() then return end
  sendCommand("toggle")
end
