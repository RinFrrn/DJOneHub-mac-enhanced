import SwiftUI

struct ContactAvatarView: View {
    let imageData: Data?
    let name: String
    var size: CGFloat = 42
    var font: Font? = nil

    var body: some View {
        Group {
            if let imageData, let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "circle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(avatarColor)
                    .overlay {
                        Text(initials)
                            .font(font ?? .system(size: size * 0.4, weight: .semibold))
                            .foregroundStyle(.white)
                    }
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

    private var avatarColor: Color {
        let colors: [Color] = [
            .blue, .purple, .pink, .orange, .green, .teal, .indigo, .red
        ]
        return colors[abs(name.hashValue) % colors.count]
    }
}

#Preview {
    VStack(spacing: 16) {
        ContactAvatarView(imageData: nil, name: "张三", size: 64)
        ContactAvatarView(imageData: nil, name: "Li Ming", size: 64)
        ContactAvatarView(imageData: nil, name: "", size: 64)
    }
}
