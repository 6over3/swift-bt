/// Node dictionaries encode as keyed objects, not unordered key/value arrays.
extension BehaviorNodeID: CodingKeyRepresentable {
  public var codingKey: any CodingKey { NodeCodingKey(stringValue: rawValue) }

  public init?<T: CodingKey>(codingKey: T) {
    self.init(rawValue: codingKey.stringValue)
  }
}

private struct NodeCodingKey: CodingKey {
  let stringValue: String
  var intValue: Int? { nil }

  init(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}
