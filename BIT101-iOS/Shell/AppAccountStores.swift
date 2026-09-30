import ScoreDomain
import ScoreInfrastructure
import GalleryFeature
import StorageCore
import ScoreFeature
import ScheduleDomain
import Foundation

struct AppAccountStores {
    let communityMessages: GalleryMessageReadStore
    let composerDrafts: ComposerDraftStore
    let scoreCache: ScoreCacheStore
    let scoreFilterPreferences: ScoreFilterPreferenceStore
    let currentSession: @MainActor () -> AppStorageSession
    let scoreSession: @MainActor () -> AppStorageSession

    static let shared = AppAccountStores(
        communityMessages: GalleryMessageReadStore(
            defaults: AppFileDirectories.defaults, session: { AppFileDirectories.currentSession }
        ),
        composerDrafts: ComposerDraftStore(
            files: AppFileDirectories.files, applicationSupport: AppFileDirectories.applicationSupport,
            session: { AppFileDirectories.currentSession }
        ),
        scoreCache: ScoreCacheStore(
            files: AppFileDirectories.files,
            storageRoot: AppFileDirectories.applicationSupportDirectoryURL(named: "BIT101-iOS"),
            defaults: AppFileDirectories.defaults,
            session: { AppFileDirectories.scoreCacheSession }
        ),
        scoreFilterPreferences: ScoreFilterPreferenceStore(
            defaults: AppFileDirectories.defaults,
            session: { AppFileDirectories.currentSession }
        ),
        currentSession: { AppFileDirectories.currentSession },
        scoreSession: { AppFileDirectories.scoreCacheSession }
    )
}

/// 成绩消费当前账号的课程快照，应用层负责读取日程存储。
extension ScoreViewModel {
    convenience init(
        service: any ScoreListServicing,
        stores: AppAccountStores = .shared,
        notificationCenter: NotificationCenter = .default,
        currentScoreCacheSession: (@MainActor () -> AppStorageSession)? = nil
    ) {
        self.init(
            service: service,
            cacheStore: stores.scoreCache,
            preferenceStore: stores.scoreFilterPreferences,
            currentScoreCacheSession: currentScoreCacheSession ?? stores.scoreSession,
            scheduleCoursesChanges: ScheduleCacheStore.changes,
            loadScheduleCourses: { session in
                let result = await ScheduleCacheStore.loadResultAsync(for: session)
                return (result.cacheIfReadable?.cachedCoursesByTerm ?? [:]).mapValues { $0.map(ScoreCourseSummary.init) }
            },
            notificationCenter: notificationCenter
        )
    }

    convenience init() { self.init(service: ScoreService()) }
}

/// 应用生命周期为基础存储提供当前账号、路径和偏好容器。
extension AccountScopedCodableStore {
    init(
        keyPrefix: String,
        defaults: UserDefaults = AppFileDirectories.defaults,
        session: @escaping () -> AppStorageSession = { AppFileDirectories.currentSession }
    ) {
        self.init(keyPrefix: keyPrefix, defaults: defaults, sessionProvider: session)
    }
}

extension AccountScopedFileCodableStore {
    init(
        filename: String,
        files: any AppFileService = AppFileDirectories.files,
        session: @escaping () -> AppStorageSession = { AppFileDirectories.currentSession }
    ) {
        self.init(filename: filename, files: files, session: session, directory: AppFileDirectories.applicationSupport)
    }
}

/// 将课表规则投影为成绩页面消费的文本与课程身份。
extension ScoreCourseSummary {
    init(course: CourseRecord) {
        let scheduleText: String
        if (1...7).contains(course.weekday), course.startSection > 0 {
            let weekdays = ["一", "二", "三", "四", "五", "六", "日"]
            let section = course.endSection > course.startSection
                ? "第\(course.startSection)-\(course.endSection)节"
                : "第\(course.startSection)节"
            scheduleText = "星期\(weekdays[course.weekday - 1]) \(section)"
        } else {
            scheduleText = "-"
        }
        self.init(
            id: course.id, term: course.term, name: course.name, number: course.number,
            type: course.type, teacher: course.teacher, classroom: course.classroom,
            campus: course.campus, description: course.description, creditText: course.creditText,
            scheduleText: scheduleText,
            weeksText: course.weeks.isEmpty ? "-" : ScheduleWeekCodec.formatWeeks(course.weeks).replacingOccurrences(of: ",", with: "、"),
            hourText: course.hour > 0 ? "\(course.hour)" : "-"
        )
    }
}
