import CcJSON

// MARK: - JSONValue (RAII wrapper)

/// Wraps a cJSON pointer with automatic memory management.
/// Owned values free their cJSON tree on deinit; borrowed values do not.
/// Borrowed values hold a strong reference to their root, preventing use-after-free.
final class JSONValue: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<cJSON>
    private var owned: Bool
    private let root: JSONValue?

    private init(_ pointer: UnsafeMutablePointer<cJSON>, owned: Bool, root: JSONValue? = nil) {
        self.pointer = pointer
        self.owned = owned
        self.root = root
    }

    /// Takes ownership — the cJSON tree will be freed when this value is deallocated.
    static func owned(_ pointer: UnsafeMutablePointer<cJSON>) -> JSONValue {
        JSONValue(pointer, owned: true)
    }

    /// Borrows a reference — the root's cJSON tree is kept alive via ARC for the lifetime of this value.
    static func borrowing(_ pointer: UnsafeMutablePointer<cJSON>, root: JSONValue) -> JSONValue {
        JSONValue(pointer, owned: false, root: root.root ?? root)
    }

    /// Gives up ownership so the cJSON tree won't be freed by this wrapper.
    /// Used when the underlying pointer has been attached to a parent cJSON node.
    func relinquishOwnership() {
        owned = false
    }

    deinit {
        if owned { cJSON_Delete(pointer) }
    }
}

// MARK: - Parsing

func jsonParse(_ string: String) -> JSONValue? {
    guard let ptr = string.withCString({ cJSON_Parse($0) }) else { return nil }
    return .owned(ptr)
}

func jsonGet(_ object: JSONValue?, key: String) -> JSONValue? {
    guard let obj = object else { return nil }
    guard let ptr = key.withCString({ cJSON_GetObjectItemCaseSensitive(obj.pointer, $0) }) else { return nil }
    return .borrowing(ptr, root: obj)
}

func jsonGetString(_ item: JSONValue?) -> String? {
    guard let item = item, cJSON_IsString(item.pointer) != 0, let vs = item.pointer.pointee.valuestring else {
        return nil
    }
    return String(cString: vs)
}

func jsonGetDouble(_ item: JSONValue?) -> Double? {
    guard let item = item, cJSON_IsNumber(item.pointer) != 0 else { return nil }
    return item.pointer.pointee.valuedouble
}

func jsonGetInt(_ item: JSONValue?) -> Int? {
    guard let d = jsonGetDouble(item) else { return nil }
    return Int(d)
}

func jsonGetBool(_ item: JSONValue?) -> Bool? {
    guard let item = item else { return nil }
    if cJSON_IsTrue(item.pointer) != 0 { return true }
    if cJSON_IsFalse(item.pointer) != 0 { return false }
    return nil
}

func jsonIsNull(_ item: JSONValue?) -> Bool {
    guard let item = item else { return true }
    return cJSON_IsNull(item.pointer) != 0
}

/// Walk a cJSON array, returning each element as a borrowed JSONValue.
func jsonGetArrayElements(_ item: JSONValue?) -> [JSONValue] {
    guard let item = item, cJSON_IsArray(item.pointer) != 0 else { return [] }
    var result: [JSONValue] = []
    var child = item.pointer.pointee.child
    while let c = child {
        result.append(.borrowing(c, root: item))
        child = c.pointee.next
    }
    return result
}

// MARK: - Building

func jsonCreateObject() -> JSONValue? {
    guard let ptr = cJSON_CreateObject() else { return nil }
    return .owned(ptr)
}

func jsonCreateArray() -> JSONValue? {
    guard let ptr = cJSON_CreateArray() else { return nil }
    return .owned(ptr)
}

func jsonCreateString(_ value: String) -> JSONValue? {
    guard let ptr = value.withCString({ cJSON_CreateString($0) }) else { return nil }
    return .owned(ptr)
}

func jsonCreateNumber(_ value: Double) -> JSONValue? {
    guard let ptr = cJSON_CreateNumber(value) else { return nil }
    return .owned(ptr)
}

func jsonCreateBool(_ value: Bool) -> JSONValue? {
    guard let ptr = cJSON_CreateBool(value ? 1 : 0) else { return nil }
    return .owned(ptr)
}

func jsonCreateNull() -> JSONValue? {
    guard let ptr = cJSON_CreateNull() else { return nil }
    return .owned(ptr)
}

/// Parses a raw JSON string and wraps it as a cJSON_Raw node, preserving it verbatim.
func jsonCreateRaw(_ rawJSON: String) -> JSONValue? {
    guard let ptr = rawJSON.withCString({ cJSON_CreateRaw($0) }) else { return nil }
    return .owned(ptr)
}

/// Adds `item` as a child of `object` under `key`.
/// Ownership of `item` transfers to `object`'s cJSON tree — the item will be freed when the root is freed.
func jsonAddItemToObject(_ object: JSONValue?, key: String, item: JSONValue?) {
    guard let object = object, let item = item else { return }
    _ = key.withCString { cJSON_AddItemToObject(object.pointer, $0, item.pointer) }
    item.relinquishOwnership()
}

/// Adds `item` as a child of `array`.
/// Ownership of `item` transfers to `array`'s cJSON tree.
func jsonAddItemToArray(_ array: JSONValue?, item: JSONValue?) {
    guard let array = array, let item = item else { return }
    cJSON_AddItemToArray(array.pointer, item.pointer)
    item.relinquishOwnership()
}

// MARK: - Serialization

func jsonPrintUnformatted(_ item: JSONValue?) -> String? {
    guard let item = item else { return nil }
    guard let cStr = cJSON_PrintUnformatted(item.pointer) else { return nil }
    let result = String(cString: cStr)
    cJSON_free(cStr)
    return result
}
