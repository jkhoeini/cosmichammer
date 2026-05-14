import Foundation
import Cocoa
import LuaSkin

// MARK: - HSRazerTartarusV2Device

@objcMembers
class HSRazerTartarusV2Device: HSRazerDevice {

    override init(device: IOHIDDevice, manager: AnyObject) {
        super.init(device: device, manager: manager)

        // The name of the Razer Device. This should match the actual product name.
        name = "Razer Tartarus V2"

        // The product ID of the Razer Device.
        productID = Int32(USB_PID_RAZER_TARTARUS_V2)

        // Number of backlight rows and columns:
        backlightRows = 4
        backlightColumns = 6

        // The ID of the scroll wheel. If supplied, this will enable the event tap which ignores scroll wheel movements:
        scrollWheelID = 56

        // A dictionary of button names. On the left is what is returned by IOHID, on the right is what we
        // want to label the buttons in Hammerspoon:
        buttonNames = [
            "30": "1",
            "31": "2",
            "32": "3",
            "33": "4",
            "34": "5",
            "43": "6",
            "20": "7",
            "26": "8",
            "8": "9",
            "21": "10",
            "57": "11",
            "4": "12",
            "22": "13",
            "7": "14",
            "9": "15",
            "225": "16",
            "29": "17",
            "27": "18",
            "6": "19",
            "44": "20",
            "56": "Scroll Wheel",
            "226": "Mode",
            "82": "Up",
            "81": "Down",
            "80": "Left",
            "79": "Right",
        ]

        // A dictionary of remapping values. On the left is "dummy" keys. On the right is actual HID Keyboard codes.
        remapping = [
            "0x100000001": "0x70000001E",
            "0x100000002": "0x70000001F",
            "0x100000003": "0x700000020",
            "0x100000004": "0x700000021",
            "0x100000005": "0x700000022",
            "0x100000006": "0x70000002B",
            "0x100000007": "0x700000014",
            "0x100000008": "0x70000001A",
            "0x100000009": "0x700000008",
            "0x100000010": "0x700000015",
            "0x100000011": "0x700000039",
            "0x100000012": "0x700000004",
            "0x100000013": "0x700000016",
            "0x100000014": "0x700000007",
            "0x100000015": "0x700000009",
            "0x100000016": "0x7000000E1",
            "0x100000017": "0x70000001D",
            "0x100000018": "0x70000001B",
            "0x100000019": "0x700000006",
            "0x100000020": "0x70000002C",
            "0x100000021": "0x700000035",
            "0x100000022": "0x700000052",
            "0x100000023": "0x700000051",
            "0x100000024": "0x700000050",
            "0x100000025": "0x70000004F",
        ]
    }

    // MARK: - Helper: extract RGB from NSColor as 0-255 NSNumber values

    private func colorComponents(_ color: NSColor) -> (red: NSNumber, green: NSNumber, blue: NSNumber) {
        let r = NSNumber(value: Int(floor(color.redComponent) * 255))
        let g = NSNumber(value: Int(floor(color.greenComponent) * 255))
        let b = NSNumber(value: Int(floor(color.blueComponent) * 255))
        return (r, g, b)
    }

    // MARK: - LED Backlights

    /*
        Effects Names in Manual:

        - Breathing         Fades in and out of the selected color(s)
        - Fire              Warm colors to mimic flames
        - Reactive          Pressed key lights up and fades off after a duration
        - Ripple            Lighting ripples away from the pressed key
        - Spectrum cycling  Cycles between 16.8 million colors indefinitely
        - Starlight         LEDs randomly fade in and out
        - Static            Remains lit in the selected color
        - Wave              Lighting scrolls in the selected direction
     */

    override func setBacklightToOff() -> HSRazerResult {
        let arguments: NSDictionary = [
            0: 0x01,    // Variable Storage
            1: 0x05,    // LED ID
            2: 0x00,    // Effect ID
            3: 0x00,    // Reserved
            4: 0x00,    // Reserved
            5: 0x00,    // Reserved
            6: 0x00,    // Reserved
        ]
        return sendRazerReport(transactionID: 0x1F, commandClass: 0x0F, commandID: 0x02, arguments: arguments)
    }

