import CommunityCore
import Foundation

/// Recommendation results and pagination state for one source page.
struct GalleryPrefetchedPage {
    let page: Int
    let posters: [CommunityPoster]
    let nextPage: Int
    let canLoadMore: Bool
}

/// Shares source-page tasks between foreground pagination and background prefetch.
@MainActor
final class GalleryRecommendPrefetchCoordinator {
    private struct PageOperation {
        let id = UUID()
        let task: Task<GalleryPrefetchedPage, Error>
    }

    private let service: any GalleryFeedServicing
    private let depth: Int
    private var generation = 0
    private var pageTasks: [Int: PageOperation] = [:]
    private var chainTask: Task<Void, Never>?

    init(service: any GalleryFeedServicing, depth: Int = 2) {
        self.service = service
        self.depth = max(depth, 0)
    }

    func start(from startPage: Int) {
        guard chainTask == nil else { return }
        let expectedGeneration = generation
        let firstPage = max(startPage, 0)

        chainTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == expectedGeneration {
                    chainTask = nil
                }
            }

            var currentPage = firstPage
            for _ in 0..<depth {
                guard !Task.isCancelled, generation == expectedGeneration else { return }
                do {
                    let page = try await operation(for: currentPage, generation: expectedGeneration).task.value
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
        let operation = operation(for: page, generation: expectedGeneration)
        let result: GalleryPrefetchedPage
        do {
            result = try await operation.task.value
        } catch {
            if pageTasks[page]?.id == operation.id {
                pageTasks[page] = nil
            }
            throw error
        }
        guard generation == expectedGeneration else { throw CancellationError() }
        // Retain nearby completed tasks. A background chain that already awaits the
        // same page can resume after foreground pagination and request that source
        // page again; retaining the completed task prevents a duplicate network
        // request. Older pages are pruned to bound memory.
        pageTasks = pageTasks.filter { $0.key >= page - 2 }
        return result
    }

    func reset() {
        generation += 1
        chainTask?.cancel()
        chainTask = nil
        pageTasks.values.forEach { $0.task.cancel() }
        pageTasks = [:]
    }

    private func operation(
        for page: Int,
        generation expectedGeneration: Int
    ) -> PageOperation {
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
        let operation = PageOperation(task: task)
        pageTasks[page] = operation
        return operation
    }
}
