import SwiftUI

struct ContactAvatarView: View {
    let imageData: Data?
    let name: String
    var size: CGFloat = 42
    var font: Font? = nil
    /// 号码是否在通讯录里：在通讯录但没头像 → 名称首字符；不在通讯录 → 人像图标。
    var isKnownContact: Bool = true

    var body: some View {
        Group {
            if let imageData, let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if isKnownContact {
                Image(systemName: "circle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(avatarGradient)
                    .overlay {
                        Text(initials)
                            .font(font ?? .system(size: size * 0.4, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(avatarGradient)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initials: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "?" }
        let components = trimmed.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        if components.count > 1,
           let first = components.first?.first,
           let last = components.last?.first {
            return String([first, last]).uppercased()
        }
        return String(trimmed.prefix(1)).uppercased()
    }

    private var avatarGradient: LinearGradient {
        LinearGradient(
            colors: [Color(white: 0.8), Color(white: 0.75)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

#Preview {
    VStack(spacing: 16) {
        ContactAvatarView(imageData: nil, name: "张三", size: 64)
        ContactAvatarView(imageData: nil, name: "Li Ming", size: 64)
        ContactAvatarView(imageData: nil, name: "", size: 64)
        ContactAvatarView(imageData: nil, name: "13800138000", size: 64, isKnownContact: false)
    }
}