    override func setBacklightToStaticColor(_ color: NSColor) -> HSRazerResult {
        let (red, green, blue) = colorComponents(color)
        let arguments: NSDictionary = [
            0: 0x01,    // Variable Storage
            1: 0x05,    // LED ID
            2: 0x01,    // Effect ID
            3: 0x00,    // Reserved
            4: 0x00,    // Reserved
            5: 0x01,    // 0x01
            6: red,     // Red
            7: green,   // Green
            8: blue,    // Blue
        ]
        return sendRazerReport(transactionID: 0x1F, commandClass: 0x0F, commandID: 0x02, arguments: arguments)
    }

    override func setBacklightToWave(speed: NSNumber, direction: String) -> HSRazerResult {
        let directionValue: NSNumber = (direction == "right") ? 2 : 1
        let arguments: NSDictionary = [
            0: 0x01,            // Variable Storage
            1: 0x05,            // LED ID
            2: 0x04,            // Effect ID
            3: directionValue,  // Direction
            4: speed,           // Speed
            5: 0x00,            // Reserved
            6: 0x00,            // Reserved
        ]
        return sendRazerReport(transactionID: 0x1F, commandClass: 0x0F, commandID: 0x02, arguments: arguments)
    }

    override func setBacklightToSpectrum() -> HSRazerResult {
        let arguments: NSDictionary = [
            0: 0x01,    // Variable Storage
            1: 0x05,    // LED ID
            2: 0x03,    // Effect ID
            3: 0x00,    // Reserved
            4: 0x00,    // Reserved
            5: 0x01,    // Reserved
            6: 0x00,    // Reserved
        ]
        return sendRazerReport(transactionID: 0x1F, commandClass: 0x0F, commandID: 0x02, arguments: arguments)
    }

    func setBacklightToFire() -> HSRazerResult {
        let arguments: NSDictionary = [
            0: 0x01,    // Variable Storage
            1: 0x05,    // LED ID
            2: 0x06,    // Effect ID
            3: 0x00,    // Reserved
            4: 0x00,    // Reserved
            5: 0x01,    // Reserved
            6: 0x00,    // Reserved
        ]
        return sendRazerReport(transactionID: 0x1F, commandClass: 0x0F, commandID: 0x02, arguments: arguments)
    }

    override func setBacklightToReactive(color: NSColor, speed: NSNumber) -> HSRazerResult {
        let (red, green, blue) = colorComponents(color)
        let arguments: NSDictionary = [
            0: 0x01,    // Variable Storage
            1: 0x05,    // LED ID
            2: 0x05,    // Effect ID
            3: 0x00,    // Reserved
            4: speed,   // Speed (1-4)
            5: 0x01,    // Reserved
            6: red,     // Red
            7: green,   // Green
            8: blue,    // Blue
        ]
        return sendRazerReport(transactionID: 0x1F, commandClass: 0x0F, commandID: 0x02, arguments: arguments)
    }

    override func setBacklightToStarlight(color: NSColor?, secondaryColor: NSColor?, speed: NSNumber) -> HSRazerResult {
        if let color = color, let secondaryColor = secondaryColor {
            // Two colours:
            let (red, green, blue) = colorComponents(color)
            let (redSecondary, greenSecondary, blueSecondary) = colorComponents(secondaryColor)
            let arguments: NSDictionary = [
                0: 0x01,            // Variable Storage
                1: 0x05,            // LED ID
                2: 0x07,            // Effect ID
                3: 0x00,            // Reserved
                4: speed,           // Speed (1-3)
                5: 0x02,            // Starlight Mode
                6: red,             // Red
                7: green,           // Green
                8: blue,            // Blue
                9: redSecondary,    // Red Secondary
                10: greenSecondary, // Green Secondary
                11: blueSecondary,  // Blue Secondary
            ]
            return sendRazerReport(transactionID: 0x1F, commandClass: 0x0F, commandID: 0x02, arguments: arguments)
        } else if let color = color {
            // One colour:
            let (red, green, blue) = colorComponents(color)
            let arguments: NSDictionary = [
                0: 0x01,    // Variable Storage
                1: 0x05,    // LED ID
                2: 0x07,    // Effect ID
                3: 0x00,    // Reserved
                4: speed,   // Speed (1-3)
                5: 0x01,    // Starlight Mode
                6: red,     // Red
                7: green,   // Green
                8: blue,    // Blue
            ]
            return sendRazerReport(transactionID: 0x1F, commandClass: 0x0F, commandID: 0x02, arguments: arguments)
        } else {
            // Random:
            let arguments: NSDictionary = [
                0: 0x01,    // Variable Storage
                1: 0x05,    // LED ID
                2: 0x07,    // Effect ID
                3: 0x00,    // Reserved
                4: speed,   // Speed (1-3)
                5: 0x00,    // Starlight Mode
            ]
            return sendRazerReport(transactionID: 0x1F, commandClass: 0x0F, commandID: 0x02, arguments: arguments)
        }
    }

