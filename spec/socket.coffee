EventEmitter = require('events').EventEmitter
Duplex = require('stream').Duplex

class Socket extends Duplex
  constructor: ->
    @data = []
    @written = null
    super

  _write: (chunk, encoding, callback) ->
    @written = chunk

  _read: (size) ->
    try
      if @data.length
        @push "#{@data.join('\n')}\n"
      else
        @push null
    finally
      @data = []

  send: (data) ->
    @data.push data

module.exports = Socket
