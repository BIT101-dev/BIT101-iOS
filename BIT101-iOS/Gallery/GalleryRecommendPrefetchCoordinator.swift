import Foundation

/// One source page retained by the recommendation prefetch pipeline.
struct GalleryPrefetchedPage {
    let page: Int
    let posters: [GalleryPoster]
    let nextPage: Int
    let canLoadMore: Bool
}

/// Owns recommendation-page tasks so foreground pagination and background
/// prefetch always share one request for the same source page.
@MainActor
final class GalleryRecommendPrefetchCoordinator {
    private let service: any GalleryFeedServicing
    private let depth: Int
    private var generation = 0
    private var pageTasks: [Int: Task<GalleryPrefetchedPage, Error>] = [:]
    private var chainTask: Task<Void, Never>?

    init(service: any GalleryFeedServicing, depth: Int = 2) {
        self.service = service
        self.depth = depth
    }

    func start(from startPage: Int) {
        guard chainTask == nil else { return }
        let expectedGeneration = generation

        chainTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == expectedGeneration {
                    chainTask = nil
                }
            }

            var currentPage = startPage
            for _ in 0..<depth {
                guard !Task.isCancelled, generation == expectedGeneration else { return }
                do {
                    let page = try await task(for: currentPage, generation: expectedGeneration).value
                    guard page.canLoadMore else { return }
                    currentPage = page.nextPage
                } catch {
                    return
                }
            }
        }
    }

    func takePage(for page: Int) async throws -> GalleryPrefetchedPage {
        let expectedGeneration = generation
        let task = task(for: page, generation: expectedGeneration)
        let result = try await task.value
        guard generation == expectedGeneration else { throw CancellationError() }
        // Keep the just-consumed task briefly. A background chain that was already
        // awaiting the same page can resume after foreground pagination and ask for
        // that source page again; retaining the completed task prevents a duplicate
        // network request. Older pages are pruned to keep memory bounded.
        pageTasks = pageTasks.filter { $0.key >= page - 2 }
        return result
    }

    func reset() {
        generation += 1
        chainTask?.cancel()
        chainTask = nil
        pageTasks.values.forEach { $0.cancel() }
        pageTasks = [:]
    }

    private func task(
        for page: Int,
        generation expectedGeneration: Int
    ) -> Task<GalleryPrefetchedPage, Error> {
        if let existing = pageTasks[page] {
            return existing
        }

        let service = service
        let task = Task { [weak self] in
            let batch = try await service.fetchRecommendPage(sourcePage: page)
            try Task.checkCancellation()
            guard let self, self.generation == expectedGeneration else {
                throw CancellationError()
            }
            return GalleryPrefetchedPage(
                page: page,
                posters: batch.posters,
                nextPage: batch.nextSourcePage,
                canLoadMore: batch.canLoadMore
            )
        }
        pageTasks[page] = task
        return task
    }
}
