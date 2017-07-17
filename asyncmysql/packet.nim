#    AsyncMysql - Asynchronous MySQL connector written in pure Nim
#        (c) Copyright 2017 Wang Tong
#
#    See the file "LICENSE", included in this distribution, for
#    details about the copyright.

#[
3              packet Length 
1              packet sequenceId
1              [0a] protocolVersion serverVersion
string[NUL]    server serverVersion
4              connection id
string[8]      scramble buff 1
1              [00] filler
2              capability flags (lower 2 bytes)
1              character set
2              serverStatus flags
  if capabilities & CLIENT_PROTOCOL_41 {
2              capability flags (upper 2 bytes)
1              scramble payloadLen
10             reserved (all [00])
string[12]     scramble buff 2
1              [00] filler
  } else {
13             [00] filler
  }
  if more data in the packet {
string[NUL]    auth-plugin name  
  }
]#

import strutils, securehash, math

const
  ## Values for the capabilities flag bitmask used by Client/Server Protocol.
  ## Currently need to fit into 32 bits.
  ## Each bit represents an optional feature of the protocol.
  ## Both the client and the server are sending these.
  ## The intersection of the two determines whast optional parts of the protocol will be used.
  CLIENT_LONG_PASSWORD* = 1
  CLIENT_FOUND_ROWS* = 1 shl 1 
  CLIENT_LONG_FLAG* = 1 shl 2 
  CLIENT_CONNECT_WITH_DB* = 1 shl 3 
  CLIENT_NO_SCHEMA* = 1 shl 4 
  CLIENT_COMPRESS* = 1 shl 5
  CLIENT_ODBC* = 1 shl 6 
  CLIENT_LOCAL_FILES* = 1 shl 7 
  CLIENT_IGNORE_SPACE* = 1 shl 8
  CLIENT_PROTOCOL_41* = 1 shl 9 
  CLIENT_INTERACTIVE* = 1 shl 10 
  CLIENT_SSL* = 1 shl 11
  CLIENT_IGNORE_SIGPIPE* = 1 shl 12 
  CLIENT_TRANSACTIONS* = 1 shl 13 
  CLIENT_RESERVED* = 1 shl 14
  CLIENT_RESERVED2* = 1 shl 15 
  CLIENT_MULTI_STATEMENTS* = 1 shl 16 
  CLIENT_MULTI_RESULTS* = 1 shl 17 
  CLIENT_PS_MULTI_RESULTS* = 1 shl 18 
  CLIENT_PLUGIN_AUTH * = 1 shl 19
  CLIENT_CONNECT_ATTRS* = 1 shl 20 
  CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA* = 1 shl 21
  CLIENT_CAN_HANDLE_EXPIRED_PASSWORDS* = 1 shl 22 
  CLIENT_SESSION_TRACK* = 1 shl 23
  CLIENT_DEPRECATE_EOF* = 1 shl 24 
  CLIENT_SSL_VERIFY_SERVER_CERT* = 1 shl 30
  CLIENT_REMEMBER_OPTIONS* = 1 shl 31

template cond(exp: untyped): untyped =
  if not exp: 
    return

proc toProtocolHex*(x: Natural, len: Positive): string =
  ## `(0xFAFF, 2)` => `"\xFF\xFA"` 
  var n = x
  result = newString(len)
  for i in 0..<int(len):
    result[i] = chr(n and 0xFF)
    n = n shr 8

proc toProtocolInt*(str: string): Natural =
  ## `"\xFF\xFA"` => `0xFAFF`  
  result = 0
  var i = 0
  for c in str:
    inc(result, ord(c) shl (8 * i)) # c.int * pow(16.0, i.float32 * 2).int
    inc(i)

template bufPosChar*(x: pointer, i: int): pointer =
  cast[pointer](cast[ByteAddress](x) + i * sizeof(char))

template bufPosCharVal*(x: pointer, i: int): char =
  cast[ptr char](bufPosChar(x, i))[]

proc joinFixedStr(s: var string, want: var int, buf: pointer, size: int) =
  # Parses only one packet buf not the whole buf.
  let n = if size > want: want else: size
  for i in 0..<n:
    s.add(bufPosCharVal(buf, i)) 
  dec(want, n)

