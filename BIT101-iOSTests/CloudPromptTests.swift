import Combine
import ScheduleSync
import Testing
@testable import BIT101_iOS

@MainActor
struct CloudPromptTests {
    @Test(.timeLimit(.minutes(1)))
    func aDismissedConflictCanBePresentedAgainThroughTheAppAdapter() async throws {
        let prompts = AppPromptCoordinator(advanceDelay: .zero)
        prompts.markHostReady()
        let present = ScheduleCloudSyncManager.appConflictPresenter(prompts: prompts)
        present("same-conflict") { _ in }
        let first = try #require(prompts.activePrompt)
        prompts.alertPresentationChanged(isPresented: false, promptID: prompts.activePrompt?.id)
        let next = Task<AppPrompt?, Never> {
            for await prompt in prompts.$activePrompt.values {
                if let prompt, prompt.id != first.id { return prompt }
            }
            return nil
        }
        present("same-conflict") { _ in }
        let second = try #require(await next.value)
        #expect(first.id != second.id)
        #expect(second.title == first.title)
    }
}
