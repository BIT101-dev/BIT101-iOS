"""Shared workflow registration and platform coverage policy."""
import sys

if sys.version_info < (3, 10):
    raise SystemExit('维护工具需要 Python 3.10 及以上版本；请按 docs/SETUP.md 选择 Homebrew Python。')

SWIFT_SYNTAX_SOURCE_NAMES = ("SwiftSyntaxIndexer.swift", "SwiftSyntaxFacts.swift")

MAXIMUM_ATTACHMENT_BYTES = 32 * 1024 * 1024
MAXIMUM_DECODED_MEDIA_BYTES = 48 * 1024 * 1024
MAXIMUM_VIDEO_SECONDS = 30
MAXIMUM_VIDEO_FRAMES = 1800
MAXIMUM_PDF_PAGES = 16
MAXIMUM_REPORT_BYTES = 128 * 1024 * 1024
MEDIA_PROBE_TIMEOUT_SECONDS = 30

APP_TEST_GROUPS = {"all", "release-runtime", "network-smoke", "catalyst", "catalyst-release-runtime", "schedule", "infrastructure", "login", "extensions"}
TEST_GROUPS = APP_TEST_GROUPS | {"modules", "ui"}
CORE_GROUPS = {'all', 'release-runtime', 'ui', 'restore'}
NETWORK_GROUPS = {"network", "ddl", "school-sms", "community-writes", "community-cleanup"}
SCHOOL_SMS_PROBES = {
    "webvpn": {"school.session", "schedule.current-term", "schedule.terms", "schedule.sync", "classroom.campuses", "classroom.buildings", "classroom.occupancy"},
    "jwb": {"score.authentication"},
    "jwb_cjd": {"score.transcript"},
    "school_sso_second_factor": {"eclass.authentication", "eclass.ddl", "lexue.calendar", "lexue.ddl"},
}
RELEASE_GROUPS = {"modules", "all", "release-runtime", "catalyst", "catalyst-release-runtime", "ui", "network", "school-sms", "icloud", "audit", "restore", "manual-device", "build-archive", "community-writes"}
BUILD_HOSTS = {"release", "release-runtime", "ui", "network-smoke", "icloud-smoke", "modules", "catalyst", "catalyst-release-runtime"}
VERIFY_GROUPS = ("modules", "all", "release-runtime", "catalyst", "catalyst-release-runtime", "ui", "network", "community-writes", "ddl", "icloud", "build-archive", "audit")
DEFAULT_VERIFY_GROUPS = tuple(group for group in VERIFY_GROUPS if group != "ddl")
REVIEW_JOB_NAMES = {'Static audit (Apple toolchain)', 'Release app and extension builds',
    'Mac Catalyst behavior tests', 'iOS Simulator behavior and UI tests'}


def workflow_timeout_seconds(groups: tuple[str, ...]) -> int:
    if not groups or any(group not in VERIFY_GROUPS for group in groups):
        raise ValueError('聚合工作流需要有效的验证组。')
    return sum(90 if group == 'ui' else 45 for group in set(groups)) * 60 + 5 * 60


def workflow_budget_self_test() -> None:
    import os
    from pathlib import Path
    import shlex
    import subprocess

    root = Path(__file__).resolve().parent.parent
    for groups, expected in ((('ui',), 95 * 60), (('ui', 'ui'), 95 * 60),
            (('all', 'release-runtime', 'ui'), 185 * 60)):
        environment = dict(os.environ)
        environment.pop('BIT101_WORKFLOW_TIMEOUT_SECONDS', None)
        command = f'ROOT_DIR={shlex.quote(str(root))}; source "$ROOT_DIR/Scripts/script-support.sh"; '
        command += 'bit101_set_workflow_budget ' + shlex.join(groups) + '; print -r -- "$BIT101_WORKFLOW_TIMEOUT_SECONDS"'
        actual = subprocess.check_output(['zsh', '-c', command], text=True, env=environment, timeout=10)
        assert int(actual) == expected
        environment['BIT101_WORKFLOW_TIMEOUT_SECONDS'] = '17'
        assert subprocess.check_output(['zsh', '-c', command], text=True, env=environment, timeout=10).strip() == '17'
    for groups in ((), ('unknown',)):
        try: workflow_timeout_seconds(groups)
        except ValueError: continue
        raise AssertionError('工作流预算需要拒绝无效验证组。')