proc joinNulStr(s: var string, buf: pointer, size: int): tuple[finished: bool, count: int] =
  # Parses only one packet buf not the whole buf.
  result.finished = false
  for i in 0..<size:
    inc(result.count)
    if bufPosCharVal(buf, i) == '\0':
      result.finished = true
      return
    else:
      s.add(bufPosCharVal(buf, i))

type
  PacketState* = enum
    packPayloadLength, packSequenceId, packFinish, 
    packHandshakeProtocolVersion, packHandshakeServerVersion, packHandshakeThreadId, 
    packHandshakeScrambleBuff1, packHandshakeFiller0, packHandshakeCapabilities1, packHandshakeCharSet, 
    packHandshakeStatus, packHandshakeCapabilities2, packHandshakeFiller1, packHandshakeFiller2, 
    packHandshakeScrambleBuff2, packHandshakeFiller3, packHandshakePlugin, 
    packGenericHeader,
    packOkAffectedRows, packOkLastInsertId, packOkServerStatus, packOkWarningCount, 
    packOkStatusInfo, packOkSessionStateInfo,
    packErrorCode, packErrorSqlStateMarker, packErrorSqlState, packErrorMessage

  LenEncodedState* = enum
    encodedFlagVal, encodedIntVal, encodedStrVal

  PacketParser* = object
    buf: pointer
    bufLen: int
    bufPos: int
    realLen: int
    packetPos: int
    word: string
    want: int
    payloadLen: int
    sequenceId: int
    wantPayloadLen: int
    relayWant: int
    isLast: bool
    state: PacketState
    relayState: PacketState
    encodedState: LenEncodedState

  HandshakePacket* = object       
    ## Packet from mysql server when connecting to the server that requires authentication.
    protocolVersion*: int      # 1
    serverVersion*: string     # NullTerminatedString
    threadId*: int             # 4
    scrambleBuff1*: string     # 8
    capabilities*: int         # (4)
    capabilities1*: int        # 2
    charset*: int              # 1
    serverStatus*: int         # 2
    capabilities2*: int        # [2]
    scrambleLen*: int          # [1]
    scrambleBuff2*: string     # [12]
    scrambleBuff*: string      # 8 + [12]
    plugin*: string            # NullTerminatedString 

  GenericPacketKind* = enum
    genericOk, genericError, genericEof  

  GenericPacket* = object
    case kind*: GenericPacketKind
    of genericOk:
      affectedRows*: int
      lastInsertId*: int
      serverStatus*: int
      warningCount*: int
      statusInfo*: string
      sessionStateInfo*: string
    of genericError:
      errorCode*: int  
      sqlStateMarker*: string
      sqlState*: string
      errorMessage*: string
    of genericEof:
      warningCountOfEof*: int
      serverStatusOfEof*: int 

proc initHandshakePacket*(): HandshakePacket =
  result.serverVersion = ""
  result.scrambleBuff1 = ""
  result.scrambleBuff2 = ""
  result.plugin = ""

proc initGenericPacket*(kind: GenericPacketKind): GenericPacket =
  case kind
  of genericOk:
    result.statusInfo = ""
    result.sessionStateInfo = ""
  of genericError:
    result.sqlStateMarker = ""
    result.sqlState = ""
    result.errorMessage = ""
  of genericEof:
    discard

proc initPacketParser*(): PacketParser = 
  ## TODO: opmitize buffer
  result.relayState = packPayloadLength
  result.state = packPayloadLength
  result.encodedState = encodedFlagVal
  result.want = 3  
  result.word = ""
  result.isLast = true

proc finished*(p: PacketParser): bool =
  result = p.state == packFinish

proc sequenceId*(parser: PacketParser): int = 
  result = parser.sequenceId

proc offset*(parser: PacketParser): int = 
  result = parser.bufPos

proc mount(p: var PacketParser, buf: pointer, size: int) = 
  p.buf = buf
  p.bufLen = size
  p.bufPos = 0
  if p.state != packPayloadLength and p.state != packSequenceId:
    p.realLen = if p.wantPayloadLen <= size: p.wantPayloadLen
                else: size

