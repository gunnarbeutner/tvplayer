import TVServices

final class TopShelfProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(
        completionHandler: @escaping ((any TVTopShelfContent)?) -> Void
    ) {
        guard let snapshot = TopShelfSnapshotStore.load() else {
            completionHandler(nil)
            return
        }

        let now = Date()
        let onNow = snapshot.availableOnNowItems(at: now)
        var sections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = []
        if !onNow.isEmpty {
            let section = TVTopShelfItemCollection(items: onNow.map(makeItem))
            section.title = "On Now"
            sections.append(section)
        }
        let recordings = snapshot.recordings.filter { $0.isAvailable(at: now) }
        if !recordings.isEmpty {
            let section = TVTopShelfItemCollection(items: recordings.map(makeItem))
            section.title = "Recordings"
            sections.append(section)
        }
        completionHandler(sections.isEmpty ? nil : TVTopShelfSectionedContent(sections: sections))
    }

    private func makeItem(_ snapshot: TopShelfSnapshot.Item) -> TVTopShelfSectionedItem {
        let item = TVTopShelfSectionedItem(identifier: snapshot.id)
        item.title = snapshot.title
        item.imageShape = .hdtv
        item.expirationDate = snapshot.topShelfExpirationDate
        item.playbackProgress = snapshot.playbackProgress ?? 0
        if let route = URL(string: snapshot.routeURL) {
            let action = TVTopShelfAction(url: route)
            item.displayAction = action
            item.playAction = action
        }
        if let filename = snapshot.artworkFilename,
           let imageURL = TopShelfSnapshotStore.cachedArtworkURL(for: filename) {
            // Traits are lookup keys, not a set of alternatives. Register
            // both scale variants separately so either Home Screen request
            // resolves to an image.
            item.setImageURL(imageURL, for: .screenScale1x)
            item.setImageURL(imageURL, for: .screenScale2x)
        }
        return item
    }
}
