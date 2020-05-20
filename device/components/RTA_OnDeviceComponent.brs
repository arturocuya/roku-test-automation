sub init()
	m.task = createNode("RTA_OnDeviceComponentTask")
	m.task.observeFieldScoped("renderThreadRequest", "onRenderThreadRequestChange")
	m.task.control = "RUN"

	m.activeObserveFieldRequests = {}
end sub

sub onRenderThreadRequestChange(event as Object)
	request = event.getData()
	requestType = request.type
	args = request.args
	if requestType = "handshake" then
		setLogLevel(getStringAtKeyPath(args, "logLevel"))
	else
		logVerbose("Received request: ", formatJson(request))
		response = Invalid
		if requestType = "getValueAtKeyPath" then
			response = processGetValueAtKeyPathRequest(args)
		else if requestType = "getValuesAtKeyPaths" then
			response = processGetValuesAtKeyPathsRequest(args)
		else if requestType = "observeField" then
			response = processObserveFieldRequest(request)
		else if requestType = "setValueAtKeyPath" then
			response = processSetValueAtKeyPathRequest(args)
		end if

		if response <> Invalid then
			sendBackResponse(request, response)
		end if
	end if
end sub

function processGetValueAtKeyPathRequest(args as Object) as Object
	baseType = args.base
	if NOT isString(baseType) then
		return buildErrorResponseObject("Had invalid base")
	end if

	base = getBaseObject(args)
	if base = Invalid then
		return buildErrorResponseObject("Could not handle base type of '" + baseType + "'")
	end if

	keyPath = args.keyPath
	if NOT isString(keyPath) then
		return buildErrorResponseObject("Had invalid keyPath")
	end if

	if keyPath <> "" then
		value = getValueAtKeyPath(base, keyPath, "[[VALUE_NOT_FOUND]]")
		found = NOT isString(value) OR value <> "[[VALUE_NOT_FOUND]]"
	else
		value = base
		found = true
	end if

	return {
		"found": found
		"value": value
	}
end function

function processGetValuesAtKeyPathsRequest(args as Object) as Object
	requests = args.requests
	if NOT isNonEmptyAA(requests) then
		return buildErrorResponseObject("getValuesAtKeyPaths did not have have any requests")
	end if
	response = {}
	for each key in requests
		result = processGetValueAtKeyPathRequest(requests[key])
		if result.value = Invalid then
			return buildErrorResponseObject(result.error.message)
		end if
		response[key] = result.value
	end for
	return response
end function

function processObserveFieldRequest(request as Object) as Dynamic
	args = request.args
	keyPath = args.keyPath
	result = processGetValueAtKeyPathRequest(args)
	node = result.value
	if NOT isNode(node) then
		return buildErrorResponseObject("Node not found at key path'" + keyPath + "'")
	end if

	field = args.field
	if node.observeFieldScoped(field, "observeFieldCallback") then
		logVerbose("Now observing '" + field + "' at key path '" + keyPath + "'")
	else
		return buildErrorResponseObject("Could not observe field '" + field + "' at key path '" + keyPath + "'")
	end if

	request.node = node
	m.activeObserveFieldRequests[request.id] = request
	return Invalid
end function

sub observeFieldCallback(event as Object)
	node = event.getRoSgNode()
	field = event.getField()
	data = event.getData()
	logVerbose("Received callback for node field '" + field + "' with value ", data)
	for each requestId in m.activeObserveFieldRequests
		request = m.activeObserveFieldRequests[requestId]
		args = request.args
		if node.isSameNode(request.node) AND args.field = field then
			match = args.match
			if isAA(match) then
				result = processGetValueAtKeyPathRequest(match)
				if result.found <> true then
					logVerbose("Unobserved '" + field + "' at key path '" + args.keyPath + "'")
					node.unobserveFieldScoped(field)
					m.activeObserveFieldRequests.delete(requestId)
					sendBackResponse(request, buildErrorResponseObject("Match was requested and key path was not valid"))
					return
				end if

				if result.value <> match.value then
					logVerbose("Match.value did not match requested value continuing to wait")
					return
				end if
			end if
			logVerbose("Unobserved '" + field + "' at key path '" + args.keyPath + "'")
			node.unobserveFieldScoped(field)
			m.activeObserveFieldRequests.delete(requestId)
			sendBackResponse(request, {
				"value": data
			})
			return
		end if
	end for
	logError("Received callback for unknown node or field ", node)
end sub

function processSetValueAtKeyPathRequest(args as Object) as Object
	keyPath = args.keyPath
	result = processGetValueAtKeyPathRequest(args)

	if result.found <> true then
		return buildErrorResponseObject("No value found at key path '" + keyPath + "'")
	end if

	resultValue = result.value
	if NOT isKeyedValueType(resultValue) AND NOT isArray(resultValue) then
		return buildErrorResponseObject("keyPath '" + keyPath + "' can not have a value assigned to it")
	end if

	field = args.field
	if NOT isString(field) then
		return buildErrorResponseObject("Missing valid 'field' param")
	end if

	' Have to walk up the tree until we get to a node as anything that is a field on a node must be replaced
	base = getBaseObject(args)
	nodeParent = resultValue
	parentKeyPath = keyPath
	parentKeyPathParts = parentKeyPath.tokenize(".").toArray()
	setKeyPathParts = []
	while NOT parentKeyPathParts.isEmpty()
		nodeParent = getValueAtKeyPath(base, parentKeyPathParts.join("."))
		if isNode(nodeParent) then
			exit while
		else
			setKeyPathParts.unshift(parentKeyPathParts.pop())
		end if
	end while

	if NOT isNode(nodeParent) then
		nodeParent = base
	end if

	if setKeyPathParts.isEmpty() then
		updateAA = createCaseSensitiveAA(field, args.value)
	else
		setKeyPathParts.push(field)
		nodeFieldKey = setKeyPathParts.shift()
		nodeFieldValueCopy = nodeParent[nodeFieldKey]
		setValueAtKeyPath(nodeFieldValueCopy, setKeyPathParts.join("."), args.value)
		updateAA = createCaseSensitiveAA(nodeFieldKey, nodeFieldValueCopy)
	end if
	nodeParent.update(updateAA, true)
	return {}
end function

function getBaseObject(args as Object) as Dynamic
	baseType = args.base
	if baseType = "global" then return m.global
	if baseType = "scene" then return m.top.getScene()
	return Invalid
end function

sub sendBackResponse(request as Object, response as Object)
	response = recursivelyConvertValueToJsonCompatible(response)
	if NOT isBoolean(response.success) then response.success = true
	response.id = request.id
	m.task.renderThreadResponse = response
end sub

function recursivelyConvertValueToJsonCompatible(value as Object) as Object
	if isArray(value) then
		for i = 0 to getLastIndex(value)
			value[i] = recursivelyConvertValueToJsonCompatible(value[i])
		end for
	else if isAA(value) then
		for each key in value
			value[key] = recursivelyConvertValueToJsonCompatible(value[key])
		end for
	else if isNode(value) then
		subtype = value.subtype()
		value = value.getFields()
		value.subtype = subtype
		value.delete("focusedChild")
		value = recursivelyConvertValueToJsonCompatible(value)
	end if
	return value
end function