proc clear*(p: var PacketParser) = 
  p.relayState = packPayloadLength
  p.state = packPayloadLength
  p.encodedState = encodedFlagVal
  p.want = 3  
  p.word = ""
  p.isLast = true

proc next(p: var PacketParser) = # clear and next
  p.relayState = p.state
  p.relayWant = p.want
  p.state = packPayloadLength
  p.want = 3  
  p.word = ""
  p.isLast = true
  p.realLen = 0
  
proc checkIfNext(p: var PacketParser): bool =
  result = true
  assert p.realLen == 0
  if p.bufLen > p.bufPos:
    assert p.wantPayloadLen == 0
    if p.isLast:
      raise newException(ValueError, "invalid packet")
    else:
      next(p)
  else: 
    if p.wantPayloadLen > 0:
      return false
    else: # == 0
      if p.isLast:
        raise newException(ValueError, "invalid packet")
      else:
        next(p)

proc parseFixed(p: var PacketParser, field: var int): bool =
  result = true
  let want = p.want
  joinFixedStr(p.word, p.want, bufPosChar(p.buf, p.bufPos), p.realLen)
  let n = want - p.want
  inc(p.bufPos, n)
  dec(p.realLen, n)
  dec(p.wantPayloadLen, n)
  if p.want > 0:
    return checkIfNext(p)
  field = toProtocolInt(p.word)
  p.word = ""

proc parseFixed(p: var PacketParser, field: var string): bool =
  result = true
  let want = p.want
  joinFixedStr(field, p.want, bufPosChar(p.buf, p.bufPos), p.realLen)
  let n = want - p.want
  inc(p.bufPos, n)
  dec(p.realLen, n)
  dec(p.wantPayloadLen, n)
  if p.want > 0:
    return checkIfNext(p)

proc parseNul(p: var PacketParser, field: var string): bool =
  result = true
  let (finished, count) = joinNulStr(field, bufPosChar(p.buf, p.bufPos), p.realLen)
  inc(p.bufPos, count)
  dec(p.realLen, count)
  dec(p.wantPayloadLen, count)
  if not finished:
    return checkIfNext(p)

proc parseFiller(p: var PacketParser): bool =
  result = true
  if p.want > p.realLen:
    inc(p.bufPos, p.realLen)
    dec(p.wantPayloadLen, p.realLen)
    dec(p.want, p.realLen)
    dec(p.realLen, p.realLen)
    return checkIfNext(p)
  else:  
    let n = p.want
    inc(p.bufPos, n)
    dec(p.realLen, n)
    dec(p.wantPayloadLen, n)
    dec(p.want, n)

proc parseLenEncoded(p: var PacketParser, field: var int): bool =
  case p.encodedState
  of encodedFlagVal:
    var value: int
    if not parseFixed(p, value):
      return false
    assert value >= 0
    if value < 251:
      field = value
      return true
    elif value == 0xFC:
      p.want = 2
    elif value == 0xFD:
      p.want = 3
    elif value == 0xFE:
      p.want = 8
    else:
      raise newException(ValueError, "invalid encoded flag")  
    p.encodedState = encodedIntVal
    return false
  of encodedIntVal:
    return parseFixed(p, field)
  else:
    raise newException(ValueError, "imposible state")

proc parseLenEncoded(p: var PacketParser, field: var string): bool =
  case p.encodedState
  of encodedFlagVal:
    var value: int
    if not parseFixed(p, value):
      return false
    assert value >= 0
    if value < 251:
      p.encodedState = encodedStrVal
      return false
    elif value == 0xFC:
      p.want = 2
    elif value == 0xFD:
      p.want = 3
    elif value == 0xFE:
      p.want = 8
    else:
      raise newException(ValueError, "invalid encoded flag")  
    p.encodedState = encodedIntVal
    return false
  of encodedIntVal:
    var value: int
    if not parseFixed(p, value):
      return false
    p.want = value
    p.encodedState = encodedStrVal
    return false
  of encodedStrVal:
    return parseFixed(p, field)

