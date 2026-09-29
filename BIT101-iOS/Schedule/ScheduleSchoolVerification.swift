import DesignSystemKit
import SwiftUI

private struct ScheduleSchoolVerification: ViewModifier {
    @ObservedObject var viewModel: ScheduleDDLViewModel

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { viewModel.schoolSMSCodeRequest },
            set: { request in
                if request == nil { viewModel.dismissSchoolSMSCode() }
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
    func scheduleSchoolVerification(viewModel: ScheduleDDLViewModel) -> some View {
        modifier(ScheduleSchoolVerification(viewModel: viewModel))
    }
}
