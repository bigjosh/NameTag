import SwiftUI

struct CardView: View {
    let nearbyContact: NearbyContact
    @Binding var selectedConnection: Connection?

    /// Height reserved for the name/message bar at the bottom
    private let bottomBarHeight: CGFloat = 130

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // Profile photo — fills the space above the bottom bar
                AsyncProfileImage(url: nearbyContact.connection.profilePhotoURL)
                    .frame(width: geo.size.width, height: geo.size.height - bottomBarHeight)
                    .clipped()

                // Name bar + message button
                VStack(spacing: 6) {
                    Text(nearbyContact.connection.fullName)
                        .font(.title2.bold())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    if !nearbyContact.connection.howDoIKnow.isEmpty {
                        Text(nearbyContact.connection.howDoIKnow)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Button {
                        selectedConnection = nearbyContact.connection
                    } label: {
                        Label("Message", systemImage: "bubble.left.fill")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.blue)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                }
                .padding(.bottom, 12)
                .frame(width: geo.size.width, height: bottomBarHeight)
                .background(.background)
            }
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(.separator, lineWidth: 0.5)
        )
    }
}