    override func setBacklightToBreathing(color: NSColor?, secondaryColor: NSColor?) -> HSRazerResult {
        if let color = color, let secondaryColor = secondaryColor {
            // Two colours:
            let (red, green, blue) = colorComponents(color)
            let (redSecondary, greenSecondary, blueSecondary) = colorComponents(secondaryColor)
            let arguments: NSDictionary = [
                0: 0x01,            // Variable Storage
                1: 0x05,            // LED ID
                2: 0x02,            // Effect ID
                3: 0x02,            // Breath Mode
                4: 0x00,            // Reserved
                5: 0x02,            // Breath Mode
                6: red,             // Red
                7: green,           // Green
                8: blue,            // Blue
                9: redSecondary,    // Red Secondary
                10: greenSecondary, // Green Secondary
                11: blueSecondary,  // Blue Secondary
            ]
            return sendRazerReport(transactionID: 0x1F, commandClass: 0x0F, commandID: 0x02, arguments: arguments)
        } else if let color = color {
            // One colour:
            let (red, green, blue) = colorComponents(color)
            let arguments: NSDictionary = [
                0: 0x01,    // Variable Storage
                1: 0x05,    // LED ID
                2: 0x02,    // Effect ID
                3: 0x01,    // Breath Mode
                4: 0x00,    // Reserved
                5: 0x01,    // Breath Mode
                6: red,     // Red
                7: green,   // Green
                8: blue,    // Blue
            ]
            return sendRazerReport(transactionID: 0x1F, commandClass: 0x0F, commandID: 0x02, arguments: arguments)
        } else {
            // Random:
            let arguments: NSDictionary = [
                0: 0x01,    // Variable Storage
                1: 0x05,    // LED ID
                2: 0x02,    // Effect ID
                3: 0x00,    // Breath Mode
                4: 0x00,    // Reserved
                5: 0x00,    // Breath Mode
            ]
            return sendRazerReport(transactionID: 0x1F, commandClass: 0x0F, commandID: 0x02, arguments: arguments)
        }
    }

    override func setBacklightToCustom(colors: NSMutableDictionary) -> HSRazerResult {
        var customColorsCount = 1
        for row in 0..<Int(backlightRows) {
            let arguments = NSMutableDictionary(capacity: 1)

            arguments[0] = NSNumber(value: 0x00)                        // Reserved
            arguments[1] = NSNumber(value: 0x00)                        // Reserved
            arguments[2] = NSNumber(value: row)                         // Row Index
            arguments[3] = NSNumber(value: 0)                           // Start Column
            arguments[4] = NSNumber(value: Int(backlightColumns) - 1)   // Stop Column

            var count = 5
            for _ in 0..<Int(backlightColumns) {
                let currentColor = colors[NSNumber(value: customColorsCount)] as? NSColor
                customColorsCount += 1

                if let currentColor = currentColor {
                    let (red, green, blue) = colorComponents(currentColor)
                    arguments[NSNumber(value: count)] = red;      count += 1
                    arguments[NSNumber(value: count)] = green;    count += 1
                    arguments[NSNumber(value: count)] = blue;     count += 1
                } else {
                    arguments[NSNumber(value: count)] = NSNumber(value: 0); count += 1
                    arguments[NSNumber(value: count)] = NSNumber(value: 0); count += 1
                    arguments[NSNumber(value: count)] = NSNumber(value: 0); count += 1
                }
            }

            let result = sendRazerReport(transactionID: 0x1F, commandClass: 0x0F, commandID: 0x03, arguments: arguments)
            if !result.success {
                return result
            }
        }

        let modeArguments: NSDictionary = [
            0: 0x00,    // Variable Storage
            1: 0x00,    // LED ID
            2: 0x08,    // Effect ID
            3: 0x00,    // Reserved
            4: 0x00,    // Reserved
            5: 0x00,    // Reserved
            6: 0x00,    // Reserved
            7: 0x00,    // Reserved
            8: 0x00,    // Reserved
            9: 0x00,    // Reserved
            10: 0x00,   // Reserved
            11: 0x00,   // Reserved
        ]
        return sendRazerReport(transactionID: 0x1F, commandClass: 0x0F, commandID: 0x02, arguments: modeArguments)
    }

