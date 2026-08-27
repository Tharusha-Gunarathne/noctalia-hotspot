--!nonstrict
--
-- Every colour is a palette role token, so switching theme or light/dark mode
-- restyles this panel with no work here. No hex values.

local opened = false
local render

local status = noctalia.state.get("hotspot_status") or {
  active = false,
  busy = false,
  available = true,
  secured = false,
  clients = {},
  clientCount = 0,
  uplink = { connected = false, ssid = "", channel = 0 },
  error = "",
}

-- Session-only credentials. Seeded from the plugin settings when the panel
-- opens, edited here, and dropped whenever the hotspot stops -- so the next
-- start falls back to the configured defaults unless the user types again.
local formSsid = ""
local formPassword = ""
local formOpen = false
local showFormPassword = false

-- Revealed passphrase of the *running* hotspot, fetched on demand.
local revealed = ""
local revealing = false
local showActivePassword = false

local function resetForm()
  formSsid = noctalia.string.trim(noctalia.getConfig("ssid") or "")
  formPassword = ""
  formOpen = noctalia.getConfig("open_network") == true
  showFormPassword = false
end

local function clearSecret()
  revealed = ""
  revealing = false
  showActivePassword = false
end

local function uplinkConnected()
  local uplink = status.uplink
  return type(uplink) == "table" and uplink.connected == true
end

local function sendCommand(action, extra)
  local command = { action = action }
  if type(extra) == "table" then
    for key, value in pairs(extra) do
      command[key] = value
    end
  end
  noctalia.state.set("hotspot_command", command)
end

local function phaseDetails()
  if status.busy == true then
    if status.active == true then
      return noctalia.tr("panel.status.stopping_title"), noctalia.tr("panel.status.stopping_message"), "on_surface_variant", "loader-2"
    end
    return noctalia.tr("panel.status.starting_title"), noctalia.tr("panel.status.starting_message"), "on_surface_variant", "loader-2"
  end

  if status.available == false then
    local message = status.error
    if message == nil or message == "" then message = noctalia.tr("error.missing_dependencies") end
    return noctalia.tr("panel.status.error_title"), message, "error", "alert-circle"
  end

  if status.active == true then
    return noctalia.tr("panel.status.active_title"), noctalia.tr("panel.status.active_message", {
      interface = status.apInterface ~= "" and status.apInterface or "?",
      channel = tostring(status.channel or 0),
    }), "tertiary", "router"
  end

  if not uplinkConnected() then
    return noctalia.tr("panel.status.no_uplink_title"), noctalia.tr("panel.status.no_uplink_message", {
      interface = status.staInterface ~= "" and status.staInterface or "?",
    }), "error", "wifi-off"
  end

  if status.error ~= nil and status.error ~= "" then
    return noctalia.tr("panel.status.error_title"), status.error, "error", "alert-circle"
  end

  return noctalia.tr("panel.status.inactive_title"), noctalia.tr("panel.status.inactive_message"), "on_surface_variant", "wifi-off"
end

local function uplinkCard()
  local connected = uplinkConnected()
  local uplink = status.uplink or {}
  local text
  if connected then
    text = noctalia.tr("panel.uplink.connected", {
      ssid = uplink.ssid ~= "" and uplink.ssid or "?",
      interface = status.staInterface ~= "" and status.staInterface or "?",
      channel = tostring(uplink.channel or 0),
    })
  else
    text = noctalia.tr("panel.uplink.disconnected", {
      interface = status.staInterface ~= "" and status.staInterface or "?",
    })
  end

  return ui.row({
    align = "center", gap = 10, paddingH = 12, paddingV = 10,
    fill = "surface_variant/0.35", radius = 10,
  }, {
    ui.glyph({ name = connected and "access-point" or "access-point-off", size = 16, color = connected and "primary" or "error" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = noctalia.tr("panel.uplink.title"), fontSize = 11, color = "on_surface_variant" }),
      ui.label({ text = text, maxLines = 2 }),
    }),
  })
end

