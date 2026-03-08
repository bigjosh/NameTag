import SwiftUI

struct CardStackView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = CardStackViewModel()
    @State private var selectedConnection: Connection?

    /// Tracks the order of contacts for the deck
    @State private var deckOrder: [String] = []
    /// Drag offset for the top card
    @State private var dragOffset: CGSize = .zero
    /// Rotation for the top card while dragging
    @State private var dragRotation: Double = 0

    /// How many pixels each back card peeks below the one in front
    private let peekOffset: CGFloat = 20
    /// How many pixels narrower each back card is (per side)
    private let widthStep: CGFloat = 12
    /// Max cards visible in the stack
    private let maxVisible = 4
    /// Swipe threshold to trigger send-to-back
    private let swipeThreshold: CGFloat = 100

    var body: some View {
        NavigationStack {
            VStack(spacing: 4) {
                // Title area
                VStack(spacing: 2) {
                    Text("Nearby")
                        .font(.largeTitle.bold())
                    if !viewModel.nearbyContacts.isEmpty {
                        Text("\(viewModel.nearbyContacts.count) contact\(viewModel.nearbyContacts.count == 1 ? "" : "s")")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)

                // Notification snooze picker
                suppressionPicker
                    .padding(.horizontal, 24)

                if viewModel.nearbyContacts.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    cardDeck
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarHidden(true)
            .navigationDestination(item: $selectedConnection) { connection in
                ConversationView(
                    connection: connection,
                    currentUID: appState.authService.currentUID ?? ""
                )
            }
            .onAppear { viewModel.startMonitoring(appState: appState) }
            .onDisappear { viewModel.stopMonitoring() }
            .onChange(of: viewModel.nearbyContacts.map(\.id)) { _, newIDs in
                syncDeckOrder(with: newIDs)
            }
        }
    }

    // MARK: - Suppression Picker

    private var suppressionPicker: some View {
        VStack(spacing: 4) {
            Text("Snooze after alert")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Snooze", selection: Binding(
                get: { appState.notificationGatekeeper.suppressionDuration },
                set: {
                    appState.notificationGatekeeper.suppressionDuration = $0
                    // Immediately update all nearby contacts' suppression entries
                    appState.recheckNearbyNotifications()
                }
            )) {
                Text("None").tag(NotificationSuppression.none)
                Text("15 min").tag(NotificationSuppression.fifteenMinutes)
                Text("1 hr").tag(NotificationSuppression.oneHour)
                Text("1 day").tag(NotificationSuppression.oneDay)
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "wave.3.right")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse)

            Text("No contacts nearby")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("When your contacts are close by,\ntheir cards will appear here.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Card Deck

    private var cardDeck: some View {
        GeometryReader { geo in
            let topCardWidth = geo.size.width - 48  // 24pt margin each side
            let topCardHeight = geo.size.height - 16
            // Reserve space at bottom for peek of back cards
            let frontHeight = topCardHeight - CGFloat(maxVisible - 1) * peekOffset

            ZStack(alignment: .top) {
                ForEach(Array(orderedContacts.enumerated().prefix(maxVisible).reversed()), id: \.element.id) { deckIndex, contact in
                    let isTop = deckIndex == 0
                    let cardWidth = topCardWidth - CGFloat(deckIndex) * widthStep * 2
                    let yOffset = CGFloat(deckIndex) * peekOffset

                    CardView(nearbyContact: contact, selectedConnection: $selectedConnection)
                        .frame(width: cardWidth, height: frontHeight)
                        .offset(y: yOffset)
                        .offset(x: isTop ? dragOffset.width : 0)
                        .rotationEffect(isTop ? .degrees(dragRotation) : .zero)
                        .zIndex(Double(maxVisible - deckIndex))
                        .animation(isTop ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: deckOrder)
                        .gesture(isTop ? swipeGesture : nil)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: - Ordered contacts based on deck

    private var orderedContacts: [NearbyContact] {
        let contactMap = Dictionary(uniqueKeysWithValues: viewModel.nearbyContacts.map { ($0.id, $0) })
        return deckOrder.compactMap { contactMap[$0] }
    }

    // MARK: - Swipe Gesture

    private var swipeGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = value.translation
                dragRotation = Double(value.translation.width / 20)
            }
            .onEnded { value in
                if abs(value.translation.width) > swipeThreshold {
                    let direction: CGFloat = value.translation.width > 0 ? 1 : -1
                    withAnimation(.easeIn(duration: 0.2)) {
                        dragOffset = CGSize(width: direction * 500, height: 0)
                        dragRotation = Double(direction * 25)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        sendTopToBack()
                        dragOffset = .zero
                        dragRotation = 0
                    }
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        dragOffset = .zero
                        dragRotation = 0
                    }
                }
            }
    }

    // MARK: - Deck Management

    private func sendTopToBack() {
        guard !deckOrder.isEmpty else { return }
        let top = deckOrder.removeFirst()
        deckOrder.append(top)
    }

    private func syncDeckOrder(with newIDs: [String]) {
        let existing = Set(deckOrder)
        for id in newIDs where !existing.contains(id) {
            deckOrder.append(id)
        }
        let currentSet = Set(newIDs)
        deckOrder.removeAll { !currentSet.contains($0) }
        if deckOrder.isEmpty {
            deckOrder = newIDs
        }
    }
}
