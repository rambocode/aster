import AppKit
import Testing
@testable import Aster

@Test @MainActor
func doubleClickFileButtonRejectsNonMouseEventsWithoutReadingClickCount() throws {
  let event = try #require(NSEvent.otherEvent(with: .applicationDefined, location: .zero,
    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0))
  #expect(!PointingHandButton.isDoubleClickEvent(event))
  #expect(!PointingHandButton.isDoubleClickEvent(nil))
}

@Test @MainActor
func doubleClickFileButtonRequiresLeftMouseDoubleClick() throws {
  for clicks in [1, 2] {
    let event = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero,
      modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
      eventNumber: 1, clickCount: clicks, pressure: 0))
    #expect(PointingHandButton.isDoubleClickEvent(event) == (clicks == 2))
  }
}