def workflow_conditions(group: str) -> tuple[str, ...]:
    group = group.removeprefix('build-')
    group = {'network-smoke': 'network', 'icloud-smoke': 'icloud', 'icloud-cleanup': 'icloud'}.get(group, group)
    if group in {'all', 'catalyst', 'schedule', 'infrastructure', 'login', 'extensions'}:
        return ('DEBUG', 'EXTENDED_AUTOMATION', 'BIT101_AUTOMATED_TESTING')
    if group == 'ui': return ('EXTENDED_AUTOMATION', 'BIT101_AUTOMATED_TESTING', 'BIT101_UI_TESTING')
    if group in NETWORK_GROUPS: return ('RELEASE_NETWORK_SMOKE',)
    if group == 'icloud': return ('DEBUG', 'ICLOUD_CROSS_DEVICE_SMOKE')
    return ()


FORMAL_RUNTIME_SUITES = {"ReleaseRuntimeContractTests", "CommunitySessionRecoveryTests", "ExtendedLoginTests", "LoginStorageTests", "LoginBootstrapTests", "NetworkClientTests",
    "FeatureCompositionTests", "ExperimentalPreferenceCloudSyncTests", "AppExternalDisplayTests", "ReminderContextTests", "ScheduleModuleBoundaryTests"}
APP_COVERAGE_FLOOR = 35
MODULE_COVERAGE_FLOORS = {
    "ClientCore": 63, "CommunityCore": 87, "CommunityPersistence": 98, "CommunityTransport": 82,
    "CommunityUI": 100, "CourseFeature": 65, "DesignSystemKit": 86, "GalleryFeature": 76,
    "MapFeature": 34, "MediaKit": 100, "MineFeature": 82, "PaperFeature": 81,
    "ScheduleContracts": 87, "ScheduleDomain": 75, "ScheduleFeature": 52, "ScheduleInfrastructure": 62,
    "SchedulePersistence": 77, "SchedulePorts": 35, "ScheduleSharedStore": 97, "ScheduleSync": 77,
    "ScorePorts": 96, "ScoreDomain": 92, "ScoreFeature": 74, "ScoreInfrastructure": 76, "StorageCore": 87, "TransportCore": 77,
}
IOS_MODULE_COVERAGE_FLOORS = {
    "ClientCore": 48, "CommunityCore": 47, "CommunityPersistence": 67, "CommunityTransport": 67,
    "CommunityUI": 6, "CourseFeature": 8, "DesignSystemKit": 44, "GalleryFeature": 14,
    "MapFeature": 21, "MediaKit": 53, "MineFeature": 25, "PaperFeature": 36,
    "ScheduleActivityContracts": 100, "ScheduleContracts": 88, "ScheduleDomain": 79,
    "ScheduleFeature": 30, "ScheduleInfrastructure": 26, "SchedulePersistence": 27,
    "SchedulePorts": 64, "ScheduleSharedStore": 52, "ScheduleSync": 5,
    "ScorePorts": 45, "ScoreDomain": 45, "ScoreFeature": 7, "ScoreInfrastructure": 31, "StorageCore": 75, "TransportCore": 77,
}
UI_PRODUCTION_MODULES = frozenset({
    "CommunityUI", "CourseFeature", "DesignSystemKit", "GalleryFeature", "MapFeature", "MediaKit",
    "MineFeature", "PaperFeature", "ScheduleFeature", "ScoreFeature",
})


def coverage_registry_findings(modules: set[str], ui_modules: set[str] | None = None) -> list[str]:
    errors = []
    if UI_PRODUCTION_MODULES - modules:
        errors.append(f"UI 覆盖率登记需要匹配生产模块：{sorted(UI_PRODUCTION_MODULES - modules)}")
    if ui_modules is not None and ui_modules != UI_PRODUCTION_MODULES:
        errors.append(f"UI 覆盖率登记需要匹配 SwiftUI 生产模块：新增 {sorted(ui_modules - UI_PRODUCTION_MODULES)}；清理 {sorted(UI_PRODUCTION_MODULES - ui_modules)}")
    for platform, floors, expected in (("macOS", MODULE_COVERAGE_FLOORS, modules - {"ScheduleActivityContracts"}),
            ("iOS", IOS_MODULE_COVERAGE_FLOORS, modules)):
        if set(floors) != expected:
            errors.append(f"{platform} 模块覆盖率登记需要匹配生产模块：新增 {sorted(expected - floors.keys())}；清理 {sorted(floors.keys() - expected)}")
    return errors


