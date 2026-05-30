import Cocoa
import Testing
import CLua
@testable import HSSwiftExtensions

extension CosmicHammerTests {

    @Suite(.serialized) @MainActor final class CanvasValueConversionTests {

        @Test func testCanvasViewMassagesColorTablesWithoutLuaSkinTypeMutation() throws {
            try withLuaState { L in
                ensureCanvasLanguageDictionary(L)
                let view = HSCanvasView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
                view.elementList.add(NSMutableDictionary())

                let colorTable: NSDictionary = ["red": 0.25, "green": 0.5, "blue": 0.75, "alpha": 0.8]
                let status = AttributeValidity(rawValue: view.setElementValue(for: "fillColor", atIndex: 0, to: colorTable, withState: L))

                #expect(status == .valid)
                let color = try #require(view.getElementValue(for: "fillColor", atIndex: 0) as? NSColor)
                let rgb = try #require(color.usingColorSpace(.genericRGB))
                #expect(abs(rgb.redComponent - 0.25) < 0.001)
                #expect(abs(rgb.greenComponent - 0.5) < 0.001)
                #expect(abs(rgb.blueComponent - 0.75) < 0.001)
                #expect(abs(rgb.alphaComponent - 0.8) < 0.001)
                #expect(colorTable["__luaSkinType"] == nil)
            }
        }

        @Test func testCanvasViewMassagesGradientTransformAndShadowTables() throws {
            try withLuaState { L in
                ensureCanvasLanguageDictionary(L)
                let view = HSCanvasView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
                view.elementList.add(NSMutableDictionary())

                let gradient: NSMutableArray = [
                    ["red": 1.0, "green": 0.0, "blue": 0.0],
                    ["red": 0.0, "green": 0.0, "blue": 1.0],
                ]
                #expect(AttributeValidity(rawValue: view.setElementValue(for: "fillGradientColors", atIndex: 0, to: gradient, withState: L)) == .valid)
                let colors = try #require(view.getElementValue(for: "fillGradientColors", atIndex: 0) as? NSArray)
                #expect(colors.count == 2)
                #expect(colors[0] is NSColor)
                #expect(colors[1] is NSColor)

                let matrix: NSDictionary = ["m11": 1.0, "m12": 0.0, "m21": 0.0, "m22": 1.0, "tX": 12.0, "tY": 34.0]
                #expect(AttributeValidity(rawValue: view.setElementValue(for: "transformation", atIndex: 0, to: matrix, withState: L)) == .valid)
                let transform = try #require(view.getElementValue(for: "transformation", atIndex: 0) as? NSAffineTransform)
                #expect(transform.transformStruct.tX == 12.0)
                #expect(transform.transformStruct.tY == 34.0)

                let shadowTable: NSDictionary = [
                    "offset": ["w": 2.0, "h": -3.0],
                    "blurRadius": 4.0,
                    "color": ["white": 0.2, "alpha": 0.6],
                ]
                #expect(AttributeValidity(rawValue: view.setElementValue(for: "shadow", atIndex: 0, to: shadowTable, withState: L)) == .valid)
                let shadow = try #require(view.getElementValue(for: "shadow", atIndex: 0) as? NSShadow)
                #expect(shadow.shadowOffset.width == 2.0)
                #expect(shadow.shadowOffset.height == -3.0)
                #expect(shadow.shadowBlurRadius == 4.0)
                #expect(shadow.shadowColor != nil)
            }
        }

        @Test func testCanvasLuaValueConversionHandlesTypedUserdata() throws {
            try withLuaState { L in
                ensureCanvasLanguageDictionary(L)
                registerObjectMetatable(L, tag: "hs.image")
                registerObjectMetatable(L, tag: "hs.styledtext")

                let image = NSImage(size: NSSize(width: 16, height: 16))
                pushObjectUserdata(L, image, tag: "hs.image")
                #expect(canvas_valueFromLua(L, at: -1, forKey: "image") as? NSImage === image)
                lua_pop(L, 1)

                let string = NSAttributedString(string: "canvas")
                pushObjectUserdata(L, string, tag: "hs.styledtext")
                let converted = try #require(canvas_valueFromLua(L, at: -1, forKey: "text") as? NSAttributedString)
                #expect(converted.string == "canvas")
                lua_pop(L, 1)
            }
        }

        @Test func testCanvasLuaValueConversionLeavesPlainTextPlain() {
            withLuaState { L in
                lua_pushstring(L, "plain")
                #expect(canvas_valueFromLua(L, at: -1, forKey: "text") as? String == "plain")
                lua_pop(L, 1)
            }
        }

        @Test func testCanvasPushValuePreservesTypedValues() {
            withLuaState { L in
                registerObjectMetatable(L, tag: "hs.image")
                registerObjectMetatable(L, tag: "hs.styledtext")

                canvas_pushValue(L, NSColor(calibratedRed: 0.1, green: 0.2, blue: 0.3, alpha: 0.4))
                #expect(lua_type(L, -1) == LUA_TTABLE)
                #expect(lua_getfield(L, -1, "__luaSkinType") == LUA_TSTRING)
                #expect(String(cString: lua_tostring(L, -1)) == "NSColor")
                lua_pop(L, 2)

                let transform = NSAffineTransform()
                transform.translateX(by: 5, yBy: 7)
                canvas_pushValue(L, transform)
                #expect(lua_type(L, -1) == LUA_TTABLE)
                #expect(lua_getfield(L, -1, "tX") == LUA_TNUMBER)
                #expect(lua_tonumber(L, -1) == 5.0)
                lua_pop(L, 2)

                let image = NSImage(size: NSSize(width: 10, height: 10))
                canvas_pushValue(L, image)
                #expect(toNSImage(L, at: -1) === image)
                lua_pop(L, 1)

                let attr = NSAttributedString(string: "styled")
                canvas_pushValue(L, attr)
                #expect(toNSAttributedString(L, at: -1)?.string == "styled")
                lua_pop(L, 1)
            }
        }

        private func ensureCanvasLanguageDictionary(_ L: UnsafeMutablePointer<lua_State>) {
            _ = luaopen_hs_libcanvas(L)
            lua_pop(L, 1)
        }

        private func registerObjectMetatable(_ L: UnsafeMutablePointer<lua_State>, tag: String) {
            luaL_newmetatable(L, tag)
            lua_pop(L, 1)
        }

        private func pushObjectUserdata(_ L: UnsafeMutablePointer<lua_State>, _ object: AnyObject, tag: String) {
            let ptr = lua_newuserdata(L, MemoryLayout<UnsafeRawPointer>.size)!
            ptr.storeBytes(of: Unmanaged.passUnretained(object).toOpaque(), as: UnsafeRawPointer.self)
            luaL_getmetatable(L, tag)
            lua_setmetatable(L, -2)
        }
    }
}