proc parseOnPayloadLen(p: var PacketParser): bool =
  result = true
  let w = p.want
  joinFixedStr(p.word, p.want, bufPosChar(p.buf, p.bufPos), p.bufLen - p.bufPos)
  inc(p.bufPos, w - p.want)
  if p.want > 0: 
    return false
  p.payloadLen = toProtocolInt(p.word)
  if p.payloadLen == 0xFFFFFF:
    p.isLast = false
  elif p.payloadLen == 0:
    p.isLast = true
  p.word = ""
  p.wantPayloadLen = p.payloadLen
  p.want = 1
  p.state = packSequenceId
  
proc parseOnSequenceId(p: var PacketParser, nextWant: int, nextState: PacketState): bool =
  result = true
  let w = p.want
  joinFixedStr(p.word, p.want, bufPosChar(p.buf, p.bufLen - p.bufPos), p.bufLen - p.bufPos)
  inc(p.bufPos, w - p.want)
  if p.want > 0:
    return false
  p.sequenceId = toProtocolInt(p.word)
  p.word = ""
  inc(p.packetPos)
  p.realLen = if p.bufLen - p.bufPos > p.wantPayloadLen: p.wantPayloadLen
              else: p.bufLen - p.bufPos
  if p.relayState == packPayloadLength:
    p.want = nextWant
    p.state = nextState
  else:
    p.state = p.relayState
    p.want = p.relayWant
    p.relayState = packPayloadLength

proc parse*(p: var PacketParser, packet: var HandshakePacket, buf: pointer, size: int) = 
  mount(p, buf, size)
  while true:
    case p.state
    of packPayloadLength:
      cond parseOnPayloadLen(p)
    of packSequenceId:
      cond parseOnSequenceId(p, 1, packHandshakeProtocolVersion)
    of packHandshakeProtocolVersion:
      cond parseFixed(p, packet.protocolVersion)
      p.state = packHandshakeServerVersion
    of packHandshakeServerVersion:
      cond parseNul(p, packet.serverVersion)
      p.state = packHandshakeThreadId
      p.want = 4
    of packHandshakeThreadId:
      cond parseFixed(p, packet.threadId)
      p.state = packHandshakeScrambleBuff1
      p.want = 8
    of packHandshakeScrambleBuff1:
      cond parseFixed(p, packet.scrambleBuff1)
      p.state = packHandshakeFiller0
      p.want = 1
    of packHandshakeFiller0:
      cond parseFiller(p)
      p.state = packHandshakeCapabilities1
      p.want = 2
    of packHandshakeCapabilities1:
      cond parseFixed(p, packet.capabilities1)
      p.state = packHandshakeCharSet
      p.want = 1
    of packHandshakeCharSet:
      cond parseFixed(p, packet.charset)
      p.state = packHandshakeStatus
      p.want = 2
    of packHandshakeStatus:
      cond parseFixed(p, packet.serverStatus)
      if (packet.capabilities1 and CLIENT_PROTOCOL_41) > 0:
        p.state = packHandshakeCapabilities2
        p.want = 2
      else:
        p.state = packHandshakeFiller3
        p.want = 13
    of packHandshakeCapabilities2:
      cond parseFixed(p, packet.capabilities2)
      packet.capabilities = packet.capabilities1 + 16 * packet.capabilities2
      p.state = packHandshakeFiller1
      p.want = 1
    of packHandshakeFiller1:
      cond parseFixed(p, packet.scrambleLen)
      p.state = packHandshakeFiller2
      p.want = 10
    of packHandshakeFiller2:
      cond parseFiller(p)
      p.state = packHandshakeScrambleBuff2
      # scrambleBuff2 should be 0x00 terminated, but sphinx does not do this
      # so we assume scrambleBuff2 to be 12 byte and treat the next byte as a
      # filler byte.
      p.want = 12
    of packHandshakeScrambleBuff2:
      cond parseFixed(p, packet.scrambleBuff2)
      packet.scrambleBuff = packet.scrambleBuff1 & packet.scrambleBuff2
      p.state = packHandshakeFiller3
      p.want = 1
    of packHandshakeFiller3:
      cond parseFiller(p)
      if p.isLast and p.wantPayloadLen == 0:
        p.state = packFinish
      else:  
        p.state = packHandshakePlugin
    of packHandshakePlugin:
      # According to the docs this should be 0x00 terminated, but MariaDB does
      # not do this, so we assume this string to be packet terminated.
      cond parseNul(p, packet.plugin)
      p.state = packFinish
    of packFinish:
      return
    else:
      raise newException(ValueError, "imposible state")