NETWORK_CAPABILITIES = {
 'MediaKit.MediaEnvironment': {'verifyRemoteImage(at:URL)': 'network'},
 'BIT101-iOS.BIT101APIClient': {
     'fetchSchoolLoginContext()': 'first-login',
     'loginSchool(studentID:String,password:String,salt:String,execution:String)': 'first-login',
     'webVPNVerifyInit(studentID:String)': 'first-login',
     'webVPNVerify(studentID:String,password:String,execution:String,cookie:String,salt:String)': 'first-login',
     'register(password:String,token:String,code:String,loginMode:Bool)': 'first-login',
     'mailVerify(studentID:String)': 'first-login',
     'loginCommunity(studentID:String,passwordDigest:String)': 'first-login',
     'checkBIT101Login(fakeCookie:String)': 'account-lifecycle'},
 'BIT101-iOS.FeedbackSubmissionClient': {'static submit(:Payload)': 'feedback-delivery', 'static submitNetworkSmoke(runID:String)': 'network'},
 'BIT101-iOS.NetworkDiagnosisRunner': {'run()': 'web-interactions'},
 'BIT101-iOS.AppUpdatePromptCoordinator': {'noticeToPresentAtLaunch()': 'web-interactions', 'checkManually()': 'web-interactions'},
 'BIT101-iOS.AppUpdateChecker': {'releaseToPresentAtLaunch()': 'web-interactions',
                                 'checkManually()': 'web-interactions'},
 'BIT101-iOS.EmergencyUpdateChecker': {'noticeToPresentAtLaunch()': 'web-interactions'},
 'BIT101-iOS.LoginService': {'checkLogin()': 'network',
                             'restoreSchoolSessionIfNeeded()': 'network',
                             'login(studentID:String,password:String)': 'first-login',
                             'sendRegistrationEmail(studentID:String)': 'first-login',
                             'verifyRegistrationIdentity(studentID:String,password:String)': 'first-login',
                             'registerAccount(studentID:String,password:String,token:String,code:String,schoolPassword:String?)': 'first-login',
                             'renewCommunitySession(observed:CommunityCredentials)': 'account-lifecycle',
                             'restoreCommunitySession(password:String)': 'profile-writes'},
 'BIT101-iOS.SettingsNetworkService': {'fetchMyInfo()': 'profile-writes',
                                       'updateUser(nickname:String?,motto:String?,avatarMid:String?)': 'profile-writes',
                                       'uploadAvatar(data:Data,filename:String)': 'profile-writes',
                                       'checkLogin()': 'account-lifecycle'},
 'GalleryFeature.GalleryWebCoordinator': {
    'start(in:WKWebView,url:URL)': 'web-interactions',
    'webView(:WKWebView,didFinish:WKNavigation?)': 'web-interactions',
    'synchronizeCredentials(in:WKWebView)': 'web-interactions',
    'webView(:WKWebView,didFail:WKNavigation?,withError:Error)': 'web-interactions',
    'webView(:WKWebView,didFailProvisionalNavigation:WKNavigation?,withError:Error)': 'web-interactions',
    'webViewWebContentProcessDidTerminate(:WKWebView)': 'web-interactions'},
 'CourseFeature.CourseService': {'fetchCourses(search:String,page:Int)': 'network',
                                 'fetchCourse(id:Int)': 'network',
                                 'fetchCourseHistories(number:String)': 'network',
                                 'fetchComments(courseID:Int,page:Int?)': 'network',
                                 'like(objectID:String)': 'community-writes',
                                 'createComment(objectID:String,text:String,replyObjectID:String?,replyUID:Int?,anonymous:Bool,rate:Int?)': 'community-writes'},
 'GalleryFeature.GalleryService': {'fetchFeed(kind:GalleryFeedKind,page:Int?)': 'network',
                                   'fetchRecommendPage(sourcePage:Int)': 'network',
                                   'searchPosters(query:GallerySearchQuery,page:Int?)': 'network',
                                   'fetchBotFeed(startPage:Int)': 'network',
                                   'fetchClaims()': 'network',
                                   'fetchSubscriptions(page:Int)': 'network',
                                   'setSubscription(objectID:String,level:GallerySubscriptionLevel)': 'community-writes',
                                   'uploadImage(data:Data,filename:String)': 'community-writes',
                                   'createPoster(title:String,text:String,imageMids:[String],anonymous:Bool,tags:[String],claimID:Int,isPublic:Bool)': 'community-writes',
                                   'fetchPoster(id:Int)': 'network',
                                   'deletePoster(id:Int)': 'community-writes',
                                   'updatePoster(id:Int,title:String,text:String,imageMids:[String],plugins:String,anonymous:Bool,tags:[String],claimID:Int,isPublic:Bool)': 'community-writes',
                                   'fetchReportTypes()': 'network',
                                   'report(objectID:String,typeID:Int,text:String)': 'gallery-report',
                                   'fetchComments(objectID:String,order:CommunityCommentOrder,page:Int?)': 'network',
                                   'fetchRawComments(objectID:String,order:CommunityCommentOrder,page:Int?)': 'community-writes',
                                   'like(objectID:String)': 'community-writes',
                                   'createComment(objectID:String,text:String,replyObjectID:String?,replyUID:Int?,anonymous:Bool,imageMids:[String])': 'community-writes',
                                   'uploadCommentImage(data:Data,filename:String)': 'community-writes',
                                   'deleteComment(id:Int)': 'community-writes',
                                   'fetchMessageUnreadCounts()': 'network',
                                   'fetchMessages(type:GalleryMessageType,lastID:Int?)': 'message-read'},
 'MineFeature.MineService': {'fetchMyInfo()': 'network',
                             'fetchUserInfo(id:Int)': 'network',
                             'followUser(id:Int)': 'community-writes',
                             'fetchFollowings(page:Int)': 'network',
                             'fetchFollowers(page:Int)': 'network',
                             'fetchMyPosters(page:Int)': 'network',
                             'fetchUserPosters(userID:Int,page:Int)': 'network'},
 'PaperFeature.PaperService': {'fetchPapers(search:String?,order:PaperSortOrder,page:Int)': 'network',
                               'fetchPreviewMetadata(id:Int)': 'network',
                               'fetchPaper(id:Int)': 'network',
                               'fetchComments(paperID:Int,order:CommunityCommentOrder,page:Int?)': 'network',
                               'likePaper(id:Int)': 'community-writes',
                               'sendLike(objectID:String)': 'community-writes',
                               'createComment(objectID:String,text:String,replyObjectID:String?,replyUID:Int?,anonymous:Bool)': 'community-writes',
                               'createPaper(title:String,intro:String,content:String,anonymous:Bool,publicEdit:Bool)': 'community-writes',
                               'updatePaper(id:Int,title:String,intro:String,content:String,anonymous:Bool,publicEdit:Bool,lastUpdatedAt:String)': 'community-writes',
                               'deletePaper(id:Int)': 'community-writes'},
 'ScheduleInfrastructure.ScheduleService': {'fetchEclassDDLEvents(schoolSMSCodeHandler:SchoolSMSCodeHandler?)': 'network',
                                            'fetchEclassDDLEventsForPreflight()': 'network',
                                            'syncCourses(term:String?)': 'network',
                                            'fetchAvailableTerms()': 'network',
                                            'submitSMSCodeForTeachingCenterAuthentication(:String,for:BITLoginAuthenticationChallenge)': 'web-interactions',
                                            'fetchCurrentTermOnly()': 'network',
                                            'prepareTeachingCenterAccess()': 'network',
                                            'fetchCampuses()': 'network',
                                            'fetchBuildings(campusCode:String?)': 'network',
                                            'fetchClassrooms(buildingID:String,term:String,date:Date)': 'network',
                                            'syncDDLEvents(existingEvents:[DDLEventRecord],storedURL:String,schoolSMSCodeHandler:SchoolSMSCodeHandler?,onSource:DDLSyncSourceDelivery?)': 'web-interactions',
                                            'syncDDLEventsForPreflight(existingEvents:[DDLEventRecord],storedURL:String)': 'network',
                                            'refreshLexueCalendarURL(schoolSMSCodeHandler:SchoolSMSCodeHandler?)': 'web-interactions',
                                            'refreshLexueCalendarURLForPreflight()': 'network'},
 'ScoreInfrastructure.ScoreService': {'startScoreChallenge()': 'network',
                                      'fetchScores(detail:Bool,authenticatedBy:BITLoginAuthenticationChallenge)': 'network',
                                      'submitScoreSMSCode(:String,for:BITLoginAuthenticationChallenge)': 'network',
                                      'fetchTrustedTranscriptPages(onPage:TrustedTranscriptPageDelivery?)': 'network',
                                      'fetchTrustedTranscriptPages(authenticatedBy:BITLoginAuthenticationChallenge,onPage:TrustedTranscriptPageDelivery?)': 'network',
                                      'submitTranscriptSMSCode(:String,for:BITLoginAuthenticationChallenge)': 'network'}}



