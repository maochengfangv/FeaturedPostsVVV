//：视频数据和封面图生成。
import UIKit

//遵守Hashable协议让Model具备 可去重、可快速查找、可作为字典 key、可参与 diff 的能力
// 在视频播放器组件里，让视频模型遵守 Hashable ，通常是为了把它当成一个可唯一识别的业务实体使用
struct VideoItem: Hashable {
    let id: String
    let title: String
    let url: URL
    let color: UIColor
    
    func coverImage(size: CGSize = CGSize(width: 720, height: 1280)) -> UIImage {
        
        let reanderer = UIGraphicsImageRenderer(size: size)
        
        return reanderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            let colors = [
                color.cgColor,
                color.withAlphaComponent(0.75).cgColor,
                UIColor.black.cgColor
            ] as CFArray
            
            let space = CGColorSpaceCreateDeviceRGB()
            let locations: [CGFloat] = [0, 0.45, 1.0]
            if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: locations) {
                ctx.cgContext.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: size.width, y: size.height),
                    options: []
                )
            }
            
            let badgeRect = CGRect(x: 28, y: 36, width: 96, height: 36)
            UIBezierPath(roundedRect: badgeRect, cornerRadius: 18).fill(with: .normal, alpha: 0.18)
            let badgeText = "DEMO"
            badgeText.draw(
                in: badgeRect.insetBy(dx: 18, dy: 9),
                withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: 16),
                    .foregroundColor: UIColor.white
                ]
            )
            
            title.draw(
                in: CGRect(x: 32, y: size.height * 0.68, width: size.width - 64, height: 80),
                withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: 42),
                    .foregroundColor: UIColor.white
                ]
            )
            
            "封面占位到首帧".draw(
                in: CGRect(x: 32, y: size.height * 0.80, width: size.width - 64, height: 40),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 24, weight: .medium),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.82)
                ]
            )
        }
    }
}

enum VideoDemoConfig {
    static let sampleURL = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8")!
    static let preloadBytes = 300 * 1024
    static let firstFrameTimeout: TimeInterval = 2.5
    
    static let videos: [VideoItem] = [
        VideoItem(id: "1", title: "短剧 01", url: sampleURL, color: .systemPink),
        VideoItem(id: "2", title: "短剧 02", url: sampleURL, color: .systemBlue),
        VideoItem(id: "3", title: "短剧 03", url: sampleURL, color: .systemOrange),
        VideoItem(id: "4", title: "短剧 04", url: sampleURL, color: .systemPurple)
    ]
}