proc parse*(parser: var PacketParser, packet: var HandshakePacket, buf: string) =
  ## Parse the ``buf`` data.
  parse(parser, packet, buf.cstring, buf.len)

proc parse*(p: var PacketParser, packet: var GenericPacket, handPacket: HandshakePacket, buf: pointer, size: int) = 
  mount(p, buf, size)
  while true:
    case p.state
    of packPayloadLength:
      cond parseOnPayloadLen(p)
    of packSequenceId:
      cond parseOnSequenceId(p, 1, packGenericHeader)
    of packGenericHeader:
      var header: int
      cond parseFixed(p, header)
      case header
      of 0x00:
        packet = initGenericPacket(genericOk)
        p.state = packOkAffectedRows
        p.want = 1
        p.encodedState = encodedFlagVal
      of 0xFE:
        packet = initGenericPacket(genericError)
        if (handPacket.capabilities and CLIENT_PROTOCOL_41) > 0:
          discard # TODO
        else:
          p.state = packFinish
      of 0xFF:
        packet = initGenericPacket(genericEof)
        p.state = packErrorCode # TODO
        p.want = 2
      else:
        raise newException(ValueError, "invalid header")
    of packOkAffectedRows:
      cond parseLenEncoded(p, packet.affectedRows)
      p.state = packOkLastInsertId
    of packOkLastInsertId:
      cond parseLenEncoded(p, packet.lastInsertId)
      if (handPacket.capabilities and CLIENT_PROTOCOL_41) > 0 or 
         (handPacket.capabilities and CLIENT_PROTOCOL_41) > 0:
        p.state = packOkServerStatus
        p.want = 2
      else:
        p.state = packOkStatusInfo
        if (handPacket.capabilities and CLIENT_SESSION_TRACK) == 0:
          p.want = p.wantPayloadLen
    of packOkServerStatus:
      cond parseFixed(p, packet.serverStatus)
      if (handPacket.capabilities and CLIENT_PROTOCOL_41) > 0:
        p.state = packOkWarningCount
        p.want = 2
      else:
        p.state = packOkStatusInfo
        if (handPacket.capabilities and CLIENT_SESSION_TRACK) == 0:
          p.want = p.wantPayloadLen
    of packOkWarningCount:
      cond parseFixed(p, packet.warningCount)
      p.state = packOkStatusInfo
      if (handPacket.capabilities and CLIENT_SESSION_TRACK) == 0:
        p.want = p.wantPayloadLen
    of packOkStatusInfo:
      if (handPacket.capabilities and CLIENT_SESSION_TRACK) > 0:
        cond parseLenEncoded(p, packet.sessionStateInfo)
        p.state = packOkSessionStateInfo
        p.want = p.wantPayloadLen
      else:
        cond parseFixed(p, packet.statusInfo)
        p.state = packFinish
    of packOkSessionStateInfo:
      cond parseLenEncoded(p, packet.sessionStateInfo)
      p.state = packFinish
    of packFinish:
      return
    else:
      raise newException(ValueError, "imposible state")

type
  ClientAuthenticationPacket* = tuple 
    ## Packet for login request.
    capabilities: int         # 4
    maxPacketSize: int        # 4
    charset: int              # [1]
    # filler: string          # [23]
    user: string              # NullTerminatedString
    # scrambleLen             # 1
    scrambleBuff: string      # 20
    database: string          # NullTerminatedString

