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
        let recordings = snapshot.recordings.filter { $0.isAvailable(at: now) }
        let items = (onNow + recordings).map(makeItem)
        guard !items.isEmpty else {
            completionHandler(nil)
            return
        }
        completionHandler(TVTopShelfCarouselContent(style: .details, items: items))
    }

    private func makeItem(_ snapshot: TopShelfSnapshot.Item) -> TVTopShelfCarouselItem {
        let item = TVTopShelfCarouselItem(identifier: snapshot.id)
        item.title = snapshot.title
        item.contextTitle = snapshot.contextTitle
        item.summary = snapshot.summary
        item.genre = snapshot.genre
        item.duration = snapshot.duration ?? 0
        item.creationDate = snapshot.creationDate
        item.mediaOptions = mediaOptions(for: snapshot.mediaOptions ?? [])
        item.namedAttributes = (snapshot.namedAttributes ?? []).prefix(4).map {
            TVTopShelfNamedAttribute(name: $0.name, values: $0.values)
        }
        item.expirationDate = snapshot.topShelfExpirationDate
        if let playURL = URL(string: snapshot.routeURL) {
            item.playAction = TVTopShelfAction(url: playURL)
        }
        if let displayRouteURL = snapshot.displayRouteURL,
           let displayURL = URL(string: displayRouteURL) {
            item.displayAction = TVTopShelfAction(url: displayURL)
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

    private func mediaOptions(
        for options: [TopShelfSnapshot.MediaOption]
    ) -> TVTopShelfCarouselItem.MediaOptions {
        var result: TVTopShelfCarouselItem.MediaOptions = []
        if options.contains(.hd) {
            result.insert(.videoResolutionHD)
        }
        if options.contains(.closedCaptioning) {
            result.insert(.audioTranscriptionClosedCaptioning)
        }
        return result
    }
}
