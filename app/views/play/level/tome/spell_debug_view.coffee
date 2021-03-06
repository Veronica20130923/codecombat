View = require 'views/kinds/CocoView'
template = require 'templates/play/level/tome/spell_debug'
Range = ace.require("ace/range").Range
TokenIterator = ace.require("ace/token_iterator").TokenIterator
serializedClasses =
  Thang: require "lib/world/thang"
  Vector: require "lib/world/vector"
  Rectangle: require "lib/world/rectangle"

module.exports = class DebugView extends View
  className: 'spell-debug-view'
  template: template

  subscriptions:
    'god:new-world-created': 'onNewWorld'
    'god:debug-value-return': 'handleDebugValue'
    'tome:spell-shown': 'changeCurrentThangAndSpell'
    'tome:cast-spells': 'onTomeCast'
    'surface:frame-changed': 'onFrameChanged'

  events: {}

  constructor: (options) ->
    super options
    @ace = options.ace
    @thang = options.thang
    @spell = options.spell
    @variableStates = {}
    @globals = {Math: Math, _: _, String: String, Number: Number, Array: Array, Object: Object}  # ... add more as documented
    for className, serializedClass of serializedClasses
      @globals[className] = serializedClass

    @onMouseMove = _.throttle @onMouseMove, 25
    @cache = {}
    @lastFrameRequested = -1
    @workerIsSimulating = false
    
  setTooltipKeyAndValue: (key, value) =>
    @$el.find("code").text "#{key}: #{value}"
    @$el.show().css(@pos)
    
  setTooltipText: (text) =>
    #perhaps changing styling here in the future
    @$el.find("code").text text
    @$el.show().css(@pos)
    
  onTomeCast: ->
    @invalidateCache()
    
  invalidateCache: -> @cache = {}
  
  retrieveValueFromCache: (thangID,spellID,variableChain,frame) ->
    joinedVariableChain = variableChain.join()
    value = @cache[frame]?[thangID]?[spellID]?[joinedVariableChain]
    return value ? undefined
  
  updateCache: (thangID, spellID, variableChain, frame, value) ->
    currentObject = @cache
    keys = [frame,thangID,spellID,variableChain.join()]
    for keyIndex in [0...(keys.length - 1)]
      key = keys[keyIndex]
      unless key of currentObject
        currentObject[key] = {}
      currentObject = currentObject[key]
    currentObject[keys[keys.length - 1]] = value
  
      
  changeCurrentThangAndSpell: (thangAndSpellObject) ->
    @thang = thangAndSpellObject.thang
    @spell = thangAndSpellObject.spell

  handleDebugValue: (returnObject) ->
    @workerIsSimulating = false
    {key, value} = returnObject
    @updateCache(@thang.id,@spell.name,key.split("."),@lastFrameRequested,value)
    if @variableChain and not key is @variableChain.join(".") then return
    @setTooltipKeyAndValue(key,value)


  afterRender: ->
    super()
    @ace.on "mousemove", @onMouseMove

  setVariableStates: (@variableStates) ->
    @update()

  isIdentifier: (t) ->
    t and (t.type is 'identifier' or t.value is 'this' or @globals[t.value])

  onMouseMove: (e) =>
    return if @destroyed
    pos = e.getDocumentPosition()
    it = new TokenIterator e.editor.session, pos.row, pos.column
    endOfLine = it.getCurrentToken()?.index is it.$rowTokens.length - 1
    while it.getCurrentTokenRow() is pos.row and not @isIdentifier(token = it.getCurrentToken())
      break if endOfLine or not token  # Don't iterate beyond end or beginning of line
      it.stepBackward()
    if @isIdentifier token
      # This could be a property access, like "enemy.target.pos" or "this.spawnedRectangles".
      # We have to realize this and dig into the nesting of the objects.
      start = it.getCurrentTokenColumn()
      [chain, start, end] = [[token.value], start, start + token.value.length]
      while it.getCurrentTokenRow() is pos.row
        it.stepBackward()
        break unless it.getCurrentToken()?.value is "."
        it.stepBackward()
        token = null  # If we're doing a complex access like this.getEnemies().length, then length isn't a valid var.
        break unless @isIdentifier(prev = it.getCurrentToken())
        token = prev
        start = it.getCurrentTokenColumn()
        chain.unshift token.value
    #Highlight all tokens, so true overrides all other conditions TODO: Refactor this later
    if token and (true or token.value of @variableStates or token.value is "this" or @globals[token.value])
      @variableChain = chain
      offsetX = e.domEvent.offsetX ? e.clientX - $(e.domEvent.target).offset().left
      offsetY = e.domEvent.offsetY ? e.clientY - $(e.domEvent.target).offset().top
      w = $(document).width()
      offsetX = w - $(e.domEvent.target).offset().left - 300 if e.clientX + 300 > w
      @pos = {left: offsetX + 50, top: offsetY + 20}
      @markerRange = new Range pos.row, start, pos.row, end
    else
      @variableChain = @markerRange = null
    @update()

  onMouseOut: (e) ->
    @variableChain = @markerRange = null
    @update()

  onNewWorld: (e) ->
    @thang = @options.thang = e.world.thangMap[@thang.id] if @thang
    
  onFrameChanged: (data) ->
    @currentFrame = data.frame
    
  update: ->
    if @variableChain
      if @workerIsSimulating
        @setTooltipText("World is simulating, please wait...")
      else if @currentFrame is @lastFrameRequested and (cacheValue = @retrieveValueFromCache(@thang.id, @spell.name, @variableChain, @currentFrame))
        @setTooltipKeyAndValue(@variableChain.join("."),cacheValue)
      else
        Backbone.Mediator.publish 'tome:spell-debug-value-request',
          thangID: @thang.id
          spellID: @spell.name
          variableChain: @variableChain
          frame: @currentFrame
        if @currentFrame isnt @lastFrameRequested then @workerIsSimulating = true
        @lastFrameRequested = @currentFrame
        @setTooltipText("Finding value...")
    else
      @$el.hide()
    if @variableChain?.length is 2
      clearTimeout @hoveredPropertyTimeout if @hoveredPropertyTimeout
      @hoveredPropertyTimeout = _.delay @notifyPropertyHovered, 500
    else
      @notifyPropertyHovered()
    @updateMarker()

  notifyPropertyHovered: =>
    clearTimeout @hoveredPropertyTimeout if @hoveredPropertyTimeout
    @hoveredPropertyTimeout = null
    oldHoveredProperty = @hoveredProperty
    @hoveredProperty = if @variableChain?.length is 2 then owner: @variableChain[0], property: @variableChain[1] else {}
    unless _.isEqual oldHoveredProperty, @hoveredProperty
      Backbone.Mediator.publish 'tome:spell-debug-property-hovered', @hoveredProperty
  updateMarker: ->
    if @marker
      @ace.getSession().removeMarker @marker
      @marker = null
    if @markerRange
      @marker = @ace.getSession().addMarker @markerRange, "ace_bracket", "text"


  destroy: ->
    @ace?.removeEventListener "mousemove", @onMouseMove
    super()
