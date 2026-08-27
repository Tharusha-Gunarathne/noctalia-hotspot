--!nonstrict
--
-- Background service for the NixOS AP+STA hotspot.
--
-- State comes from `hotspot-status --json`, which is read-only and
-- unprivileged. Mutations go through `sudo -n`, authorised NOPASSWD by
-- modules/features/services/hotspot.nix.

local STATUS_KEY = "hotspot_status"
local COMMAND_KEY = "hotspot_command"

local busy = false
local revision = 0
local refreshing = false
local refreshAgain = false

local available = noctalia.commandExists("hotspot-status")
  and noctalia.commandExists("start-hotspot")
  and noctalia.commandExists("stop-hotspot")

local status = {
  active = false,
  busy = false,
  available = available,
  error = "",
  revision = 0,
  ssid = "",
  secured = false,
  apInterface = "",
  staInterface = "",
  channel = 0,
  gateway = "",
  uplink = { connected = false, ssid = "", channel = 0 },
  clients = {},
  clientCount = 0,
}

local refresh

local function publish(errorMessage)
  revision += 1
  status.busy = busy
  status.available = available
  status.revision = revision
  status.error = errorMessage or status.error or ""
  status.clientCount = #(status.clients or {})
  noctalia.state.set(STATUS_KEY, status)
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function showNotification(title, body, icon, urgency)
  local payload = noctalia.json.encode({
    app_name = noctalia.tr("title"),
    summary = title,
    body = body or "",
    icon = icon,
    urgency = urgency,
  })
  if payload == nil then
    if urgency == "critical" then
      noctalia.notifyError(title, body)
    else
      noctalia.notify(title, body)
    end
    return
  end
  noctalia.runAsync("noctalia msg notification-show " .. shellQuote(payload))
end

local function runArgv(argv, callback, timeoutMs)
  local started = noctalia.runAsync(argv, callback, timeoutMs or 15000)
  if not started and type(callback) == "function" then
    callback({
      exitCode = -1,
      stdout = "",
      stderr = noctalia.tr("error.command_start"),
      timedOut = false,
    })
  end
  return started
end

local function apInterface()
  local iface = noctalia.string.trim(noctalia.getConfig("ap_interface") or "")
  if iface == "" then iface = "ap0" end
  return iface
end

local function applySnapshot(snapshot)
  status.active = snapshot.active == true
  status.ssid = snapshot.ssid or ""
  status.secured = snapshot.secured == true
  status.apInterface = snapshot.ap_interface or ""
  status.staInterface = snapshot.sta_interface or ""
  status.channel = tonumber(snapshot.channel) or 0
  status.gateway = snapshot.gateway or ""

  local uplink = snapshot.uplink
  if type(uplink) == "table" then
    status.uplink = {
      connected = uplink.connected == true,
      ssid = uplink.ssid or "",
      channel = tonumber(uplink.channel) or 0,
    }
  else
    status.uplink = { connected = false, ssid = "", channel = 0 }
  end

  local clients = {}
  if type(snapshot.clients) == "table" then
    for _, client in ipairs(snapshot.clients) do
      table.insert(clients, {
        mac = tostring(client.mac or ""):lower(),
        ip = client.ip or "",
        signal = tonumber(client.signal),
      })
    end
  end
  table.sort(clients, function(left, right)
    if left.ip ~= right.ip then
      if left.ip == "" then return false end
      if right.ip == "" then return true end
      return left.ip < right.ip
    end
    return left.mac < right.mac
  end)
  status.clients = clients
end

local function completeRefresh(callback, active)
  refreshing = false
  if callback then callback(active) end
  if refreshAgain then
    refreshAgain = false
    refresh()
  end
end

refresh = function(callback)
  if not available then
    status.active = false
    status.clients = {}
    publish(noctalia.tr("error.missing_dependencies"))
    if callback then callback(false) end
    return
  end

  if refreshing then
    refreshAgain = true
    if callback then callback(status.active) end
    return
  end
  refreshing = true

  runArgv({ "hotspot-status", "--json", "--ap", apInterface() }, function(result)
    if result.exitCode ~= 0 then
      local detail = noctalia.string.trim(result.stderr or "")
      if detail == "" then detail = noctalia.tr("error.status_failed") end
      status.active = false
      status.clients = {}
      publish(detail)
      completeRefresh(callback, false)
      return
    end

    local snapshot = noctalia.json.decode(result.stdout or "")
    if type(snapshot) ~= "table" then
      publish(noctalia.tr("error.status_parse"))
      completeRefresh(callback, status.active)
      return
    end

    applySnapshot(snapshot)
    publish("")
    completeRefresh(callback, status.active)
  end, 10000)
end

local function friendlyError(detail)
  if detail:find("password is required") ~= nil or detail:find("sudo:") ~= nil then
    return noctalia.tr("error.sudo_denied")
  elseif detail:find("No password configured") ~= nil then
    return noctalia.tr("error.no_password")
  end
  return detail