-- Read-only credentials of the live hotspot, with the passphrase masked until
-- the user asks for it. The reveal is a separate privileged call so the key
-- never rides along on the status poll.
local function activeNetworkCard()
  local rows = {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "wifi", size = 15, color = "tertiary" }),
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = noctalia.tr("panel.network.name"), fontSize = 11, color = "on_surface_variant" }),
        ui.label({ text = status.ssid ~= "" and status.ssid or "?", fontWeight = "medium", maxLines = 1 }),
      }),
    }),
  }

  if status.secured == true then
    local shown
    if not showActivePassword then
      shown = string.rep("*", 10)
    elseif revealing then
      shown = noctalia.tr("panel.network.revealing")
    elseif revealed ~= "" then
      shown = revealed
    else
      shown = noctalia.tr("panel.network.reveal_failed")
    end

    table.insert(rows, ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "key", size = 15, color = "primary" }),
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = noctalia.tr("panel.network.password"), fontSize = 11, color = "on_surface_variant" }),
        ui.label({ text = shown, fontWeight = "medium", maxLines = 1 }),
      }),
      ui.button({
        glyph = showActivePassword and "eye-off" or "eye",
        variant = "ghost",
        controlSize = "sm",
        tooltip = showActivePassword and noctalia.tr("panel.network.hide") or noctalia.tr("panel.network.show"),
        onClick = "onToggleReveal",
      }),
    }))
  else
    table.insert(rows, ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "lock-open", size = 15, color = "error" }),
      ui.label({ text = noctalia.tr("panel.network.open"), color = "on_surface_variant", flexGrow = 1 }),
    }))
  end

  if status.gateway ~= nil and status.gateway ~= "" then
    table.insert(rows, ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "router", size = 15, color = "on_surface_variant" }),
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = noctalia.tr("panel.network.gateway"), fontSize = 11, color = "on_surface_variant" }),
        ui.label({ text = status.gateway, maxLines = 1 }),
      }),
    }))
  end

  return ui.column({ gap = 10, padding = 12, fill = "surface_variant/0.35", radius = 10 }, rows)
end

-- Credential entry, shown only while the hotspot is off: hostapd cannot be
-- reconfigured in place, so editing these mid-session would be a lie.
local function configCard()
  local children = {
    ui.label({ text = noctalia.tr("panel.config.title"), fontSize = 11, color = "on_surface_variant" }),
    ui.input({
      key = "ssid-input",
      value = formSsid,
      placeholder = noctalia.tr("panel.config.ssid_placeholder"),
      controlSize = "sm",
      enabled = status.busy ~= true,
      onChange = "onSsidChanged",
    }),
  }

  if not formOpen then
    table.insert(children, ui.row({ gap = 6, align = "center" }, {
      ui.input({
        key = "password-input",
        value = formPassword,
        placeholder = noctalia.tr("panel.config.password_placeholder"),
        controlSize = "sm",
        password = not showFormPassword,
        enabled = status.busy ~= true,
        flexGrow = 1,
        onChange = "onPasswordChanged",
      }),
      ui.button({
        glyph = showFormPassword and "eye-off" or "eye",
        variant = "ghost",
        controlSize = "sm",
        tooltip = showFormPassword and noctalia.tr("panel.network.hide") or noctalia.tr("panel.network.show"),
        onClick = "onToggleFormPassword",
      }),
    }))
  end

  table.insert(children, ui.row({ align = "center", gap = 8 }, {
    ui.glyph({ name = "lock-open", size = 14, color = formOpen and "error" or "on_surface_variant" }),
    ui.label({ text = noctalia.tr("panel.config.open"), flexGrow = 1 }),
    ui.toggle({ checked = formOpen, enabled = status.busy ~= true, onChange = "onOpenChanged" }),
  }))

  return ui.column({ gap = 8, padding = 12, fill = "surface_variant/0.35", radius = 10 }, children)
end

