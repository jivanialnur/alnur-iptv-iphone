import SwiftUI
import UIKit

final class ImageMemory {
    static let shared: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 600
        return c
    }()
}

struct RemoteImage: View {
    let url: String?
    var placeholder = "tv"
    var fill = false
    @State private var img: UIImage?

    var body: some View {
        ZStack {
            if let img {
                if fill { Image(uiImage: img).resizable().scaledToFill() }
                else { Image(uiImage: img).resizable().scaledToFit() }
            } else {
                Image(systemName: placeholder)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let s = url, !s.isEmpty, let u = URL(string: s) else { img = nil; return }
        if let c = ImageMemory.shared.object(forKey: s as NSString) { img = c; return }
        img = nil
        var req = URLRequest(url: u)
        req.timeoutInterval = 20
        guard let r = try? await URLSession.shared.data(for: req), let i = UIImage(data: r.0) else { return }
        let small = i.preparingThumbnail(of: CGSize(width: 300, height: 300 * i.size.height / max(i.size.width, 1))) ?? i
        ImageMemory.shared.setObject(small, forKey: s as NSString)
        if url == s { img = small }
    }
}
