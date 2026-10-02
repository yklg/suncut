import SwiftUI

struct SidebarView: View {
    @Bindable var projectVM: ProjectViewModel
    @Binding var selectedNavItem: NavigationItem?

    @State private var projectToDelete: Project?
    @State private var showSettings = false
    @State private var hoveredProject: UUID?
    @State private var hoveredNavItem: NavigationItem?
    @State private var isSettingsHovered = false
    @State private var hasAPIKey: Bool = true
    @State private var hasWhisperModel: Bool = true
    @State private var renamingProjectID: UUID?
    @State private var renameText: String = ""

    private var hasMissingDependency: Bool { !hasAPIKey || !hasWhisperModel }

    private var activeProjects: [Project] {
        projectVM.projects.filter { $0.status != .archived }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏（点击回 Welcome）
            Button {
                projectVM.selectedProject = nil
                selectedNavItem = nil
            } label: {
                HStack(spacing: DesignTokens.Spacing.compact) {
                    BrandLogo(size: 14)
                    Text(Brand.displayName)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("回到欢迎页")
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            // 内容列表
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.tight) {
                    // 项目区域（按产品分组：产品标题可折叠，项目缩进列其下）
                    sectionHeader("项目")
                        .padding(.top, 4)

                    ForEach(projectVM.sidebarGroups, id: \.productID) { group in
                        productGroupHeader(group)
                        if projectVM.isExpanded(group.productID) {
                            ForEach(group.projectIDs, id: \.self) { projectID in
                                if let project = projectVM.projects.first(where: { $0.id == projectID }) {
                                    projectRow(project)
                                        .padding(.leading, 16)
                                }
                            }
                        }
                    }

                    newProjectButton
                        .padding(.top, 2)

                    // 工作区
                    sectionHeader("工作区")
                        .padding(.top, 16)

                    ForEach(NavigationItem.allCases) { item in
                        navRow(item)
                    }
                    .opacity(projectVM.selectedProject == nil ? 0.35 : 1.0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            Divider()

            // 底部设置按钮
            Button {
                showSettings = true
            } label: {
                HStack(spacing: DesignTokens.Spacing.compact) {
                    Image(systemName: "gear")
                        .font(DesignTokens.Typography.label)
                        .frame(width: 20)
                    Text("设置")
                        .font(DesignTokens.Typography.label)
                    Spacer()
                    if hasMissingDependency {
                        // 未配置依赖时显示橙色感叹号
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(.orange)
                            .help(hasAPIKey ? "Whisper 语音模型未下载" : "AI API Key 未配置")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSettingsHovered ? Color.secondary.opacity(0.08) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .foregroundStyle(hasMissingDependency ? .secondary : .tertiary)
            .onHover { hovering in
                withAnimation(DesignTokens.Motion.hover) {
                    isSettingsHovered = hovering
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onAppear { refreshDependencyStatus() }
        .onChange(of: showSettings) { _, newValue in
            // Settings 关闭时重新检查
            if !newValue { refreshDependencyStatus() }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .sheet(isPresented: $projectVM.isCreatingProject) {
            NewProjectSheet(projectVM: projectVM)
        }
        .alert("确认删除项目", isPresented: Binding(
            get: { projectToDelete != nil },
            set: { if !$0 { projectToDelete = nil } }
        )) {
            Button("取消", role: .cancel) {
                projectToDelete = nil
            }
            Button("删除", role: .destructive) {
                if let project = projectToDelete {
                    if projectVM.selectedProject?.id == project.id {
                        selectedNavItem = .overview
                    }
                    projectVM.deleteProject(project)
                }
                projectToDelete = nil
            }
        } message: {
            if let project = projectToDelete {
                Text("将删除项目「\(project.name)」及其全部视频、分镜与方案。删除后 5 秒内可点「撤销」找回。")
            }
        }
    }

    /// 产品分组标题行：色点 + 产品名 + 项目数 + 折叠箭头
    @ViewBuilder
    private func productGroupHeader(_ group: SidebarProductGroup) -> some View {
        let product = projectVM.product(byID: group.productID)
        let expanded = projectVM.isExpanded(group.productID)
        Button {
            projectVM.toggleCollapsed(group.productID)
        } label: {
            HStack(spacing: 7) {
                ProductDot(product: product, size: 7)
                Text(product?.name ?? ProductCatalogDefaults.defaultProductName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("\(group.projectIDs.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(product?.name ?? ProductCatalogDefaults.defaultProductName)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(DesignTokens.Typography.microEmphasis)
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
    }

    private func projectRow(_ project: Project) -> some View {
        let isSelected = projectVM.selectedProject?.id == project.id
        let isHovered = hoveredProject == project.id
        let isRenaming = renamingProjectID == project.id
        return Button {
            if !isRenaming {
                projectVM.selectedProject = project
                if selectedNavItem == nil {
                    selectedNavItem = .overview
                }
            }
        } label: {
            HStack(spacing: DesignTokens.Spacing.compact) {
                Image(systemName: isSelected ? "film.fill" : "film")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                if isRenaming {
                    TextField("项目名", text: $renameText, onCommit: {
                        commitRename(project)
                    })
                    .font(DesignTokens.Typography.label)
                    .textFieldStyle(.plain)
                    .onExitCommand {
                        renamingProjectID = nil
                    }
                } else {
                    Text(project.name)
                        .font(DesignTokens.Typography.label)
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                }
                Spacer()
                if isSelected && !isRenaming {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) :
                          isHovered ? Color.secondary.opacity(0.06) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(DesignTokens.Motion.hover) {
                hoveredProject = hovering ? project.id : nil
            }
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                renameText = project.name
                renamingProjectID = project.id
            }
        )
        .contextMenu {
            // 归属信息（删除/重命名前确认是哪个产品的项目）
            HStack(spacing: 8) {
                ProductDot(product: project.product, size: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text("所属产品")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(project.product?.name ?? ProductCatalogDefaults.defaultProductName)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            Divider()
            Button("重命名") {
                renameText = project.name
                renamingProjectID = project.id
            }
            Divider()
            Button("删除", role: .destructive) {
                projectToDelete = project
            }
        }
    }

    private func commitRename(_ project: Project) {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != project.name {
            projectVM.renameProject(project, to: name)
            ToastCenter.shared.show("已重命名为「\(name)」", icon: "pencil")
        }
        renamingProjectID = nil
    }

    private func navRow(_ item: NavigationItem) -> some View {
        let isSelected = selectedNavItem == item && projectVM.selectedProject != nil
        let isHovered = hoveredNavItem == item
        let shortcut = shortcutHint(for: item)
        return Button {
            guard projectVM.selectedProject != nil else { return }
            withAnimation(DesignTokens.Motion.transition) {
                selectedNavItem = item
            }
        } label: {
            HStack(spacing: DesignTokens.Spacing.compact) {
                Image(systemName: item.icon)
                    .font(DesignTokens.Typography.label)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(item.rawValue)
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                Spacer()
                if isHovered, !shortcut.isEmpty {
                    Text(shortcut)
                        .font(DesignTokens.Typography.microMono)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) :
                          isHovered ? Color.secondary.opacity(0.06) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(DesignTokens.Motion.hover) {
                hoveredNavItem = hovering ? item : nil
            }
        }
        .disabled(projectVM.selectedProject == nil)
        .help(shortcut.isEmpty ? item.rawValue : "\(item.rawValue) (\(shortcut))")
    }

    private func refreshDependencyStatus() {
        hasAPIKey = KeychainHelper.hasAPIKey(for: KeychainHelper.activeProvider)
        hasWhisperModel = ASRService().isModelAvailable()
    }

    private func shortcutHint(for item: NavigationItem) -> String {
        switch item {
        case .overview:       return "⌘1"
        case .importMedia:    return "⌘2"
        case .segmentLibrary: return "⌘3"
        case .schemes:        return "⌘4"
        case .export:         return "⌘5"
        case .bgmLibrary:     return "⌘6"
        }
    }

    private var newProjectButton: some View {
        Button {
            projectVM.isCreatingProject = true
        } label: {
            HStack(spacing: DesignTokens.Spacing.compact) {
                Image(systemName: "plus.circle.fill")
                    .font(DesignTokens.Typography.label)
                    .frame(width: 18)
                Text("新建项目")
                    .font(DesignTokens.Typography.label)
                Spacer()
                Text("⌘N")
                    .font(DesignTokens.Typography.microMono)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor.opacity(0.8))
        .help("新建项目 (⌘N)")
    }
}

/// 新建项目弹窗
struct NewProjectSheet: View {
    @Bindable var projectVM: ProjectViewModel
    @Environment(\.dismiss) private var dismiss
    /// 产品行处于「输入新产品名」内联模式
    @State private var isCreatingProductInline = false
    /// 重名二次确认（使用已有 / 仍要创建）
    @State private var duplicateCandidate: Product?

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.generous) {
            VStack(spacing: 6) {
                Image(systemName: "film.stack.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.blue)
                Text("新建项目")
                    .font(DesignTokens.Typography.title)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("项目名称")
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(.secondary)
                TextField("输入项目名称", text: $projectVM.newProjectName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                    .onSubmit { submit() }
            }

            // 产品归属行：Menu 选已有产品，或内联当场新建
            VStack(alignment: .leading, spacing: 6) {
                Text("所属产品")
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(.secondary)
                if isCreatingProductInline {
                    HStack {
                        TextField("新产品名称", text: $projectVM.newProductName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 224)
                        Button("取消") {
                            projectVM.newProductName = ""
                            isCreatingProductInline = false
                        }
                        .buttonStyle(.borderless)
                    }
                    .frame(width: 300, alignment: .leading)
                    if let dup = duplicateCandidate {
                        HStack(spacing: 6) {
                            Text("已存在同名产品「\(dup.name)」")
                                .font(DesignTokens.Typography.microRegular)
                                .foregroundStyle(.orange)
                            Button("使用已有") {
                                projectVM.newProductName = ""
                                projectVM.newProjectProductID = dup.id
                                duplicateCandidate = nil
                                isCreatingProductInline = false
                            }
                            .buttonStyle(.borderless)
                            .font(DesignTokens.Typography.micro)
                            Text("·")
                            Button("仍要创建") {
                                // 用户明确拍板：允许重名（菜单用「名称 · N 个项目」消歧）
                                duplicateCandidate = nil
                                submit(forceNewProduct: true)
                            }
                            .buttonStyle(.borderless)
                            .font(DesignTokens.Typography.micro)
                        }
                    }
                } else if let current = projectVM.effectiveNewProjectProduct {
                    HStack(spacing: 8) {
                        Menu {
                            ForEach(projectVM.products) { product in
                                Button {
                                    projectVM.newProjectProductID = product.id
                                } label: {
                                    Label(product.name,
                                          systemImage: product.id == current.id ? "checkmark" : "")
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(current.name)
                                    .lineLimit(1)
                                Text("· \(projectVM.projectCountByProduct[current.id] ?? 0) 个项目")
                                    .font(DesignTokens.Typography.microRegular)
                                    .foregroundStyle(.tertiary)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .frame(width: 224)
                            .background(Color.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .menuIndicator(.hidden)
                        .fixedSize()

                        Button {
                            projectVM.newProductName = ""
                            duplicateCandidate = nil
                            isCreatingProductInline = true
                        } label: {
                            Label("新产品", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                        .font(DesignTokens.Typography.micro)
                    }
                    .frame(width: 300, alignment: .leading)
                }
            }

            HStack(spacing: DesignTokens.Spacing.normal) {
                Button("取消") {
                    projectVM.newProjectName = ""
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button { submit() } label: {
                    HStack(spacing: DesignTokens.Spacing.tight) {
                        Image(systemName: "plus")
                            .font(DesignTokens.Typography.caption)
                        Text("创建")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(projectVM.newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(28)
        .onAppear {
            // 首次展示先确保默认产品存在（backfill 已做一层，这是 UI 期兜底），并初始化选中态。
            projectVM.ensureDefaultProduct()
            if projectVM.newProjectProductID == nil {
                projectVM.newProjectProductID = projectVM.effectiveNewProjectProduct?.id
            }
        }
    }

    /// 提交创建；内联新产品名遇重名时先停下让用户拍板，不静默合并。
    private func submit(forceNewProduct: Bool = false) {
        guard !projectVM.newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if isCreatingProductInline && !forceNewProduct {
            let trimmed = projectVM.newProductName.trimmingCharacters(in: .whitespacesAndNewlines)
            if let dup = projectVM.product(named: trimmed), duplicateCandidate == nil {
                duplicateCandidate = dup
                return
            }
        }
        projectVM.createProject()
        dismiss()
    }
}
