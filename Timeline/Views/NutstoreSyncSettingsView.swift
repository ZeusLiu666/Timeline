import SwiftUI

struct NutstoreSyncSettingsView: View {
    @EnvironmentObject private var store: TimelineStore
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    @FocusState private var passwordFocus: PasswordField?
    @State private var isSaving = false
    @State private var configurationError: String?

    private enum PasswordField: Hashable { case hidden, visible }

    private var isBusy: Bool { isSaving || store.nutstoreState.isSyncing }
    private var hasBoundAccount: Bool { !store.nutstoreUsername().isEmpty }
    private var canSave: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (store.nutstoreConfigured || !password.isEmpty)
            && !isBusy
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        if isBusy {
                            ProgressView().controlSize(.small).padding(.top, 3)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundStyle(TimelineTheme.muted).padding(.top, 3)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(store.nutstoreState.title).font(.headline)
                            Text(store.nutstoreState.detail)
                                .font(.callout).foregroundStyle(.secondary)
                            if let lastSync = store.nutstoreState.lastSync {
                                Text("上次同步：\(lastSync.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if store.nutstoreConfigured {
                        Button("立即同步") {
                            configurationError = nil
                            Task { await store.syncNutstore() }
                        }
                        .disabled(isBusy)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("仅在本机已保存内容较上次成功同步有变化时自动同步，自动同步间隔至少 24 小时。")
                        Text("自动同步仅在前台执行；到期时应用未打开，会在下次回到前台时检查。编辑草稿期间暂停。")
                        Text("点击同步不受 24 小时间隔限制。本机没有变化时，请手动同步以接收其他设备的更新。")
                    }
                }

                Section {
                    TextField("坚果云邮箱", text: $username)
                        .textContentType(.username)
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                        .disabled(hasBoundAccount)
                    passwordField
                    if let configurationError {
                        Label(configurationError, systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("保存并同步", action: saveConfiguration)
                        .disabled(!canSave)
                } header: {
                    Text("账户")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("请填写坚果云为第三方应用生成的应用密码。两端使用同一账户即可同步。")
                        Text("保存并同步会将本机记录与此账号的 Timeline 数据合并。")
                        if hasBoundAccount {
                            Text("如需更换账号，需先单独迁移数据；本页可更新应用密码。")
                        }
                    }
                }
                .disabled(isBusy)

                Section {
                    LabeledContent("服务地址", value: "https://dav.jianguoyun.com/dav/")
                    LabeledContent("同步文件夹", value: "TimelineSync-v1")
                } footer: {
                    Text("Timeline 会在专用文件夹中保存同步资料。请保留其中的文件。")
                }

                Section {
                    Link("如何获取坚果云应用密码", destination: URL(string: "https://help.jianguoyun.com/?p=2064")!)
                    if store.nutstoreConfigured {
                        Button("停用此设备的同步", role: .destructive) {
                            store.disableNutstore()
                            password = ""
                            configurationError = nil
                        }
                        .disabled(isBusy)
                    }
                } footer: {
                    Text("停用同步不会删除本机或云端的记录。")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("坚果云同步")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.disabled(isSaving)
                }
            }
        }
        .task { username = store.nutstoreUsername() }
        #if os(macOS)
        .frame(width: 490, height: 590)
        #endif
    }

    private var passwordField: some View {
        HStack(spacing: 8) {
            Group {
                if showPassword {
                    TextField(store.nutstoreConfigured ? "应用密码（留空保留）" : "应用密码", text: $password)
                        .textContentType(.password)
                        .focused($passwordFocus, equals: .visible)
                } else {
                    SecureField(store.nutstoreConfigured ? "应用密码（留空保留）" : "应用密码", text: $password)
                        .textContentType(.password)
                        .focused($passwordFocus, equals: .hidden)
                }
            }
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif

            Button {
                showPassword.toggle()
                let target: PasswordField = showPassword ? .visible : .hidden
                Task { @MainActor in
                    await Task.yield()
                    passwordFocus = target
                }
            } label: {
                Image(systemName: showPassword ? "eye.slash" : "eye")
                    .foregroundStyle(TimelineTheme.muted)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showPassword ? "隐藏密码" : "显示密码")
            .help(showPassword ? "隐藏密码" : "显示密码")
        }
    }

    private func saveConfiguration() {
        configurationError = nil
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            do {
                try await store.configureNutstore(
                    username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                    password: password
                )
                password = ""
            } catch {
                configurationError = error.localizedDescription
            }
        }
    }
}