MANUAL_CAPABILITY_SCENARIOS = {
 'BIT101-iOS.BIT101APIClient': {
    'fetchSchoolLoginContext()': 'registered-account',
    'loginSchool(studentID:String,password:String,salt:String,execution:String)': 'registered-account',
    'webVPNVerifyInit(studentID:String)': 'registered-account',
    'webVPNVerify(studentID:String,password:String,execution:String,cookie:String,salt:String)': 'registered-account',
    'register(password:String,token:String,code:String,loginMode:Bool)': 'new-account-registration',
    'mailVerify(studentID:String)': 'new-account-registration',
    'loginCommunity(studentID:String,passwordDigest:String)': 'registered-account',
    'checkBIT101Login(fakeCookie:String)': 'sign-in-a'},
 'BIT101-iOS.FeedbackSubmissionClient': {'static submit(:Payload)': 'delivery'},
 'BIT101-iOS.NetworkDiagnosisRunner': {'run()': 'network-diagnosis'},
 'BIT101-iOS.AppUpdatePromptCoordinator': {'noticeToPresentAtLaunch()': 'update-launch', 'checkManually()': 'update-manual'},
 'BIT101-iOS.AppUpdateChecker': {'releaseToPresentAtLaunch()': 'update-launch', 'checkManually()': 'update-manual'},
 'BIT101-iOS.EmergencyUpdateChecker': {'noticeToPresentAtLaunch()': 'update-launch'},
 'BIT101-iOS.LoginService': {'login(studentID:String,password:String)': 'registered-account',
    'sendRegistrationEmail(studentID:String)': 'new-account-registration',
    'verifyRegistrationIdentity(studentID:String,password:String)': 'new-account-registration',
    'registerAccount(studentID:String,password:String,token:String,code:String,schoolPassword:String?)': 'new-account-registration',
    'renewCommunitySession(observed:CommunityCredentials)': 'refresh-credentials-a',
    'restoreCommunitySession(password:String)': 'community-reauthentication'},
 'BIT101-iOS.SettingsNetworkService': {'fetchMyInfo()': 'restore-profile',
    'updateUser(nickname:String?,motto:String?,avatarMid:String?)': 'nickname-save',
    'uploadAvatar(data:Data,filename:String)': 'avatar-bind', 'checkLogin()': 'sign-in-b'},
 'GalleryFeature.GalleryService': {'report(objectID:String,typeID:Int,text:String)': 'submit-and-confirm',
    'fetchMessages(type:GalleryMessageType,lastID:Int?)': 'first-open'},
 'GalleryFeature.GalleryWebCoordinator': {
    'start(in:WKWebView,url:URL)': 'gallery-account-switch',
    'webView(:WKWebView,didFinish:WKNavigation?)': 'gallery-login',
    'synchronizeCredentials(in:WKWebView)': 'gallery-sign-out',
    'webView(:WKWebView,didFail:WKNavigation?,withError:Error)': 'gallery-login',
    'webView(:WKWebView,didFailProvisionalNavigation:WKNavigation?,withError:Error)': 'gallery-login',
    'webViewWebContentProcessDidTerminate(:WKWebView)': 'gallery-login'},
 'ScheduleInfrastructure.ScheduleService': {
    'submitSMSCodeForTeachingCenterAuthentication(:String,for:BITLoginAuthenticationChallenge)': 'school-sms',
    'syncDDLEvents(existingEvents:[DDLEventRecord],storedURL:String,schoolSMSCodeHandler:SchoolSMSCodeHandler?,onSource:DDLSyncSourceDelivery?)': 'school-calendar',
    'refreshLexueCalendarURL(schoolSMSCodeHandler:SchoolSMSCodeHandler?)': 'school-calendar'},
}



def manual_capabilities(check: str, scenario: str) -> set[str]:
    return {f'{owner}.{method}' for owner, methods in MANUAL_CAPABILITY_SCENARIOS.items()
        for method, assigned in methods.items() if assigned == scenario
        and NETWORK_CAPABILITIES.get(owner, {}).get(method) == check}