local function clientRow(client)
  local subtitle = client.mac
  if client.ip ~= nil and client.ip ~= "" then
    subtitle = client.ip .. "  ·  " .. client.mac
  end
  local trailing = nil
  if client.signal ~= nil then
    trailing = ui.label({ text = tostring(client.signal) .. " dBm", fontSize = 11, color = "on_surface_variant" })
  end

  return ui.row({
    key = "client-" .. tostring(client.mac),
    align = "center", gap = 10, paddingH = 14, paddingV = 10,
    fill = "surface_variant/0.35", radius = 10,
  }, {
    ui.glyph({ name = "device-mobile", size = 18, color = "primary" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({
        text = (client.ip ~= nil and client.ip ~= "") and client.ip or client.mac,
        fontWeight = "medium", maxLines = 1,
      }),
      ui.label({ text = subtitle, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
    trailing,
  })
end

render = function()
  local busy = status.busy == true
  local active = status.active == true
  local canToggle = status.available ~= false and not busy and (active or uplinkConnected())
  local stateTitle, stateMessage, stateColor, stateGlyph = phaseDetails()

  local actionText = noctalia.tr("panel.action.start")
  local actionGlyph = "player-play"
  local actionVariant = "primary"
  if active then
    actionText = noctalia.tr("panel.action.stop")
    actionGlyph = "player-stop"
    actionVariant = "destructive"
  end
  if busy then
    actionText = active and noctalia.tr("panel.action.stopping") or noctalia.tr("panel.action.starting")
    actionGlyph = "loader-2"
  end

  local children = {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.row({ align = "center", gap = 9, flexGrow = 1 }, {
        ui.glyph({ name = "router", size = 18, color = "primary" }),
        ui.label({ text = noctalia.tr("title"), fontSize = 16, fontWeight = "bold" }),
      }),
      ui.button({ glyph = "settings", variant = "ghost", tooltip = noctalia.tr("panel.configure"), onClick = "onConfigure" }),
      ui.button({ glyph = "refresh", variant = "ghost", tooltip = noctalia.tr("panel.refresh"), enabled = not busy, onClick = "onRefresh" }),
      ui.button({ glyph = "close", variant = "ghost", tooltip = noctalia.tr("panel.close"), onClick = "onCloseClicked" }),
    }),
    ui.row({ align = "center", gap = 10, fill = "surface_variant/0.45", radius = 10, padding = 12 }, {
      ui.glyph({ name = stateGlyph, size = 18, color = stateColor }),
      ui.column({ gap = 3, flexGrow = 1 }, {
        ui.label({ text = stateTitle, fontWeight = "medium", color = stateColor }),
        ui.label({ text = stateMessage, color = "on_surface_variant", maxLines = 3 }),
      }),
    }),
    uplinkCard(),
  }

  if active then
    table.insert(children, activeNetworkCard())
  else
    table.insert(children, configCard())
  end

  table.insert(children, ui.row({ gap = 8 }, {
    ui.button({
      text = actionText, glyph = actionGlyph, variant = actionVariant,
      controlSize = "lg", enabled = canToggle, flexGrow = 1, onClick = "onToggle",
    }),
    ui.button({
      glyph = "refresh-alert", variant = "outline", controlSize = "lg",
      tooltip = noctalia.tr("panel.reset"),
      enabled = status.available ~= false and not busy,
      onClick = "onReset",
    }),
  }))

  table.insert(children, ui.row({ align = "center", justify = "space_between" }, {
    ui.label({ text = noctalia.tr("panel.clients_title"), fontWeight = "medium", color = "on_surface_variant" }),
    ui.label({ text = tostring(status.clientCount or #(status.clients or {})), fontSize = 11, color = "on_surface_variant" }),
  }))

  local clients = status.clients or {}
  if #clients == 0 then
    table.insert(children, ui.column({ padding = 12 }, {
      ui.label({
        text = active and noctalia.tr("panel.no_clients") or noctalia.tr("panel.clients_inactive"),
        color = "on_surface_variant", maxLines = 2,
      }),
    }))
  else
    local listChildren = {}
    for _, client in ipairs(clients) do
      table.insert(listChildren, clientRow(client))
    end
    table.insert(children, ui.scroll({ flexGrow = 1, gap = 8 }, listChildren))
  end

  panel.render(ui.column({ flexGrow = 1, gap = 12 }, children))
end

noctalia.state.watch("hotspot_status", function(value)
  if type(value) ~= "table" then return end
  local wasActive = status.active
  status = value
  -- Session credentials and any revealed key die with the session.
  if wasActive == true and status.active ~= true then
    clearSecret()
    resetForm()
  end
  if opened then render() end
end)

function onOpen(_context)
  opened = true
  status = noctalia.state.get("hotspot_status") or status
  clearSecret()
  resetForm()
  sendCommand("refresh")
  render()
end

function onClose()
  opened = false
  clearSecret()
end

function onCloseClicked()
  panel.close()
end

function onSsidChanged(value)
  formSsid = value or ""
end

function onPasswordChanged(value)
  formPassword = value or ""
end

function onOpenChanged(value)
  formOpen = value == "true"
  render()
end

function onToggleFormPassword()
  showFormPassword = not showFormPassword
  formPassword = formPassword
  render()
end

function onToggleReveal()
  if showActivePassword then
    clearSecret()
    render()
    return
  end

  showActivePassword = true
  if revealed ~= "" then
    render()
    return
  end

  revealing = true
  render()

  local started = noctalia.runAsync({ "sudo", "-n", "hotspot-secret" }, function(result)
    revealing = false
    if result.exitCode == 0 then
      revealed = noctalia.string.trim(result.stdout or "")
    else
      revealed = ""
    end
    if opened then render() end
  end, 10000)

  if not started then
    revealing = false
    revealed = ""
    render()
  end
end

function onToggle()
  if status.busy == true or status.available == false then return end
  if status.active == true then
    sendCommand("disable")
    return
  end
  if not uplinkConnected() then return end
  sendCommand("enable", {
    ssid = formSsid,
    password = formPassword,
    open = formOpen,
  })
end

function onRefresh()
  sendCommand("refresh")
end

function onReset()
  if status.busy == true or status.available == false then return end
  sendCommand("reset")
end

function onConfigure()
  noctalia.openSettings()
end
