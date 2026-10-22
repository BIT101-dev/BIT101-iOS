import Foundation
import Observation
import TransportCore
import CommunityTransport

/// 举报状态和在途任务归当前弹层实例维护。
@MainActor @Observable
final class GalleryReportViewModel {
    var reportTypes: [GalleryReportType] = []
    var selectedTypeID: Int?
    var text = ""
    var hasChanges: Bool { !text.isEmpty || selectedTypeID != reportTypes.first?.id }
    private(set) var isLoading = true
    private(set) var isSubmitting = false
    private(set) var resultNeedsReview = false
    private(set) var errorMessage: String?
    private let service: any GalleryReportServicing
    private var generation = 0
    @ObservationIgnored private var loadTask: Task<[GalleryReportType], Error>?
    @ObservationIgnored private var submissionTask: Task<Void, Error>?

    init(service: any GalleryReportServicing) { self.service = service }

    deinit { loadTask?.cancel(); submissionTask?.cancel() }

    func cancel() {
        generation &+= 1
        loadTask?.cancel(); loadTask = nil
        submissionTask?.cancel(); submissionTask = nil
        isLoading = false
        isSubmitting = false
    }

    func loadReportTypes() async {
        guard loadTask == nil, !resultNeedsReview else { return }
        let operation = generation
        isLoading = true
        errorMessage = nil
        let service = service
        let task = Task { try await service.fetchReportTypes() }
        loadTask = task
        defer { if generation == operation { loadTask = nil; isLoading = false } }
        do {
            let types = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard generation == operation else { return }
            reportTypes = GalleryReportType.usableOptions(types)
            selectedTypeID = reportTypes.first?.id
        } catch {
            guard generation == operation, !TaskCancellation.matches(error) else { return }
            reportTypes = []
            selectedTypeID = nil
            errorMessage = error.localizedDescription
        }
    }

    func submit(objectID: String) async -> Bool {
        guard !isLoading, !resultNeedsReview, submissionTask == nil, let selectedTypeID,
              reportTypes.contains(where: { $0.id == selectedTypeID }) else { return false }
        let operation = generation
        let service = service
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        isSubmitting = true
        errorMessage = nil
        let task = Task { try await service.report(objectID: objectID, typeID: selectedTypeID, text: text) }
        submissionTask = task
        defer { if generation == operation { submissionTask = nil; isSubmitting = false } }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            return generation == operation
        } catch {
            if generation == operation {
                if error is CommunityCreateOutcomeUnknown {
                    resultNeedsReview = true
                    errorMessage = CommunityCreateOutcomeUnknown.reportReviewMessage
                } else if !TaskCancellation.matches(error) { errorMessage = error.localizedDescription }
            }
            return false
        }
    }
}
