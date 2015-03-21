split = require('split')
EventEmitter = require('events').EventEmitter
Socket = require('net').Socket

pad = (num, len = 3) ->
  num = num.toString()
  while (num.length < len)
    num = "0#{num}"
  num


class Alarm extends EventEmitter
  constructor: (@socket) ->
    @setup()

  setup: =>
    @socket.pipe(split()).on 'data', (line) =>
      @handleMessage(line.toString('ascii'))

  ###
  Internal: A message has been received and must be handled.
  msg: String message sent by the AD2USB interface.
  ###
  panelMessageRegex = /^\[/
  rfMessageRegex = /^!RFX/
  sendingRegex = /^!Sending(\.*)done/
  handleMessage: (msg) ->
    try
      if msg.match(panelMessageRegex)
        @handlePanelData msg
      else if msg.match(rfMessageRegex)
        @handleRfMessage msg
      else if msg.match(sendingRegex)
        @emit 'sent'
    catch err
      @emit 'error', err


  ###
  Internal: Panel data has been received. Parse it, keep state, and emit events when state changes.
  ###
  handlePanelData: (msg) ->
    parts = msg.split(',')

    # Keep record of each section of the message
    sections = []

    # Section 1:  [1000000100000000----]

    sec = parts[0].replace(/[\[\]]/g, '')
    sections.push sec
    sec1 = sec.split('')
    ready = sec1.shift() == '1'
    armedAway = sec1.shift() == '1'
    armedStay = sec1.shift() == '1'
    armedState = 'disarmed'
    if ready
      armedState = 'ready'
    else if armedAway
      armedState = 'armedAway'
    else if armedStay
      armedState = 'armedStay'
    if armedState != @armedState
      @emit armedState
    @armedState = armedState

    @state 'backlight', sec1.shift() == '1'
    @state 'programming', sec1.shift() == '1'

    beeps = parseInt(sec1.shift(), 10)
    @emit 'beep', beeps if beeps > 0

    @state 'bypass', sec1.shift() == '1'
    @state 'power', sec1.shift() == '1'
    @state 'chimeMode', sec1.shift() == '1'
    @state 'alarmOccured', sec1.shift() == '1'
    @state 'alarm', sec1.shift() == '1'
    @state 'batteryLow', sec1.shift() == '1'
    @state 'entryDelayOff', sec1.shift() == '1'
    @state 'fireAlarm', sec1.shift() == '1'
    @state 'checkZone', sec1.shift() == '1'
    @state 'perimeterOnly', sec1.shift() == '1'

    # Section 2: 008
    sec2 = parts[1]
    sections.push sec2
    @state 'numeric_code', sec2

    # Section 3: [f702000b1008001c08020000000000]
    sec3 = parts[2].replace(/[\[\]]/g, '')
    sections.push sec3

    # Section 4: "****DISARMED****  Ready to Arm  "
    sec4 = parts[3].replace(/\"/g, '')
    sections.push sec4
    @state 'message', sec4
    @state 'message:1', sec4.substring(0,16)
    @state 'message:2', sec4.substring(16,32)

    @emit.apply @, ['raw'].concat(sections) # raw emit for debugging or additional handling


  ###
  Internal: A RF sensor has reported its status. Parse it, keep state and emit events when state changes.
  ###
  handleRfMessage: (msg) ->
    parts = msg.replace('!RFX:', '').split(',')
    serial = parts.shift()
    status = pad(parseInt(parts.shift(), 16).toString(2), 8).split('').reverse()
    status =
      battery: status[1] == '0'
      supervision: status[2] == '0'
      loop1: status[7] == '0'
      loop2: status[5] == '0'
      loop3: status[4] == '0'
      loop4: status[6] == '0'
    @state "supervision:#{serial}", status.supervision
    @state "battery:#{serial}", status.battery
    @state "loop:#{serial}:1", status.loop1
    @state "loop:#{serial}:2", status.loop2
    @state "loop:#{serial}:3", status.loop3
    @state "loop:#{serial}:4", status.loop4


  ###
  Internal: Keep track of the state of the named property. If the property changes, then emit
  an event with the new state.
  ###
  state: (name, state) ->
    changed =  @[name] != state
    if changed
      @[name] = state
      @emit name, state
    changed


  ###
  Internal: Send a command to the AD2USB interface.

  code: String command to send (i.e. "12341")
  callback: function invoked when interface acknowledges command (optional)

  Returns true if command is sent, otherwise false.
  ###
  send: (cmd, callback) ->
    @once 'sent', (msg) -> callback(null, msg) if callback
    @socket.write(cmd)

  ###
  Public: Check ready status

  Returns true if alarm is disarmed and ready to be armed, otherwise false
  ###
  isReady: ->
    @armedState == "ready"

  ###
  Public: Check armed status

  Returns true if alarm is armed in stay or away mode, otherwise false
  ###
  isArmed: ->
    @armedState == "armedStay" or @armedState == "armedAway"

  ###
  Public: Arm the alarm in away mode.

  code: The user code to use to arm the alarm.
  callback: function invoked when interface acknowledegs command (optional)

  Returns true if command is sent, otherwise false
  ###
  armAway: (code, callback) ->
    @send "#{code}2", callback if code


  ###
  Public: Arm the alarm in away stay mode.

  code: The user code to use to arm the alarm.
  callback: function invoked when interface acknowledegs command (optional)

  Returns true if command is sent, otherwise false
  ###
  armStay: (code, callback) ->
    @send "#{code}3", callback if code


  ###
  Public: Disarm the alarm.

  code: The user code to use to disarm the alarm.
  callback: function invoked when interface acknowledegs command (optional)

  Returns true if command is sent, otherwise false
  ###
  disarm: (code, callback) ->
    @send "#{code}1", callback if code


  ###
  Public: Bypass a zone.

  code: The user code to use to bypass
  zone: The zone number to bypass
  callback: function invoked when interface acknowledegs command (optional)

  Returns true if command is sent, otherwise false
  ###
  bypass: (code, zone, callback) ->
    @send "#{code}6#{zone}", callback if code


  ###
  Public: Connect to the AD2USB device using a TCP socket.

  ip: String IP address of interface
  port: Integer TCP port of interface (optional, defaults to 4999)
  callback: invoked once the connection has been established (optional)
  ###
  @connect: (args...) ->
    callback = args.pop() if typeof args[args.length - 1] == 'function'
    ip = args.shift()
    port = args.shift() ? 4999

    socket = new Socket(type: 'tcp4')
    alarm = new Alarm(socket)
    socket.connect(port, ip, callback)
    alarm


module.exports = Alarm
