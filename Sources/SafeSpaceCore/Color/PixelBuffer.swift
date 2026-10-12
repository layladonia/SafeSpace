// represent an image as raw pixel data using uses RGBA8 (red, green, blue, alpha (opacity))

public struct PixelBuffer {
    public let width: Int
    public let height: Int
    public var bytes: [UInt8]

    public init(width: Int, height: Int, bytes: [UInt8]) {
        self.width = width
        self.height = height
        self.bytes = bytes
    }
}
