#if os(iOS)
import ClientCore
import DesignSystemKit
import SwiftUI

private struct ScheduleSchoolVerification: ViewModifier {
    @ObservedObject var viewModel: ScheduleDDLViewModel
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { isEnabled ? viewModel.schoolSMSCodeRequest : nil },
            set: { request in
                if isEnabled, request == nil { viewModel.dismissSchoolSMSCode() }
            }
        )) { request in
            AppSchoolSMSVerificationSheet(
                maskedPhone: request.maskedPhone,
                onCancel: viewModel.dismissSchoolSMSCode,
                onSubmit: viewModel.submitSchoolSMSCode
            )
        }
    }
}

extension View {
    public func scheduleSchoolVerification(viewModel: ScheduleDDLViewModel, isEnabled: Bool = true) -> some View {
        modifier(ScheduleSchoolVerification(viewModel: viewModel, isEnabled: isEnabled))
    }
}

#endif