end

local function finishToggle(expectedActive, result)
  if result.exitCode ~= 0 then
    busy = false
    local detail = noctalia.string.trim(result.stderr or "")
    if detail == "" then detail = noctalia.string.trim(result.stdout or "") end
    if detail == "" then detail = noctalia.tr("error.command_failed") end
    detail = friendlyError(detail)
    publish(detail)
    showNotification(noctalia.tr("title"), detail, "alert-circle", "critical")
    refresh()
    return
  end

  refresh(function(currentActive)
    busy = false
    publish("")

    if currentActive ~= expectedActive then
      showNotification(noctalia.tr("title"), noctalia.tr("error.state_mismatch"), "alert-circle", "critical")
    elseif currentActive then
      showNotification(
        noctalia.tr("notification.enabled.title"),
        noctalia.tr("notification.enabled.body", {
          ssid = status.ssid ~= "" and status.ssid or "?",
          channel = tostring(status.channel or 0),
        }),
        "wifi",
        "normal"
      )
    else
      showNotification(
        noctalia.tr("notification.disabled.title"),
        noctalia.tr("notification.disabled.body"),
        "wifi-off",
        "normal"
      )
    end
  end)
end

-- Resolution order for credentials, most specific first:
--   1. the panel's session fields (this start only)
--   2. the plugin's persistent settings
--   3. omitted entirely -> start-hotspot falls back to .env.local
-- Nothing is remembered between starts, which is what makes the panel values
-- "session only": stopping simply drops them.
local function buildStartArgv(overrides)
  local argv = { "sudo", "-n", "start-hotspot" }
  overrides = type(overrides) == "table" and overrides or {}

  local ssid = noctalia.string.trim(overrides.ssid or "")
  if ssid == "" then
    ssid = noctalia.string.trim(noctalia.getConfig("ssid") or "")
  end
  if ssid ~= "" then
    if #ssid > 32 then
      return nil, noctalia.tr("error.ssid_too_long")
    end
    table.insert(argv, "-id")
    table.insert(argv, ssid)
  end

  local open = overrides.open
  if open == nil then
    open = noctalia.getConfig("open_network") == true
  end
  if open == true then
    table.insert(argv, "-nopw")
    return argv, nil
  end

  local password = tostring(overrides.password or "")
  if password == "" then
    password = tostring(noctalia.getConfig("password") or "")
  end
  if password ~= "" then
    if #password < 8 then
      return nil, noctalia.tr("error.password_too_short")
    end
    table.insert(argv, "-pw")
    table.insert(argv, password)
  end

  return argv, nil
end

local function startHotspot(overrides)
  if status.uplink == nil or status.uplink.connected ~= true then
    busy = false
    local message = noctalia.tr("error.no_uplink", {
      interface = status.staInterface ~= "" and status.staInterface or "?",
    })
    publish(message)
    showNotification(noctalia.tr("title"), message, "alert-circle", "critical")
    return
  end

  local argv, err = buildStartArgv(overrides)
  if argv == nil then
    busy = false
    publish(err)
    showNotification(noctalia.tr("title"), err, "alert-circle", "critical")
    return
  end

  runArgv(argv, function(result)
    finishToggle(true, result)
  end, 45000)
end

local function stopHotspot()
  runArgv({ "sudo", "-n", "stop-hotspot" }, function(result)
    finishToggle(false, result)
  end, 30000)
end

local function setActive(nextActive, overrides)
  if busy or not available then return end
  busy = true
  publish("")
  if nextActive then
    startHotspot(overrides)
  else
    stopHotspot()
  end
end

local function resetHotspot()
  if busy or not available then return end
  busy = true
  publish("")
  runArgv({ "sudo", "-n", "hotspot-reset" }, function(result)
    finishToggle(false, result)
  end, 30000)
end

local function handleCommand(command)
  local action = command.action
  if action == "toggle" then
    setActive(not status.active, command)
  elseif action == "enable" then
    setActive(true, command)
  elseif action == "disable" then
    setActive(false)
  elseif action == "reset" then
    resetHotspot()
  elseif action == "refresh" or action == "status" then
    refresh()
  end
end

noctalia.state.watch(COMMAND_KEY, function(command)
  if type(command) ~= "table" or type(command.action) ~= "string" then return end
  handleCommand(command)
end)

publish(available and "" or noctalia.tr("error.missing_dependencies"))
refresh()

function update()
  local seconds = tonumber(noctalia.getConfig("refresh_interval")) or 5
  noctalia.setUpdateInterval(math.max(2, seconds) * 1000)
  if not busy then
    refresh()
  end
end

function onConfigChanged()
  update()
end

function onIpc(event, _payload)
  handleCommand({ action = event })
end
