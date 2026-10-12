import Darwin
import Testing

@main
struct NativeNarrationSpeechTests {
    static func main() async {
        let result: CInt = await Testing.__swiftPMEntryPoint()
        exit(result)
    }
}
