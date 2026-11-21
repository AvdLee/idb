import AppKit
@testable import FBSimulatorControl
import Foundation
import Testing

@Suite
struct FBSimulatorAccessibilitySerializerCompatibilityTests {
  @Test
  func xcode27PreservesTraitsKeyWithoutReadingUnsupportedAttribute() {
    let element = makeElement()
    element.stubTraits = ["Button"]

    let value = FBSimulatorAccessibilitySerializer.serializedTraits(
      for: element,
      xcodeVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
    )

    #expect(value is NSNull)
    #expect(!element.accessedProperties.contains("accessibilityTraits"))
  }

  @Test
  func xcode26ReadsAndReturnsTraits() {
    let element = makeElement()
    element.stubTraits = ["Button", "Selected"]

    let value = FBSimulatorAccessibilitySerializer.serializedTraits(
      for: element,
      xcodeVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 0)
    )

    #expect(value as? [String] == ["Button", "Selected"])
    #expect(element.accessedProperties.contains("accessibilityTraits"))
  }

  // MARK: - Keyboard descendants

  @Test
  func nestedSerializationStopsAtKeyboardHostWhenRequested() {
    let keys = [makeKey("q"), makeKey("w")]
    let keyboard = makeKeyboardHost(role: "AXKeyboard", identifier: nil, frame: keyboardFrame, children: keys)
    let field = FBAccessibilityTestElementBuilder.button(withLabel: "Email", identifier: "email", frame: NSRect(x: 20, y: 100, width: 300, height: 40))
    let root = FBAccessibilityTestElementBuilder.rootElement(withChildren: [field, keyboard])

    let result = serialize(root, nested: true, skipsKeyboardDescendants: true)

    let children = result[0]["children"] as? [[String: Any]]
    #expect(children?.count == 2)
    #expect(children?[0]["AXLabel"] as? String == "Email")
    #expect(children?[1]["role"] as? String == "AXKeyboard")
    #expect((children?[1]["children"] as? [Any])?.isEmpty == true)
    #expect(!keyboard.accessedProperties.contains("accessibilityChildren"))
    #expect(keys.allSatisfy { !$0.accessedProperties.contains("accessibilityLabel") })
  }

  @Test
  func nestedSerializationKeepsKeyboardKeysByDefault() {
    let keys = [makeKey("q"), makeKey("w")]
    let keyboard = makeKeyboardHost(role: "AXKeyboard", identifier: nil, frame: keyboardFrame, children: keys)
    let root = FBAccessibilityTestElementBuilder.rootElement(withChildren: [keyboard])

    let result = serialize(root, nested: true, skipsKeyboardDescendants: false)

    let keyboardValues = (result[0]["children"] as? [[String: Any]])?.first
    let keyLabels = (keyboardValues?["children"] as? [[String: Any]])?.compactMap { $0["AXLabel"] as? String }
    #expect(keyLabels == ["q", "w"])
  }

  @Test
  func flatSerializationStopsAtKeyboardHostIdentifiedByClassToken() {
    let keys = [makeKey("q"), makeKey("w")]
    let keyboard = makeKeyboardHost(role: "AXGroup", identifier: "UIKeyboardLayoutStar Preview", frame: keyboardFrame, children: keys)
    let root = FBAccessibilityTestElementBuilder.rootElement(withChildren: [keyboard])

    let result = serialize(root, nested: false, skipsKeyboardDescendants: true)

    #expect(result.count == 2)
    #expect(result[1]["AXUniqueId"] as? String == "UIKeyboardLayoutStar Preview")
    #expect(keys.allSatisfy { !$0.accessedProperties.contains("accessibilityLabel") })
  }

  @Test
  func keyboardHostWithEmptyFrameDoesNotStopRecursion() {
    let keys = [makeKey("q")]
    let inner = makeKeyboardHost(role: "AXGroup", identifier: "UIKeyboardLayoutStar Preview", frame: keyboardFrame, children: keys)
    let wrapper = makeKeyboardHost(role: "AXGroup", identifier: "RTIInputSystemHostView", frame: .zero, children: [inner])
    let root = FBAccessibilityTestElementBuilder.rootElement(withChildren: [wrapper])

    let result = serialize(root, nested: true, skipsKeyboardDescendants: true)

    let wrapperValues = (result[0]["children"] as? [[String: Any]])?.first
    let innerValues = (wrapperValues?["children"] as? [[String: Any]])?.first
    #expect(innerValues?["AXUniqueId"] as? String == "UIKeyboardLayoutStar Preview")
    #expect((innerValues?["children"] as? [Any])?.isEmpty == true)
    #expect(keys.allSatisfy { !$0.accessedProperties.contains("accessibilityLabel") })
  }

  @Test
  func ordinaryGroupsKeepTheirChildren() {
    let button = FBAccessibilityTestElementBuilder.button(withLabel: "Continue", identifier: "continue", frame: NSRect(x: 0, y: 0, width: 100, height: 44))
    let group = makeKeyboardHost(role: "AXGroup", identifier: "content", frame: NSRect(x: 0, y: 0, width: 390, height: 600), children: [button])
    let root = FBAccessibilityTestElementBuilder.rootElement(withChildren: [group])

    let result = serialize(root, nested: true, skipsKeyboardDescendants: true)

    let groupValues = (result[0]["children"] as? [[String: Any]])?.first
    #expect((groupValues?["children"] as? [Any])?.count == 1)
  }

  private var keyboardFrame: NSRect { NSRect(x: 0, y: 544, width: 390, height: 300) }

  private func makeKey(_ label: String) -> FBSimulatorControlTests_AXPMacPlatformElement_Double {
    FBAccessibilityTestElementBuilder.button(withLabel: label, identifier: nil, frame: NSRect(x: 0, y: 560, width: 30, height: 40))
  }

  private func makeKeyboardHost(
    role: String,
    identifier: String?,
    frame: NSRect,
    children: [FBSimulatorControlTests_AXPMacPlatformElement_Double]
  ) -> FBSimulatorControlTests_AXPMacPlatformElement_Double {
    FBSimulatorControlTests_AXPMacPlatformElement_Double(
      label: nil,
      identifier: identifier,
      role: role,
      frame: frame,
      enabled: true,
      actionNames: nil,
      children: children
    )
  }

  private func serialize(
    _ root: FBSimulatorControlTests_AXPMacPlatformElement_Double,
    nested: Bool,
    skipsKeyboardDescendants: Bool
  ) -> [[String: Any]] {
    FBSimulatorAccessibilitySerializer.recursiveDescription(
      fromElement: root,
      token: "test-token",
      nestedFormat: nested,
      keys: [.label, .frame, .uniqueID, .role, .type],
      collector: nil,
      coverageGrid: nil,
      seenPids: nil,
      skipsKeyboardDescendants: skipsKeyboardDescendants
    )
  }

  private func makeElement() -> FBSimulatorControlTests_AXPMacPlatformElement_Double {
    FBAccessibilityTestElementBuilder.button(
      withLabel: "Continue",
      identifier: "continue",
      frame: NSRect(x: 20, y: 20, width: 100, height: 44)
    )
  }
}