proc parseHex(c: char): int =
  case c
  of '0'..'9':
    result = ord(c.toUpperAscii) - ord('0') 
  of 'a'..'f':
    result = ord(c.toUpperAscii) - ord('A') + 10
  of 'A'..'F':
    result = ord(c.toUpperAscii) - ord('A') + 10
  else:
    raise newException(ValueError, "invalid hex char: " & c)

proc `xor`(a: string, b: string): string =
  assert a.len == b.len
  result = newStringOfCap(a.len)
  for i in 0..<a.len:
    let c = ord(a[i]) xor ord(b[i])
    add(result, chr(c))

proc sha1(seed: string): string =
  const len = 20
  result = newString(len)
  let s = $secureHash(seed) # TODO: optimize
  for i in 0..<len:
    result[i] = chr(parseHex(s[i*2]) shl 4 + parseHex(s[i*2+1]))

proc token(scrambleBuff: string, password: string): string =
  let stage1 = sha1(password)
  let stage2 = sha1(stage1)
  let stage3 = sha1(scrambleBuff & stage2)
  result = stage3 xor stage1

proc hash323(s: string): tuple[a: uint32, b: uint32] =
  var nr = 0x50305735'u32
  var add = 7'u32
  var nr2 = 0x12345671'u32
  var tmp: uint32
  for c in s:
    case c
    of '\x09', '\x20':
      continue
    else:
      tmp = 0xFF and ord(c)
      nr = nr xor ((((nr and 63) + add) * tmp) + (nr shl 8))
      nr2 = nr2 + ((nr2 shl 8) xor nr)
      add = add + tmp
  result.a = nr and 0x7FFFFFFF
  result.b = (nr2 and 0x7FFFFFFF)

proc scramble323(seed: string, password: string): string =
  assert password != nil
  if password == "":
    return ""
  var pw = hash323(seed)
  var msg = hash323(password)
  const max = 0x3FFFFFFF'u32
  var seed1 = (pw.a xor msg.a) mod max
  var seed2 = (pw.b xor msg.b) mod max
  var b: uint32
  result = newString(seed.len)
  for i in 0..<seed.len:
    seed1 = ((seed1 * 3) + seed2) mod max
    seed2 = (seed1 + seed2 + 33) mod max
    b = floor((seed1.int / max.int * 31) + 64).uint32
    result[i] = chr(b)
  seed1 = ((seed1 * 3) + seed2) mod max
  seed2 = (seed1 + seed2 + 33) mod max
  b = floor(seed1.int / max.int * 31).uint32
  for i in 0..<seed.len:
    result[i] = chr(ord(result[i]) xor b.int)

proc toPacketHex*(packet: ClientAuthenticationPacket, sequenceId: int,
                  password: string, protocol41: bool): string =
  var payloadLen: int
  if protocol41:
    payloadLen = 4 + 4 + 1 + 23 + packet.user.len + 1 + 1 +
                    20 + packet.database.len + 1
    result = newStringOfCap(4 + payloadLen)
    add(result, toProtocolHex(payloadLen, 3))
    add(result, toProtocolHex(sequenceId, 1))
    add(result, toProtocolHex(packet.capabilities, 4))
    add(result, toProtocolHex(packet.maxPacketSize, 4))
    add(result, toProtocolHex(packet.charset, 1))
    add(result, toProtocolHex(0, 23))
    add(result, packet.user)
    add(result, '\0')
    add(result, toProtocolHex(20, 1))
    add(result, token(packet.scrambleBuff, password))
    add(result, packet.database)
    add(result, '\0')
  else:
    payloadLen = 2 + 3 + packet.user.len + 1 + 
                    8 + 1 + packet.database.len + 1
    result = newStringOfCap(4 + payloadLen)                
    add(result, toProtocolHex(payloadLen, 3))
    add(result, toProtocolHex(sequenceId, 1))

    add(result, toProtocolHex(packet.capabilities, 2))
    add(result, toProtocolHex(packet.maxPacketSize, 3))

    add(result, packet.user)
    add(result, '\0')
    add(result, scramble323(packet.scrambleBuff[0..7], password))
    add(result, toProtocolHex(0, 1))
    add(result, packet.database)
    add(result, '\0')

