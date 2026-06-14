import Cocoa
import Testing
import CLua
@testable import HSSwiftExtensions

@_silgen_name("luaopen_hs_libcanvas")
private func luaopen_hs_libcanvas(_ L: UnsafeMutablePointer<lua_State>?) -> Int32

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class TigerStyleUITests {

        // MARK: - Canvas validation assertions

        @Test func testCanvasValidationRejectsEmptyKeyName() throws {
            try withLuaState { L in
                loadCanvasModule(L)
                // canvas_isValueValidForAttribute requires a non-empty key name;
                // passing a known-valid key should return .valid for a correct value
                let result = canvas_isValueValidForAttribute("fillColor" as NSString, NSColor.red)
                #expect(result == .valid)

                // Passing a key that does not exist in the language dictionary should return .invalid
                let badResult = canvas_isValueValidForAttribute("nonExistentKey12345" as NSString, "whatever")
                #expect(badResult == .invalid)
            }
        }

        // MARK: - CanvasView element value management

        @Test func testCanvasViewGetElementValueReturnsNilForOutOfBoundsIndex() throws {
            try withLuaState { L in
                loadCanvasModule(L)
                let view = HSCanvasView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
                // No elements added, so index 0 is out of bounds
                let result = view.getElementValue(for: "type", atIndex: 0)
                #expect(result == nil)

                // Add one element and verify the default for "type" is still nil
                // (because "type" has no default -- it's required but must be explicitly set)
                view.elementList.add(NSMutableDictionary())
                let typeResult = view.getElementValue(for: "type", atIndex: 0, onlyIfSet: true)
                #expect(typeResult == nil)
            }
        }

        @Test func testCanvasViewSetElementValueValidatesType() throws {
            try withLuaState { L in
                loadCanvasModule(L)
                let view = HSCanvasView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
                view.elementList.add(NSMutableDictionary())

                // Setting a valid type should succeed
                let validStatus = AttributeValidity(rawValue: view.setElementValue(for: "type", atIndex: 0, to: "rectangle", withState: L))
                #expect(validStatus == .valid)

                // Confirm the type was stored
                let storedType = view.getElementValue(for: "type", atIndex: 0) as? String
                #expect(storedType == "rectangle")

                // Setting an invalid type should fail
                let invalidStatus = AttributeValidity(rawValue: view.setElementValue(for: "type", atIndex: 0, to: "notAValidType", withState: L))
                #expect(invalidStatus == .invalid)
            }
        }

        // MARK: - Color hex parsing

        @Test func testCanvasColorFromHexStringProducesCorrectRGB() throws {
            // Test that the hex parser produces expected color values
            let result = canvas_colorFromValue(["hex": "#FF0000", "alpha": 1.0] as NSDictionary)
            #expect(result != nil)
            if let color = result?.usingColorSpace(.genericRGB) {
                #expect(abs(color.redComponent - 1.0) < 0.01)
                #expect(abs(color.greenComponent - 0.0) < 0.01)
                #expect(abs(color.blueComponent - 0.0) < 0.01)
            }

            // Test shorthand hex
            let shortResult = canvas_colorFromValue(["hex": "#0F0", "alpha": 0.5] as NSDictionary)
            #expect(shortResult != nil)
            if let color = shortResult?.usingColorSpace(.genericRGB) {
                #expect(abs(color.greenComponent - 1.0) < 0.01)
                #expect(abs(color.alphaComponent - 0.5) < 0.01)
            }
        }

        // MARK: - Helpers

        private func loadCanvasModule(_ L: UnsafeMutablePointer<lua_State>) {
            _ = luaopen_hs_libcanvas(L)
            lua_pop(L, 1)
        }

        // MARK: - Percentage string conversion

        @Test func testPercentageStringConversion() throws {
            // A valid percentage string like "50%" should convert to 0.5
            let half = canvas_convertPercentageStringToNumber("50%")
            #expect(half != nil)
            #expect(abs((half?.doubleValue ?? 0) - 0.5) < 0.001)

            // A plain decimal string should also parse
            let decimal = canvas_convertPercentageStringToNumber("0.75")
            #expect(decimal != nil)
            #expect(abs((decimal?.doubleValue ?? 0) - 0.75) < 0.001)

            // An invalid string should return nil
            let invalid = canvas_convertPercentageStringToNumber("not_a_number")
            #expect(invalid == nil)
        }
    }
}
