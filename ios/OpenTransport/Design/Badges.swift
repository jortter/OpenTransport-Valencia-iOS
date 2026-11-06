import SwiftUI
import UIKit
import OpenTransportCore

/// Images shipped in the Android assets folder (logos, Metro line badges).
enum BundledAsset {
    private static var cache: [String: UIImage] = [:]

    @MainActor
    static func image(_ path: String) -> UIImage? {
        if let cached = cache[path] { return cached }
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("assets").appendingPathComponent(path),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache[path] = image
        return image
    }
}

/// The official EMT line badges from the geoportal icon generator (the same
/// images the Android app and EMT's web use), cached in memory.
@MainActor
final class EmtBadgeImages {
    static let shared = EmtBadgeImages()

    private var cache: [String: UIImage] = [:]
    private var failed: Set<String> = []
    private var loading: [String: Task<UIImage?, Never>] = [:]

    func cached(_ line: String) -> UIImage? { cache[line] }

    func load(_ line: String) async -> UIImage? {
        if let image = cache[line] { return image }
        if failed.contains(line) { return nil }
        if let task = loading[line] { return await task.value }
        let task = Task<UIImage?, Never> {
            var components = URLComponents(string: "https://geoportal.emtvalencia.es/ciudadano/icongenerator/create-line-image.php")!
            components.queryItems = [
                URLQueryItem(name: "size", value: "50"),
                URLQueryItem(name: "type", value: "normal"),
                URLQueryItem(name: "lineNumber", value: line),
                URLQueryItem(name: "showBorder", value: "false"),
                URLQueryItem(name: "borderColor", value: "white"),
            ]
            guard let url = components.url,
                  let result = try? await URLSession.shared.data(from: url),
                  (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return UIImage(data: result.0, scale: 2)
        }
        loading[line] = task
        let image = await task.value
        loading[line] = nil
        if let image { cache[line] = image } else { failed.insert(line) }
        return image
    }
}

/// Port of `LineBadge` / `SmallLineBadge`: Rodalies (C1…) and Metrobús (MB…)
/// are text pills, Metro uses the bundled PNGs and EMT the official images.
struct LineBadge: View {
    let line: String
    var height: CGFloat = 24

    @State private var image: UIImage?

    var body: some View {
        Group {
            if isNumbered(prefix: "C") {
                let hex = RodaliesData.lineColors[line] ?? RodaliesData.networkColor
                pill(line, color: Color(hex: hex), text: LineColors.textColor(on: hex))
            } else if line.hasPrefix("MB") {
                // Each line in its official colour once loaded, the network's blue until then.
                let hex = LineColors.shared.metrobus[line]
                pill(String(line.dropFirst(2)), color: hex.map { Color(hex: $0) } ?? networkColor(.metrobus),
                     text: hex.map(LineColors.textColor) ?? .white)
            } else if isNumbered(prefix: "M"), let metro = BundledAsset.image("metrovalencia/\(line.dropFirst()).png") {
                bitmap(metro)
            } else if let image {
                bitmap(image)
            } else {
                pill(line, color: stableLineColor(line))
            }
        }
        .accessibilityLabel(line)
        .task(id: line) {
            guard !line.hasPrefix("M"), !isNumbered(prefix: "C") else { return }
            image = EmtBadgeImages.shared.cached(line)
            if image == nil { image = await EmtBadgeImages.shared.load(line) }
        }
    }

    private func isNumbered(prefix: String) -> Bool {
        line.hasPrefix(prefix) && line.count > 1 && line.dropFirst().allSatisfy(\.isNumber)
    }

    /// Fixed size from the image's aspect, so wrapping layouts measure it right.
    private func bitmap(_ image: UIImage) -> some View {
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1.4
        return Image(uiImage: image).resizable().frame(width: height * aspect, height: height)
    }

    private func pill(_ text: String, color: Color, text textColor: Color = .white) -> some View {
        Text(text)
            .font(.system(size: height * 0.5, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(textColor)
            .padding(.horizontal, height * 0.3)
            .frame(minWidth: height * 1.35, minHeight: height)
            .background(color, in: RoundedRectangle(cornerRadius: height * 0.25, style: .continuous))
    }
}

/// Network logo (`ServiceLogo` in EmtApp.kt).
struct ServiceLogo: View {
    let network: Network
    var size: CGFloat = 22

    var body: some View {
        if let image = BundledAsset.image(network.asset) {
            Image(uiImage: image).resizable().scaledToFit().frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size / 3).fill(networkColor(network)).frame(width: size, height: size)
        }
    }
}

/// `networkDot` in EmtApp.kt.
func networkColor(_ network: Network) -> Color {
    switch network {
    case .emt: return Color(hex: 0xF97316)
    case .metro: return Color(hex: 0xE4002B)
    case .valenbisi: return Color(hex: 0x22C55E)
    case .metrobus: return Color(hex: 0x0EA5E9)
    case .rodalies: return Color(hex: 0xE30613)
    }
}

/// Line colours that come from a service at run time (Metrobús publishes one
/// per line). Observed, so badges recolour as soon as they load.
@Observable @MainActor
final class LineColors {
    static let shared = LineColors()

    /// "MB150" → 0x25D5FF
    var metrobus: [String: Int] = [:]

    /// White or dark text, whichever reads better on `hex` (some line colours
    /// are very light, like a fluorescent green).
    nonisolated static func textColor(on hex: Int) -> Color {
        func channel(_ shift: Int) -> Double {
            let c = Double((hex >> shift) & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
        return luminance > 0.4 ? Color(hex: 0x1F2933) : .white
    }
}