    // MARK: - LED Brightness

    override func getBrightness() -> HSRazerResult {
        let arguments: NSDictionary = [
            0: 0x00,    // Variable Storage
            1: 0x00,    // LED ID
            2: 0x00,    // Effect ID
        ]

        let result = sendRazerReport(transactionID: 0x1F, commandClass: 0x0F, commandID: 0x84, arguments: arguments)

        // The brightness comes back on argument 2 as 0-255, so we convert it to 0-100 range:
        if result.success {
            let argumentTwo = result.argumentTwo
            result.brightness = NSNumber(value: round(Double(argumentTwo) / 2.55))
        }

        return result
    }

    override func setBrightness(_ brightness: NSNumber) -> HSRazerResult {
        // We get the brightness in a 0-100 range, and we need to convert it to 0-255:
        let converted = NSNumber(value: round(Double(brightness.intValue) * 2.55))

        let arguments: NSDictionary = [
            0: 0x00,        // Variable Storage
            1: 0x00,        // LED ID
            2: converted,   // Brightness Value
        ]

        let result = sendRazerReport(transactionID: 0x1F, commandClass: 0x0F, commandID: 0x04, arguments: arguments)

        // The brightness comes back on argument 2 as 0-255, so we convert it to 0-100 range:
        if result.success {
            let argumentTwo = result.argumentTwo
            result.brightness = NSNumber(value: round(Double(argumentTwo) / 2.55))
        }

        return result
    }

    // MARK: - Status Lights

    override func setOrangeStatusLight(_ active: Bool) -> HSRazerResult {
        let onOrOff: UInt8 = active ? 0x01 : 0x00
        let arguments: NSDictionary = [
            0: 0x00,            // Variable Storage
            1: 0x0C,            // LED ID
            2: NSNumber(value: onOrOff),  // Status Light Value
        ]
        return sendRazerReport(transactionID: 0x1F, commandClass: 0x03, commandID: 0x00, arguments: arguments)
    }

    override func getOrangeStatusLight() -> HSRazerResult {
        let arguments: NSDictionary = [
            0: 0x00,    // Variable Storage
            1: 0x0C,    // LED ID
            2: 0x00,    // Reserved
        ]

        let result = sendRazerReport(transactionID: 0x1F, commandClass: 0x03, commandID: 0x80, arguments: arguments)

        if result.success {
            result.orangeStatusLight = (result.argumentTwo == 1)
        }

        return result
    }

    override func setGreenStatusLight(_ active: Bool) -> HSRazerResult {
        let onOrOff: UInt8 = active ? 0x01 : 0x00
        let arguments: NSDictionary = [
            0: 0x00,            // Variable Storage
            1: 0x0D,            // LED ID
            2: NSNumber(value: onOrOff),  // Status Light Value
        ]
        return sendRazerReport(transactionID: 0x1F, commandClass: 0x03, commandID: 0x00, arguments: arguments)
    }

    override func getGreenStatusLight() -> HSRazerResult {
        let arguments: NSDictionary = [
            0: 0x00,    // Variable Storage
            1: 0x0D,    // LED ID
            2: 0x00,    // Reserved
        ]

        let result = sendRazerReport(transactionID: 0x1F, commandClass: 0x03, commandID: 0x80, arguments: arguments)

        if result.success {
            result.greenStatusLight = (result.argumentTwo == 1)
        }

        return result
    }

    override func setBlueStatusLight(_ active: Bool) -> HSRazerResult {
        let onOrOff: UInt8 = active ? 0x01 : 0x00
        let arguments: NSDictionary = [
            0: 0x00,            // Variable Storage
            1: 0x0E,            // LED ID
            2: NSNumber(value: onOrOff),  // Status Light Value
        ]
        return sendRazerReport(transactionID: 0x1F, commandClass: 0x03, commandID: 0x00, arguments: arguments)
    }

    override func getBlueStatusLight() -> HSRazerResult {
        let arguments: NSDictionary = [
            0: 0x00,    // Variable Storage
            1: 0x0E,    // LED ID
            2: 0x00,    // Reserved
        ]

        let result = sendRazerReport(transactionID: 0x1F, commandClass: 0x03, commandID: 0x80, arguments: arguments)

        if result.success {
            result.blueStatusLight = (result.argumentTwo == 1)
        }

        return result
    }
}
